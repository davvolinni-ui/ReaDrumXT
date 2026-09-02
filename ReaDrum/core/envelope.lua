-- @noindex
local M = {}

M.TIME_TAPER = 3
M.ATTACK_MAX_SECONDS = 0.5
M.DECAY_MAX_SECONDS = 12.5
M.RELEASE_MAX_SECONDS = 1.0
M.GATE_RELEASE_MAX_SECONDS = 2.0
M.FADE_MAX_SECONDS = 0.1
M.SUSTAIN_FLOOR_DB = -60

local function clamp(value, minimum, maximum)
  return math.max(minimum, math.min(maximum, tonumber(value) or minimum))
end

function M.time_seconds(control, maximum)
  control = clamp(control, 0, 1)
  maximum = math.max(0, tonumber(maximum) or 0)
  return control ^ M.TIME_TAPER * maximum
end

function M.time_control(seconds, maximum)
  seconds = math.max(0, tonumber(seconds) or 0)
  maximum = math.max(0, tonumber(maximum) or 0)
  if maximum == 0 or seconds == 0 then return 0 end
  return clamp((math.min(seconds, maximum) / maximum) ^ (1 / M.TIME_TAPER), 0, 1)
end

function M.sustain_db(amplitude)
  amplitude = clamp(amplitude, 0, 1)
  if amplitude <= 0 then return -math.huge end
  return 20 * math.log(amplitude, 10)
end

function M.sustain_from_db(db)
  db = tonumber(db) or M.SUSTAIN_FLOOR_DB
  if db <= M.SUSTAIN_FLOOR_DB then return 0 end
  return clamp(10 ^ (db / 20), 0, 1)
end

function M.format_time(seconds)
  seconds = math.max(0, tonumber(seconds) or 0)
  if seconds <= 0 then return "OFF" end
  local milliseconds = seconds * 1000
  if milliseconds < 10 then return string.format("%.1f ms", milliseconds) end
  if milliseconds < 1000 then return string.format("%.0f ms", milliseconds) end
  return string.format("%.2f s", seconds)
end

function M.format_sustain(amplitude)
  local db = M.sustain_db(amplitude)
  return db == -math.huge and "-inf dB" or string.format("%.1f dB", db)
end

M.DEFAULT_DECAY_CONTROL = M.time_control(0.25, M.DECAY_MAX_SECONDS)

return M
