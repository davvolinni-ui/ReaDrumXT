local model = require("ReaDrum.core.model")
local json = require("ReaDrum.core.json")
local clipboard = require("ReaDrum.core.clipboard")
local Adapter = require("ReaDrum.reaper.adapter")
local tags = require("ReaDrum.reaper.tags")
local lifecycle = require("ReaDrum.reaper.lifecycle")
local rs5k = require("ReaDrum.reaper.rs5k")
local sampler_engine = require("ReaDrum.reaper.sampler_engine")
local sampler_bank = require("ReaDrum.reaper.sampler_bank")
local snapshot = require("ReaDrum.reaper.snapshot")
local snapshot_v2 = require("ReaDrum.reaper.snapshot_v2")
local scheduler_oracle = require("ReaDrum.reaper.scheduler_oracle")
local transport = require("ReaDrum.reaper.transport_map")
local state = require("ReaDrum.app.state")
local bridge = require("ReaDrum.app.bridge")

local Controller = {}
Controller.__index = Controller
local clipper_reloaded=setmetatable({},{__mode="k"})

local function engine_namespace(host,project)
  local text=host.GetProjectGUID and host.GetProjectGUID(project) or tostring(project or 0)
  local hash=2166136261
  for index=1,#text do hash=(hash ~ text:byte(index))*16777619 & 0xffffffff end
  -- One namespace owns all eight sampler banks. Named JSFX gmem contains
  -- 8,388,608 entries, so eight namespaces fit; 64 would alias addresses.
  return hash%8
end

local function snapshot_bases(_) return 0,300000 end

local function sample_name(pad)
  local sample=pad and pad.sample
  local path=type(sample)=="table" and sample.path or sample
  if type(path)~="string" or path=="" then return nil end
  return (path:match("([^/\\]+)%.[^%.]+$") or path:match("([^/\\]+)$")):gsub("[%c]",""):sub(1,64)
end

local function audio_rate(host, project)
  if host.GetAudioDeviceInfo then
    local ok, value = host.GetAudioDeviceInfo("SRATE", "")
    local rate = tonumber(value)
    if ok and rate and rate > 0 then return math.floor(rate + 0.5) end
  end
  local rate = host.GetSetProjectInfo(project, "PROJECT_SRATE", 0, false)
  return rate and rate > 0 and math.floor(rate + 0.5) or 48000
end

local function time_signatures(host, project, qn_end)
  local result, seen = {}, {}
  local function add(qn, num, den)
    if qn >= 0 and qn <= qn_end and not seen[qn] then
      result[#result + 1] = { qn = qn, num = math.max(1, num), den = math.max(1, den) }; seen[qn] = true
    end
  end
  local num, den = host.TimeMap_GetTimeSigAtTime(project, 0)
  add(0, num or 4, den or 4)
  for index = 0, host.CountTempoTimeSigMarkers(project) - 1 do
    local ok, time, _, _, _, marker_num, marker_den = host.GetTempoTimeSigMarker(project, index)
    if ok and marker_num and marker_num > 0 and marker_den and marker_den > 0 then add(host.TimeMap2_timeToQN(project, time), marker_num, marker_den) end
  end
  table.sort(result, function(a, b) return a.qn < b.qn end)
  return result
end

local function transport_key(host,project,project_end,qn_end,rate)
  local parts={string.format("%.6f",project_end),tostring(qn_end),tostring(rate)}
  for index=0,host.CountTempoTimeSigMarkers(project)-1 do
    local ok,time,measure,beat,bpm,num,den,linear=host.GetTempoTimeSigMarker(project,index)
    if ok then parts[#parts+1]=table.concat({string.format("%.9f",time or 0),tostring(measure or 0),string.format("%.9f",beat or 0),string.format("%.9f",bpm or 0),tostring(num or 0),tostring(den or 0),linear and "1" or "0"},":") end
  end
  return table.concat(parts,"|")
end

function Controller.new(host, project)
  local rack, restored, warning = state.load(host, project)
  -- JSFX gmem is global to REAPER, so each project needs a stable mailbox
  -- namespace or an idle/open project can control another project's banks.
  rack.engine_namespace=engine_namespace(host,project)
  local self = setmetatable({ host = host, project = project, adapter = Adapter.new(host, project), rack = rack,
    restored = restored, warning = warning, selected_pad = (rack.selected_bank - 1) * 16 + 1,
    selected_step = 1, pattern_index = rack.selected_pattern or 1, variation_index = rack.selected_variation or 1, revision = 1, dirty = true,
    structural_dirty = true, publish_dirty = true, due = 0, state_pending = false, state_due = 0, state_generation=0,
    pending_pad_controls = {}, structural_pad_ids = {}, structural_queue = {}, structural_queue_set = {}, sampler_cache = {},
    track_cache = false, track_cache_epoch = false, follow_variation_events = true, variation_events_dirty=true, status = "Starting" }, Controller)
  self.undo_stack,self.redo_stack={},{}
  self.engine_active_variation=self:active_variation_number()
  self:flush(true)
  self:remove_legacy_gain_lfo()
  self:remove_master_clipper()
  return self
end

function Controller:pattern() return self.rack.patterns[self.pattern_index] end
function Controller:variation() return self:pattern().variations[self.variation_index] end
function Controller:pad(index) return self.rack.pads[index or self.selected_pad] end
function Controller:lane(index)
  local wanted = self:pad(index).id
  for _, lane in ipairs(self:variation().lanes) do if lane.pad_id == wanted then return lane end end
end
function Controller:step() return self:lane().steps[self.selected_step] end

function Controller:set_clipboard_envelope(envelope)
  clipboard.assert_valid_envelope(envelope);self.clipboard_envelope=envelope
  local raw=json.encode(envelope);self.clipboard_json=raw
  if self.host.CF_SetClipboard then pcall(self.host.CF_SetClipboard,raw) end
end

function Controller:get_clipboard_envelope(scope)
  local envelope=self.clipboard_envelope
  -- The local envelope is already validated and is the common same-instance
  -- path. Reading and decoding the Windows clipboard here caused a visible UI
  -- stall on every paste. Only consult it for a cross-instance/project paste.
  if (not envelope or (scope and envelope.scope~=scope)) and self.host.CF_GetClipboard then
    local ok,raw=pcall(self.host.CF_GetClipboard)
    if ok and type(raw)=="string" and raw:find('"format":"readrum%-clipboard"') then
      local decoded_ok,decoded=pcall(json.decode,raw)
      if decoded_ok and clipboard.validate_envelope(decoded) then envelope=decoded;self.clipboard_envelope=decoded end
    end
  end
  if not envelope or (scope and envelope.scope~=scope) then return nil end
  return envelope
end

function Controller:active_variation_number()
  local number = 0
  for pattern_index, pattern in ipairs(self.rack.patterns) do
    for variation_index in ipairs(pattern.variations) do
      number = number + 1
      if pattern_index == self.pattern_index and variation_index == self.variation_index then return number end
    end
  end
  return 1
end

function Controller:sync_engine_variation(track,fx)
  local playing=(self.host.GetPlayState()&1)~=0
  if not playing then self.engine_active_variation=self:active_variation_number();return self.engine_active_variation end
  track=track or self:find_track("sequencer");if not track or not self.host.TrackFX_GetParam then return self.engine_active_variation end
  fx=fx or self:dispatcher(track)
  local active=self.host.TrackFX_GetParam(track,fx,71);local pending=self.host.TrackFX_GetParam(track,fx,72);local observed=self.host.TrackFX_GetParam(track,fx,78)
  if type(active)=="number" and active>=1 and math.floor((pending or 0)+.5)==0 then
    if not self.variation_request_token or math.floor((observed or -1)+.5)==self.variation_request_token then self.engine_active_variation=math.floor(active+.5) end
  end
  return self.engine_active_variation
end

function Controller:follow_engine_variation_display()
  if (self.host.GetPlayState()&1)==0 then return false end
  local wanted=math.floor(tonumber(self.engine_active_variation) or 0);if wanted<1 then return false end
  local number=0
  for pattern_index,pattern in ipairs(self.rack.patterns) do
    for variation_index in ipairs(pattern.variations) do
      number=number+1
      if number==wanted then
        if self.pattern_index==pattern_index and self.variation_index==variation_index then return false end
        self.pattern_index,self.variation_index=pattern_index,variation_index
        self.rack.selected_pattern,self.rack.selected_variation=pattern_index,variation_index
        self.selected_step=math.min(self.selected_step,self:lane().step_count)
        self.status="Playing variation: "..self:variation().name
        return true
      end
    end
  end
  return false
end

function Controller:variation_entry(pattern_id,variation_id)
  local number=0
  for _,pattern in ipairs(self.rack.patterns) do
    for _,variation in ipairs(pattern.variations) do
      number=number+1
      if pattern.id==pattern_id and variation.id==variation_id then return number,pattern,variation end
    end
  end
end

function Controller:variation_number(pattern_id,variation_id)
  return self:variation_entry(pattern_id,variation_id)
end

function Controller:variation_event_ids(item)
  if not item then return end
  local ok,tag=self.host.GetSetMediaItemInfo_String(item,"P_EXT:READRUM_VARIATION","",false)
  if not ok or tag=="" then return end
  return tag:match("^([^|]+)|([^|]+)|([^|]+)$")
end

function Controller:refresh_variation_events()
  if not self.host.CountMediaItems then return end
  local refreshed,stale=0,0
  for item_index=0,self.host.CountMediaItems(self.project)-1 do
    local item=self.host.GetMediaItem(self.project,item_index)
    local rack_id,pattern_id,variation_id=self:variation_event_ids(item)
    if rack_id==self.rack.id then
      local number,pattern,variation=self:variation_entry(pattern_id,variation_id)
      local take=self.host.GetActiveTake(item)
      local _,was_stale=self.host.GetSetMediaItemInfo_String(item,"P_EXT:READRUM_STALE","",false)
      if number and take then
        local _,_,cc_count=self.host.MIDI_CountEvts(take);local changed=false
        if self.host.GetMediaItemInfo_Value(item,"B_LOOPSRC")~=1 then self.host.SetMediaItemInfo_Value(item,"B_LOOPSRC",1);changed=true end
        for cc_index=0,cc_count-1 do
          local got,_,_,_,chanmsg,channel,msg2=self.host.MIDI_GetCC(take,cc_index)
          if got and chanmsg==0xC0 and channel==15 and msg2~=number-1 then
            self.host.MIDI_SetCC(take,cc_index,nil,nil,nil,nil,nil,number-1,nil,true);changed=true
          end
        end
        local wanted_name="ReaDrumXT  •  "..variation.name
        local _,current_name=self.host.GetSetMediaItemTakeInfo_String(take,"P_NAME","",false)
        if current_name~=wanted_name then self.host.GetSetMediaItemTakeInfo_String(take,"P_NAME",wanted_name,true);changed=true end
        if self.host.ColorToNative then
          local wanted_color=self.host.ColorToNative(35,128,184)|0x1000000
          if self.host.GetMediaItemInfo_Value(item,"I_CUSTOMCOLOR")~=wanted_color then self.host.SetMediaItemInfo_Value(item,"I_CUSTOMCOLOR",wanted_color);changed=true end
        end
        if was_stale=="1" then
          local _,previous_mute=self.host.GetSetMediaItemInfo_String(item,"P_EXT:READRUM_PREVIOUS_MUTE","",false)
          self.host.SetMediaItemInfo_Value(item,"B_MUTE",previous_mute=="1" and 1 or 0)
          self.host.GetSetMediaItemInfo_String(item,"P_EXT:READRUM_STALE","",true)
          self.host.GetSetMediaItemInfo_String(item,"P_EXT:READRUM_PREVIOUS_MUTE","",true);changed=true
        end
        if changed then self.host.MIDI_Sort(take);self.host.UpdateItemInProject(item);refreshed=refreshed+1 end
      elseif not number then
        if was_stale~="1" then
          local muted=self.host.GetMediaItemInfo_Value(item,"B_MUTE")>0
          self.host.GetSetMediaItemInfo_String(item,"P_EXT:READRUM_PREVIOUS_MUTE",muted and "1" or "0",true)
          self.host.GetSetMediaItemInfo_String(item,"P_EXT:READRUM_STALE","1",true)
        end
        self.host.SetMediaItemInfo_Value(item,"B_MUTE",1)
        if take then self.host.GetSetMediaItemTakeInfo_String(take,"P_NAME","[Missing ReaDrum variation]",true) end
        self.host.UpdateItemInProject(item);stale=stale+1
      end
    end
  end
  return refreshed,stale
end

function Controller:poll_variation_event_selection(force)
  if not self.host.CountSelectedMediaItems or self.host.CountSelectedMediaItems(self.project)~=1 then return false end
  local item=self.host.GetSelectedMediaItem(self.project,0)
  if not force and item==self.followed_item then return false end
  local rack_id,pattern_id,variation_id=self:variation_event_ids(item)
  if rack_id~=self.rack.id then self.followed_item=nil;return false end
  self.followed_item=item
  for pattern_index,pattern in ipairs(self.rack.patterns) do
    if pattern.id==pattern_id then
      for variation_index,variation in ipairs(pattern.variations) do
        if variation.id==variation_id then
          if self.pattern_index~=pattern_index or self.variation_index~=variation_index then
            self.pattern_index,self.variation_index=pattern_index,variation_index
            self.rack.selected_pattern,self.rack.selected_variation=pattern_index,variation_index
            self.selected_step=1;self:mark_dirty(false)
          end
          self.status="Following variation event: "..variation.name
          return true
        end
      end
    end
  end
  self.status="Selected ReaDrum event refers to a deleted variation"
  return false
end

function Controller:reassign_selected_variation_event()
  if not self.host.CountSelectedMediaItems then return false end
  local items={}
  for index=0,self.host.CountSelectedMediaItems(self.project)-1 do
    local item=self.host.GetSelectedMediaItem(self.project,index)
    local rack_id=self:variation_event_ids(item)
    if rack_id==self.rack.id then items[#items+1]=item end
  end
  if #items==0 and self.followed_item and (not self.host.ValidatePtr2 or self.host.ValidatePtr2(self.project,self.followed_item,"MediaItem*")) then
    local rack_id=self:variation_event_ids(self.followed_item)
    if rack_id==self.rack.id then items[1]=self.followed_item end
  end
  if #items==0 then return false end
  local reference=self.rack.id.."|"..self:pattern().id.."|"..self:variation().id
  self.host.Undo_BeginBlock2(self.project)
  for _,item in ipairs(items) do self.host.GetSetMediaItemInfo_String(item,"P_EXT:READRUM_VARIATION",reference,true) end
  self:refresh_variation_events()
  self.host.Undo_EndBlock2(self.project,"ReaDrum: assign variation event",-1)
  self.host.UpdateArrange()
  self.followed_item=items[1]
  self.status="Variation event assigned: "..self:variation().name
  return true
end

local function track_cache_key(kind, object_id)
  return kind .. "\0" .. (object_id or "")
end

function Controller:invalidate_track_cache()
  self.track_cache=false;self.track_cache_epoch=false
end

function Controller:refresh_track_cache(force)
  local epoch=self.host.GetProjectStateChangeCount and self.host.GetProjectStateChangeCount(self.project) or false
  if not force and self.track_cache and (epoch==false or epoch==self.track_cache_epoch) then return end
  local cache={}
  for index = 0, self.adapter:track_count() - 1 do
    local track = self.adapter:track_at(index); local tag = tags.read_track(self.adapter, track)
    if tag and tag.rack_id == self.rack.id then
      local exact=track_cache_key(tag.kind,tag.object_id)
      local first=track_cache_key(tag.kind)
      cache[exact]=cache[exact] or track;cache[first]=cache[first] or track
    end
  end
  self.track_cache=cache;self.track_cache_epoch=epoch
end

function Controller:find_track(kind, object_id)
  self:refresh_track_cache(false)
  return self.track_cache[track_cache_key(kind,object_id)]
end

function Controller:dispatcher(track)
  for index = 0, self.adapter:fx_count(track) - 1 do
    local name = self.adapter:fx_name(track, index)
    if name:find("ReaDrum Round Robin Dispatcher", 1, true) then return index end
  end
  local index = self.adapter:add_fx(track, "JS: ReaDrum/ReaDrum_RoundRobinDispatcher")
  assert(index and index >= 0, "ReaDrum dispatcher is not installed. Run tools/install_readrum.ps1 first.")
  self.adapter:hide_fx(track,index)
  return index
end
function Controller:reset_dispatcher_schedule()
  local track=self:find_track("sequencer")
  if not track or not self.host.TrackFX_GetParam or not self.host.TrackFX_SetParam then return false end
  local fx=self:dispatcher(track)
  local value=self.host.TrackFX_GetParam(track,fx,27) or 0
  self.host.TrackFX_SetParam(track,fx,27,value>=.5 and 0 or 1)
  return true
end
function Controller:set_fill(enabled)
  self.fill=enabled and true or false;local track=self:find_track("sequencer");if track then self.host.TrackFX_SetParam(track,self:dispatcher(track),64,self.fill and 1 or 0)end
end

local function signed_unit(text)
  local h=2166136261
  for i=1,#text do h=((h~text:byte(i))*16777619)%2147483647 end
  return ((h%20001)/10000)-1
end

local function rounded(value)
  return value>=0 and math.floor(value+.5) or math.ceil(value-.5)
end

local function humanized_pitch(step,lane,step_index,amount)
  local total=(tonumber(step.pitch_semitones) or 0)*100+(tonumber(step.pitch_cents) or 0)
  total=math.max(-9700,math.min(9700,rounded(total+signed_unit(lane.id..":p:"..step_index)*amount)))
  local semitones
  if total>=9600 then semitones=96
  elseif total<=-9600 then semitones=-96
  else semitones=total>=0 and math.floor(total/100) or math.ceil(total/100) end
  step.pitch_semitones=semitones
  step.pitch_cents=total-semitones*100
end

local function accentuator_factor(rack,lane,step,step_index)
  local a=rack.accentuator
  if step.accent or not a or a.enabled==false or lane.accentuator_enabled~=true then return 1 end
  local unit=4*(tonumber(lane.division_num) or 1)/(tonumber(lane.division_den) or 16)
  -- The displayed curve begins at a zero crossing. Sample each event at the
  -- center of its step so high-rate waves (especially 1/8 on a 1/16 grid)
  -- produce the same alternating values shown by the preview instead of
  -- repeatedly landing on zero crossings.
  local pos=((step_index-.5+(lane.phase or 0))*unit)%4
  local periods={2,1,4/6,0.5}
  local sum=0
  for i=1,4 do sum=sum+(tonumber(a.bands and a.bands[i]) or 0)/100*math.sin(2*math.pi*pos/periods[i]) end
  local amount=math.max(0,math.min(2,(tonumber(a.amount) or 100)/100))
  -- Accentuator modulation uses only the downward half of the composite curve.
  -- Explicit accent notes bypass that attenuation and are handled separately.
  return math.max(0,math.min(1,1+sum*0.25*amount))
end

local function effective_velocity(rack,variation,lane,step,step_index)
  local scale=math.max(25,math.min(200,tonumber(lane.velocity_scale) or 100))/100
  local accent=step.accent and math.max(100,math.min(200,tonumber(rack.accent_multiplier) or 130))/100 or 1
  -- Global and lane VS use the same 0..200 scale.  100% is neutral;
  -- multiplying the normalized controls makes the global control broad and
  -- the lane control a predictable per-lane adjustment around that setting.
  local global_sensitivity=lane.global_velocity_sensitivity_enabled==false and 1 or
    math.max(0,math.min(200,tonumber(rack.global_velocity_sensitivity) or 100))/100
  local lane_sensitivity=math.max(0,math.min(200,tonumber(lane.velocity_sensitivity) or 100))/100
  local sensitivity=math.max(0,math.min(2,global_sensitivity*lane_sensitivity))
  local humanize=math.min(100,
    (lane.global_velocity_humanize_enabled==false and 0 or (variation.velocity_humanize or 0))+
    (lane.velocity_humanize or 0))
  local base=math.max(1,math.min(127,tonumber(step.velocity) or 100))
  -- Humanization is part of the authored velocity input.  Apply VS after it
  -- so the compression half also processes the humanized input.
  if humanize>0 then base=base+signed_unit(lane.id..":v:"..step_index)*20*humanize/100 end
  base=math.max(1,math.min(127,base))
  -- The accentuator shapes the authored hit before velocity sensitivity.
  -- This lets VS compress or expand the already-attenuated result instead of
  -- applying a second, unrelated reduction after the sensitivity curve.
  base=base*accentuator_factor(rack,lane,step,step_index)
  -- VelSens has two curves around the fixed 127 pivot.  The left half is
  -- linear compression toward full velocity.  Above 100%, use a soft-knee
  -- expansion gain: quiet hits receive the greatest attenuation, the middle
  -- opens up without collapsing, and attenuation fades rapidly near 127.
  if sensitivity<=1 then
    base=127-(127-base)*sensitivity
  else
    local normalized=base/127
    local expansion=sensitivity-1
    local low_velocity_weight=(1-normalized)^1.5
    local gain=1-.78*expansion*low_velocity_weight
    base=127*normalized*gain
  end
  local value=base*scale*accent
  return math.max(1,math.min(127,math.floor(value+.5)))
end

function Controller:effective_step_velocity(lane,step,step_index)
  return effective_velocity(self.rack,self:variation(),lane,step,step_index)
end

function Controller:probe(name,started)
  if self.perf_callback then self.perf_callback(name,self.host.time_precise()-started) end
end

function Controller:runtime_rack(yield_hook)
  local started=self.host.time_precise()
  local tick=yield_hook or function()end
  local source=self.rack
  local runtime={}
  for key,value in pairs(source) do if key~="patterns" then runtime[key]=value end end
  runtime.patterns={}
  if not yield_hook then self:probe("runtime scaffold",started);started=self.host.time_precise()end
  local populated,pads_by_id={},{}
  for _,pad in ipairs(source.pads) do
    tick();pads_by_id[pad.id]=pad;populated[pad.id]=pad.sample~=false and pad.sample~=nil
  end
  for pattern_index,pattern in ipairs(source.patterns) do
    tick()
    local runtime_pattern={};for key,value in pairs(pattern)do if key~="variations"then runtime_pattern[key]=value end end
    runtime_pattern.variations={};runtime.patterns[pattern_index]=runtime_pattern
    for variation_index,variation in ipairs(pattern.variations) do
      tick()
      local runtime_variation={};for key,value in pairs(variation)do if key~="lanes"then runtime_variation[key]=value end end
      local preview=self.groove_preview and self.groove_preview.variation_id==variation.id and self.groove_preview or nil
      if preview then runtime_variation.groove=preview.groove~=false and preview.groove or nil else runtime_variation.groove=variation.groove end
      runtime_variation.groove_strength=preview and preview.strength or variation.swing
      runtime_variation.lanes={};runtime_pattern.variations[variation_index]=runtime_variation
      local by_id,needed,transformed={},{},{}
      for _,lane in ipairs(variation.lanes) do by_id[lane.id]=lane end
      for _,lane in ipairs(variation.lanes) do
        tick()
        if populated[lane.pad_id] then
          local runtime_lane={};for key,value in pairs(lane)do if key~="steps"then runtime_lane[key]=value end end
          runtime_lane.steps={};transformed[lane.id]=runtime_lane
          local pad=pads_by_id[lane.pad_id]
          -- Glide handoffs require adjacent notes to meet exactly. While Glide
          -- is active, keep this pad on the straight grid and preserve the
          -- user's timing settings so they return unchanged when Glide is off.
          local glide_timing_lock=pad and pad.default_controls and
            (tonumber(pad.default_controls.glide) or 0)>0
          local receives_global_swing=lane.global_swing_enabled~=false
          runtime_lane.groove_enabled=not glide_timing_lock and receives_global_swing
          if glide_timing_lock then runtime_lane.swing=0
          elseif runtime_variation.groove and receives_global_swing then
            -- With a MIDI groove this field is a signed lane trim. The engine
            -- combines it with the variation amount and clamps the result to
            -- 0..100, rather than layering a second classic swing curve.
            runtime_lane.swing=math.max(-100,math.min(100,tonumber(lane.swing)or 0))
          else
            -- Classic swing uses the same base-plus-trim model. A bypassed
            -- lane keeps only its positive local amount; reverse swing is not
            -- part of the user-facing timing contract.
            local base=receives_global_swing and math.max(0,math.min(100,tonumber(variation.swing)or 0))or 0
            runtime_lane.swing=math.max(0,math.min(100,base+(tonumber(lane.swing)or 0)))
          end
          local global_sensitivity=lane.global_velocity_sensitivity_enabled==false and 1 or
            math.max(0,math.min(200,tonumber(source.global_velocity_sensitivity) or 100))/100
          local lane_sensitivity=math.max(0,math.min(200,tonumber(lane.velocity_sensitivity) or 100))/100
          runtime_lane.velocity_sensitivity=math.floor(math.max(0,math.min(200,global_sensitivity*lane_sensitivity*100))+.5)
          local timing_humanize=glide_timing_lock and 0 or
            math.min(100,(variation.timing_humanize or 0)+(lane.timing_humanize or 0))
          local pitch_humanize=math.min(100,(variation.pitch_humanize or 0)+(lane.pitch_humanize or 0))
          local pan_humanize=math.min(100,(variation.pan_humanize or 0)+(lane.pan_humanize or 0))
          local lane_timing_offset=glide_timing_lock and 0 or
            math.max(-48,math.min(48,tonumber(lane.timing_offset) or 0))
          -- Lane/global Gate shapes only the final step of a sustained note.
          -- Clamp the combined control to the same 0..200% contract so it can
          -- remove that last step or extend it by at most one step.
          local gate_scale=math.max(0,math.min(2,
            math.max(0,math.min(200,lane.gate_scale or 100))/100*
            (lane.global_gate_enabled==false and 1 or math.max(0,math.min(200,source.global_gate_scale or 100))/100)))
          for step_index,source_step in ipairs(lane.steps) do
            tick()
            local step={};for key,value in pairs(source_step)do step[key]=value end
            runtime_lane.steps[step_index]=step
            if source_step.enabled then
              needed[lane.id]=true
              local condition=source_step.condition
              if condition and condition.type=="previous" and condition.lane_id and by_id[condition.lane_id] then needed[condition.lane_id]=true end
            end
            if source_step.cut then needed[lane.id]=true end
            if not source_step.cut then
              local step_timing_offset=glide_timing_lock and 0 or
                math.max(-48,math.min(48,tonumber(step.timing_offset) or 0))
              step.timing_offset=step_timing_offset+lane_timing_offset
              -- Every hit has a real note lifecycle. The sampler's per-pad
              -- playback mode decides whether its note-off is musical (Gate)
              -- or ignored (One Shot).
              step.runtime_one_shot=false
              local source_gate=math.max(0,math.min(1600,tonumber(step.gate) or 100))
              local complete_steps=source_gate>0 and math.max(0,math.ceil(source_gate/100)-1) or 0
              local final_step=source_gate-complete_steps*100
              step.gate=math.max(0,math.min(1600,complete_steps*100+final_step*gate_scale))
              step.velocity=effective_velocity(source,variation,lane,step,step_index)
              if timing_humanize>0 then step.timing_offset=math.max(-960,math.min(960,math.floor(step.timing_offset+signed_unit(lane.id..":t:"..step_index)*120*timing_humanize/100+.5))) end
              if pitch_humanize>0 then humanized_pitch(step,lane,step_index,pitch_humanize) end
              if pan_humanize>0 then
                local pad_pan=pad and pad.default_controls and pad.default_controls.pan
                local base_pan=step.pan_lock==false and (((pad_pan==nil and .5 or pad_pan)-.5)*200) or (tonumber(step.pan_lock) or 0)
                step.pan_lock=math.max(-100,math.min(100,rounded(base_pan+signed_unit(lane.id..":pan:"..step_index)*pan_humanize)))
              end
            end
          end
        end
      end
      for _,lane in ipairs(variation.lanes) do
        tick()
        if needed[lane.id] then
          local runtime_lane=transformed[lane.id]
          if not runtime_lane then runtime_lane={};for key,value in pairs(lane)do runtime_lane[key]=value end end
          runtime_variation.lanes[#runtime_variation.lanes+1]=runtime_lane
        end
      end
    end
  end
  if not yield_hook then self:probe("runtime minimal build",started)end
  return runtime
end

function Controller:build_publish_payload(yield_hook)
  local started=self.host.time_precise()
  if self.variation_events_dirty then self:refresh_variation_events();self.variation_events_dirty=false end
  local track = assert(self:find_track("sequencer"), "ReaDrum sequencer track is missing")
  local fx = self:dispatcher(track)
  self:sync_engine_variation(track,fx)
  local selected_variation=self:active_variation_number()
  local playing=(self.host.GetPlayState()&1)~=0
  local engine_variation=selected_variation
  if playing then
    engine_variation=self.engine_active_variation or selected_variation
  end
  self.engine_active_variation=engine_variation
  self.last_published_active_variation=engine_variation
  if not yield_hook then self:probe("publish preamble",started);started=self.host.time_precise()end
  local runtime=self:runtime_rack(yield_hook)
  local image = snapshot_v2.encode(runtime, { revision = self.revision, active_variation = engine_variation, yield_hook=yield_hook })
  if not yield_hook then self:probe("snapshot encode",started);started=self.host.time_precise()end
  local project_end = self.host.TimeMap2_timeToQN(self.project, math.max(0, self.host.GetProjectLength(self.project)))
  local qn_end = math.max(256, math.ceil(project_end + 64))
  local rate = audio_rate(self.host, self.project)
  local map_key=transport_key(self.host,self.project,math.max(0,self.host.GetProjectLength(self.project)),qn_end,rate)
  local map_model
  if self.transport_cache and self.transport_cache.key==map_key then
    map_model=self.transport_cache.map
  else
    map_model=transport.build(function(qn) return self.host.TimeMap2_QNToTime(self.project, qn) end, {
      sample_rate = rate, qn_start = 0, qn_end = qn_end, revision = self.revision,
      time_signatures = time_signatures(self.host, self.project, qn_end),
    })
    self.transport_cache={key=map_key,map=map_model}
  end
  -- Runtime and map revisions must match, but the expensive anchor sampling is
  -- reusable across ordinary sequencer edits.
  map_model.revision=self.revision
  local map=transport.encode(map_model)
  if not yield_hook then self:probe("transport prepare",started)end
  return track,fx,image,map
end

function Controller:publish()
  local track,fx,image,map=self:build_publish_payload()
  local runtime_base,map_base=snapshot_bases(self.rack)
  local accepted, analysis = snapshot.write_admitted_pair_fx(self.host, track, fx, image, map, {
    gmem_name = "ReaDrumSnapshot", runtime_base = runtime_base, map_base = map_base,
    token = image.revision, promote_token = image.revision, max_block_samples = 16384,
  })
  self.host.TrackFX_SetParam(track,fx,64,self.fill and 1 or 0)
  self.host.TrackFX_SetParam(track,fx,65,1) -- map the rotated one-channel 128-note range to pads
  local playback=self.rack.playback_mode=="rendered" and 0 or (self.rack.playback_mode=="events" and 2 or 1)
  self.host.TrackFX_SetParam(track,fx,66,playback)
  assert(accepted, type(analysis) == "table" and table.concat(analysis.reasons or {}, "; ") or tostring(analysis))
  self.status = "Engine revision " .. image.revision .. " published"
end

function Controller:queue_publish()
  local token=self.revision
  local units=0
  local task={token=token}
  task.coroutine=coroutine.create(function()
    local function tick()
      units=units+1
      -- A full 128-pad image used to take dozens of UI frames to build, so a
      -- freshly painted step could miss one or more playback cycles. This is
      -- still sliced, but at a large enough grain to become audible promptly.
      if units>=1024 then units=0;coroutine.yield()end
    end
    local track,fx,image,map=self:build_publish_payload(tick)
    local analysis,failure=snapshot.admit_runtime_pair(image,map,{max_block_samples=16384})
    assert(analysis,type(failure)=="string"and failure or"runtime/map admission rejected")
    local runtime_base,map_base=snapshot_bases(self.rack)
    return {track=track,fx=fx,image=image,map=map,phase="runtime",index=1,started=false,token=image.revision,runtime_base=runtime_base,map_base=map_base}
  end)
  self.publish_build_task=task;self.publish_task=nil
  self.status="Preparing engine revision "..token
end

function Controller:process_publish(budget)
  -- One immutable page is shared with the audio thread. Never begin replacing
  -- it until the dispatcher confirms the previous commit became active;
  -- rapid step entry otherwise starves every revision after the first burst.
  if self.publish_awaiting_revision then
    local track=self:find_track("sequencer")
    if not track or not self.host.TrackFX_GetParam then return false end
    local fx=self:dispatcher(track)
    local active=math.floor((self.host.TrackFX_GetParam(track,fx,34)or 0)+.5)
    if active==self.publish_awaiting_revision then self.publish_awaiting_revision=nil else return false end
  end
  local build=self.publish_build_task
  if build then
    local ok,result=coroutine.resume(build.coroutine)
    if not ok then self.publish_build_task=nil;self.status="ERROR: "..tostring(result);return false end
    if coroutine.status(build.coroutine)=="dead"then
      self.publish_build_task=nil
      if build.token==self.revision then self.publish_task=result;self.status="Staging engine revision "..build.token end
    end
    return false
  end
  local task=self.publish_task;if not task then return false end
  budget=math.max(1,math.floor(budget or 512));local host=self.host
  if not task.started then
    host.gmem_attach("ReaDrumSnapshot");task.started=true
  end
  while budget>0 do
    local words=task.phase=="runtime" and task.image.words or task.map.words
    local base=task.phase=="runtime" and task.runtime_base or task.map_base
    if task.index<=#words then
      host.gmem_write(base+8+task.index,words[task.index]);task.index=task.index+1;budget=budget-1
    elseif task.phase=="runtime" then task.phase="map";task.index=1
    else
      local image,map,track,fx=task.image,task.map,task.track,task.fx
      local token=image.revision
      local runtime_base,map_base=task.runtime_base,task.map_base
      host.gmem_write(runtime_base+2,#image.words);host.gmem_write(runtime_base+3,image.checksum);host.gmem_write(runtime_base+4,image.revision);host.gmem_write(runtime_base+1,snapshot_v2.VERSION);host.gmem_write(runtime_base,snapshot_v2.MAGIC)
      host.gmem_write(map_base+2,#map.words);host.gmem_write(map_base+3,map.checksum);host.gmem_write(map_base+4,map.words[5]);host.gmem_write(map_base+1,transport.VERSION);host.gmem_write(map_base,transport.MAGIC)
      host.TrackFX_SetParam(track,fx,28,snapshot_v2.MAGIC);host.TrackFX_SetParam(track,fx,29,snapshot_v2.VERSION);host.TrackFX_SetParam(track,fx,30,runtime_base);host.TrackFX_SetParam(track,fx,31,#image.words);host.TrackFX_SetParam(track,fx,32,image.checksum);host.TrackFX_SetParam(track,fx,33,token)
      host.TrackFX_SetParam(track,fx,37,transport.MAGIC);host.TrackFX_SetParam(track,fx,38,transport.VERSION);host.TrackFX_SetParam(track,fx,39,map_base);host.TrackFX_SetParam(track,fx,40,#map.words);host.TrackFX_SetParam(track,fx,41,map.checksum);host.TrackFX_SetParam(track,fx,42,token)
      host.TrackFX_SetParam(track,fx,36,token);host.TrackFX_SetParam(track,fx,43,token)
      local playback=self.rack.playback_mode=="rendered" and 0 or (self.rack.playback_mode=="events" and 2 or 1)
      host.TrackFX_SetParam(track,fx,64,self.fill and 1 or 0);host.TrackFX_SetParam(track,fx,65,1);host.TrackFX_SetParam(track,fx,66,playback)
      self.publish_task=nil;self.publish_awaiting_revision=token;self.status="Engine revision "..token.." published";return true
    end
  end
  return false
end

function Controller:mark_dirty(structural,publish)
  if self.ui_invalidate then self.ui_invalidate() end
  local new_burst=not self.dirty
  if new_burst and not self.history_lock and self.last_committed and not self.checkpoint_task then
    -- last_committed is already an immutable snapshot; transferring its
    -- reference avoids cloning the entire 128-pad rack on mouse-down.
    self.undo_stack[#self.undo_stack+1]=self.last_committed;if #self.undo_stack>32 then table.remove(self.undo_stack,1)end;self.redo_stack={}
  end
  if new_burst then self.state_generation=(self.state_generation or 0)+1 end
  self.dirty = true; self.structural_dirty = self.structural_dirty or structural or false
  -- An edit supersedes any partially staged idle persistence job. Its metadata
  -- has not committed yet; the replacement job writes the current rack.
  self.state_save_task=nil
  self.checkpoint_task=nil
  self.publish_task=nil
  self.publish_build_task=nil
  self.publish_dirty = self.publish_dirty or publish~=false
  -- Coalesce a paint gesture without making a single click audibly late.
  self.due = self.host.time_precise() + 0.03
end

function Controller:publish_transient_runtime(status,immediate)
  self.publish_task=nil;self.publish_build_task=nil;self.publish_awaiting_revision=nil
  self.revision=self.revision%16777214+1
  if immediate then
    local ok,failure=pcall(function()self:publish()end)
    if not ok then self.status="Could not publish temporary engine state: "..tostring(failure);return false end
  else self:queue_publish()end
  if status then self.status=status end
  return true
end

function Controller:preview_groove(value)
  local variation=self:variation();local groove=value and model.deep_copy(value) or false
  local strength=variation.swing or 0;if groove and strength==0 then strength=100 end
  self.groove_preview={variation_id=variation.id,groove=groove,strength=strength}
  return self:publish_transient_runtime("Previewing groove: "..(groove and groove.name or "Classic Swing"),true)
end

function Controller:cancel_groove_preview(immediate)
  if not self.groove_preview then return false end
  self.groove_preview=nil
  if immediate then
    self.publish_task=nil;self.publish_build_task=nil;self.publish_awaiting_revision=nil;self.revision=self.revision%16777214+1
    local ok,failure=pcall(function()self:publish()end);if not ok then self.status="Could not restore groove preview: "..tostring(failure)end
  else self:publish_transient_runtime("Groove preview cancelled",true)end
  return true
end

function Controller:apply_groove(value)
  local variation=self:variation();self.groove_preview=nil
  variation.groove=value and model.deep_copy(value) or nil
  if variation.groove and (variation.swing or 0)==0 then variation.swing=100 end
  self:mark_dirty(false)
  self.status="Groove applied: "..(variation.groove and variation.groove.name or "Classic Swing")
end

function Controller:queue_pad_controls(index,immediate)
  local target=index or self.selected_pad
  local already_pending=self.pending_pad_controls[target]==true
  self.pending_pad_controls[target]=true
  -- A continuous gesture can report hundreds of mouse samples. One dirty
  -- transition is sufficient for undo/persistence; repeating it needlessly
  -- cancels and reschedules idle work on every rendered frame.
  if not already_pending then self:mark_dirty(false,false) end
  -- Sampler controls are a small gmem packet; publish them during a waveform
  -- drag so ADSR/fade edits are audible immediately without rebuilding the
  -- sequencer snapshot on every mouse sample.
  if immediate then self:sync_pending_pad_controls() end
end

function Controller:mark_pad_structural(index)
  local pad=self:pad(index or self.selected_pad)
  if pad then self.structural_pad_ids[pad.id]=true end
  self:mark_dirty(true)
end

function Controller:queue_pad_structural(index)
  local pad=self:pad(index)
  if not pad or self.structural_queue_set[pad.id] then return end
  self.structural_queue[#self.structural_queue+1]=index;self.structural_queue_set[pad.id]=true
end

function Controller:process_structural_queue(limit)
  limit=limit or 1;local processed,requested=0,{}
  while processed<limit and #self.structural_queue>0 do
    local index=table.remove(self.structural_queue,1);local pad=self:pad(index)
    if pad then
      requested[pad.id]=true;self.structural_queue_set[pad.id]=nil;processed=processed+1
    end
  end
  -- Discover the rack and open the REAPER undo block once for the whole batch.
  -- Per-pad reconciliation repeated both operations and dominated large drops.
  if processed>0 then
    local report=lifecycle.reconcile(self.adapter,self.rack,{engine="sampler_bank",sampler_cache=self.sampler_cache,pad_ids=requested,undo_label="ReaDrum: prepare sample pads"})
    self.sampler_cache=report.sampler_cache or self.sampler_cache
    self.bank_tracks=report.bank_tracks or self.bank_tracks
    self:invalidate_track_cache()
    self:sync_pad_track_names(requested)
    self.status=string.format("Preparing pads: %d remaining",#self.structural_queue)
  end
  if processed>0 and #self.structural_queue==0 then self.status="Samples ready" end
  return processed
end

function Controller:sync_pending_pad_controls()
  local track=self:find_track("sequencer")
  local any_solo=false
  for _,candidate in ipairs(self.rack.pads or {}) do if candidate.sample~=false and candidate.sample~=nil and candidate.soloed==true then any_solo=true;break end end
  for index in pairs(self.pending_pad_controls or {}) do
    local pad=self:pad(index)
    if track and pad and pad.sample~=false then
      local audible=pad.muted~=true and(not any_solo or pad.soloed==true)
      local cache_entry=self.sampler_cache[pad.id]
      if cache_entry then sampler_engine.publish_pad_controls(self.host,self.rack,pad,cache_entry,audible)
      else
        local bank_index=math.floor(((tonumber(pad.logical_index)or 1)-1)/16)
        local worker=self:find_track("bank",tostring(bank_index))
        if worker then sampler_engine.publish_pad(self.host,worker,self.rack,pad,nil) end
      end
    end
  end
  self.pending_pad_controls={}
end

function Controller:poll_sampler_loads(limit)
  local result=sampler_engine.poll(self.host,self:find_track("sequencer"),self.sampler_cache,limit or 4)
  local repaired=0
  for index,pad in ipairs(self.rack.pads or {}) do
    if repaired<(limit or 4) and pad.sample~=false and pad.sample~=nil then
      local logical=math.max(1,math.floor(tonumber(pad.logical_index)or index))-1
      local bank_index,slot_index=math.floor(logical/16),logical%16
      if sampler_bank.control_revision(self.host,bank_index,slot_index,self.rack.engine_namespace or 0)==0 then
        sampler_engine.publish_pad_controls(self.host,self.rack,pad,self.sampler_cache[pad.id])
        repaired=repaired+1
      end
    end
  end
  result.controls_repaired=repaired
  if result.failed>0 then self.status="Retrying a sample that failed to decode" end
  return result
end

function Controller:audition_pad(index,velocity,pitch_semitones)
  local pad=self:pad(index);if not pad or pad.sample==false then return false end
  local logical=math.max(1,math.floor(tonumber(pad.logical_index) or index or 1))-1
  local namespace=math.max(0,math.min(sampler_bank.MAX_NAMESPACE,math.floor(tonumber(self.rack.engine_namespace) or 0)))
  sampler_bank.audition(self.host,math.floor(logical/16),logical%16,
    math.max(0,math.min(127,69+math.floor((pitch_semitones or 0)+.5))),
    math.max(1,math.min(127,math.floor((velocity or 100)+.5))),namespace)
  return true
end

function Controller:release_pad_audition(index)
  local pad=self:pad(index);if not pad then return false end
  local logical=math.max(1,math.floor(tonumber(pad.logical_index) or index or 1))-1
  local namespace=math.max(0,math.min(sampler_bank.MAX_NAMESPACE,math.floor(tonumber(self.rack.engine_namespace) or 0)))
  sampler_bank.release_audition(self.host,math.floor(logical/16),logical%16,namespace)
  return true
end

function Controller:sync_pad_track_names(filter)
  local sync_colors=self.host.GetExtState and self.host.GetExtState("ReaDrum5k","apply_pad_track_colors")=="1"
  for index,pad in ipairs(self.rack.pads) do
    if not filter or filter[pad.id] then
      local track=self:pad_track(index)
      local wanted=sample_name(pad) or pad.name or string.format("Pad %03d",index)
      if track and self.adapter:get_track_string(track,"P_NAME")~=wanted then self.adapter:set_track_string(track,"P_NAME",wanted) end
      if sync_colors and track and self.host.SetTrackColor and self.host.ColorToNative then
        local hex=pad.color
        if not hex or hex=="#808080" then
          local defaults={"#C82C55","#3A86D4","#E0522D","#49A25B","#8457C5","#D18422","#2B9BA3","#799E32"}
          hex=defaults[(((index-1)*5)%#defaults)+1]
        end
        local rgb=type(hex)=="string" and tonumber(hex:match("^#(%x%x%x%x%x%x)$"),16)
        if rgb then
          local red=(rgb>>16)&0xFF;local green=(rgb>>8)&0xFF;local blue=rgb&0xFF
          self.host.SetTrackColor(track,self.host.ColorToNative(red,green,blue))
        end
      end
    end
  end
end

function Controller:save_if_due(force)
  if not self.state_pending or (not force and self.host.time_precise()<(self.state_due or 0)) then return false end
  if force then
    self.state_save_task=nil;state.save(self.host,self.project,self.rack)
    self.state_pending=false;self.state_due=0;return true
  end
  if self.checkpoint_task or self.last_committed_generation~=self.state_generation then return false end
  if not self.state_save_task then self.state_save_task=state.begin_save(self.host,self.project,self.rack,self.perf_callback,self.last_committed);self.state_due=0 end
  local complete=state.step_save(self.state_save_task,1)
  if complete then self.state_save_task=nil;self.state_pending=false;self.state_due=0 end
  return complete
end

function Controller:process_checkpoint()
  local task=self.checkpoint_task;if not task then return false end
  local ok,complete,result=pcall(state.step_compact,task.work)
  if not ok then self.checkpoint_task=nil;self.status="ERROR: "..tostring(complete);return false end
  if complete then
    self.checkpoint_task=nil
    if not self.dirty and task.generation==self.state_generation then
      self.last_committed=result;self.last_committed_generation=task.generation
    end
    return true
  end
  return false
end

function Controller:flush(force,options)
  options=options or {}
  if self.history_delete_empty_tracks then options.delete_empty_tracks=true end
  if not self.dirty or (not force and self.host.time_precise() < self.due) then return false end
  local ok, failure = xpcall(function()
    if force then model.assert_valid(self.rack) end
    if self.structural_dirty then
      self:reset_dispatcher_schedule()
      local filter=next(self.structural_pad_ids or {}) and self.structural_pad_ids or nil
      local report=lifecycle.reconcile(self.adapter,self.rack,{engine="sampler_bank",sampler_cache=self.sampler_cache,pad_ids=filter,delete_empty_tracks=options.delete_empty_tracks==true,undo_label=options.undo_label})
      self.sampler_cache=report.sampler_cache or self.sampler_cache
      self.bank_tracks=report.bank_tracks or self.bank_tracks
      self:invalidate_track_cache()
      self:sync_pad_track_names(filter)
    end
    local stage_started=self.host.time_precise()
    self:sync_pending_pad_controls()
    self:probe("flush pad controls",stage_started)
    if force then
      self.state_save_task=nil;state.save(self.host,self.project,self.rack);self.state_pending=false;self.state_due=0
    else
      -- Rack serialization writes both project ext-state and its redundant
      -- folder-track copy. Keep that work out of slider/click release frames;
      -- repeated edits coalesce into one idle write. Ctrl+S forces it first.
      self.state_pending=true;self.state_due=self.host.time_precise()+0.65
    end
    if self.publish_dirty then
      stage_started=self.host.time_precise()
      self.revision = self.revision % 16777214 + 1
      -- Runtime payloads are small enough to publish as one complete
      -- transaction. Sliced publication allowed rapid edits to cancel or
      -- overwrite an in-flight revision, leaving later steps unactivated.
      -- Always publish the latest complete rack; intermediate revisions do
      -- not need to reach the audio thread.
      self.publish_task=nil;self.publish_build_task=nil;self.publish_awaiting_revision=nil;self:publish()
      self:probe("flush publish build",stage_started)
    end
  end, debug.traceback)
  if ok then
    self.dirty, self.structural_dirty, self.publish_dirty = false, false, false;self.structural_pad_ids={};self.history_delete_empty_tracks=false
    if force then
      local checkpoint_started=self.host.time_precise();self.last_committed=state.compact(self.rack);self.last_committed_generation=self.state_generation;self.checkpoint_task=nil;self:probe("undo checkpoint",checkpoint_started)
    else
      self.checkpoint_task={generation=self.state_generation,work=state.begin_compact(self.rack,128)}
    end
  else self.status = "ERROR: " .. tostring(failure) end
  return ok, failure
end

function Controller:set_bank(bank)
  self.rack.selected_bank = math.max(1, math.min(8, bank)); self.selected_pad = (self.rack.selected_bank - 1) * 16 + 1
  self.selected_step = 1;self:mark_dirty(false,false)
end

function Controller:sync_live_bank()
  -- Banks are visual pages. Every pad owns one unique MIDI note and route.
end

function Controller:set_playback_mode(mode,record_history)
  mode=mode=="items" and "events" or mode
  if mode~="events" and mode~="rendered" then mode="continuous" end
  if self.rack.playback_mode==mode then return end
  self.rack.playback_mode=mode
  local previous_history_lock=self.history_lock
  if record_history==false then self.history_lock=true end
  self:mark_dirty(false);self:flush(true)
  self.history_lock=previous_history_lock
  self.status=mode=="events" and "Variation events gate playback" or (mode=="rendered" and "Rendered MIDI owns playback" or "Continuous variation playback")
end

function Controller:request_engine_variation()
  local track=self:find_track("sequencer");if not track then return end
  local fx=self:dispatcher(track);local target=self:active_variation_number();self.variation_request_token=((self.variation_request_token or 0)%16777214)+1
  if (self.host.GetPlayState()&1)==0 then self.engine_active_variation=target end
  self.host.TrackFX_SetParam(track,fx,69,target)
  self.host.TrackFX_SetParam(track,fx,70,self.variation_request_token)
end

function Controller:create_variation_event()
  local track=self:find_track("sequencer");if not track then self.status="ReaDrumXT MIDI track is missing";return end
  local qn_length=0
  for _,lane in ipairs(self:variation().lanes) do qn_length=math.max(qn_length,lane.step_count*4*lane.division_num/lane.division_den) end
  qn_length=math.max(qn_length,.25)
  local start_time=self.host.GetCursorPositionEx and self.host.GetCursorPositionEx(self.project) or self.host.GetCursorPosition()
  local start_qn=self.host.TimeMap2_timeToQN(self.project,start_time);local end_time=self.host.TimeMap2_QNToTime(self.project,start_qn+qn_length)
  self.host.Undo_BeginBlock2(self.project);self.host.PreventUIRefresh(1)
  local ok,failure=xpcall(function()
    local item=assert(self.host.CreateNewMIDIItemInProj(track,start_time,end_time,false),"could not create variation event")
    local take=assert(self.host.GetActiveTake(item),"variation event has no MIDI take")
    local ppq0=self.host.MIDI_GetPPQPosFromProjTime(take,start_time);local ppq1=self.host.MIDI_GetPPQPosFromProjTime(take,end_time)
    assert(self.host.MIDI_InsertCC(take,false,false,ppq0,0xC0,15,self:variation_number(self:pattern().id,self:variation().id)-1,0),"could not write variation selector")
    assert(self.host.MIDI_InsertNote(take,false,false,ppq0,math.max(ppq0+1,ppq1-1),15,127,127,true),"could not write variation gate")
    self.host.MIDI_Sort(take)
    self.host.GetSetMediaItemTakeInfo_String(take,"P_NAME","ReaDrumXT  •  "..self:variation().name,true)
    self.host.GetSetMediaItemInfo_String(item,"P_EXT:READRUM_VARIATION",self.rack.id.."|"..self:pattern().id.."|"..self:variation().id,true)
    self.host.SetMediaItemInfo_Value(item,"B_LOOPSRC",1)
    if self.host.ColorToNative then self.host.SetMediaItemInfo_Value(item,"I_CUSTOMCOLOR",self.host.ColorToNative(35,128,184)|0x1000000) end
    for index=0,self.host.CountMediaItems(self.project)-1 do self.host.SetMediaItemSelected(self.host.GetMediaItem(self.project,index),false) end
    self.host.SetMediaItemSelected(item,true);self.host.UpdateItemInProject(item)
  end,debug.traceback)
  self.host.PreventUIRefresh(-1);self.host.Undo_EndBlock2(self.project,"ReaDrum: create variation event",ok and -1 or 0);self.host.UpdateArrange()
  if not ok then self.status="Variation event error: "..tostring(failure);return end
  self:set_playback_mode("events",false);self.status="Variation event created"
end

local function rational_value(value)
  if type(value)=="number" then return value end
  if type(value)=="table" and tonumber(value.denominator) and value.denominator~=0 then return value.numerator/value.denominator end
  return 1/16
end

function Controller:render_variation_to_midi()
  local track=self:find_track("sequencer");if not track then self.status="ReaDrumXT MIDI track is missing";return end
  local variation=self:variation();local length_qn,tail_qn=0,.25
  for _,lane in ipairs(variation.lanes) do
    local unit=4*lane.division_num/lane.division_den
    length_qn=math.max(length_qn,lane.step_count*unit)
    for _,step in ipairs(lane.steps) do
      local repeat_tail=math.max(0,(step.repeat_count or 1)-1)*4*rational_value(step.repeat_spacing)
      tail_qn=math.max(tail_qn,repeat_tail+unit*math.max(0,(step.gate or 100))/100+math.abs(step.timing_offset or 0)/960)
    end
  end
  length_qn=math.max(.25,length_qn)
  local runtime=self:runtime_rack()
  local export_first_qn=0
  for _,pattern in ipairs(runtime.patterns) do for _,runtime_variation in ipairs(pattern.variations) do
    for _,lane in ipairs(runtime_variation.lanes) do
      local unit=4*lane.division_num/lane.division_den
      local clock_zero=((lane.phase or 0)%2==1) and unit*(lane.swing or 0)/200 or 0
      local first_step=lane.steps[((lane.phase or 0)%lane.step_count)+1]
      if first_step then export_first_qn=math.min(export_first_qn,clock_zero+(first_step.timing_offset or 0)/960) end
    end
  end end
  local image=snapshot_v2.encode(runtime,{revision=self.revision,active_variation=self:active_variation_number()})
  -- Include clock-zero hits pulled before the item boundary by negative step or
  -- lane timing. The oracle begins at clock index zero, so this pre-roll cannot
  -- accidentally import notes from a preceding pattern cycle.
  local events=scheduler_oracle.schedule(image,export_first_qn-.001,length_qn+tail_qn+.001,{fill=self.fill==true})
  local offs,notes={},{}
  for _,event in ipairs(events) do
    if event.kind=="off" then offs[event.token]=event.qn end
  end
  for _,event in ipairs(events) do
    if event.kind=="on" and event.qn<length_qn then
      local pad_zero=math.max(0,math.min(127,event.pad-1))
      local raw_end=math.max(event.qn+.001,offs[event.token] or event.qn+.05)
      local start_qn=math.max(0,event.qn)
      -- MIDI items cannot contain a note before their own start. Pin a negative
      -- first hit to QN zero and move its end by the same amount, preserving the
      -- intended gate instead of dropping or shortening the note.
      local end_qn=event.qn<0 and (raw_end-event.qn) or raw_end
      local rendered_pad=self.rack.pads[event.pad];local rendered_controls=rendered_pad and rendered_pad.default_controls or {}
      notes[#notes+1]={start_qn=start_qn,end_qn=math.max(start_qn+.001,end_qn),pad=pad_zero,pitch=(36+pad_zero)%128,velocity=event.velocity,
        transpose=(event.note or 69)-69,pitch_cents=event.pitch_cents or 0,pan=event.pan or 0,slide=event.slide==true,transient_shift=event.transient_shift or 0,
        glide=math.max(0,math.min(.5,tonumber(rendered_controls.glide) or 0))}
    end
  end
  if #notes==0 then self.status="Add at least one step before inserting MIDI";return end
  table.sort(notes,function(a,b)if a.start_qn~=b.start_qn then return a.start_qn<b.start_qn end;return a.pad<b.pad end)
  -- Mark slide handoffs here, then enforce the overlap in PPQ below. A QN
  -- epsilon can quantize back onto the note boundary when REAPER stores MIDI,
  -- allowing the old note-off to kill the voice before the slide note arrives.
  local previous_by_pad={}
  for _,note in ipairs(notes) do
    local previous=previous_by_pad[note.pad]
    if note.slide and previous and math.abs(previous.end_qn-note.start_qn)<1e-9 then previous.slide_handoff_qn=note.start_qn end
    previous_by_pad[note.pad]=note
  end
  -- MIDI pitch bend/CC are channel-scoped. Notes sharing an onset may share a
  -- channel only when their complete performance packet is identical.
  local onset=false;local packets={};local onset_channels={};local used_channels={};local previous_channel_by_pad={};local active_channels_by_pad={}
  for _,note in ipairs(notes) do
    if onset==false or math.abs(note.start_qn-onset)>1e-9 then onset=note.start_qn;packets={};onset_channels={} end
    local total_pitch=math.max(-24,math.min(24,note.transpose+note.pitch_cents/100))
    note.bend=math.max(0,math.min(16383,math.floor(8192+total_pitch*8192/24+.5)))
    note.pan_cc=math.max(0,math.min(127,math.floor((math.max(-100,math.min(100,note.pan))+100)*127/200+.5)))
    note.slide_cc=note.slide and 127 or 0;note.shift_cc=math.max(0,math.min(127,math.floor(note.transient_shift*127+.5)));note.glide_cc=math.max(0,math.min(127,math.floor(note.glide*254+.5)))
    -- Swing can make the short half of a pair begin before the preceding
    -- same-pad note has ended. Reusing its channel/pitch lets that older MIDI
    -- note-off terminate the newer voice. Keep overlapping (and exact
    -- boundary) same-pad notes on separate channels, as the live engine does.
    local forbidden={};local active=active_channels_by_pad[note.pad] or {}
    for channel,end_qn in pairs(active) do
      if end_qn>=note.start_qn-1e-9 then forbidden[channel]=true else active[channel]=nil end
    end
    local previous=previous_channel_by_pad[note.pad]
    if note.slide and previous~=nil then forbidden[previous]=true end
    local forbidden_key={};for channel=0,15 do if forbidden[channel] then forbidden_key[#forbidden_key+1]=channel end end
    local key=table.concat({note.bend,note.pan_cc,note.slide_cc,note.shift_cc,note.glide_cc,table.concat(forbidden_key,",")},":")
    local channel=packets[key]
    if channel==nil then
      channel=0;while channel<16 and (onset_channels[channel] or forbidden[channel]) do channel=channel+1 end
      if channel>=16 then self.status="MIDI render needs more than 16 simultaneous performance channels";return end
      packets[key]=channel
    end
    note.channel=channel;onset_channels[channel]=true;used_channels[channel]=true;previous_channel_by_pad[note.pad]=channel
    active_channels_by_pad[note.pad]=active;active[channel]=math.max(active[channel] or -math.huge,note.end_qn)
  end
  local start_time=self.host.GetCursorPositionEx and self.host.GetCursorPositionEx(self.project) or self.host.GetCursorPosition()
  local start_qn=self.host.TimeMap2_timeToQN(self.project,start_time)
  -- The arrange item represents the pattern cycle, not its longest note gate.
  -- Keep both edges exactly on the requested pattern bounds. Performance CCs
  -- for clock-zero notes share the first PPQ position instead of growing a
  -- hidden pre-roll, and note tails remain source data clipped by the item.
  local item_start_time=start_time
  local end_time=self.host.TimeMap2_QNToTime(self.project,start_qn+length_qn)
  self.host.Undo_BeginBlock2(self.project);self.host.PreventUIRefresh(1)
  local ok,failure=xpcall(function()
    local item=assert(self.host.CreateNewMIDIItemInProj(track,item_start_time,end_time,false),"could not create MIDI item")
    local take=assert(self.host.GetActiveTake(item),"MIDI item has no take")
    local item_ppq=self.host.MIDI_GetPPQPosFromProjTime(take,item_start_time)
    for channel in pairs(used_channels) do
      -- Declare the same +/-24-semitone bend range consumed by ReaDrum's
      -- rendered-MIDI decoder. This also keeps the item meaningful when it is
      -- routed to another MPE-capable instrument.
      assert(self.host.MIDI_InsertCC(take,false,false,item_ppq,0xB0,channel,101,0),"could not write pitch range")
      assert(self.host.MIDI_InsertCC(take,false,false,item_ppq,0xB0,channel,100,0),"could not write pitch range")
      assert(self.host.MIDI_InsertCC(take,false,false,item_ppq,0xB0,channel,6,24),"could not write pitch range")
      assert(self.host.MIDI_InsertCC(take,false,false,item_ppq,0xB0,channel,38,0),"could not write pitch range")
    end
    for _,note in ipairs(notes) do
      local note_start=self.host.TimeMap2_QNToTime(self.project,start_qn+note.start_qn)
      local note_end=self.host.TimeMap2_QNToTime(self.project,start_qn+note.end_qn)
      local start_ppq=self.host.MIDI_GetPPQPosFromProjTime(take,note_start);local end_ppq=self.host.MIDI_GetPPQPosFromProjTime(take,note_end)
      if note.slide_handoff_qn then
        local handoff_time=self.host.TimeMap2_QNToTime(self.project,start_qn+note.slide_handoff_qn)
        local handoff_ppq=self.host.MIDI_GetPPQPosFromProjTime(take,handoff_time)
        end_ppq=math.max(end_ppq,handoff_ppq+1)
      end
      local packet_ppq=math.max(item_ppq,start_ppq-1)
      assert(self.host.MIDI_InsertCC(take,false,false,packet_ppq,0xE0,note.channel,note.bend&127,(note.bend>>7)&127),"could not write MIDI pitch")
      assert(self.host.MIDI_InsertCC(take,false,false,packet_ppq,0xB0,note.channel,5,note.glide_cc),"could not write MIDI glide")
      assert(self.host.MIDI_InsertCC(take,false,false,packet_ppq,0xB0,note.channel,10,note.pan_cc),"could not write MIDI pan")
      assert(self.host.MIDI_InsertCC(take,false,false,packet_ppq,0xB0,note.channel,68,note.slide_cc),"could not write MIDI slide")
      assert(self.host.MIDI_InsertCC(take,false,false,packet_ppq,0xB0,note.channel,74,note.shift_cc),"could not write MIDI transient shift")
      assert(self.host.MIDI_InsertNote(take,false,false,start_ppq,math.max(start_ppq+1,end_ppq),note.channel,note.pitch,note.velocity,true),"could not write MIDI note")
    end
    self.host.MIDI_Sort(take)
    self.host.GetSetMediaItemTakeInfo_String(take,"P_NAME","ReaDrumXT  •  "..variation.name.." [MIDI]",true)
    self.host.GetSetMediaItemInfo_String(item,"P_EXT:READRUM_RENDERED_MIDI",self.rack.id.."|"..self:pattern().id.."|"..variation.id,true)
    for index=0,self.host.CountMediaItems(self.project)-1 do self.host.SetMediaItemSelected(self.host.GetMediaItem(self.project,index),false) end
    self.host.SetMediaItemSelected(item,true);self.host.UpdateItemInProject(item)
  end,debug.traceback)
  self.host.PreventUIRefresh(-1);self.host.Undo_EndBlock2(self.project,"ReaDrum: create variation MIDI",ok and -1 or 0);self.host.UpdateArrange()
  if not ok then self.status="Could not insert MIDI: "..tostring(failure);return end
  self:set_playback_mode("rendered",false)
  self.status=string.format("Inserted %d editable MIDI notes at the edit cursor",#notes)
end


function Controller:select_pattern(index)
  self.pattern_index = math.max(1, math.min(#self.rack.patterns, index)); self.variation_index = 1
  self.rack.selected_pattern, self.rack.selected_variation = self.pattern_index, self.variation_index
  self.selected_step = 1
  self:mark_dirty(false)
  self:request_engine_variation()
end

function Controller:select_variation(index)
  self.variation_index = math.max(1, math.min(#self:pattern().variations, index))
  self.rack.selected_pattern, self.rack.selected_variation = self.pattern_index, self.variation_index
  self.selected_step = 1
  self:reassign_selected_variation_event()
  self:mark_dirty(false)
  self:request_engine_variation()
end

function Controller:add_pattern(duplicate)
  if #self.rack.patterns >= 8 then self.status = "Eight-pattern runtime limit reached"; return end
  local source = duplicate and self:pattern() or nil
  local name = source and (source.name .. " Copy") or ("Pattern " .. (#self.rack.patterns + 1))
  local pattern = state.new_pattern(self.rack.pads, name, source, "readrum_p" .. os.time() .. "_" .. (#self.rack.patterns + 1))
  self.rack.patterns[#self.rack.patterns + 1] = pattern;self.variation_events_dirty=true; self:select_pattern(#self.rack.patterns); self:flush(true)
end

function Controller:delete_pattern()
  if #self.rack.patterns == 1 then self.status = "A rack must keep one pattern"; return end
  table.remove(self.rack.patterns, self.pattern_index);self.variation_events_dirty=true; self:select_pattern(math.min(self.pattern_index, #self.rack.patterns)); self:flush(true)
end

function Controller:add_variation(duplicate)
  local pattern = self:pattern()
  local total = 0; for _, item in ipairs(self.rack.patterns) do total = total + #item.variations end
  if total >= 64 then self.status = "Variation runtime limit reached"; return end
  local source = duplicate and self:variation() or nil
  local name = source and (source.name .. " Copy") or ("Variation " .. (#pattern.variations + 1))
  pattern.variations[#pattern.variations + 1] = state.new_variation(self.rack.pads, name, source, "readrum_v" .. os.time() .. "_" .. total)
  self.variation_events_dirty=true
  self:mark_dirty(false)
  self:select_variation(#pattern.variations)
end

function Controller:delete_variation()
  local pattern = self:pattern(); if #pattern.variations == 1 then self.status = "ReaDrum must keep one variation"; return end
  table.remove(pattern.variations, self.variation_index);self.variation_events_dirty=true;self:mark_dirty(false);self:select_variation(math.min(self.variation_index, #pattern.variations))
end

function Controller:rename_pattern(name)
  name=tostring(name or ""):gsub("[%c]",""):sub(1,64)
  if name~="" and self:pattern().name~=name then self:pattern().name=name;self:mark_dirty(false) end
end

function Controller:rename_variation(name)
  name=tostring(name or ""):gsub("[%c]",""):sub(1,64)
  if name~="" and self:variation().name~=name then self:variation().name=name;self.variation_events_dirty=true;self:mark_dirty(false) end
end

function Controller:copy_pattern()
  self.pattern_clipboard=model.deep_copy(self:pattern());self:set_clipboard_envelope(clipboard.copy_pattern(self:pattern()));self.status="Pattern copied"
end

function Controller:paste_pattern()
  local envelope=self:get_clipboard_envelope("pattern");local copied=(envelope and envelope.payload.pattern) or self.pattern_clipboard
  if not copied then self.status="Copy a pattern first";return end
  local source=model.deep_copy(copied)
  self.rack.patterns[self.pattern_index]=state.new_pattern(self.rack.pads,source.name,source,"readrum_pattern_paste_"..os.time())
  self.variation_events_dirty=true
  self.variation_index=math.min(self.variation_index,#self:pattern().variations)
  self.rack.selected_pattern,self.rack.selected_variation=self.pattern_index,self.variation_index
  self.selected_step=1;self:mark_dirty(false);self.status="Pattern pasted"
end

function Controller:copy_variation()
  local envelope=clipboard.copy_variation(self:variation())
  self.variation_clipboard=envelope.payload.variation;self:set_clipboard_envelope(envelope);self.status="Variation copied"
end

function Controller:paste_variation()
  local envelope=self:get_clipboard_envelope("variation");local copied=(envelope and envelope.payload.variation) or self.variation_clipboard
  if not copied then self.status="Copy a variation first";return end
  self:pattern().variations[self.variation_index]=state.new_variation(self.rack.pads,copied.name,copied,"readrum_variation_paste_"..os.time())
  self.variation_events_dirty=true
  self.selected_step=1;self:mark_dirty(false);self.status="Variation pasted"
end

function Controller:save_kit()
  local path
  if self.host.JS_Dialog_BrowseForSaveFile then local ok,value=self.host.JS_Dialog_BrowseForSaveFile("Save ReaDrum Kit","","ReaDrum Kit.readrum","ReaDrum Kit (*.readrum)\0*.readrum\0");if ok==1 then path=value end
  else local ok,value=self.host.GetUserInputs("Save ReaDrum Kit",1,"Full .readrum path:","ReaDrum Kit.readrum");if ok then path=value end end
  if not path or path==""then return end;if not path:lower():match("%.readrum$")then path=path..".readrum"end
  local file,err=io.open(path,"wb");if not file then self.status="Could not save kit: "..tostring(err);return end;file:write(json.encode(self.rack));file:close();self.status="Kit saved"
end
function Controller:load_kit()
  -- GetUserFileNameForRead expects an extension list, not a Windows
  -- description/pattern filter pair. Supplying embedded NULs makes REAPER
  -- construct a malformed filter that hides valid .readrum kits.
  local ok,path=self.host.GetUserFileNameForRead("Load ReaDrum Kit","",".readrum");if not ok or path==""then return end
  local file,err=io.open(path,"rb");if not file then self.status="Could not load kit: "..tostring(err);return end;local raw=file:read("*a");file:close()
  local decoded;ok,decoded=pcall(json.decode,raw);if not ok then self.status="Invalid kit: "..tostring(decoded);return end;local valid,why=model.validate_rack(decoded);if not valid then self.status="Invalid kit: "..tostring(why);return end
  self.undo_stack[#self.undo_stack+1]=state.compact(self.rack);self.rack=decoded;self.pattern_index=1;self.variation_index=1;self.selected_pad=1;self.selected_step=1;self.dirty=true;self.structural_dirty=true;self.publish_dirty=true;self.variation_events_dirty=true;self.structural_pad_ids={};self.due=0;self:flush(true);self.status="Kit loaded"
end

function Controller:copy_steps(positions)
  positions=positions or {self.selected_step};table.sort(positions)
  local envelope=clipboard.copy_selected_steps(self:lane(),{positions=positions,time_origin=positions[1],span=positions[#positions]-positions[1]+1})
  self.steps_clipboard=envelope;self.step_clipboard=#positions==1 and model.deep_copy(self:lane().steps[positions[1]]) or nil
  self:set_clipboard_envelope(envelope);self.status=#positions==1 and "Step copied" or (#positions.." steps copied")
end
function Controller:copy_step() self:copy_steps({self.selected_step}) end

function Controller:duplicate_lane_steps(lane_indices)
  lane_indices=lane_indices or {};if #lane_indices==0 then lane_indices={self.selected_pad} end
  local duplicated=0;local full=0
  for _,lane_index in ipairs(lane_indices) do
    local lane=self:variation().lanes[lane_index]
    if lane then
      local source_count=lane.step_count
      if source_count>=64 then full=full+1 else
        local target_count=math.min(64,source_count*2)
        for position=source_count+1,target_count do lane.steps[position]=model.deep_copy(lane.steps[position-source_count]) end
        lane.step_count=target_count;duplicated=duplicated+1
      end
    end
  end
  if duplicated>0 then self:mark_dirty(false) end
  self.status=duplicated>0 and (duplicated.." selected lane"..(duplicated==1 and "" or "s").." duplicated"..(full>0 and ("; "..full.." already at 64 steps") or "")) or "Selected lanes are already at 64 steps"
end

function Controller:paste_steps()
  local envelope=self:get_clipboard_envelope("selected_steps") or self.steps_clipboard
  if not envelope then
    if self.step_clipboard then self:lane().steps[self.selected_step]=model.deep_copy(self.step_clipboard);self:mark_dirty(false);return end
    self.status="No copied steps";return
  end
  local lane,count=self:lane(),0
  for _,entry in ipairs(envelope.payload.steps) do
    local target=self.selected_step+entry.position
    if target>=1 and target<=lane.step_count then lane.steps[target]=model.deep_copy(entry.step);count=count+1 end
  end
  self:mark_dirty(false);self.status=count.." step"..(count==1 and "" or "s").." pasted"
end
function Controller:paste_step() self:paste_steps() end
function Controller:clear_step()
  self:lane().steps[self.selected_step]=model.new_step();self:mark_dirty(false);self.status="Step cleared"
end
function Controller:clear_steps(positions)
  positions=positions or {self.selected_step};local lane=self:lane();local count=0
  for _,position in ipairs(positions) do if position>=1 and position<=lane.step_count then lane.steps[position]=model.new_step();count=count+1 end end
  self:mark_dirty(false);self.status=count.." step"..(count==1 and "" or "s").." cleared"
end
function Controller:copy_lane() self.lane_clipboard=model.deep_copy(self:lane());self:set_clipboard_envelope(clipboard.copy_lane(self:lane()));self.status="Lane copied" end
function Controller:copy_lanes(indices)
  self.lanes_clipboard={};for _,index in ipairs(indices) do self.lanes_clipboard[#self.lanes_clipboard+1]=model.deep_copy(self:lane(index)) end
  self.status=#indices.." lane"..(#indices==1 and "" or "s").." copied"
end
function Controller:paste_lanes(indices)
  local copied=self.lanes_clipboard
  if not copied or #copied==0 then self.status="No copied lanes";return end
  for position,index in ipairs(indices) do
    local source=copied[#copied==1 and 1 or position]
    if source then
      local lane=self:lane(index);local id,pad_id=lane.id,lane.pad_id
      local replacement=model.deep_copy(source);replacement.id,replacement.pad_id=id,pad_id
      self:variation().lanes[index]=replacement
    end
  end
  self:mark_dirty(false);self.status="Lanes pasted"
end
function Controller:clear_lanes(indices)
  for _,index in ipairs(indices) do local lane=self:lane(index);for step=1,lane.step_count do lane.steps[step]=model.new_step() end end
  self:mark_dirty(false);self.status=#indices.." lane"..(#indices==1 and "" or "s").." cleared"
end
function Controller:paste_lane()
  local envelope=self:get_clipboard_envelope("lane");local copied=(envelope and envelope.payload.lane) or self.lane_clipboard
  if not copied then self.status = "No copied lane"; return end
  local lane=self:lane()
  lane.step_count, lane.division_num, lane.division_den, lane.phase, lane.swing = copied.step_count, copied.division_num, copied.division_den, copied.phase, copied.swing
  lane.timing_offset,lane.velocity_scale,lane.velocity_sensitivity,lane.gate_scale,lane.accentuator_enabled,lane.velocity_humanize,lane.timing_humanize,lane.pitch_humanize,lane.pan_humanize=copied.timing_offset or 0,copied.velocity_scale or 100,copied.velocity_sensitivity or 100,copied.gate_scale or 100,copied.accentuator_enabled==true,copied.velocity_humanize or 0,copied.timing_humanize or 0,copied.pitch_humanize or 0,copied.pan_humanize or 0
  lane.global_swing_enabled=copied.global_swing_enabled~=false
  lane.global_gate_enabled=copied.global_gate_enabled~=false
  lane.global_velocity_sensitivity_enabled=copied.global_velocity_sensitivity_enabled~=false
  lane.global_velocity_humanize_enabled=copied.global_velocity_humanize_enabled~=false
  lane.defaults, lane.steps = model.deep_copy(copied.defaults), model.deep_copy(copied.steps); self.selected_step = math.min(self.selected_step, lane.step_count); self:mark_dirty(false)
end
function Controller:copy_step_property(key)
  assert(model.get_step_property_definition(key),"Unknown step property: "..tostring(key));local values={}
  for index,step in ipairs(self:lane().steps) do values[index]={value=model.deep_copy(step[key])} end
  self.property_clipboard={key=key,values=values};self:set_clipboard_envelope(clipboard.copy_property_lane(self:lane(),key,{time_origin=1,span=self:lane().step_count}));self.status="Copied "..key.." values"
end
function Controller:paste_step_property(key)
  local envelope=self:get_clipboard_envelope("property_lane");local clip
  if envelope then clip={key=envelope.property_id,values={}};for _,entry in ipairs(envelope.payload.values) do clip.values[entry.position+1]={value=model.deep_copy(entry.value)} end
  else clip=self.property_clipboard end
  if not clip then self.status="No copied parameter values";return end
  if clip.key~=key then self.status="Copied values are for "..clip.key;return end
  local lane=self:lane();for index=1,math.min(lane.step_count,#clip.values) do lane.steps[index][key]=model.deep_copy(clip.values[index].value) end
  self:mark_dirty(false);self.status="Pasted "..key.." values"
end
function Controller:copy_pad()
  self.pad_clipboard=model.deep_copy(self:pad());self:set_clipboard_envelope(clipboard.copy_pad(self:pad()));self.status="Pad copied"
end
function Controller:paste_pad()
  local envelope=self:get_clipboard_envelope("pad");local copied=(envelope and envelope.payload.pad) or self.pad_clipboard
  if not copied then self.status="No copied pad";return end
  local destination=self:pad();local source=model.deep_copy(copied)
  local id,logical_index,refs=destination.id,destination.logical_index,destination.reaper_object_refs
  for key in pairs(destination) do destination[key]=nil end
  for key,value in pairs(source) do destination[key]=value end
  destination.id,destination.logical_index,destination.reaper_object_refs=id,logical_index,refs
  local valid_ids={};for _,pad in ipairs(self.rack.pads) do valid_ids[pad.id]=true end
  local function safe_targets(targets)
    local result,seen={},{}
    for _,target in ipairs(targets or {}) do
      if target~=id and valid_ids[target] and not seen[target] and #result<4 then seen[target]=true;result[#result+1]=target end
    end
    return result
  end
  destination.simultaneous_play_targets=safe_targets(destination.simultaneous_play_targets)
  destination.mute_targets=safe_targets(destination.mute_targets)
  self:mark_pad_structural(self.selected_pad);self.status="Pad pasted without replacing its track identity"
end

-- Move selected pad identities into a consecutive destination block. Pads
-- displaced by the block fill the vacated source slots, so a one-pad drag is
-- a swap and overlapping multi-pad moves become a stable rotation. Because
-- IDs travel with the pad, its RS5K track, FX, automation and relationships do
-- not need to be copied or rebuilt.
function Controller:move_pads(indices,destination)
  if #self.structural_queue>0 then self:process_structural_queue(math.huge) end
  if self.dirty then local ok=self:flush(true);if not ok then return false end end
  local total=#self.rack.pads;local seen,sources={},{}
  for _,index in ipairs(indices or {}) do
    index=math.floor(tonumber(index) or 0)
    if index>=1 and index<=total and not seen[index] then seen[index]=true;sources[#sources+1]=index end
  end
  table.sort(sources)
  if #sources==0 then self.status="No pads selected to move";return false end
  destination=math.max(1,math.min(total-#sources+1,math.floor(tonumber(destination) or sources[1])))
  local targets,target_set={},{}
  for offset=0,#sources-1 do local slot=destination+offset;targets[#targets+1]=slot;target_set[slot]=true end
  local unchanged=#sources==#targets
  for index=1,#sources do if sources[index]~=targets[index] then unchanged=false;break end end
  if unchanged then self.status="Pads are already in that position";return false end

  local before=model.deep_copy(self.rack);local working=model.deep_copy(self.rack)
  local source_set,incoming,displaced,vacated={},{},{},{}
  for _,slot in ipairs(sources) do source_set[slot]=true;incoming[#incoming+1]=working.pads[slot] end
  for _,slot in ipairs(targets) do if not source_set[slot] then displaced[#displaced+1]=working.pads[slot] end end
  for _,slot in ipairs(sources) do if not target_set[slot] then vacated[#vacated+1]=slot end end
  assert(#displaced==#vacated,"pad move permutation is unbalanced")
  for index,slot in ipairs(targets) do working.pads[slot]=incoming[index] end
  for index,slot in ipairs(vacated) do working.pads[slot]=displaced[index] end
  local affected={}
  for slot,pad in ipairs(working.pads) do
    pad.logical_index=slot;working.pad_order[slot]=pad.id
    if before.pads[slot].id~=pad.id then affected[before.pads[slot].id]=true;affected[pad.id]=true end
  end
  local valid,error_message=model.validate_rack(working)
  if not valid then self.status="Pad move rejected: "..tostring(error_message);return false end

  self.rack=working;self.selected_pad=destination;self.rack.selected_bank=math.floor((destination-1)/16)+1
  self.selected_step=math.min(self.selected_step,self:lane().step_count)
  self.structural_pad_ids=affected
  self:mark_dirty(true)
  local ok,failure=self:flush(true)
  if not ok then self.rack=before;self.status="Pad move failed: "..tostring(failure);return false end
  if #sources==1 then self.status=string.format("Pad moved to %03d",destination)
  else self.status=string.format("%d pads moved to %03d",#sources,destination) end
  return targets
end
function Controller:clear_lane()
  local lane = self:lane(); for index = 1, lane.step_count do lane.steps[index].enabled = false end; self:mark_dirty(false)
end
function Controller:rotate_lane(amount)
  local lane=self:lane();local result={};for index=1,lane.step_count do local target=((index-1+amount)%lane.step_count)+1;result[target]=lane.steps[index]end;lane.steps=result;self:mark_dirty(false)
end
function Controller:reverse_lane()local lane=self:lane();for left=1,math.floor(lane.step_count/2)do local right=lane.step_count-left+1;lane.steps[left],lane.steps[right]=lane.steps[right],lane.steps[left]end;self:mark_dirty(false)end
function Controller:randomize_lane(density)
  local lane=self:lane();density=density or 50;for _,step in ipairs(lane.steps)do step.enabled=math.random(100)<=density;step.velocity=math.random(72,127)end;self:mark_dirty(false)
end
function Controller:humanize_lane(amount)
  local lane=self:lane();amount=amount or 12;for _,step in ipairs(lane.steps)do if step.enabled then step.velocity=math.max(1,math.min(127,step.velocity+math.random(-amount,amount)));step.timing_offset=math.max(-960,math.min(960,step.timing_offset+math.random(-amount*2,amount*2)))end end;self:mark_dirty(false)
end
function Controller:euclidean_lane(pulses)
  local lane=self:lane();pulses=math.max(0,math.min(lane.step_count,pulses or 4));for index,step in ipairs(lane.steps)do step.enabled=math.floor(index*pulses/lane.step_count)~=math.floor((index-1)*pulses/lane.step_count)end;self:mark_dirty(false)
end

function Controller:double_lane()
  local lane=self:lane();local old_count=lane.step_count;local new_count=math.min(64,old_count*2)
  if new_count==old_count then self.status="Lane is already at 64 steps";return end
  for index=old_count+1,new_count do lane.steps[index]=model.deep_copy(lane.steps[((index-1)%old_count)+1]) end
  lane.step_count=new_count;self:mark_dirty(false);self.status="Lane doubled to "..new_count.." steps"
end

function Controller:half_lane()
  local lane=self:lane();local new_count=math.max(1,math.floor(lane.step_count/2))
  if new_count==lane.step_count then return end
  for index=lane.step_count,new_count+1,-1 do lane.steps[index]=nil end
  lane.step_count=new_count;self.selected_step=math.min(self.selected_step,new_count);self:mark_dirty(false);self.status="Lane halved to "..new_count.." steps"
end

function Controller:ramp_step_property(key,first_value,last_value)
  local definition=assert(model.get_step_property_definition(key),"Unknown step property: "..tostring(key))
  local lane=self:lane();local span=math.max(1,lane.step_count-1)
  for index,step in ipairs(lane.steps) do
    local value=first_value+(last_value-first_value)*(index-1)/span
    if definition.value_type=="integer" or definition.value_type=="integer_or_false" then value=math.floor(value+0.5) end
    if definition.minimum then value=math.max(definition.minimum,value) end
    if definition.maximum then value=math.min(definition.maximum,value) end
    step[key]=value
  end
  self:mark_dirty(false);self.status="Ramped "..definition.label
end

function Controller:scale_step_property(key,factor)
  local definition=assert(model.get_step_property_definition(key),"Unknown step property: "..tostring(key))
  for _,step in ipairs(self:lane().steps) do
    local value=step[key]
    if type(value)=="number" then
      value=value*factor
      if definition.value_type=="integer" or definition.value_type=="integer_or_false" then value=math.floor(value+0.5) end
      if definition.minimum then value=math.max(definition.minimum,value) end
      if definition.maximum then value=math.min(definition.maximum,value) end
      step[key]=value
    end
  end
  self:mark_dirty(false);self.status=string.format("Scaled %s to %.0f%%",definition.label,factor*100)
end

function Controller:reset_step_property(key)
  local definition=assert(model.get_step_property_definition(key),"Unknown step property: "..tostring(key))
  for _,step in ipairs(self:lane().steps) do step[key]=model.deep_copy(definition.default) end
  self:mark_dirty(false);self.status="Reset "..definition.label
end


function Controller:link_pads(indices)
  indices=indices or {}
  if #indices==1 and indices[1]~=self.selected_pad then indices={self.selected_pad,indices[1]} end
  if #indices>=2 then
    local members,member_ids,seen={},{},{}
    for _,index in ipairs(indices) do
      local pad=self:pad(index)
      if pad and pad.sample~=false and not seen[pad.id] and #members<5 then
        seen[pad.id]=true;members[#members+1]=index;member_ids[pad.id]=true
      end
    end
    if #members<2 then self.status="Select at least two loaded pads for a trigger link";return false end
    -- Detach every selected member from any previous trigger group first.
    -- Otherwise old pads retain incoming references and contaminate the new group.
    for _,pad in ipairs(self.rack.pads) do
      local targets={}
      if not member_ids[pad.id] then
        for _,target in ipairs(pad.simultaneous_play_targets or {}) do if not member_ids[target] then targets[#targets+1]=target end end
      end
      pad.simultaneous_play_targets=targets
    end
    for _,source_index in ipairs(members) do
      local targets={};for _,target_index in ipairs(members) do if target_index~=source_index then targets[#targets+1]=self:pad(target_index).id end end
      self:pad(source_index).simultaneous_play_targets=targets
    end
    self:mark_dirty(false);self.status="Trigger link assigned to "..#members.." pads";return true
  else
    local id=self:pad().id
    for _,pad in ipairs(self.rack.pads) do
      local related=pad.id==id
      for _,target in ipairs(pad.simultaneous_play_targets or {}) do if target==id then related=true;break end end
      if related then pad.simultaneous_play_targets={} end
    end
    self:mark_dirty(false);self.status="Trigger link cleared";return true
  end
end

function Controller:clear_pad_relationships(indices)
  local ids,count={},0
  for _,index in ipairs(indices or {}) do local pad=self:pad(index);if pad and not ids[pad.id] then ids[pad.id]=true;count=count+1 end end
  if count==0 then local pad=self:pad();ids[pad.id]=true;count=1 end
  local function without_targets(source)
    local result={};for _,id in ipairs(source or {}) do if not ids[id] then result[#result+1]=id end end;return result
  end
  for _,pad in ipairs(self.rack.pads) do
    if ids[pad.id] then
      pad.simultaneous_play_targets={};pad.mute_targets={};pad.choke_group=false;pad.self_choke=false
    else
      pad.simultaneous_play_targets=without_targets(pad.simultaneous_play_targets)
      pad.mute_targets=without_targets(pad.mute_targets)
    end
  end
  local groups={}
  for _,group in ipairs(self.rack.round_robin_groups) do
    local affected=false;for _,id in ipairs(group.member_pad_ids) do if ids[id] then affected=true;break end end
    if not affected then groups[#groups+1]=group end
  end
  self.rack.round_robin_groups=groups
  self:mark_dirty(false);self.status=string.format("Relationships cleared for %d pad%s",count,count==1 and "" or "s")
  return true
end

function Controller:assign_choke_group(indices)
  indices=indices or {}
  if #indices<2 then self.status="Select at least two pads for a choke group";return false end
  local group=self:pad(indices[1]).choke_group
  if group==false or not group then
    local used={};for _,pad in ipairs(self.rack.pads) do if pad.choke_group~=false then used[pad.choke_group]=true end end
    for candidate=1,32 do if not used[candidate] then group=candidate;break end end
    group=group or 1
  end
  for _,index in ipairs(indices) do self:pad(index).choke_group=group;self:pad(index).self_choke=true end
  self:mark_dirty(false);self.status=string.format("Choke group %d assigned to %d pads",group,#indices)
  return true
end

function Controller:set_mute_targets(indices)
  local master, targets = self:pad(), {}
  for _, index in ipairs(indices or {}) do
    if index ~= master.logical_index and #targets < 4 then targets[#targets + 1] = self:pad(index).id end
  end
  master.mute_targets = targets
  self:mark_dirty(false)
  self.status = #targets > 0 and ("Pad chokes " .. #targets .. " selected pad(s)") or "Explicit choke targets cleared"
end

function Controller:round_robin_for_pad(index)
  local id = self:pad(index).id
  for group_index, group in ipairs(self.rack.round_robin_groups) do
    for _, member in ipairs(group.member_pad_ids) do if member == id then return group, group_index end end
  end
end

function Controller:pad_index_for_id(id)
  for index,pad in ipairs(self.rack.pads) do if pad.id==id then return index end end
end

function Controller:set_round_robin_master(index)
  local group=self:round_robin_for_pad(index or self.selected_pad)
  if not group then self.status="Selected pad is not in a round robin group";return end
  group.master_pad_id=self:pad(index or self.selected_pad).id;self:mark_dirty(false)
  self.status="Round robin master set to "..(self:pad(index or self.selected_pad).name or ("Pad "..tostring(index or self.selected_pad)))
end

function Controller:make_round_robin(indices)
  local members, seen = {}, {}
  local member_indices={}
  local function add(index)
    local pad=type(index)=="number" and self:pad(index) or nil
    if pad and pad.sample~=false and not seen[index] then
      seen[index]=true;member_indices[#member_indices+1]=index;members[#members+1]=pad.id
    end
  end
  if indices and #indices>0 then for _,index in ipairs(indices) do add(index) end else add(self.selected_pad) end
  if #members < 2 then self.status = "Select at least two loaded pads for round robin"; return false end
  local master_index=seen[self.selected_pad] and self.selected_pad or member_indices[1]
  local remove = {}; for index in ipairs(self.rack.round_robin_groups) do remove[index]=false end
  for index, group in ipairs(self.rack.round_robin_groups) do
    for _, member in ipairs(group.member_pad_ids) do for _, wanted in ipairs(members) do if member==wanted then remove[index]=true end end end
  end
  for index=#remove,1,-1 do if remove[index] then table.remove(self.rack.round_robin_groups,index) end end
  local ids=model.new_id_factory("readrum_rr_"..os.time().."_"..#self.rack.round_robin_groups)
  self.rack.round_robin_groups[#self.rack.round_robin_groups+1]=model.new_round_robin_group({master_pad_id=self:pad(master_index).id,member_pad_ids=members,mode="sequential",probability=100,reset_policy="transport",advance_on_skip=false,advance_each_repeat=false,seed=os.time()%2147483647},ids)
  self:mark_dirty(false);self.status="Round robin ready: "..(self:pad(master_index).name or "selected pad").." cycles "..#members.." pads"
  return true
end

function Controller:remove_round_robin()
  local _,index=self:round_robin_for_pad(self.selected_pad);if index then table.remove(self.rack.round_robin_groups,index);self:mark_dirty(false);self.status="Round robin removed" end
end

function Controller:pad_track(index) return self:find_track("pad", self:pad(index).id) end
function Controller:output_track(id) return self:find_track("output",id) end
function Controller:aux_track(id) return self:find_track("aux",id) end
function Controller:active_outputs()
  local result={}
  for _,output in ipairs(self.rack.outputs or {}) do if self:output_track(output.id) then result[#result+1]=output end end
  return result
end
function Controller:set_output_aux_send(output,key,value)
  if not output or (key~="aux_a_send" and key~="aux_b_send") then return false end
  output[key]=math.max(0,math.min(1,tonumber(value)or 0));self:mark_dirty(true);return true
end
function Controller:track_value(track,key,default)
  if not track then return default or 0 end
  local value=self.adapter:get_track_value(track,key);return value==nil and (default or 0) or value
end
function Controller:set_track_value(track,key,value)
  if not track then return false end
  self.adapter:set_track_value(track,key,value);if self.host.MarkProjectDirty then self.host.MarkProjectDirty(self.project)end;return true
end
function Controller:toggle_track_value(track,key)
  return self:set_track_value(track,key,self:track_value(track,key,0)>0 and 0 or 1)
end
function Controller:set_mixer_track_mute(track,muted)
  if not track then return false end
  muted=muted==true
  local wanted=muted and 1 or 0
  local result
  if self.host.SetTrackUIMute then result=self.host.SetTrackUIMute(track,wanted,3)
  else self.adapter:set_track_value(track,"B_MUTE",wanted);result=wanted end
  if muted then
    if self.host.SetTrackUISolo then self.host.SetTrackUISolo(track,0,3)
    else self.adapter:set_track_value(track,"I_SOLO",0) end
  end
  if self.host.TrackList_AdjustWindows then self.host.TrackList_AdjustWindows(false) end
  if self.host.UpdateArrange then self.host.UpdateArrange() end
  if self.host.MarkProjectDirty then self.host.MarkProjectDirty(self.project) end
  local ok,ui_muted=false,false
  if self.host.GetTrackUIMute then ok,ui_muted=self.host.GetTrackUIMute(track) end
  local actual=ok and ui_muted or self:track_value(track,"B_MUTE",0)>0
  if actual~=muted then self.status="Mixer mute write was rejected by REAPER";return false end
  return result~=-1
end
function Controller:set_mixer_track_solo(track,soloed)
  if not track then return false end
  soloed=soloed==true
  local wanted=soloed and 1 or 0
  local result
  if self.host.SetTrackUISolo then result=self.host.SetTrackUISolo(track,wanted,3)
  else self.adapter:set_track_value(track,"I_SOLO",wanted);result=wanted end
  if soloed then
    if self.host.SetTrackUIMute then self.host.SetTrackUIMute(track,0,3)
    else self.adapter:set_track_value(track,"B_MUTE",0) end
  end
  if self.host.TrackList_AdjustWindows then self.host.TrackList_AdjustWindows(false) end
  if self.host.UpdateArrange then self.host.UpdateArrange() end
  if self.host.MarkProjectDirty then self.host.MarkProjectDirty(self.project) end
  local actual=self:track_value(track,"I_SOLO",0)>0
  if actual~=soloed then self.status="Mixer solo write was rejected by REAPER";return false end
  return result~=-1
end
function Controller:track_meter(track)
  if not track or not self.host.Track_GetPeakInfo then return 0,0 end
  return math.max(0,self.host.Track_GetPeakInfo(track,0)or 0),math.max(0,self.host.Track_GetPeakInfo(track,1)or 0)
end
function Controller:track_fx_count(track)return track and self.adapter:fx_count(track)or 0 end
function Controller:show_track_fx_chain(track)
  if not track then return false end
  if self.host.SetOnlyTrackSelected then self.host.SetOnlyTrackSelected(track)end
  self.host.TrackFX_Show(track,0,1);return true
end
function Controller:set_pad_output_number(indices,number)
  number=math.max(1,math.min(self.max_outputs==16 and 16 or 8,math.floor(tonumber(number) or 1)))
  local id=number==1 and "main" or "output_"..number;local found=false
  for _,output in ipairs(self.rack.outputs or {}) do if output.id==id then found=true;break end end
  if not found then self.rack.outputs[#self.rack.outputs+1]=model.new_output({id=id,name=number==1 and "Main" or "Output "..number}) end
  for _,index in ipairs(indices or {self.selected_pad}) do if self:pad(index) then self:pad(index).output_id=id end end
  local used={main=true};for _,pad in ipairs(self.rack.pads or {}) do used[pad.output_id or "main"]=true end
  for output_index=#self.rack.outputs,1,-1 do if not used[self.rack.outputs[output_index].id] then table.remove(self.rack.outputs,output_index) end end
  table.sort(self.rack.outputs,function(a,b)local an=a.id=="main"and 1 or tonumber(a.id:match("(%d+)$"))or 99;local bn=b.id=="main"and 1 or tonumber(b.id:match("(%d+)$"))or 99;return an<bn end)
  self:mark_dirty(true);return true
end
function Controller:set_pad_track_color_sync(enabled)
  if self.host.SetExtState then self.host.SetExtState("ReaDrum5k","apply_pad_track_colors",enabled and "1" or "0",true) end
  if enabled then self:sync_pad_track_names() end
  if self.host.TrackList_AdjustWindows then self.host.TrackList_AdjustWindows(false) end
  if self.host.UpdateArrange then self.host.UpdateArrange() end
end
function Controller:set_pad_colors(indices,hex)
  if type(hex)~="string" or not hex:match("^#%x%x%x%x%x%x$") then return false end
  local filter={}
  for _,index in ipairs(indices or {}) do
    local pad=self:pad(index)
    if pad then pad.color=hex;filter[pad.id]=true end
  end
  self:sync_pad_track_names(filter)
  if self.host.TrackList_AdjustWindows then self.host.TrackList_AdjustWindows(false) end
  if self.host.UpdateArrange then self.host.UpdateArrange() end
  self:mark_dirty(false)
  return true
end
function Controller:pad_muted(index)
  local pad=self:pad(index)
  return pad and pad.muted==true or false
end
function Controller:pad_soloed(index)
  local pad=self:pad(index)
  return pad and pad.soloed==true or false
end
function Controller:sync_pad_audio_masks()
  for index,pad in ipairs(self.rack.pads or {}) do
    if pad.sample~=false and pad.sample~=nil then self.pending_pad_controls[index]=true end
  end
  self:sync_pending_pad_controls()
end
function Controller:commit_pad_audibility()
  -- Mute and solo are live monitoring state, not musical edit history. Apply
  -- the sampler masks immediately and persist them without creating a custom
  -- ReaDrum undo checkpoint.
  self:sync_pad_audio_masks()
  self:save_state_only()
end
function Controller:set_pad_mute(index,muted)
  local pad=self:pad(index);if not pad then return false end
  pad.muted=muted==true
  if pad.muted then pad.soloed=false end
  self:commit_pad_audibility();return true
end
function Controller:set_pad_solo(index,soloed)
  local pad=self:pad(index);if not pad then return false end
  pad.soloed=soloed==true
  if pad.soloed then pad.muted=false end
  self:commit_pad_audibility();return true
end
function Controller:set_pad_mute_many(indices,muted)
  local changed=false
  for _,index in ipairs(indices or {}) do
    local pad=self:pad(index)
    if pad then pad.muted=muted==true;if pad.muted then pad.soloed=false end;changed=true end
  end
  if changed then self:commit_pad_audibility() end
  return changed
end
function Controller:set_pad_solo_many(indices,soloed)
  local changed=false
  for _,index in ipairs(indices or {}) do
    local pad=self:pad(index)
    if pad then pad.soloed=soloed==true;if pad.soloed then pad.muted=false end;changed=true end
  end
  if changed then self:commit_pad_audibility() end
  return changed
end
function Controller:toggle_pad_mute(index)
  local pad=self:pad(index);if not pad or pad.sample==false or pad.sample==nil then self.status="Load a sample before muting this lane";return false end
  self:set_pad_mute(index,not self:pad_muted(index))
  if self.host.TrackList_AdjustWindows then self.host.TrackList_AdjustWindows(false) end
  if self.host.UpdateArrange then self.host.UpdateArrange() end
  return true
end
function Controller:toggle_pad_solo(index)
  local pad=self:pad(index);if not pad or pad.sample==false or pad.sample==nil then self.status="Load a sample before soloing this lane";return false end
  self:set_pad_solo(index,not self:pad_soloed(index))
  if self.host.TrackList_AdjustWindows then self.host.TrackList_AdjustWindows(false) end
  if self.host.UpdateArrange then self.host.UpdateArrange() end
  return true
end
function Controller:pad_track_shown(index)
  local track=self:pad_track(index)
  return track and self.adapter:get_track_value(track,"B_SHOWINMIXER")>0 and self.adapter:get_track_value(track,"B_SHOWINTCP")>0 or false
end
function Controller:pad_shown_in_mixer(index)local track=self:pad_track(index);return track and self.adapter:get_track_value(track,"B_SHOWINMIXER")>0 or false end
function Controller:pad_shown_in_tcp(index)local track=self:pad_track(index);return track and self.adapter:get_track_value(track,"B_SHOWINTCP")>0 or false end
function Controller:set_pad_tracks_visibility(indices,field,label,shown)
  local tracks={}
  for _,index in ipairs(indices or {}) do local track=self:pad_track(index);if track then tracks[#tracks+1]=track end end
  if #tracks==0 then self.status="Load samples before showing selected pad tracks";return false end
  for _,track in ipairs(tracks) do self.adapter:set_track_value(track,field,shown and 1 or 0) end
  if self.host.TrackList_AdjustWindows then self.host.TrackList_AdjustWindows(false) end
  if self.host.UpdateArrange then self.host.UpdateArrange() end
  self.status=string.format("%d pad track%s %s %s",#tracks,#tracks==1 and "" or "s",shown and "shown in" or "hidden from",label)
  return true
end
function Controller:set_pads_shown_in_mixer(indices,shown)return self:set_pad_tracks_visibility(indices,"B_SHOWINMIXER","mixer",shown)end
function Controller:set_pads_shown_in_tcp(indices,shown)return self:set_pad_tracks_visibility(indices,"B_SHOWINTCP","TCP",shown)end
function Controller:all_pad_tracks_visible(view)
  local shown=view=="mixer" and self.pad_shown_in_mixer or self.pad_shown_in_tcp
  local found=false
  for index,pad in ipairs(self.rack.pads) do
    if pad.sample~=false then
      found=true
      if not shown(self,index) then return false end
    end
  end
  return found
end
function Controller:toggle_all_pad_tracks(view)
  local indices={};for index,pad in ipairs(self.rack.pads) do if pad.sample~=false then indices[#indices+1]=index end end
  local all_visible=self:all_pad_tracks_visible(view)
  return view=="mixer" and self:set_pads_shown_in_mixer(indices,not all_visible) or self:set_pads_shown_in_tcp(indices,not all_visible)
end
function Controller:toggle_all_pad_tracks_in_mixer()return self:toggle_all_pad_tracks("mixer")end
function Controller:toggle_all_pad_tracks_in_tcp()return self:toggle_all_pad_tracks("tcp")end
function Controller:set_pad_tracks_shown(indices,shown)
  local tracks={}
  -- Resolve first, then mutate: project changes invalidate the track cache.
  for _,index in ipairs(indices or {}) do local track=self:pad_track(index);if track then tracks[#tracks+1]=track end end
  if #tracks==0 then self.status="Load samples before showing selected pad tracks";return false end
  for _,track in ipairs(tracks) do
    self.adapter:set_track_value(track,"B_SHOWINTCP",shown and 1 or 0)
    self.adapter:set_track_value(track,"B_SHOWINMIXER",shown and 1 or 0)
  end
  if self.host.TrackList_AdjustWindows then self.host.TrackList_AdjustWindows(false) end
  if self.host.UpdateArrange then self.host.UpdateArrange() end
  self.status=string.format("%d pad track%s %s",#tracks,#tracks==1 and "" or "s",shown and "shown in TCP and mixer" or "hidden")
  return true
end
function Controller:set_pad_shown_in_mixer(index,shown)return self:set_pads_shown_in_mixer({index},shown)end
function Controller:select_pad_track(index)local track=self:pad_track(index);if track then self.host.SetOnlyTrackSelected(track);self.host.SetMixerScroll(track)end end
function Controller:show_pad_sampler(index)
  local pad=self:pad(index);local track=self:pad_track(index)
  if not pad or not track then self.status="Load a sample to create this pad's RS5K";return false end
  -- Managed samplers are renamed in the FX chain, so displayed-name matching
  -- is unreliable. Resolve the exact instance from ReaDrum's stored GUID.
  local fx=rs5k.find_managed(self.adapter,track,self.rack.id,pad.id)
  if fx==nil then self.status="Selected pad's RS5K is unavailable";return false end
  self.host.TrackFX_Show(track,fx,3)
  self.status="Opened selected pad's RS5K"
  return true
end
function Controller:show_pad_fx_chain(index)
  local track=self:pad_track(index);if not track then self.status="Load a sample to create this pad track";return end
  self.host.SetOnlyTrackSelected(track);self.host.TrackFX_Show(track,0,1);self.status="Opened pad FX chain"
end
function Controller:master_track() return self:find_track("folder",self.rack.id.."/folder") end
function Controller:master_clipper(create)
  local track=self:master_track();if not track then return nil end
  for index=0,self.adapter:fx_count(track)-1 do
    if self.adapter:fx_name(track,index):find("ReaDrum Master Soft Clipper",1,true) then
      local last=self.adapter:fx_count(track)-1
      if index~=last and self.host.TrackFX_CopyToTrack then
        self.host.TrackFX_CopyToTrack(track,index,track,last,true);index=last
      end
      if not clipper_reloaded[track] and self.host.TrackFX_SetOffline then
        clipper_reloaded[track]=true;self.host.TrackFX_SetOffline(track,index,true);self.host.TrackFX_SetOffline(track,index,false)
      end
      return track,index
    end
  end
  if not create then return track,nil end
  local index=self.adapter:add_fx(track,"JS: ReaDrum/ReaDrum_MasterSoftClipper")
  if index and index>=0 then self.adapter:hide_fx(track,index);return track,index end
  return track,nil
end
function Controller:remove_master_clipper()
  local track=self:master_track();if not track or not self.host.TrackFX_Delete then return 0 end
  local removed=0
  for index=self.adapter:fx_count(track)-1,0,-1 do if self.adapter:fx_name(track,index):find("ReaDrum Master Soft Clipper",1,true)then self.host.TrackFX_Delete(track,index);removed=removed+1 end end
  return removed
end
function Controller:clipper_value(parameter)
  local track,fx=self:master_clipper(true);if not fx then return 0 end
  return self.host.TrackFX_GetParam(track,fx,parameter) or 0
end
function Controller:set_clipper_value(parameter,value)
  local track,fx=self:master_clipper(true);if not fx then return false end
  self.host.TrackFX_SetParam(track,fx,parameter,value)
  if self.host.MarkProjectDirty then self.host.MarkProjectDirty(self.project) end
  return true
end
function Controller:send_fx_value(parameter)
  return 0
end
function Controller:set_send_fx_value(parameter,value)
  return false
end
function Controller:pad_meter(index)
  index=math.max(1,math.min(128,math.floor(tonumber(index) or 1)))
  return sampler_bank.meter(self.host,math.floor((index-1)/16),(index-1)%16,self.rack.engine_namespace or 0)
end
function Controller:gain_lfo(create)
  local track=self:master_track();if not track then return nil end
  for index=0,self.adapter:fx_count(track)-1 do
    if self.adapter:fx_name(track,index):find("ReaDrum Gain LFO",1,true) then return track,index end
  end
  if not create then return track,nil end
  local index=self.adapter:add_fx(track,"JS: ReaDrum/ReaDrum_GainLFO")
  if not index or index<0 then self.status="ReaDrum Gain LFO is not installed";return track,nil end
  self.adapter:hide_fx(track,index);return track,index
end
function Controller:remove_legacy_gain_lfo()
  local track=self:master_track();if not track or not self.host.TrackFX_Delete then return 0 end
  local removed=0
  for index=self.adapter:fx_count(track)-1,0,-1 do
    if self.adapter:fx_name(track,index):find("ReaDrum Gain LFO",1,true) then self.host.TrackFX_Delete(track,index);removed=removed+1 end
  end
  if removed>0 then self.status="Removed legacy bus Accentuator" end
  return removed
end
function Controller:gain_lfo_value(parameter,create)
  local track,fx=self:gain_lfo(create~=false);if not fx then return 0 end
  local value=self.host.TrackFX_GetParam(track,fx,parameter);return value or 0
end
function Controller:set_gain_lfo_value(parameter,value)
  local track,fx=self:gain_lfo(true);if not fx then return false end
  self.host.TrackFX_SetParam(track,fx,parameter,value);if self.host.MarkProjectDirty then self.host.MarkProjectDirty(self.project) end;return true
end
function Controller:master_value(key)
  local track=self:master_track();if not track then return 0 end
  return self.adapter:get_track_value(track,key)
end
function Controller:set_master_value(key,value)
  local track=self:master_track();if not track then return end
  self.adapter:set_track_value(track,key,value)
end
function Controller:toggle_master_mute()local track=self:master_track();if track then self.adapter:set_track_value(track,"B_MUTE",self:master_value("B_MUTE")>0 and 0 or 1)end end
function Controller:toggle_master_solo()local track=self:master_track();if track then self.adapter:set_track_value(track,"I_SOLO",self:master_value("I_SOLO")>0 and 0 or 1)end end
function Controller:show_master_fx_chain()local track=self:master_track();if track then self.host.TrackFX_Show(track,0,1)end end
function Controller:select_master_track()local track=self:master_track();if track then self.host.SetOnlyTrackSelected(track);self.host.SetMixerScroll(track)end end

function Controller:select_pad(index)
  self.selected_pad=index
  self.rack.selected_bank=math.floor((index-1)/16)+1
  self.selected_step=math.min(self.selected_step,self:lane().step_count)
  self:sync_live_bank()
end

function Controller:rename_pad(name)
  name=tostring(name or ""):gsub("[%c]",""):sub(1,64)
  if name=="" then name=string.format("Pad %03d",self.selected_pad) end
  local pad=self:pad(); if pad.name==name then return end
  pad.name=name
  local track=self:pad_track(self.selected_pad)
  if track then self.adapter:set_track_string(track,"P_NAME",sample_name(pad) or name) end
  self:mark_dirty(false)
end

function Controller:load_selected_sample()
  local ok, path = self.host.GetUserFileNameForRead("Load sample into " .. state.sample_label(self:pad()), "", "Audio files (*.wav;*.aif;*.aiff;*.flac;*.ogg)\0*.wav;*.aif;*.aiff;*.flac;*.ogg\0All files\0*.*\0")
  if ok and path ~= "" then
    self:pad().sample = path; self:pad().name = path:match("([^/\\]+)%.[^%.]+$") or path:match("([^/\\]+)$") or self:pad().name
    self:mark_pad_structural(self.selected_pad); self:flush(true)
  end
end

function Controller:load_sample_path(index,path)
  if not path or path==""or not self.adapter:file_exists(path)then self.status="Sample path is missing";return false end
  local pad=self:pad(index);pad.sample=path;pad.name=path:match("([^/\\]+)%.[^%.]+$")or path:match("([^/\\]+)$")or pad.name;self.selected_pad=index;self:mark_pad_structural(index);self:flush(true);return true
end

function Controller:load_sample_paths(start_index, paths)
  start_index=math.max(1,math.min(#self.rack.pads,math.floor(tonumber(start_index) or 1)))
  local capacity=#self.rack.pads-start_index+1
  local loaded,invalid,overflow,changed_indices = 0,0,0,{}
  local before=model.deep_copy(self.rack)
  for _,path in ipairs(paths or {}) do
    if loaded>=capacity then
      overflow=overflow+1
    elseif path and path ~= "" and self.adapter:file_exists(path) then
      local index=start_index+loaded
      local pad=self:pad(index)
      pad.sample=path
      pad.name=path:match("([^/\\]+)%.[^%.]+$") or path:match("([^/\\]+)$") or pad.name
      loaded=loaded+1
      changed_indices[#changed_indices+1]=index
    else
      invalid=invalid+1
    end
  end
  if loaded > 0 then
    self.selected_pad=start_index
    self.rack.selected_bank=math.floor((start_index-1)/16)+1
    for _,index in ipairs(changed_indices) do self.structural_pad_ids[self:pad(index).id]=true end
    self:mark_dirty(true)
    self.status=string.format("Loading %d samples as one batch",loaded)
    local ok,failure=self:flush(true,{undo_label=string.format("ReaDrum: load %d samples",loaded)})
    if not ok then
      self.rack=before;self.structural_pad_ids={};self.dirty=false;self.structural_dirty=false;self.publish_dirty=false
      self:invalidate_track_cache()
      local detail=tostring(failure or "unknown error")
      local reason=detail:match("runtime/map admission rejected:%s*([^\r\n]+)") or detail:match("^([^\r\n]+)") or "unknown error"
      self.status="Sample batch failed; nothing was loaded: "..reason:sub(1,180)
      return false
    end
    if overflow>0 or invalid>0 then
      local details={}
      if overflow>0 then details[#details+1]=string.format("ERROR: %d could not be loaded because no pad slots remained",overflow) end
      if invalid>0 then details[#details+1]=string.format("%d unsupported or missing",invalid) end
      self.status=string.format("%d sample%s loaded — %s",loaded,loaded==1 and "" or "s",table.concat(details,"; "))
    else
      self.status = string.format("%d sample%s ready", loaded, loaded == 1 and "" or "s")
    end
    return true,loaded,overflow
  end
  self.status = "No supported sample files were dropped"
  return false
end

function Controller:cycle_sample(direction)
  local sample=self:pad().sample;local path=type(sample)=="table" and sample.path or sample
  if not path or path=="" or not self.host.EnumerateFiles then self.status="Load a sample before browsing its folder";return false end
  local directory,filename=path:match("^(.*)[/\\]([^/\\]+)$");if not directory then self.status="Sample folder is unavailable";return false end
  local files,index={},0;local audio={wav=true,wave=true,aif=true,aiff=true,flac=true,ogg=true,mp3=true,wv=true}
  while true do local name=self.host.EnumerateFiles(directory,index);if not name then break end;index=index+1;local extension=name:lower():match("%.([^%.]+)$");if audio[extension] then files[#files+1]=name end end
  if #files==0 then self.status="No audio files found in sample folder";return false end
  table.sort(files,function(a,b)return a:lower()<b:lower() end);local current=1
  for i,name in ipairs(files) do if name:lower()==filename:lower() then current=i;break end end
  local target=((current-1+(direction and direction<0 and -1 or 1))%#files)+1
  local next_path=directory..package.config:sub(1,1)..files[target];local loaded=self:load_sample_path(self.selected_pad,next_path)
  if loaded then self.status=string.format("Sample %d/%d: %s",target,#files,files[target]) end
  return loaded
end
function Controller:normalize_selected_sample()
  local pad=self:pad();local sample=pad.sample;local path=type(sample)=="table" and sample.path or sample
  if not path or path=="" or not self.adapter:file_exists(path) then self.status="Load a sample before normalizing";return false end
  if not (self.host.PCM_Source_CreateFromFile and self.host.PCM_Source_GetPeaks and self.host.new_array) then self.status="This REAPER build cannot analyze sample peaks";return false end
  local source=self.host.PCM_Source_CreateFromFile(path);if not source then self.status="Could not open sample for normalization";return false end
  local count=2048;local length=math.max(.001,self.host.GetMediaSourceLength(source) or .001);local buffer=self.host.new_array(count*2)
  local packed=self.host.PCM_Source_GetPeaks(source,count/length,0,1,count,0,buffer);local got=(packed or 0)&0xFFFFF
  local values=buffer.table and buffer.table(1,count*2) or {};local peak=0
  for i=1,math.min(count,got>0 and got or count) do peak=math.max(peak,math.abs(values[i] or 0),math.abs(values[count+i] or 0)) end
  if self.host.PCM_Source_Destroy then self.host.PCM_Source_Destroy(source) end
  if peak<=0.0000001 then self.status="Sample is silent; normalization was not applied";return false end
  local target=10^(-1/20);local gain=math.min(4,target/peak)
  pad.default_controls.volume=math.max(0,math.min(1,.5*math.sqrt(gain)))
  pad.default_controls.normalized_peak=peak;self:queue_pad_controls(self.selected_pad)
  self.status=string.format("Normalized %s (peak %.1f dBFS, gain %+.1f dB)",pad.name,20*math.log(peak,10),20*math.log(gain,10))
  return true
end

function Controller:detect_selected_pitch(snap_to_c)
  if snap_to_c==nil then snap_to_c=true end
  local pad=self:pad();local sample=pad.sample;local path=type(sample)=="table"and sample.path or sample
  if not path or path==""or not self.adapter:file_exists(path)then self.status="Load a sample before detecting pitch";return false end
  if not(self.host.PCM_Source_CreateFromFile and self.host.PCM_Source_GetPeaks and self.host.new_array)then self.status="This REAPER build cannot analyze pitch";return false end
  local source=self.host.PCM_Source_CreateFromFile(path);if not source then self.status="Could not open sample for pitch detection";return false end
  local rate=(self.host.GetMediaSourceSampleRate and self.host.GetMediaSourceSampleRate(source))or 48000
  local analysis_rate=math.min(12000,math.max(4000,rate));local count=8192;local buffer=self.host.new_array(count*2)
  local packed=self.host.PCM_Source_GetPeaks(source,analysis_rate,.02,1,count,0,buffer);local got=(packed or 0)&0xFFFFF
  local raw=buffer.table and buffer.table(1,count*2)or{};if self.host.PCM_Source_Destroy then self.host.PCM_Source_Destroy(source)end
  local n=math.min(count,got);if n<512 then self.status="Sample is too short for reliable pitch detection";return false end
  local values,mean={},0;for i=1,n do local v=((raw[i]or 0)+(raw[count+i]or 0))*.5;values[i]=v;mean=mean+v end;mean=mean/n
  local energy=0;for i=1,n do values[i]=values[i]-mean;energy=energy+values[i]*values[i]end
  if energy<1e-8 then self.status="Sample is too quiet for pitch detection";return false end
  local lo=math.max(2,math.floor(analysis_rate/1000));local hi=math.min(math.floor(analysis_rate/25),math.floor(n/3));local best_lag,best_score=nil,-1
  for lag=lo,hi do
    local sum,a,b=0,0,0
    for i=1,n-lag do local x,y=values[i],values[i+lag];sum=sum+x*y;a=a+x*x;b=b+y*y end
    local score=sum/math.sqrt(math.max(1e-20,a*b))
    if score>best_score then best_score,best_lag=score,lag end
  end
  if not best_lag or best_score<.25 then self.status="No stable pitch detected";return false end
  local hz=analysis_rate/best_lag;local midi=69+12*math.log(hz/440,2);local target=math.floor(midi/12+.5)*12;local correction=target-midi
  local semitones=math.floor(correction+(correction>=0 and .5 or-.5));local cents=math.floor((correction-semitones)*100+.5)
  pad.default_controls.detected_pitch_hz=hz;pad.default_controls.detected_pitch_midi=midi;pad.default_controls.pitch_confidence=best_score
  if snap_to_c then
    if pad.default_controls.pre_snap_transpose==nil then pad.default_controls.pre_snap_transpose=pad.default_controls.transpose_semitones or 0 end
    if pad.default_controls.pre_snap_tune==nil then pad.default_controls.pre_snap_tune=pad.default_controls.tune_cents or 0 end
    pad.default_controls.transpose_semitones=math.max(-48,math.min(48,semitones));pad.default_controls.tune_cents=math.max(-100,math.min(100,cents))
  end
  self:queue_pad_controls(self.selected_pad)
  local names={"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"};local note=math.floor(midi+.5)
  self.status=snap_to_c and string.format("Detected %s%d (%.1f Hz, %.0f%%); snapped to C with %+d st %+d ct",names[note%12+1],math.floor(note/12)-1,hz,best_score*100,semitones,cents) or string.format("Detected %s%d (%.1f Hz, %.0f%%); tuning unchanged",names[note%12+1],math.floor(note/12)-1,hz,best_score*100)
  return true
end
function Controller:revert_pitch_snap()
  local controls=self:pad().default_controls or {}
  controls.transpose_semitones=controls.pre_snap_transpose or 0;controls.tune_cents=controls.pre_snap_tune or 0
  controls.pre_snap_transpose=nil;controls.pre_snap_tune=nil
  self:queue_pad_controls(self.selected_pad);self.status="Restored tuning from before pitch snap";return true
end
function Controller:snap_detected_pitch_to_c()
  local controls=self:pad().default_controls or {};local midi=tonumber(controls.detected_pitch_midi)
  if not midi then return self:detect_selected_pitch(true) end
  local correction=math.floor(midi/12+.5)*12-midi;local semitones=math.floor(correction+(correction>=0 and .5 or-.5));local cents=math.floor((correction-semitones)*100+.5)
  if controls.pre_snap_transpose==nil then controls.pre_snap_transpose=controls.transpose_semitones or 0 end
  if controls.pre_snap_tune==nil then controls.pre_snap_tune=controls.tune_cents or 0 end
  controls.transpose_semitones=math.max(-48,math.min(48,semitones));controls.tune_cents=math.max(-100,math.min(100,cents))
  self:queue_pad_controls(self.selected_pad);self.status="Detected pitch snapped to C";return true
end
function Controller:adjust_sample_octave(delta)
  local controls=self:pad().default_controls or {};self:pad().default_controls=controls
  controls.transpose_semitones=math.max(-48,math.min(48,(tonumber(controls.transpose_semitones) or 0)+(delta or 0)*12))
  self:queue_pad_controls(self.selected_pad);self.status=string.format("Sample octave %+d",math.floor(controls.transpose_semitones/12));return true
end
function Controller:reset_pad_controls()
  self:pad().default_controls={};self:queue_pad_controls(self.selected_pad);self.status="Pad controls reset"
end
function Controller:poll_bridge()
  if self.host.time_precise()<(self.bridge_due or 0)then return end;self.bridge_due=self.host.time_precise()+0.25
  local command;command,self.bridge_id=bridge.poll(self.host,self.project,self.bridge_id);if not command then return end
  local index=command.pad or self.selected_pad
  if command.command=="load_next_empty"then for i=1,#self.rack.pads do if self:pad(i).sample==false then index=i;break end end end
  local accepted=(command.command=="load_selected"or command.command=="load_pad"or command.command=="load_next_empty")and self:load_sample_path(index,command.path)
  bridge.ack(self.host,self.project,command.id,accepted and"ok"or"rejected")
end

function Controller:clear_selected_sample()
  local pad=self:pad()
  pad.sample=false
  pad.name=string.format("Pad %03d",pad.logical_index or self.selected_pad)
  self:mark_pad_structural(self.selected_pad)
  self.status=pad.name.." cleared"
  self:flush(true)
end

function Controller:clear_pads(indices)
  if self.dirty then local ok=self:flush(true);if not ok then return false end end
  local seen,targets,ids={}, {}, {}
  for _,index in ipairs(indices or {}) do
    index=math.floor(tonumber(index) or 0)
    if index>=1 and index<=#self.rack.pads and not seen[index] then
      seen[index]=true;targets[#targets+1]=index;ids[self:pad(index).id]=true
    end
  end
  table.sort(targets)
  if #targets==0 then self.status="No pads selected to clear";return false end

  -- Cancel deferred creation for pads that are being removed before it runs.
  local queued={}
  for _,index in ipairs(self.structural_queue) do
    local pad=self:pad(index)
    if pad and ids[pad.id] then self.structural_queue_set[pad.id]=nil else queued[#queued+1]=index end
  end
  self.structural_queue=queued

  local working=model.deep_copy(self.rack)
  for _,index in ipairs(targets) do
    local pad=working.pads[index]
    pad.name=string.format("Pad %03d",index);pad.sample=false;pad.color="#808080";pad.choke_group=false
    pad.simultaneous_play_targets={};pad.mute_targets={};pad.polyphony=16;pad.self_choke=true
    pad.default_controls={};pad.reaper_object_refs={}
  end
  for _,pad in ipairs(working.pads) do
    local function without_cleared(source)
      local result={};for _,id in ipairs(source or {}) do if not ids[id] then result[#result+1]=id end end;return result
    end
    pad.simultaneous_play_targets=without_cleared(pad.simultaneous_play_targets)
    pad.mute_targets=without_cleared(pad.mute_targets)
  end
  local groups={}
  for _,group in ipairs(working.round_robin_groups) do
    local members={};for _,id in ipairs(group.member_pad_ids) do if not ids[id] then members[#members+1]=id end end
    if #members>=2 then
      group.member_pad_ids=members
      if ids[group.master_pad_id] then group.master_pad_id=members[1] end
      groups[#groups+1]=group
    end
  end
  working.round_robin_groups=groups
  for _,pattern in ipairs(working.patterns) do
    for _,variation in ipairs(pattern.variations) do
      for lane_index,lane in ipairs(variation.lanes) do
        if ids[lane.pad_id] then
          variation.lanes[lane_index]=model.new_lane({id=lane.id,pad_id=lane.pad_id,step_count=16,division_num=1,division_den=16})
        end
      end
    end
  end
  local valid,error_message=model.validate_rack(working)
  if not valid then self.status="Clear pads rejected: "..tostring(error_message);return false end
  self.rack=working;self.structural_pad_ids=ids;self:mark_dirty(true)
  local ok,failure=self:flush(true,{delete_empty_tracks=true,undo_label="ReaDrum: clear pads"})
  if not ok then self.status="Clear pads failed: "..tostring(failure);return false end
  self.status=#targets==#self.rack.pads and "All pads cleared" or string.format("%d pad%s cleared",#targets,#targets==1 and "" or "s")
  return true
end

function Controller:close()
  if self.groove_preview then self:cancel_groove_preview(true) end
  self:process_structural_queue(math.huge)
  if self.dirty then self:flush(true) else self:save_if_due(true) end
end

function Controller:save_state_only()
  state.save(self.host,self.project,self.rack)
  self.state_pending=false;self.state_due=0
end

function Controller:restore_history(snapshot,target)
  local current=self.rack;local rack=state.expand(model.deep_copy(snapshot));local structural_ids={}
  local audibility={}
  for _,pad in ipairs(current.pads or {}) do
    audibility[pad.id]={muted=pad.muted==true,soloed=pad.soloed==true}
  end
  -- Undo/Redo restores musical rack edits but never rewinds live mute/solo.
  for _,pad in ipairs(rack.pads or {}) do
    local live=audibility[pad.id]
    if live then pad.muted,pad.soloed=live.muted,live.soloed end
  end
  local function sample_path(sample)return type(sample)=="table" and sample.path or sample end
  for index=1,math.max(#(current.pads or {}),#(rack.pads or {})) do
    local before,after=current.pads[index],rack.pads[index]
    if not before or not after or before.id~=after.id or before.logical_index~=after.logical_index or
        before.output_id~=after.output_id or sample_path(before.sample)~=sample_path(after.sample) then
      if before then structural_ids[before.id]=true end;if after then structural_ids[after.id]=true end
    end
  end
  -- Logical outputs are physical routing topology. Restoring their list must
  -- create/remove the corresponding output tracks and worker sends, not just
  -- change the number shown on the pad.
  local function output_signature(outputs)
    local parts={}
    for index,output in ipairs(outputs or {}) do parts[index]=table.concat({output.id or "",output.name or ""},"\0") end
    return table.concat(parts,"\1")
  end
  if output_signature(current.outputs)~=output_signature(rack.outputs) then
    for _,pad in ipairs(current.pads or {}) do structural_ids[pad.id]=true end
    for _,pad in ipairs(rack.pads or {}) do structural_ids[pad.id]=true end
  end
  -- Stack entries stop being mutable as soon as they leave self.rack, so move
  -- the snapshots between stacks instead of cloning the complete rack twice.
  target[#target+1]=state.compact(current);self.history_lock=true;self.rack=rack
  -- Sampler-bank controls live outside the serialized rack snapshot. Queue a
  -- fresh packet for every loaded pad so Undo/Redo cannot leave gain, ADSR,
  -- pitch, or especially output-pair routing at the value being undone.
  self.pending_pad_controls={}
  for index,pad in ipairs(self.rack.pads or {}) do
    if pad.sample~=false and pad.sample~=nil then self.pending_pad_controls[index]=true end
  end
  self.pattern_index=math.min(self.rack.selected_pattern or 1,#self.rack.patterns);self.variation_index=math.min(self.rack.selected_variation or 1,#self:pattern().variations)
  self.selected_pad=math.min(self.selected_pad,#self.rack.pads);self.selected_step=math.min(self.selected_step,self:lane().step_count)
  self.dirty=true;self.structural_dirty=next(structural_ids)~=nil;self.publish_dirty=true;self.variation_events_dirty=true;self.structural_pad_ids=structural_ids
  self.history_delete_empty_tracks=true;self.due=self.host.time_precise()+.01;self.history_lock=false
end
function Controller:undo()local rack=table.remove(self.undo_stack);if rack then self:restore_history(rack,self.redo_stack);self.status="Undo"end end
function Controller:redo()local rack=table.remove(self.redo_stack);if rack then self:restore_history(rack,self.undo_stack);self.status="Redo"end end

return Controller
