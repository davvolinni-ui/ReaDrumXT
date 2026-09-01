local tags = require("ReaDrum.reaper.tags")
local rs5k = require("ReaDrum.reaper.rs5k")
local sampler_engine = require("ReaDrum.reaper.sampler_engine")

local M = {}
M.DUPLICATE_POLICY = "earliest_project_order_wins;later_track_tags_detached"

local function pad_send_flags(logical_index)
  local zero = logical_index - 1
  local src_channel = (zero % 16) + 1
  local src_bus = math.floor(zero / 16) + 1
  local dst_channel, dst_bus = 1, 1
  return src_channel | (dst_channel << 5) | (src_bus << 14) | (dst_bus << 22)
end

M.pad_send_flags = pad_send_flags

local function key(kind, object_id)
  return kind .. "\0" .. object_id
end

local function desired_objects(rack, pad_ids, include_pad_tracks)
  local desired = {
    { kind = "folder", object_id = rack.id .. "/folder", name = rack.name },
    { kind = "sequencer", object_id = rack.id .. "/sequencer", name = "ReaDrumXT MIDI" },
  }
  for _, pad in ipairs(rack.pads) do
    if include_pad_tracks and pad.sample ~= false and (not pad_ids or pad_ids[pad.id]) then
      desired[#desired + 1] = {
        kind = "pad", object_id = pad.id, pad_id = pad.id,
        logical_index = pad.logical_index,
        name = pad.name or string.format("Pad %03d", pad.logical_index),
      }
    end
  end
  if not include_pad_tracks then
    local used={};for _,pad in ipairs(rack.pads)do if pad.sample~=false then used[pad.output_id]=true end end
    for _,output in ipairs(rack.outputs or {})do if output.id=="main"or used[output.id]then
      desired[#desired+1]={kind="output",object_id=output.id,name=output.id=="main"and "Output 1"or output.name}
    end end
  end
  desired[#desired+1]={kind="aux",object_id="aux_a",name="ReaDrumXT AUX A"}
  desired[#desired+1]={kind="aux",object_id="aux_b",name="ReaDrumXT AUX B"}
  return desired
end

local function discover(adapter, rack_id, report)
  local found = {}
  for index = 0, adapter:track_count() - 1 do
    local track = adapter:track_at(index)
    local tag = tags.read_track(adapter, track)
    if tag and tag.rack_id == rack_id then
      local object_key = key(tag.kind, tag.object_id)
      if found[object_key] then
        tags.clear_track(adapter, track)
        report.duplicates_repaired = report.duplicates_repaired + 1
        report.changed = true
      else
        found[object_key] = track
      end
    end
  end
  return found
end

local function create_track(adapter, spec, rack_id, report, found)
  local insertion=adapter:track_count()
  if found and spec.kind=="output" then
    local first_aux
    for _,aux_id in ipairs({"aux_a","aux_b"}) do
      local aux=found[key("aux",aux_id)]
      if aux then local index=adapter:track_index(aux);first_aux=first_aux and math.min(first_aux,index) or index end
    end
    if first_aux then insertion=first_aux else
      local last=-1;for _,managed in pairs(found) do last=math.max(last,adapter:track_index(managed)) end
      if last>=0 then insertion=last+1 end
    end
  elseif found and (spec.kind=="sequencer" or spec.kind=="aux") then
    local last=-1
    for _,managed in pairs(found) do last=math.max(last,adapter:track_index(managed)) end
    if last>=0 then insertion=last+1 end
  end
  local prior=insertion>0 and adapter:track_at(insertion-1) or nil
  local prior_depth=prior and adapter:get_track_value(prior,"I_FOLDERDEPTH") or 0
  local track = adapter:insert_track(insertion)
  -- If the previous managed child closed the folder, transfer that closing
  -- edge to the newly inserted output so it cannot appear outside the rack.
  if prior and prior_depth<0 and (spec.kind=="sequencer" or spec.kind=="output") then
    adapter:set_track_value(prior,"I_FOLDERDEPTH",0)
    adapter:set_track_value(track,"I_FOLDERDEPTH",prior_depth)
  end
  tags.write_track(adapter, track, {
    kind = spec.kind, rack_id = rack_id, object_id = spec.object_id,
    logical_index = spec.logical_index,
  })
  adapter:set_track_string(track, "P_NAME", spec.name)
  if spec.kind == "sequencer" then
    adapter:set_track_value(track, "B_MAINSEND", 0)
    adapter:set_track_value(track, "I_RECARM", 1)
    adapter:set_track_value(track, "I_RECMON", 1)
    adapter:set_track_value(track, "I_RECINPUT", 6112) -- all MIDI devices, all channels
  end
  report.created_tracks = report.created_tracks + 1
  report.changed = true
  return track
end

local function reconcile_folder_shape(adapter, rack, found, report, include_pad_tracks)
  local ordered = {
    found[key("folder", rack.id .. "/folder")],
    found[key("sequencer", rack.id .. "/sequencer")],
  }
  if include_pad_tracks then for _, pad in ipairs(rack.pads) do
    if pad.sample ~= false then ordered[#ordered + 1] = found[key("pad", pad.id)] end
  end end
  if not include_pad_tracks then
    local used={};for _,pad in ipairs(rack.pads)do if pad.sample~=false then used[pad.output_id]=true end end
    for _,output in ipairs(rack.outputs or{})do if output.id=="main"or used[output.id]then ordered[#ordered+1]=found[key("output",output.id)]end end
  end
  local first = adapter:track_index(ordered[1])
  for index, track in ipairs(ordered) do
    if adapter:track_index(track) ~= first + index - 1 then
      report.folder_shape = "preserved_noncontiguous_user_layout"
      return
    end
  end
  for index, track in ipairs(ordered) do
    local wanted = index == 1 and 1 or (index == #ordered and -1 or 0)
    if adapter:get_track_value(track, "I_FOLDERDEPTH") ~= wanted then
      adapter:set_track_value(track, "I_FOLDERDEPTH", wanted)
      report.changed = true
    end
  end
  -- AUX returns are managed siblings immediately after the rack folder. This
  -- keeps drum-bus clipping/compression off the wet returns and lets unrelated
  -- project tracks send to the same reverb or delay returns.
  for _,aux_id in ipairs({"aux_a","aux_b"}) do
    local aux=found[key("aux",aux_id)]
    if aux and adapter:get_track_value(aux,"I_FOLDERDEPTH")~=0 then adapter:set_track_value(aux,"I_FOLDERDEPTH",0);report.changed=true end
    if aux and adapter:get_track_value(aux,"B_MAINSEND")~=1 then adapter:set_track_value(aux,"B_MAINSEND",1);report.changed=true end
  end
  report.folder_shape = "managed_folder_with_project_aux_returns"
end

local function reconcile_output_send(adapter,rack_id,sequencer,track,output_id,pair,report)
  local tag_id="logical-output-"..output_id;local wanted=tags.send_key(rack_id,tag_id);local canonical
  for index=0,adapter:send_count(sequencer)-1 do local tag=tags.read_send(adapter,sequencer,index)
    if tag and tag.rack_id==rack_id and tag.object_id==wanted and adapter:send_destination(sequencer,index)==track then canonical=index;break end
  end
  if canonical==nil then canonical=adapter:create_send(sequencer,track);tags.write_send(adapter,sequencer,canonical,rack_id,tag_id);report.created_sends=report.created_sends+1;report.changed=true end
  local desired={I_SRCCHAN=pair*2,I_DSTCHAN=0,I_MIDIFLAGS=31,D_VOL=1}
  for name,value in pairs(desired)do if adapter:get_send_value(sequencer,canonical,name)~=value then adapter:set_send_value(sequencer,canonical,name,value);report.changed=true end end
  return wanted
end

local function reconcile_aux_bus_send(adapter,rack_id,sequencer,track,aux_id,source_channel,report)
  local tag_id="aux-bus-"..aux_id;local wanted=tags.send_key(rack_id,tag_id);local canonical
  for index=0,adapter:send_count(sequencer)-1 do local tag=tags.read_send(adapter,sequencer,index)
    if tag and tag.rack_id==rack_id and tag.object_id==wanted and adapter:send_destination(sequencer,index)==track then canonical=index;break end
  end
  if canonical==nil then canonical=adapter:create_send(sequencer,track);tags.write_send(adapter,sequencer,canonical,rack_id,tag_id);report.created_sends=report.created_sends+1;report.changed=true end
  local desired={I_SRCCHAN=source_channel,I_DSTCHAN=0,I_MIDIFLAGS=31,D_VOL=1,I_SENDMODE=0}
  for name,value in pairs(desired)do if adapter:get_send_value(sequencer,canonical,name)~=value then adapter:set_send_value(sequencer,canonical,name,value);report.changed=true end end
  return wanted
end

local function reconcile_output_aux_send(adapter,rack_id,source,destination,output_id,aux_id,amount,report)
  local tag_id="output-aux-"..output_id.."-"..aux_id;local wanted=tags.send_key(rack_id,tag_id);local canonical
  for index=0,adapter:send_count(source)-1 do local tag=tags.read_send(adapter,source,index)
    if tag and tag.rack_id==rack_id and tag.object_id==wanted and adapter:send_destination(source,index)==destination then canonical=index;break end
  end
  if canonical==nil then canonical=adapter:create_send(source,destination);tags.write_send(adapter,source,canonical,rack_id,tag_id);report.created_sends=report.created_sends+1;report.changed=true end
  local desired={I_SRCCHAN=0,I_DSTCHAN=0,I_MIDIFLAGS=31,D_VOL=math.max(0,math.min(1,tonumber(amount)or 0)),I_SENDMODE=0}
  for name,value in pairs(desired)do if adapter:get_send_value(source,canonical,name)~=value then adapter:set_send_value(source,canonical,name,value);report.changed=true end end
end

local function reconcile_send(adapter, rack_id, sequencer, pad_track, pad, report)
  local wanted_key = tags.send_key(rack_id, pad.id)
  local canonical, duplicates = nil, {}
  for index = 0, adapter:send_count(sequencer) - 1 do
    local tag = tags.read_send(adapter, sequencer, index)
    if tag and tag.rack_id == rack_id and tag.object_id == wanted_key and
        adapter:send_destination(sequencer, index) == pad_track then
      if canonical == nil then canonical = index else duplicates[#duplicates + 1] = index end
    end
  end
  for index = #duplicates, 1, -1 do
    adapter:remove_send(sequencer, duplicates[index])
    report.duplicate_sends_removed = report.duplicate_sends_removed + 1
    report.changed = true
  end
  if canonical == nil then
    canonical = adapter:create_send(sequencer, pad_track)
    tags.write_send(adapter, sequencer, canonical, rack_id, pad.id)
    report.created_sends = report.created_sends + 1
    report.changed = true
  end
  local flags = pad_send_flags(pad.logical_index)
  if adapter:get_send_value(sequencer, canonical, "I_SRCCHAN") ~= -1 then
    adapter:set_send_value(sequencer, canonical, "I_SRCCHAN", -1)
    report.repaired_sends = report.repaired_sends + 1
    report.changed = true
  end
  if adapter:get_send_value(sequencer, canonical, "I_MIDIFLAGS") ~= flags then
    adapter:set_send_value(sequencer, canonical, "I_MIDIFLAGS", flags)
    report.repaired_sends = report.repaired_sends + 1
    report.changed = true
  end
end

local function reconcile_preview_send(adapter,rack_id,sequencer,folder,report)
  local preview_id="preview-audio"
  local wanted_key=tags.send_key(rack_id,preview_id)
  local canonical,duplicates=nil,{}
  for index=0,adapter:send_count(sequencer)-1 do
    local tag=tags.read_send(adapter,sequencer,index)
    if tag and tag.rack_id==rack_id and tag.object_id==wanted_key and adapter:send_destination(sequencer,index)==folder then
      if canonical==nil then canonical=index else duplicates[#duplicates+1]=index end
    end
  end
  for index=#duplicates,1,-1 do adapter:remove_send(sequencer,duplicates[index]);report.duplicate_sends_removed=report.duplicate_sends_removed+1;report.changed=true end
  if canonical==nil then
    canonical=adapter:create_send(sequencer,folder)
    tags.write_send(adapter,sequencer,canonical,rack_id,preview_id)
    report.created_sends=report.created_sends+1;report.changed=true
  end
  local desired={I_SRCCHAN=0,I_DSTCHAN=0,I_MIDIFLAGS=31,D_VOL=1}
  for key,value in pairs(desired) do
    if adapter:get_send_value(sequencer,canonical,key)~=value then adapter:set_send_value(sequencer,canonical,key,value);report.repaired_sends=report.repaired_sends+1;report.changed=true end
  end
end

local function reconcile_sampler(adapter, rack, pad_track, pad, report)
  if adapter:get_track_value(pad_track, "I_FREEZECOUNT") > 0 then
    report.frozen_pads_skipped = report.frozen_pads_skipped + 1
    return
  end
  local fx, created = rs5k.find_or_add(adapter, pad_track, rack.id, pad.id)
  if created then report.created_rs5k = report.created_rs5k + 1; report.changed = true end
  local _, controls_changed = rs5k.apply_controls(adapter, pad_track, fx, pad.default_controls, pad.polyphony)
  if controls_changed then report.controls_updated = report.controls_updated + 1; report.changed = true end
  local sample = rs5k.load_sample(adapter, pad_track, fx, pad.sample)
  if sample.changed then report.samples_updated = report.samples_updated + 1; report.changed = true end
  if sample.state == "missing" then
    report.missing_media[#report.missing_media + 1] = { pad_id = pad.id, path = sample.path }
  end
end

local function reconcile_pad_visibility(adapter,pad_track,report)
  if adapter:get_track_string(pad_track,"P_EXT:READRUM_VISIBILITY_INIT")~="1" then
    adapter:set_track_value(pad_track,"B_SHOWINTCP",0)
    adapter:set_track_value(pad_track,"B_SHOWINMIXER",0)
    adapter:set_track_string(pad_track,"P_EXT:READRUM_VISIBILITY_INIT","1")
    report.changed=true
  end
end

local function reconcile_pad_identity(adapter,rack_id,pad_track,pad,report)
  local tag=tags.read_track(adapter,pad_track)
  if tag and tag.logical_index~=tostring(pad.logical_index) then
    tags.write_track(adapter,pad_track,{kind="pad",rack_id=rack_id,object_id=pad.id,logical_index=pad.logical_index})
    report.changed=true
  end
end

local function reconcile_sequencer_visibility(adapter,sequencer,report)
  if adapter:get_track_string(sequencer,"P_EXT:READRUM_MIXER_VISIBILITY_INIT")~="1" then
    -- The sequencer track owns variation events and MIDI routing, so keep it in
    -- the arrange view but do not spend a mixer channel on infrastructure.
    adapter:set_track_value(sequencer,"B_SHOWINTCP",1)
    adapter:set_track_value(sequencer,"B_SHOWINMIXER",0)
    adapter:set_track_string(sequencer,"P_EXT:READRUM_MIXER_VISIBILITY_INIT","1")
    report.changed=true
  end
end

local function reconcile_cleared_sampler(adapter, rack, pad_track, pad, report)
  if not pad_track or adapter:get_track_value(pad_track, "I_FREEZECOUNT") > 0 then return end
  local fx=rs5k.find_managed(adapter,pad_track,rack.id,pad.id)
  if not fx then return end
  local sample=rs5k.load_sample(adapter,pad_track,fx,false)
  if sample.changed then report.samples_updated=report.samples_updated+1;report.changed=true end
end

function M.reconcile(adapter, rack, options)
  options = options or {}
  assert(type(adapter) == "table", "adapter is required")
  assert(type(rack) == "table" and rack.type == "Rack", "Rack model is required")
  local report = {
    schema_version = 1, rack_id = rack.id, changed = false,
    duplicate_policy = M.DUPLICATE_POLICY,
    created_tracks = 0, created_sends = 0, repaired_sends = 0,
    deleted_tracks = 0,
    duplicates_repaired = 0, duplicate_sends_removed = 0, preserved_untagged = true,
    created_rs5k = 0, controls_updated = 0, samples_updated = 0,
    frozen_pads_skipped = 0, missing_media = {},
  }
  if options.undo ~= false then adapter:begin_undo(options.undo_label or "ReaDrum: reconcile rack lifecycle") end
  local ok, failure = xpcall(function()
    local found = discover(adapter, rack.id, report)
    local use_bank_engine=options.engine=="sampler_bank"
    -- Incremental sample loading passes a pad filter. Honor it during track
    -- creation so the first batch cannot create the entire drop synchronously.
    for _, spec in ipairs(desired_objects(rack, options.pad_ids, not use_bank_engine)) do
      local object_key = key(spec.kind, spec.object_id)
      if not found[object_key] then found[object_key] = create_track(adapter, spec, rack.id, report,found) end
    end
    if use_bank_engine then
      local wanted={}
      for _,output in ipairs(rack.outputs or {}) do wanted[output.id]=true end
      for object_key,track in pairs(found) do
        local tag=tags.read_track(adapter,track)
        if tag and tag.kind=="output" and not wanted[tag.object_id] then
          adapter:delete_track(track);found[object_key]=nil;report.deleted_tracks=report.deleted_tracks+1;report.changed=true
        end
      end
    end
    local folder=found[key("folder",rack.id.."/folder")]
    if adapter:get_track_string(folder,"P_NAME")~=rack.name then adapter:set_track_string(folder,"P_NAME",rack.name);report.changed=true end
    reconcile_folder_shape(adapter, rack, found, report, not use_bank_engine)
    local sequencer = found[key("sequencer", rack.id .. "/sequencer")]
    if adapter:get_track_string(sequencer,"P_NAME")~="ReaDrumXT MIDI" then adapter:set_track_string(sequencer,"P_NAME","ReaDrumXT MIDI");report.changed=true end
    reconcile_sequencer_visibility(adapter,sequencer,report)
    if not use_bank_engine then reconcile_preview_send(adapter,rack.id,sequencer,folder,report) end
    if use_bank_engine then
      -- Retire all legacy per-pad MIDI sends without deleting the user's old
      -- tracks. They remain available for rollback, but cannot double-trigger.
      local aux_a,aux_b=found[key("aux","aux_a")],found[key("aux","aux_b")]
      local preserved={}
      preserved[reconcile_aux_bus_send(adapter,rack.id,sequencer,aux_a,"aux_a",32,report)]=true
      preserved[reconcile_aux_bus_send(adapter,rack.id,sequencer,aux_b,"aux_b",34,report)]=true
      for pair,output in ipairs(rack.outputs or{})do local track=found[key("output",output.id)];if track then preserved[reconcile_output_send(adapter,rack.id,sequencer,track,output.id,pair-1,report)]=true end end
      for _,output in ipairs(rack.outputs or{})do local track=found[key("output",output.id)];if track then reconcile_output_aux_send(adapter,rack.id,track,aux_a,output.id,"a",output.aux_a_send,report);reconcile_output_aux_send(adapter,rack.id,track,aux_b,output.id,"b",output.aux_b_send,report)end end
      for send=adapter:send_count(sequencer)-1,0,-1 do
        local tag=tags.read_send(adapter,sequencer,send)
        if tag and tag.rack_id==rack.id and not preserved[tag.object_id] then
          adapter:remove_send(sequencer,send);report.changed=true
        end
      end
      report.sampler_cache,report.sampler_engine=sampler_engine.reconcile(adapter.host,sequencer,rack,options.sampler_cache)
      report.changed=true
    else for _, pad in ipairs(rack.pads) do
      local requested=not options.pad_ids or options.pad_ids[pad.id]
      if requested and pad.sample ~= false then
        local pad_track = found[key("pad", pad.id)]
        reconcile_pad_identity(adapter,rack.id,pad_track,pad,report)
        reconcile_pad_visibility(adapter,pad_track,report)
        reconcile_send(adapter, rack.id, sequencer, pad_track, pad, report)
        -- Phase 2A test doubles intentionally implement only the older narrow
        -- lifecycle boundary. Real adapters and Phase 2B doubles expose FX.
        if adapter.fx_count and options.samplers ~= false then
          reconcile_sampler(adapter, rack, pad_track, pad, report)
        end
      elseif requested and adapter.fx_count and options.samplers ~= false then
        local pad_track=found[key("pad",pad.id)]
        if options.delete_empty_tracks and pad_track and adapter.delete_track then
          adapter:delete_track(pad_track);report.deleted_tracks=report.deleted_tracks+1;report.changed=true
        else
          reconcile_cleared_sampler(adapter,rack,pad_track,pad,report)
        end
      end
    end end
  end, debug.traceback)
  if options.undo ~= false then adapter:end_undo(report.changed) end
  if not ok then error(failure, 0) end
  return report
end

function M.inspect(adapter, rack_id)
  local result = { folder = 0, sequencer = 0, pad = 0, managed = 0, duplicates = 0 }
  local seen = {}
  for index = 0, adapter:track_count() - 1 do
    local tag = tags.read_track(adapter, adapter:track_at(index))
    if tag and tag.rack_id == rack_id then
      result.managed = result.managed + 1
      result[tag.kind] = (result[tag.kind] or 0) + 1
      local object_key = key(tag.kind, tag.object_id)
      if seen[object_key] then result.duplicates = result.duplicates + 1 end
      seen[object_key] = true
    end
  end
  return result
end

return M
