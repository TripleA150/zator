-- Сид новых хостов и порядок авторотации по соседям. Run from repository root:
--   lua tests/slm_seed_rotation.lua   (Lua 5.1+; ничего не пишет на диск)
local G = _G
G.DLOG = function() end
G.DLOG_ERR = function() end
G.bitand = function(a, b)
  local result, bit = 0, 1
  while a > 0 and b > 0 do
    if a % 2 == 1 and b % 2 == 1 then result = result + bit end
    a, b, bit = math.floor(a / 2), math.floor(b / 2), bit * 2
  end
  return result
end
G.TH_RST = 0x04

-- Порядок --lua-init из config.default: locked.lua раньше SLM и детектора.
dofile("orchestra/locked.lua")
G.io = { open = function(_, mode)
  if mode == "r" then return nil end
  return { write = function() return true end, close = function() return true end }
end }
G.os = { time = os.time, date = os.date, rename = function() return true end, remove = function() end }
G.BLOCKED_STRATEGIES = {}
dofile("lua/strategy-lock-manager.lua")
dofile("lua/combined-detector.lua")

local function eq(actual, expected, message)
  assert(actual == expected, message .. ": got " .. tostring(actual) .. ", expected " .. tostring(expected))
end
local function order_str(order)
  return table.concat(order, ",")
end

-- ===== seed =====
G.locked_load_lines_for_tests({ "3\ttls\t7", "4\ttls\t0", "9\thttp\t30", "example.com\ttls\t5" })
eq(G.slm_seed_strategy("3", "default", 10, "tls", "new.example"), 7, "profile lock seeds a new host")
eq(G.slm_seed_strategy("3", "mark:1", 10, "tls", "new.example"), 7, "scoped seed falls back to the default profile row")
eq(G.slm_seed_strategy("4", "default", 10, "tls", "new.example"), 1, "lock 0 is not a seed")
eq(G.slm_seed_strategy("9", "default", 8, "http", "new.example"), 1, "out-of-range profile lock is ignored")
eq(G.slm_seed_strategy("example.com", "default", 10, "tls", "x"), 5, "only the askey row is consulted")
G.slm_preload_blocked("3", "blocked.example", { 7 })
eq(G.slm_seed_strategy("3", "default", 10, "tls", "blocked.example"), 1, "blocked profile lock is skipped")

G.locked_load_lines_for_tests({})
G.slm_commit_auto_lock("3", "a.example", 4)
eq(G.slm_seed_strategy("3", "default", 10, "tls", "new.example"), 1, "a single sibling is not evidence")
G.slm_commit_auto_lock("3", "b.example", 4)
G.slm_commit_auto_lock("3", "c.example", 6)
eq(G.slm_seed_strategy("3", "default", 10, "tls", "new.example"), 4, "popular sibling strategy seeds")
eq(G.slm_seed_strategy("3", "mark:1", 10, "tls", "new.example"), 1, "siblings of another scope are not evidence")
G.slm_commit_auto_lock("3", "d.example", 2)
G.slm_commit_auto_lock("3", "e.example", 2)
eq(G.slm_seed_strategy("3", "default", 10, "tls", "new.example"), 2, "tie picks the lower number")
G.slm_preload_blocked("3", "picky.example", { 2 })
eq(G.slm_seed_strategy("3", "default", 10, "tls", "picky.example"), 4, "blocked popular strategy is skipped")
G.locked_load_lines_for_tests({ "3\ttls\t9" })
eq(G.slm_seed_strategy("3", "default", 10, "tls", "new.example"), 9, "profile lock beats siblings")
G.locked_load_lines_for_tests({})

-- ===== order cache =====
local order1 = G.slm_rotation_order("3", "default", 10)
eq(order_str(order1), "2,4,6,1,3,5,7,8,9,10", "popular first, then the rest ascending")
assert(G.slm_rotation_order("3", "default", 10) == order1, "unchanged version must reuse the cached order")
G.slm_commit_auto_lock("3", "f.example", 6)
G.slm_commit_auto_lock("3", "g.example", 6)
local order2 = G.slm_rotation_order("3", "default", 10)
assert(order2 ~= order1, "version bump must rebuild the order")
eq(order_str(order2), "6,2,4,1,3,5,7,8,9,10", "rebuilt order reflects new locks")
G.slm_reset("3", "f.example")
G.slm_reset("3", "g.example")
eq(order_str(G.slm_rotation_order("3", "default", 10)), "2,4,6,1,3,5,7,8,9,10", "clearing auto locks bumps the version")

-- ===== rotation =====
G.slm_preload_blocked("3", "rot.example", { 1 })
local hrec = {}
local function nxt(cur) return G.slm_rotation_next("3", "default", cur, 10, hrec, "rot.example") end
eq(nxt(2), 4, "rotation follows the cached order")
eq(nxt(4), 6, "next popular")
eq(nxt(6), 3, "blocked strategy 1 is skipped")
local s = 3
for _ = 1, 5 do s = nxt(s) end
eq(s, 10, "walks the tail of the order")
eq(nxt(10), 2, "all tried: a new cycle starts after the current strategy (wrap)")
assert(hrec.slm_tried[10] and not hrec.slm_tried[4], "new cycle keeps only the current strategy marked")
hrec = { slm_tried = { [4] = true, [6] = true } }
eq(nxt(2), 3, "already tried strategies are skipped")
G.slm_preload_blocked("3", "dead.example", { 1, 2, 3 })
eq(G.slm_rotation_next("3", "default", 2, 3, {}, "dead.example"), 2, "everything blocked keeps the current strategy")

-- ===== circular_quality wiring: seed and rotation =====
G.orchestrate = function() end
G.automate_host_record = function(desync) return desync._hrec end
G.automate_conn_record = function(desync) return desync._crec end
G.standard_hostkey = function() return "wire.example" end
G.hostlist_has_host = function() return false end
local fail_now = false
G.wire_failure = function() return fail_now end
G.wire_success = function() return false end
G.automate_failure_counter = function() return true end
G.automate_failure_counter_reset = function() end
G.plan_instance_pop = function() return nil end
local plan = {}
for i = 1, 10 do plan[i] = { arg = { strategy = i } } end
local desync = {
  arg = { key = "3", failure_detector = "wire_failure", success_detector = "wire_success" },
  plan = plan, track = { hostname = "wire.example" }, _hrec = {}, _crec = {},
}
G.circular_quality(nil, desync)
eq(desync._hrec.nstrategy, 2, "new host starts from the sibling seed")
fail_now = true
desync._crec = { strategy = 2 }
G.circular_quality(nil, desync)
eq(desync._hrec.nstrategy, 4, "failure rotates along the sibling order")

G.locked_load_lines_for_tests({ "3\ttls\t8" })
desync._hrec, desync._crec, fail_now = {}, {}, false
G.circular_quality(nil, desync)
eq(desync._hrec.nstrategy, 8, "new host starts from the profile lock")

print("slm seed rotation ok")
