-- harness.lua: run a norns script under the REAL norns core Lua.
--   lua ~/.claude/skills/norns-script/harness.lua path/to/script.lua [iterations]
-- Needs a monome/norns checkout; set NORNS_LUA=/path/to/norns/lua to override.
-- Real paramset/controlspec/util catch calls to methods that do not exist
-- (e.g. params:set_formatter). C bindings and I/O are stubbed.

local script = arg[1] or error("usage: lua harness.lua script.lua [iterations]")
local iters = tonumber(arg[2]) or 500
local home = os.getenv("HOME")
local core = os.getenv("NORNS_LUA")
if not core then
  for _, c in ipairs{home.."/code/norns/norns/lua", home.."/norns/lua", home.."/personal/norns/lua"} do
    local f = io.open(c.."/core/paramset.lua"); if f then f:close(); core = c; break end
  end
end
assert(core, "no norns checkout found; git clone https://github.com/monome/norns and set NORNS_LUA")
package.path = core.."/?.lua;"..core.."/lib/?.lua;"..package.path

-- norns runs Lua 5.3; newer system luas dropped these
math.pow = math.pow or function(a, b) return a ^ b end
math.log10 = math.log10 or function(x) return math.log(x, 10) end

local function stub(name)
  return setmetatable({}, {__index = function(_, k) return function() end end})
end
_norns = setmetatable({}, {__index = function(_, k)
  if k == "get_time" then return function() return _G.SIMT or 0, 0 end end
  -- util.scandir/os_capture expect a string back (fileselect, textentry)
  if k == "execute" then return function(cmd)
    local h = io.popen(cmd .. " 2>/dev/null"); local out = h:read("a") or ""; h:close(); return out
  end end
  return function() return 0 end
end})
_menu = {rebuild_params = function() end, mode = false,
         binarystates = {on = {}, triggered = {}}}
norns = {
  state = {shortname = "harness", name = "harness", data = "/tmp/", pset_last = 1,
           mix = {monitor = 0, output = 0, input = 0}},
  pmap = {data = {}},
  -- fileselect/textentry/listselect call these when they take over the screen
  menu = {status = function() return false end, init = function() end,
          set = function() end, get_key = function() end, get_enc = function() end,
          get_redraw = function() end, get_refresh = function() end},
  system_cmd = function() end, script = {}, version = {update = "0"},
  none = function() end,  -- fileselect/textentry swap redraw for norns.none
}
_path = {data = "/tmp/", code = "/tmp/", audio = "/tmp/", dust = "/tmp/"}
util = require 'lib/util'
tab = require 'lib/tabutil'
controlspec = require 'core/controlspec'
paramset = require 'core/paramset'
params = paramset.new()
-- system params every script can read (mix menu); real norns adds these in core/menu
for _, id in ipairs{"output_level", "input_level", "monitor_level", "headphone_gain",
                    "rev_eng_input", "rev_cut_input", "rev_monitor_input",
                    "rev_tape_input", "rev_return_level", "comp_mix"} do
  params:add_control(id, id, controlspec.new(-math.huge, 60, 'lin', 0, 0, "dB"))
end
params:add_option("monitor_mode", "monitor mode", {"STEREO", "MONO"}, 1)
params:add_option("reverb", "reverb", {"OFF", "ON"}, 1)
params:add_option("compressor", "compressor", {"OFF", "ON"}, 1)
params:add_number("clock_tempo", "clock tempo", 1, 300, 120)
screen = stub("screen")
engine = stub("engine")
audio = stub("audio")
SC = {ls={},le={},rate={},pos={},rec={},phase=nil}
softcut = setmetatable({
  loop_start=function(v,x) SC.ls[v]=x end, loop_end=function(v,x) SC.le[v]=x end,
  rate=function(v,x) SC.rate[v]=x end, position=function(v,x) SC.pos[v]=x; if v==1 then SC.jumps=(SC.jumps or 0)+1 end end,
  rec=function(v,x) SC.rec[v]=x end, event_phase=function(f) SC.phase=f end,
}, {__index=function() return function() end end})
local T=0
_norns_time=function() return T end
metro = {init = function() return {start = function() end, stop = function() end} end}
clock = {run = function() return 1 end, cancel = function() end, sleep = function() end,
         sync = function() end, get_beat_sec = function() return 0.5 end,
         get_tempo = function() return 120 end, get_beats = function() return 0 end}
local dev = function() return setmetatable({}, {__index = function() return function() end end}) end
midi = {connect = dev, vports = {}, to_msg = function() return {} end, devices = {}}
grid = {connect = dev, vports = {}}
arc = {connect = dev, vports = {}}
keyboard = {}
crow = stub("crow")
-- engine polls: poll.set(name, cb) returns an object with .time, :start(), :stop()
poll = {set = function(name, cb)
  return {time = 0, callback = cb, start = function() end, stop = function() end,
          update = function() end}
end, list_names = function() end}

local src = assert(io.open(script)):read("a")
src = src:gsub("engine%.name%s*=%s*['\"][^'\"]*['\"]", "")
assert(load(src, "@"..script))()

print("init...")
init()
print("redraw...")
redraw()
print("gestures x"..iters.."...")
for i = 1, iters do
  enc(1, (i % 3) - 1); enc(2, (i % 7) - 3); enc(3, (i % 5) - 2)
  key(2, 1); enc(2, 1); enc(3, -1); key(3, 1); key(3, 0); key(2, 0)
  key(3, 1); key(3, 0)
  if enc then enc(1, -1) end
  redraw()
end

-- playhead sim
SIMT = 0
local function tick(n)
  local starts = {(SC.ls[1]-1)/12 + 1}
  for _=1,n do
    SIMT = SIMT + 0.01
    local v=1
    local ls, le, r = SC.ls[1], SC.le[1], SC.rate[1]
    local before = SC.jumps
    local p = SC.pos[1] + r*0.01
    if p >= le then p = ls + (p-le) elseif p < ls then p = le - (ls-p) end
    SC.pos[1] = p
    SC.phase(1, p)
    assert(SC.le[1]-SC.ls[1] >= 0.049 and SC.le[1]-SC.ls[1] <= 11.5+1e-9, "len "..(SC.le[1]-SC.ls[1]))
    local slot = (SC.ls[1]-1)/12 + 1
    assert(slot == math.floor(slot) and slot>=1 and slot<=5, "slot "..slot)
    if SC.jumps ~= before then starts[#starts+1]=slot end
  end
  return starts
end
params:set("playing",1)
for _,mode in ipairs{1,2} do
 params:set("size_mode", mode)
 for _, seed in ipairs{1, 42, 777, 9999, 1234, 5} do
  params:set("rev_prob", seed % 3 == 0 and 50 or 0)
  params:set("seed", seed)
  local a = tick(6000)
  params:set("seed", seed + 1); tick(3000)
  params:set("seed", seed)
  local b = tick(6000)
  -- after a reseed, order restarts at the next boundary: compare from b[2] with a[2]
  local n = math.min(#a, #b) - 2
  assert(n > 4, "too few steps "..n)
  local ok=false
  for _,oa in ipairs{1,2} do for _,ob in ipairs{1,2} do
    local m=true
    for i=2,n do if a[i+oa-1]~=b[i+ob-1] then m=false break end end
    ok = ok or m
  end end
  assert(ok, "nondeterministic seed "..seed)
  local distinct = {}
  for _,s in ipairs(a) do distinct[s]=true end
  local c=0 for _ in pairs(distinct) do c=c+1 end
  assert(c>=2, "only one slot played")
  print("mode "..mode.." seed "..seed.." steps "..#a.." distinct "..c)
 end
end
-- size control
params:set("size_mode",1); params:set("size_sec", 2.5); tick(500)
assert(math.abs(SC.le[1]-SC.ls[1]-2.5)<1e-9, "fixed size")
params:set("pitch", 7); tick(500); assert(math.abs(math.abs(SC.rate[1]) - 2^(7/12))<1e-9)
params:set("pitch", 1); assert(params:get("pitch")==0, "pitch snap "..params:get("pitch"))
params:set("seed", 4321); params:set("size_sec", 3); params:set("mix", 0.6)
local hist = params:get("history")
params:write("/tmp/nf_test.pset")
params:set("seed", 11); params:set("size_sec", 0); params:set("mix", 0.1); params:set("history","1,2")
params:read("/tmp/nf_test.pset")
assert(params:get("seed")==4321 and params:get("size_sec")==3 and math.abs(params:get("mix")-0.6)<1e-6, "pset")
print("history", hist, "->", params:get("history"))
os.remove("/tmp/nf_test.pset")
print("SIM PASS")
if cleanup then cleanup() end
print("PASS")
