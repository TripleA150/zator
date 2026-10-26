-- auto_locked.tsv persistence regression. Run from repository root:
--   lua tests/slm_auto_locked_backup.lua   (Lua 5.1+; writes only to a temp dir)
local dir = os.tmpname()
os.remove(dir)
assert(os.execute("mkdir -p " .. dir))
local T = 1800000000
os.time = function() return T end
DLOG = function() end
local f = assert(io.open("lua/strategy-lock-manager.lua"))
local src = f:read("*a")
f:close()
src = src:gsub('local SLM_AUTO_LOCKED_PATH = "[^"]*"', 'local SLM_AUTO_LOCKED_PATH = "' .. dir .. '/active.tsv"')
src = src:gsub('local SLM_AUTO_LOCKED_BACKUP_PATH = "[^"]*"', 'local SLM_AUTO_LOCKED_BACKUP_PATH = "' .. dir .. '/backup.tsv"')
assert((loadstring or load)(src))()

local function read(name)
  local h = io.open(dir .. "/" .. name)
  if not h then return nil end
  local s = h:read("*a")
  h:close()
  return s
end

-- Последние изменения внутри интервала бэкапа доходят до /opt без новых изменений.
slm_commit_auto_lock("3", "a.example.com", 5)
T = T + 300
slm_commit_auto_lock("3", "b.example.com", 6)
T = T + 300
slm_reset("3", "a.example.com")
assert(read("backup.tsv") == "3\ta.example.com\t5\n", "change inside the interval must not be backed up at once")
slm_get_locked("3", "x.example.com")
assert(read("backup.tsv") == "3\ta.example.com\t5\n", "flush must wait for the interval")
T = T + 1800
slm_get_locked("3", "x.example.com")
assert(read("backup.tsv") == "3\tb.example.com\t6\n", "pending changes must be flushed after the interval")

-- ENOSPC: пустой/обрезанный tmp не должен подменять рабочий файл.
local full = io.open("/dev/full", "w")
if full then
  full:close()
  os.execute("ln -sf /dev/full " .. dir .. "/active.tsv.tmp")
  slm_commit_auto_lock("3", "c.example.com", 7)
  assert(read("active.tsv") == "3\tb.example.com\t6\n", "failed write must keep the previous active file")
end

os.execute("rm -rf " .. dir)
print("slm auto_locked backup ok")
