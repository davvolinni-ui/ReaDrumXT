-- @noindex
-- ReaSamplOmatic5000 boundary. Every lookup is by runtime identity, GUID, or
-- enumerated parameter name/identifier; callers never retain an FX index.
local tags = require("ReaDrum.reaper.tags")

local M = {}
local parameter_cache=setmetatable({},{__mode="k"})
local voice_value_cache=setmetatable({},{__mode="k"})
M.SCHEMA_VERSION = "1"
M.SAMPLE_MODE = "2" -- note-tracking mode; required for per-step transpose
M.FX_NAMES = { "ReaSamplOmatic5000 (Cockos)", "VSTi: ReaSamplOmatic5000 (Cockos)" }
M.PARAMETERS = {
  volume = "Volume", pan = "Pan", minimum_velocity_gain = "Gain for minimum velocity",
  note_start = "Note range start", note_end = "Note range end",
  pitch_start = "Pitch for start note", pitch_end = "Pitch for end note", voices = "Max voices",
  attack = "Attack", release = "Release", obey_note_offs = "Obey note-offs",
  loop = "Loop (requires note-offs)", sample_start = "Sample start offset",
  sample_end = "Sample end offset", pitch = "Pitch adjust", decay = "Decay",
  pitch_bend_range = "Pitchbend range",
  sustain = "Sustain", note_off_release = "Release (note-off)",
  note_off_release_override = "Use note-off release override",
}
M.DEFAULTS = {
  volume = 0.5, pan = 0.5, minimum_velocity_gain = 0, note_start = 0, note_end = 1, pitch_start = 0.06875,
  pitch_end = 0.86875, attack = 0, release = 0, obey_note_offs = 1,
  -- Match a freshly inserted RS5K for the visible ADSR: 250 ms decay and
  -- 0 dB sustain. Attack and Release already use RS5K's minimum values.
  loop = 0, sample_start = 0, sample_end = 1, pitch = 0.5, decay = 0.02,
  -- A tiny dedicated note-off fade prevents gate/choke discontinuities while
  -- leaving the visible ADSR release at its neutral zero value.
  sustain = 0.5, note_off_release = 0.00025, note_off_release_override = 1,
  -- RS5K formats this normalized value as a +/- 2.0 semitone bend range.
  pitch_bend_range = 0.1666666716337204,
}

local function normalize(value)
  return tostring(value or ""):lower():gsub("[^%w]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

function M.is_rs5k(adapter, track, index)
  local ident = adapter:get_fx_named(track, index, "fx_ident") or ""
  local name = adapter:fx_name(track, index)
  return ident:lower():find("reasamplomatic", 1, true) ~= nil
    or name:lower():find("reasamplomatic5000", 1, true) ~= nil
end

function M.discover_parameters(adapter, track, index)
  assert(M.is_rs5k(adapter, track, index), "FX is not ReaSamplOmatic5000")
  local count=adapter:fx_param_count(track,index)
  local cached=parameter_cache[adapter]
  if cached and cached.count==count then return cached end
  local by_name, by_ident, result = {}, {}, { count = count, resolved = {} }
  for parameter = 0, result.count - 1 do
    local name, ident = adapter:fx_param_name(track, index, parameter), adapter:fx_param_ident(track, index, parameter)
    by_name[normalize(name)], by_ident[normalize(ident:gsub("^%d+:", ""))] = parameter, parameter
  end
  for key, display in pairs(M.PARAMETERS) do
    result.resolved[key] = by_name[normalize(display)] or by_ident[normalize(display)]
  end
  result.by_name, result.by_ident = by_name, by_ident
  parameter_cache[adapter]=result
  return result
end

local function ownership_fields(pad_id)
  return tags.prefix .. "rs5k_schema", tags.prefix .. "rs5k_object_id", tags.prefix .. "rs5k_guid_" .. pad_id
end

function M.find_managed(adapter, track, rack_id, pad_id)
  local schema_key, object_key, guid_key = ownership_fields(pad_id)
  if adapter:get_track_string(track, schema_key) ~= M.SCHEMA_VERSION
      or adapter:get_track_string(track, object_key) ~= rack_id .. "/rs5k/" .. pad_id then return nil end
  local wanted = adapter:get_track_string(track, guid_key)
  if wanted == "" then return nil end
  for index = 0, adapter:fx_count(track) - 1 do
    if adapter:fx_guid(track, index) == wanted and M.is_rs5k(adapter, track, index) then return index end
  end
  return nil
end

function M.add_managed(adapter, track, rack_id, pad_id)
  local index=adapter.copy_batch_fx_to and adapter:copy_batch_fx_to(track) or nil
  if not index then
    for _, name in ipairs(M.FX_NAMES) do
      index = adapter:add_fx(track, name)
      if index and index >= 0 and M.is_rs5k(adapter, track, index) then break end
      index = nil
    end
    assert(index, "installed REAPER could not instantiate ReaSamplOmatic5000")
    -- Only the first RS5K in a batch is instantiated. Some REAPER setups float
    -- that constructor window, so close it immediately; all remaining pad FX
    -- are copied headlessly from this seed.
    adapter:hide_fx(track,index)
  end
  if adapter.set_batch_fx_seed then adapter:set_batch_fx_seed(track,index) end
  local schema_key, object_key, guid_key = ownership_fields(pad_id)
  adapter:set_track_string(track, schema_key, M.SCHEMA_VERSION)
  adapter:set_track_string(track, object_key, rack_id .. "/rs5k/" .. pad_id)
  adapter:set_track_string(track, guid_key, assert(adapter:fx_guid(track, index), "RS5K has no GUID"))
  adapter:set_fx_named(track, index, "renamed_name", "ReaDrum RS5K [" .. pad_id .. "]")
  return index
end

function M.find_or_add(adapter, track, rack_id, pad_id)
  local index = M.find_managed(adapter, track, rack_id, pad_id)
  if index then if adapter.set_batch_fx_seed then adapter:set_batch_fx_seed(track,index) end;return index, false end
  return M.add_managed(adapter, track, rack_id, pad_id), true
end

-- Step Pan is emitted as MIDI CC10 by the sequencer. RS5K does not bind its
-- Pan parameter to that controller by default, so keep the managed instance's
-- link explicit and repairable just like its other managed settings.
function M.configure_pan_cc_link(adapter, track, index, parameter)
  local values = {
    ["param." .. parameter .. ".plink.active"] = "1",
    ["param." .. parameter .. ".plink.effect"] = "-100",
    ["param." .. parameter .. ".plink.param"] = "-1",
    ["param." .. parameter .. ".plink.midi_bus"] = "0",
    ["param." .. parameter .. ".plink.midi_chan"] = "1",
    ["param." .. parameter .. ".plink.midi_msg"] = "176",
    ["param." .. parameter .. ".plink.midi_msg2"] = "10",
  }
  local changed = false
  for key, wanted in pairs(values) do
    if adapter:get_fx_named(track, index, key) ~= wanted then
      assert(adapter:set_fx_named(track, index, key, wanted), "could not configure RS5K Pan CC link: " .. key)
      changed = true
    end
  end
  return changed
end

function M.apply_controls(adapter, track, index, controls, polyphony)
  local map = M.discover_parameters(adapter, track, index)
  local changed = M.configure_pan_cc_link(adapter, track, index,
    assert(map.resolved.pan, "installed RS5K parameter missing: Pan"))
  if adapter:get_fx_named(track,index,"MODE")~=M.SAMPLE_MODE then
    assert(adapter:set_fx_named(track,index,"MODE",M.SAMPLE_MODE),"could not enable RS5K note-tracking mode")
    changed=true
  end
  for key, default in pairs(M.DEFAULTS) do
    local parameter = assert(map.resolved[key], "installed RS5K parameter missing: " .. M.PARAMETERS[key])
    local value = controls and controls[key]
    if value == nil then value = default end
    assert(type(value) == "number" and value >= 0 and value <= 1, key .. " must be normalized 0..1")
    if math.abs(adapter:get_fx_param_normalized(track, index, parameter) - value) > 0.00001 then
      adapter:set_fx_param_normalized(track, index, parameter, value)
      changed = true
    end
  end
  if polyphony then
    local parameter = assert(map.resolved.voices, "installed RS5K parameter missing: Max voices")
    local values=voice_value_cache[adapter]
    if not values then values={};voice_value_cache[adapter]=values end
    local best=values[polyphony]
    if not best then
      local function voice_at(step)
        local value = step / 4096
        local formatted = adapter:format_fx_param(track, index, parameter, value)
        return formatted and tonumber(formatted:match("[-+]?%d+%.?%d*")),value
      end
      local lo,hi=0,4096
      while lo<hi do
        local mid=math.floor((lo+hi)/2);local number=voice_at(mid)
        if number and number<polyphony then lo=mid+1 else hi=mid end
      end
      local best_distance
      for step=math.max(0,lo-4),math.min(4096,lo+4) do
        local number,value=voice_at(step)
        if number then
          local distance = math.abs(number - polyphony)
          if not best_distance or distance < best_distance then best, best_distance = value, distance end
          if distance == 0 then break end
        end
      end
      -- Preserve compatibility if an older or future RS5K exposes a
      -- non-monotonic formatter despite Max voices being monotonic today.
      if best_distance~=0 then
        best,best_distance=nil,nil
        for step=0,4096 do
          local number,value=voice_at(step)
          if number then
            local distance=math.abs(number-polyphony)
            if not best_distance or distance<best_distance then best,best_distance=value,distance end
            if distance==0 then break end
          end
        end
      end
      assert(best and best_distance == 0, "installed RS5K cannot represent requested polyphony " .. tostring(polyphony))
      values[polyphony]=best
    end
    if math.abs(adapter:get_fx_param_normalized(track, index, parameter) - best) > 0.001 then
      adapter:set_fx_param_normalized(track, index, parameter, best)
      changed = true
    end
  end
  return map, changed
end

function M.sample_path(sample)
  if sample == false or sample == nil then return nil end
  if type(sample) == "string" then return sample end
  return sample.path
end

function M.load_sample(adapter, track, index, sample)
  local path = M.sample_path(sample)
  if not path or path == "" then
    local current = adapter:get_fx_named(track, index, "FILE0")
    if current and current ~= "" then
      adapter:set_fx_named(track, index, "-FILE0", "")
      adapter:set_fx_named(track, index, "DONE", "")
      return { state = "clear", path = false, changed = true }
    end
    return { state = "clear", path = false, changed = false }
  end
  if not adapter:file_exists(path) then return { state = "missing", path = path } end
  if adapter:get_fx_named(track, index, "FILE0") == path then
    return { state = "loaded", path = path, changed = false }
  end
  -- FILE0 appends a slot when one already exists. The product contract is
  -- exactly one sample, so remove only RS5K's slot zero before replacement.
  if adapter:get_fx_named(track, index, "FILE0") then
    adapter:set_fx_named(track, index, "-FILE0", "")
  end
  assert(adapter:set_fx_named(track, index, "FILE0", path), "RS5K rejected sample path")
  assert(adapter:set_fx_named(track, index, "DONE", ""), "RS5K rejected sample commit")
  local actual = adapter:get_fx_named(track, index, "FILE0")
  assert(actual == path, "RS5K sample path readback mismatch")
  return { state = "loaded", path = path, changed = true }
end

return M
