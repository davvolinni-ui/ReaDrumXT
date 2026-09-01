local allocator = require("ReaDrum.core.engine_allocator")
local bank = require("ReaDrum.reaper.sampler_bank")

local M = {}
local dispatcher_reloaded = setmetatable({}, { __mode = "k" })
local banks_reloaded = setmetatable({}, { __mode = "k" })

local function sample_path(sample)
  if type(sample) == "table" then return sample.path end
  return sample
end

local function normalized_gain(value)
  value = math.max(0, math.min(1, tonumber(value) or 0.354))
  return value == 0 and 0 or (value / 0.5) ^ 2
end

function M.controls_from_pad(pad, output_pair, sample_slot, audible)
  local controls = pad.default_controls or {}
  local gate_mode = controls.playback_mode == "gate"
  local envelope_enabled = controls.envelope_enabled == true or controls.envelope_enabled == 1
  local transpose = controls.transpose_semitones
  local cents = controls.tune_cents
  if transpose == nil and cents == nil then
    local total = ((tonumber(controls.pitch) or 0.5) - 0.5) * 160
    transpose = math.floor(total + (total >= 0 and 0.5 or -0.5))
    cents = math.floor((total - transpose) * 100 + 0.5)
  end
  return {
    gain = normalized_gain(controls.volume),
    pan = math.max(-1, math.min(1, ((tonumber(controls.pan) or 0.5) - 0.5) * 2)),
    tune_semitones = transpose or 0,
    tune_cents = cents or 0,
    -- UI values are normalized, but the engine receives real sampler times.
    -- These ranges keep drum envelopes useful while remaining sample-rate independent.
    attack_seconds = envelope_enabled and math.max(0, (tonumber(controls.attack) or 0) * 0.5) or 0,
    decay_seconds = envelope_enabled and math.max(0, (tonumber(controls.decay) or 0.02) * 12.5) or 0,
    sustain_gain = envelope_enabled and math.max(0, math.min(1, tonumber(controls.sustain) or 1)) or 1,
    -- ADSR release owns note-off only while the advanced envelope is enabled.
    -- Otherwise Gate mode uses its dedicated short release/de-click time.
    release_seconds = envelope_enabled
      and math.max(0, (tonumber(controls.release) or 0) * 1.0)
      or math.max(0, math.min(2, (tonumber(controls.gate_release_ms) or 10) / 1000)),
    sample_start = tonumber(controls.sample_start) or 0,
    sample_end = tonumber(controls.sample_end) or 1,
    polyphony = pad.polyphony or 16,
    self_choke = pad.self_choke ~= false,
    choke_group = pad.choke_group,
    obey_note_offs = gate_mode,
    output_pair = output_pair,
    minimum_velocity_gain = tonumber(controls.minimum_velocity_gain) or 0,
    -- Existing normalized control storage now maps to a fixed 0..100 ms
    -- boundary fade instead of a percentage of the sample's duration.
    fade_in = math.max(0, math.min(0.1, (tonumber(controls.fade_in) or 0) * 0.1)),
    fade_out = math.max(0, math.min(0.1, (tonumber(controls.fade_out) or 0) * 0.1)),
    fade_in_curve = math.max(0, math.min(1, tonumber(controls.fade_in_curve) or .5)),
    fade_out_curve = math.max(0, math.min(1, tonumber(controls.fade_out_curve) or .5)),
    sample_slot = math.max(0,math.min(15,math.floor(tonumber(sample_slot) or (((tonumber(pad.logical_index) or 1)-1)%16)))),
    reverb_send = math.max(0,math.min(1,tonumber(controls.reverb_send) or 0)),
    delay_send = math.max(0,math.min(1,tonumber(controls.delay_send) or 0)),
    -- A tiny positive value represents immediate legato (one-sample retarget)
    -- while preserving 0 as a true retrigger when Legato is disabled.
    glide_seconds = controls.legato_enabled==false and 0 or math.max(0.000001,math.min(2,tonumber(controls.glide) or 0)),
    slide_retrigger = controls.slide_retrigger~=false,
    slide_crossfade_seconds = math.max(0,math.min(.1,(tonumber(controls.slide_crossfade_ms) or 20)/1000)),
    audible = audible~=false,
  }
end

local function bank_name(bank_index)
  return string.format("ReaDrum Sampler Bank %s", string.char(65 + bank_index))
end

function M.find_bank(host, track, bank_index)
  local wanted = bank_name(bank_index)
  for fx = 0, host.TrackFX_GetCount(track) - 1 do
    local ok, renamed = host.TrackFX_GetNamedConfigParm(track, fx, "renamed_name")
    if ok and renamed == wanted then return fx end
  end
end

function M.ensure_bank(host, track, bank_index, namespace, hide_editor)
  local fx=M.find_bank(host, track, bank_index)
  if fx==nil then return bank.add(host, track, bank_index, namespace) end
  local reloaded=banks_reloaded[track]or{};banks_reloaded[track]=reloaded
  if not reloaded[bank_index] and host.TrackFX_SetOffline then
    reloaded[bank_index]=true;host.TrackFX_SetOffline(track,fx,true);host.TrackFX_SetOffline(track,fx,false)
  end
  -- Repair banks created before engine namespaces existed, and keep restored
  -- projects attached to their own command/control mailbox.
  if host.TrackFX_SetParam then
    host.TrackFX_SetParam(track,fx,0,bank_index)
    host.TrackFX_SetParam(track,fx,4,(namespace or 0)%(bank.MAX_NAMESPACE+1))
  else
    host.TrackFX_SetParamNormalized(track,fx,0,bank_index/7)
    host.TrackFX_SetParamNormalized(track,fx,4,((namespace or 0)%(bank.MAX_NAMESPACE+1))/bank.MAX_NAMESPACE)
  end
  if hide_editor and host.TrackFX_Show then host.TrackFX_Show(track,fx,2) end
  return fx
end

function M.ensure_dispatcher(host, track)
  for fx = 0, host.TrackFX_GetCount(track) - 1 do
    local ok, name = host.TrackFX_GetFXName(track, fx, "")
    if ok and name:find("ReaDrum Round Robin Dispatcher", 1, true) then
      -- REAPER keeps an already-instantiated JSFX compiled after its source is
      -- updated on disk.  Reload this infrastructure effect once per script
      -- launch so fixes to its audio-thread scheduler actually take effect.
      -- Offline/online preserves the instance and all published parameters.
      if not dispatcher_reloaded[track] and host.TrackFX_SetOffline then
        dispatcher_reloaded[track] = true
        host.TrackFX_SetOffline(track, fx, true)
        host.TrackFX_SetOffline(track, fx, false)
      end
      return fx
    end
  end
  local fx = host.TrackFX_AddByName(track, "JS: ReaDrum/ReaDrum_RoundRobinDispatcher", false, -1)
  assert(fx and fx >= 0, "ReaDrum dispatcher is not installed")
  if host.TrackFX_Show then host.TrackFX_Show(track, fx, 2) end
  return fx
end

function M.ensure_send_fx(host,track)
  host.SetMediaTrackInfo_Value(track,"I_NCHAN",36)
  local count=host.TrackFX_GetCount(track)
  for fx=0,count-1 do
    local ok,name=host.TrackFX_GetFXName(track,fx,"")
    if ok and name:find("ReaDrum Shared Send FX",1,true) then
      if fx~=count-1 and host.TrackFX_CopyToTrack then
        host.TrackFX_CopyToTrack(track,fx,track,count,true);fx=count-1
      end
      if host.TrackFX_Show then host.TrackFX_Show(track,fx,2) end
      return fx
    end
  end
  local fx=host.TrackFX_AddByName(track,"JS: ReaDrum/ReaDrum_SendFX",false,-1)
  assert(fx and fx>=0,"ReaDrum shared send FX is not installed")
  if host.TrackFX_Show then host.TrackFX_Show(track,fx,2) end
  return fx
end

function M.remove_send_fx(host,track)
  if not host.TrackFX_Delete then return 0 end
  local removed=0
  for fx=host.TrackFX_GetCount(track)-1,0,-1 do
    local ok,name=host.TrackFX_GetFXName(track,fx,"")
    if ok and name:find("ReaDrum Shared Send FX",1,true) then host.TrackFX_Delete(track,fx);removed=removed+1 end
  end
  return removed
end

function M.reconcile(host, track, rack, previous)
  previous = previous or {}
  host.SetMediaTrackInfo_Value(track, "I_NCHAN", 36)
  M.ensure_dispatcher(host, track)
  local pads = assert(allocator.allocate(rack.pads))
  local outputs = assert(allocator.allocate_outputs(rack.outputs))
  local namespace=math.max(0,math.min(bank.MAX_NAMESPACE,math.floor(tonumber(rack.engine_namespace) or 0)))
  local next_cache, report = {}, { banks = 0, controls = 0, loads = 0, clears = 0 }
  -- Build the new cache before touching any sampler slots.  A pad move can be
  -- a swap: clearing old slots after writing the new destinations would erase
  -- the samples that were just moved into those slots.
  for _, pad in ipairs(rack.pads) do
    local path = sample_path(pad.sample)
    if type(path) == "string" and path ~= "" then
      local location = assert(pads.by_pad_id[pad.id])
      local prior=previous[pad.id]
      local reuse=type(prior)=="table" and prior.path==path and prior.bank==location.bank
      local entry
      if reuse then
        entry=prior
      else
        entry={bank=location.bank,slot=location.slot,path=path,ready=false,needs_load=true}
      end
      entry.signature=table.concat({path,entry.bank,entry.slot},"\0")
      entry.logical_bank,entry.logical_slot=location.bank,location.slot
      entry.namespace=namespace
      next_cache[pad.id]=entry
    end
  end
  local occupied={}
  for _,entry in pairs(next_cache) do
    occupied[(entry.bank or 0)..":"..(entry.slot or 0)]=true
  end
  for pad_id, prior in pairs(previous) do
    local current=next_cache[pad_id]
    local prior_signature=type(prior)=="table"and prior.signature or prior
    local current_signature=type(current)=="table"and current.signature or current
    if current_signature ~= prior_signature then
      local old_bank,old_slot
      if type(prior)=="table" then old_bank,old_slot=prior.bank,prior.slot
      else local _;_,old_bank,old_slot=tostring(prior):match("^(.-)%z(%d+)%z(%d+)$");old_bank,old_slot=tonumber(old_bank),tonumber(old_slot) end
      if old_bank and old_slot and not occupied[old_bank..":"..old_slot] then
        bank.clear(host, old_bank - 1, old_slot - 1,type(prior)=="table" and prior.namespace or namespace)
        report.clears = report.clears + 1
      end
    end
  end
  local ensured = {}
  local any_solo=false
  for _,candidate in ipairs(rack.pads or {}) do if candidate.sample~=false and candidate.sample~=nil and candidate.soloed==true then any_solo=true;break end end
  for _, pad in ipairs(rack.pads) do
    local path = sample_path(pad.sample)
    if type(path) == "string" and path ~= "" then
      local location = assert(pads.by_pad_id[pad.id])
      if not ensured[location.bank] then
        M.ensure_bank(host, track, location.bank - 1,namespace,true)
        ensured[location.bank] = true
        report.banks = report.banks + 1
      end
      local pair = assert(outputs.by_output_id[pad.output_id])
      local entry=next_cache[pad.id]
      local audible=pad.muted~=true and(not any_solo or pad.soloed==true)
      bank.publish_controls(host, location.bank - 1, location.slot - 1, M.controls_from_pad(pad, pair,entry.slot-1,audible),namespace)
      report.controls = report.controls + 1
      if entry.needs_load then
        entry.token=bank.load(host, location.bank - 1, location.slot - 1, path,namespace)
        entry.bank,entry.slot=location.bank,location.slot
        entry.signature=table.concat({path,entry.bank,entry.slot},"\0")
        entry.needs_load=nil
        entry.requested_at=host.time_precise and host.time_precise() or 0
        report.loads = report.loads + 1
      end
    end
  end
  -- Dedicated channel pairs 17/18 feed external AUX tracks. Retire the old
  -- built-in reverb/delay processor so it cannot consume or duplicate them.
  M.remove_send_fx(host,track)
  return next_cache, report
end

function M.poll(host, track, cache, limit)
  limit=limit or 4
  local checked,ready,failed=0,0,0
  local rebound={}
  local playing=host.GetPlayState and ((host.GetPlayState() or 0)&1)~=0
  for _,entry in pairs(cache or {}) do
    if type(entry)=="table" and entry.ready then
      -- Status is historical. Verify the JSFX still has committed slot
      -- metadata so a recompile/rebind cannot leave a pad permanently silent.
      local live=bank.live(host,entry.bank-1,entry.slot-1,entry.namespace)
      if live.frames<=0 or live.generation~=(entry.token or 0) then
        local now=host.time_precise and host.time_precise() or 0
        entry.live_missing_at=entry.live_missing_at or now
        if not playing and now-entry.live_missing_at>=0.75 then
          entry.ready=false
          entry.live_missing_at=nil
          entry.token=bank.load(host,entry.bank-1,entry.slot-1,entry.path,entry.namespace)
          entry.requested_at=now
        end
      else
        entry.live_missing_at=nil
      end
    elseif type(entry)=="table" and checked<limit then
      checked=checked+1
      -- A newly inserted JSFX compiles asynchronously. REAPER can restore its
      -- default sliders after the first synchronous parameter write, so bind
      -- the mailbox again while its initial sample request is outstanding.
      if track and not rebound[entry.bank] then
        M.ensure_bank(host,track,entry.bank-1,entry.namespace,true)
        rebound[entry.bank]=true
      end
      local status=bank.status(host,entry.bank-1,entry.slot-1,entry.namespace)
      local live=bank.live(host,entry.bank-1,entry.slot-1,entry.namespace)
      if status.token==entry.token and status.code==1 and status.frames>0 and live.generation==entry.token and live.frames>0 then
        entry.ready=true;entry.frames=status.frames;entry.channels=status.channels;ready=ready+1
      elseif status.token==entry.token and status.code==1 and status.frames>0 then
        -- Decode completed; wait for the audio thread to atomically commit it.
      elseif status.token==entry.token and status.code<0 then
        failed=failed+1
        entry.token=bank.load(host,entry.bank-1,entry.slot-1,entry.path,entry.namespace)
        entry.requested_at=host.time_precise and host.time_precise() or 0
      elseif host.time_precise and host.time_precise()-(entry.requested_at or 0)>2 then
        entry.token=bank.load(host,entry.bank-1,entry.slot-1,entry.path,entry.namespace)
        entry.requested_at=host.time_precise()
      end
    end
  end
  return {checked=checked,ready=ready,failed=failed}
end

function M.publish_pad(host, track, rack, pad, cache_entry)
  local logical_index = assert(tonumber(pad.logical_index), "pad logical index is required")
  local bank_index = math.floor((logical_index - 1) / 16)
  local slot_index = (logical_index - 1) % 16
  local output_pair
  for index, output in ipairs(rack.outputs or {}) do
    if output.id == pad.output_id then output_pair = index - 1; break end
  end
  assert(output_pair ~= nil, "pad references an unknown logical output")
  local namespace=math.max(0,math.min(bank.MAX_NAMESPACE,math.floor(tonumber(rack.engine_namespace) or 0)))
  M.ensure_bank(host, track, bank_index,namespace)
  local sample_slot=cache_entry and cache_entry.bank==bank_index+1 and cache_entry.slot-1 or slot_index
  local any_solo=false
  for _,candidate in ipairs(rack.pads or {}) do if candidate.sample~=false and candidate.sample~=nil and candidate.soloed==true then any_solo=true;break end end
  local audible=pad.muted~=true and(not any_solo or pad.soloed==true)
  return bank.publish_controls(host, bank_index, slot_index, M.controls_from_pad(pad, output_pair,sample_slot,audible),namespace)
end

return M
