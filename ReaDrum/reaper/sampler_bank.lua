-- @noindex
-- Boundary for the headless 16-pad JSFX playback engine. The saved ReaDrum
-- model remains authoritative; this module only publishes reconstructable
-- runtime allocations and control state.
local M = {}

M.FX_NAME = "JS: ReaDrum/ReaDrum_SamplerBank16"
M.GMEM_NAME = "ReaDrumSampler"
M.MAGIC = 52460
M.VERSION = 1
M.BANK_STRIDE = 65536
M.COMMAND_STRIDE = 2080
M.BASE = 1800000
M.PATH_OFFSET = 32
M.PATH_CAP = 2048
M.CONTROL_OFFSET = 34000
M.CONTROL_WORDS = 25
M.AUDIO_MASK_OFFSET = 35200
M.SLIDE_OFFSET = 35300
M.LIVE_OFFSET = 35400
M.AUDITION_OFFSET = 35500
M.STATUS_OFFSET = 35000
M.METER_OFFSET = 35100
M.MAX_NAMESPACE = 7

local function integer(value, name, minimum, maximum)
  assert(type(value) == "number" and value == math.floor(value), name .. " must be an integer")
  assert(value >= minimum and value <= maximum, name .. " is out of range")
  return value
end

local function finite(value, name)
  assert(type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge,
    name .. " must be finite")
  return value
end

local function clamp(value, minimum, maximum)
  return math.max(minimum, math.min(maximum, value))
end

local function namespace_index(value)
  value=math.floor(tonumber(value) or 0)
  return value % (M.MAX_NAMESPACE+1)
end

local function attach(host)
  assert(type(host.gmem_attach) == "function" and type(host.gmem_write) == "function",
    "gmem host functions are unavailable")
  host.gmem_attach(M.GMEM_NAME)
end

local function base(bank, namespace)
  return M.BASE + namespace_index(namespace) * 8 * M.BANK_STRIDE + integer(bank, "bank", 0, 7) * M.BANK_STRIDE
end

function M.meter(host, bank, slot, namespace)
  attach(host)
  slot=integer(slot,"slot",0,15)
  local address=base(bank,namespace)+M.METER_OFFSET+slot*2
  return math.max(0,tonumber(host.gmem_read(address)) or 0),math.max(0,tonumber(host.gmem_read(address+1)) or 0)
end

function M.live(host, bank, slot, namespace)
  attach(host)
  slot=integer(slot,"slot",0,15)
  local address=base(bank,namespace)+M.LIVE_OFFSET+slot*3
  return {
    frames=math.floor((host.gmem_read(address) or 0)+0.5),
    channels=math.floor((host.gmem_read(address+1) or 0)+0.5),
    generation=math.floor((host.gmem_read(address+2) or 0)+0.5),
  }
end

function M.control_revision(host,bank,slot,namespace)
  attach(host)
  slot=integer(slot,"slot",0,15)
  return math.floor((host.gmem_read(base(bank,namespace)+M.CONTROL_OFFSET+slot*M.CONTROL_WORDS)or 0)+0.5)
end

function M.audition(host, bank, slot, note, velocity, namespace)
  attach(host)
  slot=integer(slot,"slot",0,15)
  local address=base(bank,namespace)+M.AUDITION_OFFSET+slot*4
  local token=math.floor(host.gmem_read(address) or 0)%16777214+1
  host.gmem_write(address+1,integer(note,"note",0,127))
  host.gmem_write(address+2,integer(velocity,"velocity",1,127))
  host.gmem_write(address+3,1)
  host.gmem_write(address,token)
  return token
end

function M.release_audition(host, bank, slot, namespace)
  attach(host)
  slot=integer(slot,"slot",0,15)
  local address=base(bank,namespace)+M.AUDITION_OFFSET+slot*4
  local token=math.floor(host.gmem_read(address) or 0)%16777214+1
  host.gmem_write(address+3,2)
  host.gmem_write(address,token)
  return token
end

local function set_integer_parameter(host,track,fx,param,value,maximum)
  if host.TrackFX_SetParam then return host.TrackFX_SetParam(track,fx,param,value) end
  return host.TrackFX_SetParamNormalized(track,fx,param,maximum==0 and 0 or value/maximum)
end

function M.add(host, track, bank, namespace)
  integer(bank, "bank", 0, 7)
  local index = host.TrackFX_AddByName(track, M.FX_NAME, false, -1)
  assert(index and index >= 0, "could not instantiate ReaDrum Sampler Bank 16")
  set_integer_parameter(host,track,index,0,bank,7)
  if namespace ~= nil then set_integer_parameter(host,track,index,4,namespace_index(namespace),M.MAX_NAMESPACE) end
  if host.TrackFX_SetNamedConfigParm then
    host.TrackFX_SetNamedConfigParm(track, index, "renamed_name",
      string.format("ReaDrum Sampler Bank %s", string.char(65 + bank)))
  end
  -- Bank JSFX instances are infrastructure. Keep their editor closed when
  -- samples are first loaded; the UI can still open one explicitly if needed.
  if host.TrackFX_Show then host.TrackFX_Show(track, index, 2) end
  return index
end

function M.publish_controls(host, bank, slot, controls, namespace)
  attach(host)
  slot = integer(slot, "slot", 0, 15)
  controls = controls or {}
  local address = base(bank,namespace) + M.CONTROL_OFFSET + slot * M.CONTROL_WORDS
  local control_revision = math.floor(host.gmem_read(address) or 0) % 16777214 + 1
  local values = {
    control_revision,
    clamp(finite(controls.gain or 1, "gain"), 0, 4),
    clamp(finite(controls.pan or 0, "pan"), -1, 1),
    clamp(finite(controls.tune_semitones or 0, "tune_semitones"), -96, 96),
    clamp(finite(controls.tune_cents or 0, "tune_cents"), -100, 100),
    clamp(finite(controls.attack_seconds or 0, "attack_seconds"), 0, 30),
    clamp(finite(controls.decay_seconds or 0.25, "decay_seconds"), 0, 30),
    clamp(finite(controls.sustain_gain or 1, "sustain_gain"), 0, 1),
    clamp(finite(controls.release_seconds or 0, "release_seconds"), 0, 30),
    clamp(finite(controls.sample_start or 0, "sample_start"), 0, 1),
    clamp(finite(controls.sample_end or 1, "sample_end"), 0, 1),
    integer(controls.polyphony or 16, "polyphony", 1, 128),
    controls.self_choke == false and 0 or 1,
    controls.choke_group == false and 0 or integer(controls.choke_group or 0, "choke_group", 0, 32),
    controls.obey_note_offs == false and 0 or 1,
    integer(controls.output_pair or slot, "output_pair", 0, 15),
    clamp(finite(controls.minimum_velocity_gain or 0, "minimum_velocity_gain"), 0, 1),
    clamp(finite(controls.fade_in or 0, "fade_in"), 0, 0.1),
    clamp(finite(controls.fade_out or 0, "fade_out"), 0, 0.1),
    clamp(finite(controls.fade_in_curve or 0.5, "fade_in_curve"), 0, 1),
    clamp(finite(controls.fade_out_curve or 0.5, "fade_out_curve"), 0, 1),
    integer(controls.sample_slot or slot,"sample_slot",0,15),
    clamp(finite(controls.reverb_send or 0,"reverb_send"),0,1),
    clamp(finite(controls.delay_send or 0,"delay_send"),0,1),
    clamp(finite(controls.glide_seconds or 0,"glide_seconds"),0,2),
  }
  for index, value in ipairs(values) do host.gmem_write(address + index - 1, value) end
  -- A separate fixed mailbox keeps the established control stride compatible.
  -- 0 is intentionally treated as uninitialized/audible by the JSFX.
  host.gmem_write(base(bank,namespace)+M.AUDIO_MASK_OFFSET+slot,controls.audible==false and 1 or 2)
  local slide_address=base(bank,namespace)+M.SLIDE_OFFSET+slot*2
  host.gmem_write(slide_address,controls.slide_retrigger==false and 0 or 1)
  host.gmem_write(slide_address+1,clamp(finite(controls.slide_crossfade_seconds or .02,"slide_crossfade_seconds"),0,.1))
  return control_revision
end

local function command(host, bank, slot, opcode, path, namespace)
  attach(host)
  slot = integer(slot, "slot", 0, 15)
  path = path or ""
  assert(#path <= M.PATH_CAP, "sample path exceeds JSFX protocol capacity")
  local address = base(bank,namespace) + slot * M.COMMAND_STRIDE
  local command_token = math.floor(host.gmem_read(address + 2) or 0) % 16777214 + 1
  host.gmem_write(address, M.MAGIC)
  host.gmem_write(address + 1, M.VERSION)
  host.gmem_write(address + 3, opcode)
  host.gmem_write(address + 4, slot)
  host.gmem_write(address + 5, #path)
  for index = 1, #path do host.gmem_write(address + M.PATH_OFFSET + index - 1, path:byte(index)) end
  -- Commit last so the idle-thread reader can never observe a partial path.
  host.gmem_write(address + 2, command_token)
  return command_token
end

function M.load(host, bank, slot, path, namespace)
  assert(type(path) == "string" and path ~= "", "sample path is required")
  return command(host, bank, slot, 1, path,namespace)
end

function M.clear(host, bank, slot, namespace)
  return command(host, bank, slot, 2, "",namespace)
end

function M.status(host, bank, slot, namespace)
  attach(host)
  slot = integer(slot or 0, "slot", 0, 15)
  local address = base(bank,namespace) + M.STATUS_OFFSET + slot * 4
  return {
    token = math.floor(host.gmem_read(address) + 0.5),
    code = math.floor(host.gmem_read(address + 1) + 0.5),
    frames = math.floor(host.gmem_read(address + 2) + 0.5),
    channels = math.floor(host.gmem_read(address + 3) + 0.5),
  }
end

return M
