-- no friends
-- seeded cut-up looper
--
-- E1 keep (mix)
-- E2 pitch (locked)
-- E3 size (0 = seed)
-- K2 record
-- K3 reroll order
-- hold K3: E3 history, K2 clear slot

local REGION = 12        -- seconds of buffer reserved per slot
local OFFSET = 1         -- pad before slot 1
local MAX_SLOTS = 5
local MAX_LEN = REGION - 0.5
local MAX_STEPS = 16
local HIST_MAX = 16
local QUANT = 0.01

local INTERVAL_SETS = {
  {name = "octaves", st = {-24, -12, 0, 12, 24}},
  {name = "oct+5ths", st = {-24, -19, -12, -7, 0, 7, 12, 19, 24}},
  {name = "oct+5+4", st = {-24, -19, -17, -12, -7, -5, 0, 5, 7, 12, 17, 19, 24}},
}
local INTERVAL_NAMES = {[0] = "unison", [5] = "4th", [7] = "5th", [12] = "oct",
  [17] = "oct+4th", [19] = "oct+5th", [24] = "2 oct"}

local BEATS = {0.5, 1, 2, 3, 4, 6, 8}
local BEAT_NAMES = {"1/2", "1", "2", "3", "4", "6", "8"}

-- state
local ready = false
local playing = true
local recording = false
local slot_u = {}        -- seeded 0..1 per slot, mapped to a length
local order = {}         -- slot index per step
local rev = {}           -- reverse flag per step
local rev_u = {}         -- seeded 0..1 per step
local n_slots = 2
local step = 1
local cur_slot = 1
local cur_dir = 1
local cur_pos = OFFSET
local last_pos = OFFSET
local last_jump = 0
local restart_pending = false
local history = {}
local hist_pos = 0
local k3_held = false
local k3_used = false
local frame = 0
local redraw_metro

-- seeded prng (lcg), independent of math.random
local M = 2147483648
local function make_rng(seed, salt)
  local s = (math.floor(seed) * 7919 + salt * 104729) % M
  local function nxt()
    s = (s * 1103515245 + 12345) % M
    return s / M
  end
  for _ = 1, 8 do nxt() end
  return nxt
end

local function rint(rnd, a, b)
  return a + math.floor(rnd() * (b - a + 1))
end

-- lengths

local function slot_start(i)
  return OFFSET + (i - 1) * REGION
end

local function beat_len(b)
  return util.clamp(b * clock.get_beat_sec(), 0.05, MAX_LEN)
end

local function slot_len(i)
  if params:string("size_mode") == "beats" then
    local sb = params:get("size_beats")
    if sb > 1 then return beat_len(BEATS[sb - 1]) end
    local idx = math.floor(slot_u[i] * #BEATS) + 1
    return beat_len(BEATS[idx])
  end
  local size = params:get("size_sec")
  if size > 0 then return util.clamp(size, 0.05, MAX_LEN) end
  local lo, hi = params:get("len_min"), params:get("len_max")
  if lo > hi then lo, hi = hi, lo end
  return util.clamp(lo + slot_u[i] * (hi - lo), 0.05, MAX_LEN)
end

local function ratio()
  return 2 ^ (params:get("pitch") / 12)
end

-- playback

local function goto_step(i)
  step = i
  cur_slot = order[i]
  cur_dir = rev[i] and -1 or 1
  local s = slot_start(cur_slot)
  local e = s + slot_len(cur_slot)
  local p = cur_dir > 0 and s or (e - QUANT)
  for v = 1, 2 do
    softcut.rate_slew_time(v, 0)
    softcut.loop_start(v, s)
    softcut.loop_end(v, e)
    softcut.rate(v, cur_dir * ratio())
    softcut.position(v, p)
  end
  cur_pos, last_pos = p, p
  last_jump = util.time()
end

local function advance()
  if restart_pending then
    restart_pending = false
    goto_step(1)
  else
    goto_step(step % #order + 1)
  end
end

local function on_phase(v, pos)
  if v ~= 1 or not playing then return end
  local s = slot_start(cur_slot)
  local e = s + slot_len(cur_slot)
  -- stale reports from the previous slot
  if pos < s - 0.05 or pos > e + 0.05 then return end
  if util.time() - last_jump < 0.03 then return end
  cur_pos = pos
  if cur_dir > 0 then
    if pos >= e - 1.5 * QUANT or pos < last_pos - 0.001 then advance() return end
  else
    if pos <= s + 1.5 * QUANT or pos > last_pos + 0.001 then advance() return end
  end
  last_pos = pos
end

-- refresh loop points of the playing slot after a size change
local function apply_lengths()
  if not ready then return end
  local s = slot_start(cur_slot)
  local e = s + slot_len(cur_slot)
  for v = 1, 2 do softcut.loop_end(v, e) end
  if cur_pos >= e then advance() end
end

local function apply_rate()
  if not ready then return end
  for v = 1, 2 do
    softcut.rate_slew_time(v, params:get("glide"))
    softcut.rate(v, cur_dir * ratio())
  end
end

local function apply_rec()
  for v = 1, 2 do
    softcut.pre_level(v, recording and params:get("mix") or 1)
    softcut.rec_level(v, params:get("rec_level"))
    softcut.rec(v, (recording and playing) and 1 or 0)
  end
end

local function set_playing(on)
  playing = on
  if not ready then return end
  for v = 1, 2 do softcut.play(v, on and 1 or 0) end
  if on then goto_step(1) else recording = false end
  apply_rec()
end

-- generation

local function regenerate()
  if not ready then return end
  local seed = params:get("seed")
  local count_rng = make_rng(seed, 1)
  local len_rng = make_rng(seed, 2)
  local order_rng = make_rng(seed, 3)
  local rev_rng = make_rng(seed, 4)

  local sp = params:get("slots")
  n_slots = sp == 1 and rint(count_rng, 2, MAX_SLOTS) or sp

  for i = 1, MAX_SLOTS do slot_u[i] = len_rng() end
  for i = 1, MAX_STEPS do rev_u[i] = rev_rng() end

  local len = math.max(params:get("seq_len"), n_slots)
  order = {}
  for i = 1, len do
    local pick
    repeat
      pick = rint(order_rng, 1, n_slots)
    until pick ~= order[i - 1] and (i < len or pick ~= order[1] or len == 1)
    order[i] = pick
  end
  -- every slot must appear at least once, or it can never be heard/recorded.
  -- a missing slot cannot neighbour itself, so swap it in for any duplicate.
  for sl = 1, n_slots do
    local seen = false
    for i = 1, len do if order[i] == sl then seen = true break end end
    if not seen then
      local counts = {}
      for i = 1, len do counts[order[i]] = (counts[order[i]] or 0) + 1 end
      for i = 1, len do
        if counts[order[i]] > 1 then order[i] = sl break end
      end
    end
  end

  local prob = params:get("rev_prob") / 100
  for i = 1, len do rev[i] = rev_u[i] < prob end
  for i = len + 1, MAX_STEPS do rev[i] = nil end

  restart_pending = true
  if step > #order then step = #order end
  apply_lengths()
end

-- seed history

local function history_save()
  local t = {}
  for i, s in ipairs(history) do t[i] = tostring(s) end
  params:set("history", table.concat(t, ","), true)
end

local function history_load()
  history = {}
  for s in string.gmatch(params:get("history") or "", "%d+") do
    history[#history + 1] = tonumber(s)
  end
  local seed = params:get("seed")
  hist_pos = 0
  for i, s in ipairs(history) do if s == seed then hist_pos = i end end
  if hist_pos == 0 then
    history[#history + 1] = seed
    while #history > HIST_MAX do table.remove(history, 1) end
    hist_pos = #history
    history_save()
  end
end

local function history_push(seed)
  -- drop anything after the current position, like browser history
  while #history > hist_pos do table.remove(history) end
  history[#history + 1] = seed
  while #history > HIST_MAX do table.remove(history, 1) end
  hist_pos = #history
  history_save()
end

local function reroll()
  local seed
  repeat seed = math.random(1, 9999) until seed ~= params:get("seed")
  history_push(seed)
  params:set("seed", seed)
end

local function history_step(d)
  if #history == 0 then return end
  hist_pos = util.clamp(hist_pos + d, 1, #history)
  params:set("seed", history[hist_pos])
end

local function clear_slot()
  softcut.buffer_clear_region(slot_start(cur_slot), REGION - 0.5, 0.01, 0)
end

-- pitch

local function interval_set()
  return INTERVAL_SETS[params:get("interval_set")].st
end

local function nearest_index(set, st)
  local best, bi = math.huge, 1
  for i, v in ipairs(set) do
    if math.abs(v - st) < best then best, bi = math.abs(v - st), i end
  end
  return bi
end

local function pitch_delta(d)
  local set = interval_set()
  local i = util.clamp(nearest_index(set, params:get("pitch")) + d, 1, #set)
  params:set("pitch", set[i])
end

local function pitch_string(st)
  local name = INTERVAL_NAMES[math.abs(st)] or ""
  if st == 0 then return "0" end
  return string.format("%+.0f %s", st, name)
end

-- pset audio

local function wav_path(pset_file)
  return (pset_file:gsub("%.pset$", "")) .. ".wav"
end

-- params

local function add_params()
  params:add_separator("nofriends", "no friends")

  params:add_number("seed", "seed", 1, 9999, 1)
  params:set_action("seed", function() regenerate() end)
  params:add_trigger("reroll", "reroll seed")
  params:set_action("reroll", function() reroll() end)
  params:add_option("slots", "slots", {"seed", "2", "3", "4", "5"}, 1)
  params:set_action("slots", function() regenerate() end)
  params:add_number("seq_len", "order length", 2, MAX_STEPS, 8)
  params:set_action("seq_len", function() regenerate() end)
  params:add_number("rev_prob", "reverse prob", 0, 100, 0,
    function(p) return p:get() .. "%" end)
  params:set_action("rev_prob", function() regenerate() end)

  params:add_separator("nf_size", "size")
  params:add_option("size_mode", "size mode", {"seconds", "beats"}, 1)
  params:set_action("size_mode", function() apply_lengths() end)
  params:add_control("size_sec", "size (sec)",
    controlspec.new(0, 10, 'lin', 0.25, 0, 's', 0.025),
    function(p)
      local v = p:get()
      return v == 0 and "seed" or string.format("%.2fs", v)
    end)
  params:set_action("size_sec", function() apply_lengths() end)
  local bopts = {"seed"}
  for i, n in ipairs(BEAT_NAMES) do bopts[i + 1] = n .. " beat" end
  params:add_option("size_beats", "size (beats)", bopts, 1)
  params:set_action("size_beats", function() apply_lengths() end)
  params:add_control("len_min", "seed len min",
    controlspec.new(0.25, MAX_LEN, 'lin', 0.05, 1, 's'))
  params:set_action("len_min", function() apply_lengths() end)
  params:add_control("len_max", "seed len max",
    controlspec.new(0.25, MAX_LEN, 'lin', 0.05, 10, 's'))
  params:set_action("len_max", function() apply_lengths() end)

  params:add_separator("nf_pitch", "pitch")
  local snames = {}
  for i, s in ipairs(INTERVAL_SETS) do snames[i] = s.name end
  params:add_option("interval_set", "intervals", snames, 3)
  params:set_action("interval_set", function()
    pitch_delta(0)
  end)
  params:add_number("pitch", "pitch", -24, 24, 0,
    function(p) return pitch_string(p:get()) end)
  params:set_action("pitch", function(st)
    local set = interval_set()
    local snapped = set[nearest_index(set, st)]
    if snapped ~= st then params:set("pitch", snapped) return end
    apply_rate()
  end)
  params:add_control("glide", "pitch glide",
    controlspec.new(0, 2, 'lin', 0.01, 0, 's'))

  params:add_separator("nf_rec", "record")
  params:add_control("mix", "keep (mix)",
    controlspec.new(0, 1, 'lin', 0.01, 0.25, ''),
    function(p) return string.format("%.0f%%", p:get() * 100) end)
  params:set_action("mix", function() apply_rec() end)
  params:add_control("rec_level", "rec level",
    controlspec.new(0, 1, 'lin', 0.01, 1, ''))
  params:set_action("rec_level", function() apply_rec() end)
  params:add_control("cut_in_level", "input to rec",
    controlspec.new(0, 1, 'lin', 0.01, 1, ''))
  params:set_action("cut_in_level", function(x)
    softcut.level_input_cut(1, 1, x)
    softcut.level_input_cut(2, 2, x)
  end)

  params:add_separator("nf_out", "output")
  params:add_control("play_level", "play level",
    controlspec.new(0, 1, 'lin', 0.01, 1, ''))
  params:set_action("play_level", function(x)
    for v = 1, 2 do softcut.level(v, x) end
  end)
  params:add_control("fade", "crossfade",
    controlspec.new(0.001, 0.2, 'exp', 0, 0.02, 's'))
  params:set_action("fade", function(x)
    for v = 1, 2 do softcut.fade_time(v, x) end
  end)
  params:add_binary("playing", "play", "toggle", 1)
  params:set_action("playing", function(x) set_playing(x == 1) end)
  params:add_trigger("clear_all", "clear all slots")
  params:set_action("clear_all", function() softcut.buffer_clear() end)
  params:add_trigger("panic", "all notes off")
  params:set_action("panic", function()
    recording = false
    params:set("playing", 0)
  end)

  params:add_text("history", "seed history", "")
  params:hide("history")

  params.action_write = function(filename)
    softcut.buffer_write_stereo(wav_path(filename), 0, OFFSET + MAX_SLOTS * REGION)
  end
  params.action_read = function(filename)
    local wav = wav_path(filename)
    if util.file_exists(wav) then
      softcut.buffer_clear()
      softcut.buffer_read_stereo(wav, 0, 0, -1)
    end
    history_load()
  end
  params.action_delete = function(filename)
    os.remove(wav_path(filename))
  end
end

local function setup_softcut()
  softcut.buffer_clear()
  audio.level_adc_cut(1)
  for v = 1, 2 do
    softcut.enable(v, 1)
    softcut.buffer(v, v)
    softcut.pan(v, v == 1 and -1 or 1)
    softcut.level(v, 1)
    softcut.loop(v, 1)
    softcut.loop_start(v, slot_start(1))
    softcut.loop_end(v, slot_start(1) + 1)
    softcut.position(v, slot_start(1))
    softcut.rate(v, 1)
    softcut.play(v, 1)
    softcut.rec(v, 0)
    softcut.rec_level(v, 1)
    softcut.pre_level(v, 1)
    softcut.recpre_slew_time(v, 0.01)
    softcut.level_slew_time(v, 0.05)
    softcut.fade_time(v, 0.02)
  end
  softcut.level_input_cut(1, 1, 1)
  softcut.level_input_cut(2, 2, 1)
  softcut.voice_sync(2, 1, 0)
  softcut.phase_quant(1, QUANT)
  softcut.event_phase(on_phase)
  softcut.poll_start_phase()
end

function init()
  math.randomseed(os.time())
  setup_softcut()
  add_params()
  params:bang()
  ready = true
  params:set("seed", math.random(1, 9999))
  history_push(params:get("seed"))
  regenerate()
  restart_pending = false
  goto_step(1)
  apply_rec()

  clock.tempo_change_handler = function() apply_lengths() end

  redraw_metro = metro.init(function()
    frame = frame + 1
    if norns.menu.status() == false then redraw() end
  end, 1 / 15)
  redraw_metro:start()
end

-- ui

function key(n, z)
  if n == 3 then
    if z == 1 then
      k3_held, k3_used = true, false
    else
      k3_held = false
      if not k3_used then reroll() end
    end
  elseif n == 2 and z == 1 then
    if k3_held then
      k3_used = true
      clear_slot()
    else
      if not playing then params:set("playing", 1) end
      recording = not recording
      apply_rec()
    end
  end
end

function enc(n, d)
  if n == 1 then
    params:delta("mix", d)
  elseif n == 2 then
    pitch_delta(d > 0 and 1 or -1)
  elseif n == 3 then
    if k3_held then
      k3_used = true
      history_step(d > 0 and 1 or -1)
    elseif params:string("size_mode") == "beats" then
      params:delta("size_beats", d)
    else
      params:delta("size_sec", d)
    end
  end
end

local function size_string()
  if params:string("size_mode") == "beats" then
    local sb = params:get("size_beats")
    return sb == 1 and "seed b" or (BEAT_NAMES[sb - 1] .. "b")
  end
  local v = params:get("size_sec")
  return v == 0 and "seed" or string.format("%.2fs", v)
end

function redraw()
  screen.clear()
  screen.aa(0)
  screen.font_face(1)
  screen.font_size(8)

  -- top line
  screen.level(15)
  screen.move(0, 7)
  screen.text("seed " .. params:get("seed"))
  if k3_held then
    screen.level(6)
    screen.move(64, 7)
    screen.text_center(hist_pos .. "/" .. #history)
  end
  if recording then
    screen.level(frame % 8 < 5 and 15 or 3)
    screen.move(128, 7)
    screen.text_right("REC")
  elseif not playing then
    screen.level(4)
    screen.move(128, 7)
    screen.text_right("STOP")
  end

  -- values
  screen.level(6)
  screen.move(0, 17)
  screen.text("p " .. pitch_string(params:get("pitch")))
  screen.move(76, 17)
  screen.text_center(size_string())
  screen.move(128, 17)
  screen.text_right(string.format("k%.0f%%", params:get("mix") * 100))

  -- slot boxes, width proportional to length
  local total = 0
  local lens = {}
  for i = 1, n_slots do lens[i] = slot_len(i); total = total + lens[i] end
  local x = 0
  local w_avail = 128 - (n_slots - 1) * 2
  for i = 1, n_slots do
    local w = math.max(4, math.floor(w_avail * lens[i] / total))
    if i == n_slots then w = 128 - x end
    local active = (i == cur_slot)
    screen.level(active and (recording and 6 or 3) or 1)
    screen.rect(x, 22, w, 18)
    screen.fill()
    screen.level(active and 15 or 4)
    screen.rect(x + 0.5, 22.5, w - 1, 17)
    screen.stroke()
    if active then
      local s = slot_start(i)
      local frac = util.clamp((cur_pos - s) / lens[i], 0, 1)
      local px = x + math.floor(frac * (w - 1))
      screen.level(15)
      screen.move(px + 0.5, 22)
      screen.line(px + 0.5, 40)
      screen.stroke()
    end
    screen.level(active and 15 or 6)
    screen.move(x + 3, 34)
    screen.text(tostring(i))
    x = x + w + 2
  end

  -- order row
  local len = #order
  local sp = math.min(8, math.floor(128 / math.max(len, 1)))
  local x0 = math.floor((128 - sp * len) / 2)
  for i = 1, len do
    local cx = x0 + (i - 1) * sp + sp / 2
    screen.level(i == step and 15 or 3)
    screen.move(cx, 54)
    screen.text_center(tostring(order[i]))
    if rev[i] then
      screen.move(cx - 2, 57.5)
      screen.line(cx + 2, 57.5)
      screen.stroke()
    end
  end
  if k3_held then
    screen.level(4)
    screen.move(64, 64)
    screen.text_center("E3 history  K2 clear")
  end

  screen.update()
end

function cleanup()
  if redraw_metro then redraw_metro:stop() end
  clock.tempo_change_handler = nil
  softcut.poll_stop_phase()
  for v = 1, 2 do softcut.rec(v, 0) end
end
