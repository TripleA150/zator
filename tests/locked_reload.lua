-- Перечитывание lock-файлов внутри TTL по stat(). Run from repository root:
--   lua tests/locked_reload.lua   (Lua 5.1+; пишет только во временный каталог)
local G = _G
local dir = os.tmpname()
os.remove(dir)
assert(os.execute("mkdir -p " .. dir))

local T = 1800000000
os.time = function() return T end
G.DLOG = function() end

-- Те же подстановки путей, что делает lib/supersweep_probe.sh через sed.
local f = assert(io.open("orchestra/locked.lua"))
local src = "\n" .. f:read("*a")
f:close()
local n1, n2
src, n1 = src:gsub('\nlocal LOCKED_PATH = "[^"]*"', '\nlocal LOCKED_PATH = "' .. dir .. '/locked.tsv"')
src, n2 = src:gsub('\nlocal LOCKED_MANUAL_PATH = "[^"]*"', '\nlocal LOCKED_MANUAL_PATH = "' .. dir .. '/locked.manual.tsv"')
assert(n1 == 1 and n2 == 1, "supersweep_probe.sh sed anchors must still match locked.lua")
assert((loadstring or load)(src))()

local function write(name, text)
  local h = assert(io.open(dir .. "/" .. name, "w"))
  h:write(text)
  h:close()
end

-- stat-заглушка: подпись файла задаёт тест (mv писателя = новый inode).
local sigs, stat_calls = {}, 0
local function fake_stat(path)
  stat_calls = stat_calls + 1
  local s = sigs[path]
  if not s then return nil, "No such file or directory", 2 end
  return { type = "file", mtime = s.mtime, size = s.size, inode = s.inode, dev = 1 }
end
local function mv(name, text, inode)
  write(name, text)
  sigs[dir .. "/" .. name] = { mtime = T + inode / 10, size = #text, inode = inode }
end

-- 1. stat есть: замена файла внутри TTL подхватывается сразу.
G.stat = fake_stat
mv("locked.tsv", "3\ttls\t5\n", 1)
assert(G.locked_strategy_for_profile("3", "tls") == 5, "initial load")
mv("locked.tsv", "3\ttls\t7\n", 2)
assert(G.locked_strategy_for_profile("3", "tls") == 7, "changed lock file must reload inside the TTL")
-- ручной файл появился (профиль 9 живёт в locked.manual.tsv)
mv("locked.manual.tsv", "9\thttp\t4\n", 3)
assert(G.locked_strategy_for_profile("9", "http") == 4, "new manual lock file must reload inside the TTL")

-- 2. подпись не изменилась — не перечитываем (содержимое подменено в обход mv).
write("locked.tsv", "3\ttls\t9\n")
stat_calls = 0
assert(G.locked_strategy_for_profile("3", "tls") == 7, "unchanged signature must not reload")
assert(stat_calls == 2, "one check is exactly two stat calls, got " .. stat_calls)

-- 3. circular_locked: stat только на первом вызове соединения, родители без stat.
G.VERDICT_PASS = 0
G.orchestrate = function() end
G.standard_hostkey = function() return true end
G.plan_instance_pop = function(desync) return table.remove(desync.plan, 1) end
local picked
G.plan_instance_execute = function(_, verdict, instance)
  picked = tonumber(instance.arg.strategy)
  return verdict
end
mv("locked.tsv", "example.com\ttls\t2\n", 4)
local track = { lua_state = {} }
local function run()
  picked = nil
  G.circular_locked({}, { hostname = "a.b.example.com", profile = "3", track = track, arg = {},
    plan = { { arg = { strategy = 1 } }, { arg = { strategy = 2 } } } })
  return picked
end
stat_calls = 0
assert(run() == 2, "parent domain lock must apply after reload")
assert(stat_calls == 2, "circular_locked must stat at most twice per invocation, got " .. stat_calls)
mv("locked.tsv", "example.com\ttls\t1\n", 5)
stat_calls = 0
assert(run() == 2 and stat_calls == 0, "same connection must keep TTL behaviour without stat")
track = { lua_state = {} }
assert(run() == 1, "new connection must see the replaced lock file")

-- 4. stat нет: прежнее поведение TTL.
G.stat = nil
T = T + 10
write("locked.tsv", "3\ttls\t5\n")
assert(G.locked_strategy_for_profile("3", "tls") == 5, "TTL expiry reloads")
write("locked.tsv", "3\ttls\t6\n")
T = T + 1
assert(G.locked_strategy_for_profile("3", "tls") == 5, "without stat a change inside the TTL is not seen")
T = T + 1
assert(G.locked_strategy_for_profile("3", "tls") == 6, "without stat the TTL expiry reloads")

os.execute("rm -rf " .. dir)
print("locked reload ok")
