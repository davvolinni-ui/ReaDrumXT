-- @noindex
local json = require("ReaDrum.core.json")
local model = require("ReaDrum.core.model")

local M = { SECTION = "ReaDrum", VERSION = 2, CHUNK = 48000 }

local DEFAULT_STEP=model.new_step()
local function equal(a,b)
  if type(a)~=type(b)then return false end;if type(a)~="table"then return a==b end
  for key,value in pairs(a)do if not equal(value,b[key])then return false end end
  for key in pairs(b)do if a[key]==nil then return false end end
  return true
end
local function compact_value(value,tick)
  if type(value)~="table"then return value end
  if tick then tick() end
  local out={}
  for key,child in pairs(value)do
    if not (value.type=="Lane"and key=="steps")then out[compact_value(key,tick)]=compact_value(child,tick)end
  end
  if value.type=="Lane"then
    out.steps={};out._sparse_steps=true
    for index,step in ipairs(value.steps or{})do if not equal(step,DEFAULT_STEP)then out.steps[#out.steps+1]={index=index,step=compact_value(step,tick)}elseif tick then tick()end end
  end
  return out
end
local function expand_value(value)
  if type(value)~="table"then return value end
  for key,child in pairs(value)do value[key]=expand_value(child)end
  if value.type=="Lane"and value._sparse_steps then
    local sparse=value.steps or{};value.steps={}
    for index=1,value.step_count do value.steps[index]=model.new_step()end
    for _,entry in ipairs(sparse)do if entry.index>=1 and entry.index<=value.step_count then value.steps[entry.index]=entry.step end end
    value._sparse_steps=nil
  end
  return value
end
function M.compact(rack)local result=compact_value(rack);result._readrum_sparse_state=1;return result end
function M.expand(rack)rack._readrum_sparse_state=nil;return expand_value(rack)end

function M.begin_compact(rack,budget)
  budget=math.max(8,math.floor(budget or 128))
  local count=0
  local task={}
  task.coroutine=coroutine.create(function()
    local function tick()
      count=count+1
      if count>=budget then count=0;coroutine.yield()end
    end
    local result=compact_value(rack,tick);result._readrum_sparse_state=1;return result
  end)
  return task
end

function M.step_compact(task)
  local ok,result=coroutine.resume(task.coroutine)
  if not ok then error(result,2) end
  if coroutine.status(task.coroutine)=="dead"then task.result=result;return true,result end
  return false
end

local function folder_track(host,project,rack_id)
  if not (host.CountTracks and host.GetTrack and host.GetSetMediaTrackInfo_String) then return nil end
  for index=0,host.CountTracks(project)-1 do
    local track=host.GetTrack(project,index)
    local _,kind=host.GetSetMediaTrackInfo_String(track,"P_EXT:ReaDrum.kind","",false)
    local _,owner=host.GetSetMediaTrackInfo_String(track,"P_EXT:ReaDrum.owner","",false)
    local _,found_rack=host.GetSetMediaTrackInfo_String(track,"P_EXT:ReaDrum.rack_id","",false)
    if kind=="folder" and owner=="ReaDrum" and (not rack_id or found_rack==rack_id) then return track end
  end
end

local function state_get(host,project,folder,key)
  if folder then
    local _,value=host.GetSetMediaTrackInfo_String(folder,"P_EXT:ReaDrum."..key,"",false)
    return value or ""
  end
  local _,value=host.GetProjExtState(project,M.SECTION,key)
  return value or ""
end

local function checksum(payload)
  local hash=2166136261
  for index=1,#payload do hash=((hash ~ payload:byte(index))*16777619)&0xffffffff end
  return string.format("%08x",hash)
end

local function read_chunks(host,project,folder)
  local head=state_get(host,project,folder,"state_head")
  local slot,count,bytes,digest=head:match("^([ab]):(%d+):(%d+):(%x+)$")
  if head~="" and not slot then return nil,"Project state has invalid commit metadata" end
  local count_text=count or state_get(host,project,folder,folder and "state_chunks" or "chunks")
  count=tonumber(count_text)
  if not count then
    if count_text~="" then return nil,"Project state has an invalid chunk count" end
    return nil
  end
  if count%1~=0 or count<1 or count>256 then return nil,"Project state has an invalid chunk count" end
  local chunks={}
  for index=1,count do
    local key=slot and string.format("state_%s_%03d",slot,index) or string.format("state_%03d",index)
    local value=state_get(host,project,folder,key)
    if value=="" then return nil,"Project state is incomplete" end
    chunks[index]=value
  end
  local payload=table.concat(chunks)
  if slot and (#payload~=tonumber(bytes) or checksum(payload)~=digest) then
    return nil,"Project state failed its integrity check"
  end
  return payload
end

function M.signature(host,project)
  local head=state_get(host,project,nil,"state_head")
  if head~="" then return head end
  local count=tonumber(state_get(host,project,nil,"chunks"))
  if count and count%1==0 and count>=1 and count<=256 then
    return tostring(count)..":"..state_get(host,project,nil,"state_001")..":"..
      state_get(host,project,nil,string.format("state_%03d",count))
  end
  local folder=folder_track(host,project)
  if folder then
    head=state_get(host,project,folder,"state_head")
    if head~="" then return "folder:"..head end
    count=tonumber(state_get(host,project,folder,"state_chunks"))
    if count and count%1==0 and count>=1 and count<=256 then
      return "folder:"..tostring(count)..":"..state_get(host,project,folder,"state_001")..":"..
        state_get(host,project,folder,string.format("state_%03d",count))
    end
  end
end

local function filename(path)
  return tostring(path or ""):match("([^/\\]+)$") or "Empty"
end

function M.default_fader_db(host)
  local db=tonumber(host and host.GetExtState and host.GetExtState("ReaDrum5k","default_fader_db"))
  return (db==-3 or db==0) and db or -6
end

function M.new_rack(default_db)
  -- Keep the historical value for unchanged preferences and legacy projects.
  local volume=default_db==0 and .5 or default_db==-3 and .5*10^(-3/40) or .354
  local ids = model.new_id_factory("readrum")
  local pads, lanes = {}, {}
  for index = 1, 128 do
    local pad = model.new_pad({ logical_index = index, name = string.format("Pad %03d", index), sample = false,
      default_controls = { playback_mode = "one_shot", gate_release_ms = 10, envelope_enabled = false, legato_enabled = true, slide_retrigger = true, slide_crossfade_ms = 20,
        envelope_mode = "ahd", envelope_layout_version = 2, hold = 0, fade_in = 0, fade_out = 0, volume = volume },
    }, ids)
    pads[index] = pad
    lanes[index] = model.new_lane({
      pad_id = pad.id, step_count = 16, division_num = 1, division_den = 16,
    }, ids)
  end
  local variation = model.new_variation({ name = "Variation 1", lanes = lanes }, ids)
  -- The runtime schema requires one container; it is not a user-facing pattern layer.
  local pattern = model.new_pattern({ name = "Variation Library", variations = { variation } }, ids)
  local rack=model.new_rack({ id = "readrum_main", name = "ReaDrumXT", pads = pads, patterns = { pattern }, selected_bank = 1, accent_multiplier = 130, global_velocity_sensitivity = 100 }, ids)
  rack.playback_mode="continuous"
  rack.voice_policy_version=2
  rack.noteoff_policy_version=2
  return rack
end

function M.new_pattern(pads, name, source, prefix)
  local ids = model.new_id_factory(prefix or ("readrum_pattern_" .. os.time()))
  local variations = {}
  if source then
    for variation_index, old_variation in ipairs(source.variations) do
      local lanes = {}
      for lane_index, old_lane in ipairs(old_variation.lanes) do
        lanes[lane_index] = model.new_lane({
          pad_id = old_lane.pad_id, step_count = old_lane.step_count,
          division_num = old_lane.division_num, division_den = old_lane.division_den,
          phase = old_lane.phase, swing = old_lane.swing, defaults = old_lane.defaults,
          timing_offset=old_lane.timing_offset, velocity_scale=old_lane.velocity_scale, velocity_sensitivity=old_lane.velocity_sensitivity, gate_scale=old_lane.gate_scale, accentuator_enabled=old_lane.accentuator_enabled, global_swing_enabled=old_lane.global_swing_enabled, global_gate_enabled=old_lane.global_gate_enabled, global_velocity_sensitivity_enabled=old_lane.global_velocity_sensitivity_enabled, global_velocity_humanize_enabled=old_lane.global_velocity_humanize_enabled, velocity_humanize=old_lane.velocity_humanize, timing_humanize=old_lane.timing_humanize, pitch_humanize=old_lane.pitch_humanize, pan_humanize=old_lane.pan_humanize,
          steps = old_lane.steps,
        }, ids)
      end
      variations[variation_index] = model.new_variation({
        name = old_variation.name, switch_quantization = old_variation.switch_quantization, lanes = lanes,
        swing=old_variation.swing, groove=model.deep_copy(old_variation.groove), velocity_humanize=old_variation.velocity_humanize, timing_humanize=old_variation.timing_humanize, pitch_humanize=old_variation.pitch_humanize, pan_humanize=old_variation.pan_humanize,
      }, ids)
    end
  else
    local lanes = {}
    for index, pad in ipairs(pads) do lanes[index] = model.new_lane({ pad_id=pad.id, step_count=16, division_num=1, division_den=16 }, ids) end
    variations[1] = model.new_variation({ name="Variation 1", lanes=lanes }, ids)
  end
  return model.new_pattern({ name=name or "Pattern", seed=source and source.seed or 0, variations=variations }, ids)
end

function M.new_variation(pads, name, source, prefix)
  local ids = model.new_id_factory(prefix or ("readrum_variation_" .. os.time()))
  local lanes = {}
  for index, pad in ipairs(pads) do
    local old = source and source.lanes[index]
    lanes[index] = model.new_lane(old and {
      pad_id=pad.id, step_count=old.step_count, division_num=old.division_num, division_den=old.division_den,
      phase=old.phase, swing=old.swing, defaults=old.defaults, steps=old.steps,
      timing_offset=old.timing_offset, velocity_scale=old.velocity_scale, velocity_sensitivity=old.velocity_sensitivity, gate_scale=old.gate_scale, accentuator_enabled=old.accentuator_enabled, global_swing_enabled=old.global_swing_enabled, global_gate_enabled=old.global_gate_enabled, global_velocity_sensitivity_enabled=old.global_velocity_sensitivity_enabled, global_velocity_humanize_enabled=old.global_velocity_humanize_enabled, velocity_humanize=old.velocity_humanize, timing_humanize=old.timing_humanize, pitch_humanize=old.pitch_humanize, pan_humanize=old.pan_humanize,
    } or { pad_id=pad.id, step_count=16, division_num=1, division_den=16 }, ids)
  end
  return model.new_variation({ name=name or "Variation", switch_quantization=source and source.switch_quantization or "bar", lanes=lanes,
    swing=source and source.swing or 0, groove=source and model.deep_copy(source.groove) or nil, velocity_humanize=source and source.velocity_humanize or 0, timing_humanize=source and source.timing_humanize or 0, pitch_humanize=source and source.pitch_humanize or 0, pan_humanize=source and source.pan_humanize or 0 }, ids)
end

local function decode_rack(payload)
  local rack=json.decode(payload)
  assert(type(rack)=="table","Project state must contain a rack")
  if rack._readrum_sparse_state then rack=M.expand(rack) end
  -- Logical outputs are independent of sampler bank locations. Older RS5K
  -- projects implicitly used the main output, so upgrade them losslessly.
  if type(rack.outputs)~="table" or #rack.outputs==0 then
    rack.outputs={model.new_output({id="main",name="Main"})}
  end
  for _,pad in ipairs(rack.pads or {}) do
    if type(pad.output_id)~="string" or pad.output_id=="" then pad.output_id="main" end
    pad.muted=pad.muted==true
    pad.soloed=pad.soloed==true
  end
  -- Upgrade projects made before accents were stored independently from
  -- velocity. Preserve their audible level while recovering a base velocity.
  rack.accent_multiplier=math.max(100,math.min(200,tonumber(rack.accent_multiplier) or 130))
  rack.global_gate_scale=math.max(0,math.min(200,tonumber(rack.global_gate_scale) or 100))
  rack.global_velocity_sensitivity=math.max(0,math.min(200,tonumber(rack.global_velocity_sensitivity) or 100))
  rack.accentuator=rack.accentuator or {enabled=true,amount=100,bands={0,0,0,0}}
  rack.accentuator.enabled=rack.accentuator.enabled~=false
  rack.accentuator.amount=math.max(0,math.min(200,tonumber(rack.accentuator.amount) or 100))
  rack.accentuator.bands=rack.accentuator.bands or {0,0,0,0}
  for i=1,4 do rack.accentuator.bands[i]=math.max(-100,math.min(100,tonumber(rack.accentuator.bands[i]) or 0)) end
  for _,pattern in ipairs(rack.patterns or {}) do for _,variation in ipairs(pattern.variations or {}) do for _,lane in ipairs(variation.lanes or {}) do
    lane.velocity_sensitivity=math.max(0,math.min(200,tonumber(lane.velocity_sensitivity) or 100))
    lane.accentuator_enabled=lane.accentuator_enabled~=false
    lane.global_swing_enabled=lane.global_swing_enabled~=false
    lane.global_gate_enabled=lane.global_gate_enabled~=false
    lane.global_velocity_sensitivity_enabled=lane.global_velocity_sensitivity_enabled~=false
    lane.global_velocity_humanize_enabled=lane.global_velocity_humanize_enabled~=false
  end end end
  if rack.name=="ReaDrum" or rack.name=="ReaDrum5k" then rack.name="ReaDrumXT" end
  if rack.playback_mode=="items" then rack.playback_mode="events"
  elseif rack.playback_mode~="events" and rack.playback_mode~="rendered" then rack.playback_mode="continuous" end
  -- Policy v2 separates voice capacity from choking. Preserve the previous
  -- mono/retrigger sound while making Choke Off capable of real overlap.
  if rack.voice_policy_version~=2 then
    for _,pad in ipairs(rack.pads or {}) do pad.polyphony=16;pad.self_choke=true end
    rack.voice_policy_version=2
  end
  if rack.noteoff_policy_version~=2 then
    for _,pad in ipairs(rack.pads or {}) do
      local controls=pad.default_controls or {};pad.default_controls=controls
      if controls.playback_mode~="gate" then controls.playback_mode="one_shot" end
      controls.gate_release_ms=math.max(0,math.min(2000,tonumber(controls.gate_release_ms) or 10))
      -- Preserve an intentionally edited legacy ADSR, while keeping the
      -- advanced envelope out of the default signal path.
      if controls.envelope_enabled==nil then
        controls.envelope_enabled=(tonumber(controls.attack) or 0)>0 or (tonumber(controls.release) or 0)>0 or math.abs((tonumber(controls.sustain) or 1)-1)>.000001
      end
      if controls.legato_enabled==nil then controls.legato_enabled=true end
      if controls.slide_retrigger==nil then controls.slide_retrigger=true end
      if controls.slide_crossfade_ms==nil then controls.slide_crossfade_ms=20 end
      if controls.fade_in==nil then controls.fade_in=0 end
      if controls.fade_out==nil then controls.fade_out=0 end
      controls.obey_note_offs=nil
    end
    rack.noteoff_policy_version=2
  end
  for _,pad in ipairs(rack.pads or {}) do
    local controls=pad.default_controls or {};pad.default_controls=controls
    -- Builds before the selectable envelope always implemented ADSR. Preserve
    -- their sound; only newly created pads default to the drum-oriented AHD.
    if controls.envelope_mode~="ahd" and controls.envelope_mode~="adsr" then controls.envelope_mode="adsr" end
    if controls.envelope_layout_version~=2 then
      if controls.envelope_mode=="ahd" and controls.ahd_decay==nil then controls.ahd_decay=controls.decay;controls.decay=nil end
      controls.envelope_layout_version=2
    end
    controls.hold=math.max(0,math.min(1,tonumber(controls.hold) or 0))
    if controls.filter_type~="lowpass" and controls.filter_type~="highpass" and controls.filter_type~="bandpass" then controls.filter_type="off" end
    controls.filter_cutoff_hz=math.max(20,math.min(20000,tonumber(controls.filter_cutoff_hz) or 20000))
    controls.filter_resonance=math.max(0,math.min(1,tonumber(controls.filter_resonance) or 0))
    controls.drive=math.max(0,math.min(1,tonumber(controls.drive) or 0))
    if controls.drive_character~="soft" then controls.drive_character="hard" end
  end
  for _,pattern in ipairs(rack.patterns or {}) do for _,variation in ipairs(pattern.variations or {}) do for _,lane in ipairs(variation.lanes or {}) do for _,step in ipairs(lane.steps or {}) do
    if step.accent==nil then
      step.accent=(tonumber(step.velocity) or 100)>100
      if step.accent then step.velocity=math.max(1,math.min(127,math.floor(step.velocity*100/rack.accent_multiplier+.5))) end
    end
    if step.cut==nil then step.cut=false end
    if step.slide==nil then step.slide=false end
  end end end end
  local valid, failure = model.validate_rack(rack)
  assert(valid,"Project state is invalid: "..tostring(failure))
  return rack
end

function M.load(host,project)
  local errors={}
  local function attempt(folder)
    local payload,failure=read_chunks(host,project,folder)
    if payload then
      local ok,rack=pcall(decode_rack,payload)
      if ok then return rack end
      failure=tostring(rack)
    end
    if failure then errors[#errors+1]=failure end
  end
  local rack=attempt(nil)
  if rack then return rack,true end
  local folder=folder_track(host,project)
  if folder then
    rack=attempt(folder)
    if rack then return rack,true,"Recovered ReaDrum state from its folder track" end
  end
  -- Never reconcile/save a blank rack over an existing but unreadable kit.
  if #errors>0 then error(table.concat(errors,"; ")..". Saved ReaDrum state was left intact.",2) end
  return M.new_rack(M.default_fader_db(host)),false
end

-- Encode and stage into the inactive slot across frames. Only state_head
-- makes those chunks visible; cancellation never touches the committed slot.
function M.begin_save(host,project,rack,probe,compact)
  -- Normal UI edits reuse the already completed asynchronous undo checkpoint.
  -- Callers without one retain the old synchronous fallback for compatibility.
  compact=compact or M.compact(rack)
  return {host=host,project=project,rack_id=rack.id,probe=probe,phase="encode",encode=json.begin_encode(compact,256)}
end

local function prepare_save_operations(task,payload)
  local host,project=task.host,task.project
  local count=math.max(1,math.ceil(#payload/M.CHUNK))
  assert(count<=256,"ReaDrum state exceeds the project storage capacity")
  local folder=folder_track(host,project,task.rack_id)
  local head=state_get(host,project,nil,"state_head")
  local slot=head:sub(1,1)=="a" and "b" or "a"
  local folder_head=folder and state_get(host,project,folder,"state_head") or ""
  local folder_slot=folder_head:sub(1,1)=="a" and "b" or "a"
  local suffix=string.format(":%d:%d:%s",count,#payload,checksum(payload))
  local operations={}
  for index=1,count do
    local chunk=payload:sub((index-1)*M.CHUNK+1,index*M.CHUNK)
    operations[#operations+1]={"project",string.format("state_%s_%03d",slot,index),chunk}
    if folder then operations[#operations+1]={"track",string.format("P_EXT:ReaDrum.state_%s_%03d",folder_slot,index),chunk} end
  end
  task.head,task.folder_head=slot..suffix,folder_slot..suffix
  task.folder,task.operations,task.index,task.bytes=folder,operations,1,#payload
  task.phase="write"
end

local function commit_save(task)
  -- Publish both complete copies in the same defer cycle.
  if task.folder then
    assert(task.host.GetSetMediaTrackInfo_String(task.folder,"P_EXT:ReaDrum.state_head",task.folder_head,true),"Could not commit track state")
  end
  assert(task.host.SetProjExtState(task.project,M.SECTION,"state_head",task.head)>0,"Could not commit project state")
  task.host.MarkProjectDirty(task.project)
  task.phase="done"
  return true,task.bytes
end

function M.save(host,project,rack)
  model.assert_valid(rack)
  local task={host=host,project=project,rack_id=rack.id}
  prepare_save_operations(task,json.encode(M.compact(rack)))
  M.step_save(task,#task.operations)
  return task.bytes
end

function M.step_save(task,budget)
  if task.phase=="done" then return true,task.bytes end
  if task.phase=="encode"then
    local complete,payload=json.step_encode(task.encode)
    if not complete then return false end
    prepare_save_operations(task,payload)
    return false
  end
  budget=math.max(1,math.floor(budget or 1))
  for _=1,budget do
    local operation=task.operations[task.index]
    if not operation then return commit_save(task) end
    if operation[1]=="project" then assert(task.host.SetProjExtState(task.project,M.SECTION,operation[2],operation[3])>0,"Could not stage project state")
    else assert(task.host.GetSetMediaTrackInfo_String(task.folder,operation[2],operation[3],true),"Could not stage track state") end
    task.index=task.index+1
  end
  if task.index>#task.operations then return commit_save(task) end
  return false
end

function M.sample_label(pad)
  if pad.sample == false or pad.sample == nil then return "Empty" end
  return filename(type(pad.sample) == "table" and pad.sample.path or pad.sample)
end

return M
