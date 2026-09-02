local state = require("ReaDrum.app.state")
local model = require("ReaDrum.core.model")
local theme = require("ReaDrum.app.theme")
local eula = require("ReaDrum.app.eula")
local groove = require("ReaDrum.core.groove")
local envelope = require("ReaDrum.core.envelope")
local envelope_math = envelope

local module_source=debug.getinfo(1,"S").source:sub(2)
local product_directory=assert(module_source:match("^(.*)[/\\]app[/\\]ui%.lua$"),"ReaDrum UI must remain inside Scripts/ReaDrum/app")

local UI = {}
UI.__index = UI

local function log_ui_error(area,failure)
  pcall(function()
    local file=assert(io.open(product_directory..package.config:sub(1,1).."ReaDrum-error.log","ab"))
    file:write(os.date("!%Y-%m-%dT%H:%M:%SZ"),"  ",area,"\n",tostring(failure),"\n\n")
    file:close()
  end)
end

local C = {
  window = 0x101215FF, panel = 0x171A1EFF, panel2 = 0x20242AFF,
  button = 0x292E35FF, hover = 0x343B44FF, selected = 0x1687D5FF,
  step = 0x24292FFF, beat = 0x2C3239FF, active = 0x16935AFF,
  accent = 0xF0A02BFF, playhead = 0x42A5F5FF, red = 0xC64A54FF, text = 0xDCE1E7FF,
  muted = 0x757D87FF, border = 0x30363EFF, waveform = 0x38BDF8FF,
}

local PAD_COLORS = {
  0xC82C55FF, 0x3A86D4FF, 0xE0522DFF, 0x49A25BFF,
  0x8457C5FF, 0xD18422FF, 0x2B9BA3FF, 0x799E32FF,
}
local PAD_HEX={"#C82C55","#3A86D4","#E0522D","#49A25B","#8457C5","#D18422","#2B9BA3","#799E32","#F0A02B"}

local DEFAULTS = {
  volume=0.354, pan=0.5, pitch=0.5, sample_start=0, sample_end=1,
  -- Neutral musical envelope defaults; the decay control resolves to 250 ms.
  attack=0, decay=envelope.DEFAULT_DECAY_CONTROL, sustain=1.0, release=0,
  fade_in=0, fade_out=0, fade_in_curve=.5, fade_out_curve=.5,
  obey_note_offs=1, loop=0,
}

local ENVELOPE_TIME_MAX = {
  attack=envelope.ATTACK_MAX_SECONDS,
  decay=envelope.DECAY_MAX_SECONDS,
  release=envelope.RELEASE_MAX_SECONDS,
}

local function envelope_value_text(key,value)
  if key=="sustain" then return envelope.format_sustain(value) end
  return envelope.format_time(envelope.time_seconds(value,assert(ENVELOPE_TIME_MAX[key],"unknown envelope time")))
end

local function pad_pitch_values(controls)
  if controls.transpose_semitones~=nil or controls.tune_cents~=nil then
    return math.max(-48,math.min(48,controls.transpose_semitones or 0)),math.max(-100,math.min(100,controls.tune_cents or 0))
  end
  local total=((controls.pitch or DEFAULTS.pitch)-.5)*160
  local transpose=math.max(-48,math.min(48,math.floor(total+(total>=0 and .5 or -.5))))
  return transpose,math.max(-100,math.min(100,math.floor((total-transpose)*100+.5)))
end

local function set_pad_pitch(controls,transpose,cents)
  controls.transpose_semitones=math.max(-48,math.min(48,math.floor(transpose+(transpose>=0 and .5 or -.5))))
  controls.tune_cents=math.max(-100,math.min(100,math.floor(cents+(cents>=0 and .5 or -.5))))
  controls.pitch=math.max(0,math.min(1,.5+(controls.transpose_semitones+controls.tune_cents/100)/160))
end

local GRID_STEP_X,GRID_CELL_WIDTH,GRID_CELL_STRIDE=359,27,32
local LANE_TOOLBAR_HEIGHT=24
local PAD_MIDI_BASE=36 -- C2 in REAPER's default octave naming
local WAVEFORM_PEAK_COUNT=4096

local PROPERTIES = {
  { label="Velocity", short="VEL", key="velocity", kind="int", min=1, max=127, default=100, format="%d" },
  { label="Transpose", short="TRANSPOSE", key="pitch_semitones", kind="int", min=-12, max=24, default=0, format="%+d" },
  { label="Tune", short="TUNE", key="pitch_cents", kind="int", min=-100, max=100, default=0, format="%d" },
  { label="Pan", short="PAN", key="pan_lock", kind="pan", min=-100, max=100, default=false, format="%d" },
  { label="Repeat", short="REPEAT", key="repeat_count", kind="int", min=1, max=64, default=1, format="%d" },
  { label="Ratchet", short="RATCHET", key="repeat_divide", kind="divide", min=1, max=16, default=1, format="x%d" },
  { label="Probability", short="CHANCE", key="probability", kind="double", min=0, max=100, default=100, format="%.0f" },
  -- Keep the editor focused on microtiming: +/-120 ticks is half a 1/16 note.
  -- The model still accepts +/-960 so older/extreme programmed values survive.
  { label="Timing", short="SHIFT", key="timing_offset", kind="int", min=-48, max=48, default=0, format="%+d" },
  -- Gate is a note-length control: 100% is one step, 200% is one full
  -- overlap. Keep the editor in the useful drum-sequencer range.
  { label="Gate", short="GATE", key="gate", kind="double", min=0, max=200, default=100, format="%.0f%%" },
}

local DIVISIONS = {
  {"1/4",1,4},{"1/8",1,8},{"1/16",1,16},{"1/32",1,32},
  {"1/8D",3,16},{"1/16D",3,32},{"1/8T",1,12},{"1/16T",1,24},{"1/32T",1,48},
}

local function division_index(lane)
  for index,item in ipairs(DIVISIONS) do if lane.division_num==item[2] and lane.division_den==item[3] then return index end end
  return 3
end

local function child_flags(r)
  return r.ImGui_ChildFlags_Borders and r.ImGui_ChildFlags_Borders() or 0
end

local function no_scroll_flags(r)
  local flags=0
  if r.ImGui_WindowFlags_NoScrollbar then flags=flags|r.ImGui_WindowFlags_NoScrollbar() end
  if r.ImGui_WindowFlags_NoScrollWithMouse then flags=flags|r.ImGui_WindowFlags_NoScrollWithMouse() end
  return flags
end

local function controlled_scroll_flags(r)
  return r.ImGui_WindowFlags_NoScrollWithMouse and r.ImGui_WindowFlags_NoScrollWithMouse() or 0
end

local function note_name(note)
  local names={"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"}
  return names[(note % 12)+1] .. tostring(math.floor(note/12)-1)
end

-- One-channel 128-pad map, rotated so Pad 1 begins at REAPER C2 (note 36).
-- After note 127 the remaining pads wrap through notes 0..35 exactly once.
local function pad_midi_note(index) return (PAD_MIDI_BASE+(index-1))%128 end
local function pad_bank_letter(index) return string.char(65+math.floor((index-1)/16)) end

local function pad_color(index,pad)
  local value=pad and pad.color
  if value and value~="#808080" then local rgb=tonumber(value:match("^#(%x%x%x%x%x%x)$"),16);if rgb then return (rgb<<8)|0xFF end end
  -- Stable shuffled palette: varied like a drum rack, but never changes when
  -- the project is reopened. Explicit user colors still override this.
  return PAD_COLORS[(((index-1)*5)%#PAD_COLORS)+1]
end

local function active_step_color(color,velocity)
  local amount=.62+.38*math.max(0,math.min(1,(velocity or 100)/127))
  local red=(color>>24)&0xFF;local green=(color>>16)&0xFF;local blue=(color>>8)&0xFF
  return (math.floor(red*amount)<<24)|(math.floor(green*amount)<<16)|(math.floor(blue*amount)<<8)|0xFF
end

local function blend_color(a,b,amount)
  local inverse=1-amount
  local function channel(shift)return math.floor((((a>>shift)&0xFF)*inverse)+(((b>>shift)&0xFF)*amount)+.5)end
  return (channel(24)<<24)|(channel(16)<<16)|(channel(8)<<8)|0xFF
end

local function playback_accent_color()
  local color=C.playhead
  if theme.luminance(C.panel)>=145 and theme.luminance(color)>=110 then
    color=blend_color(color,0x000000FF,.38)
  end
  return color
end

local function add_rounded_rect(r,draw,x1,y1,x2,y2,color,rounding)
  if r.ImGui_DrawFlags_RoundCornersAll then
    r.ImGui_DrawList_AddRectFilled(draw,x1,y1,x2,y2,color,rounding,r.ImGui_DrawFlags_RoundCornersAll())
  else
    r.ImGui_DrawList_AddRectFilled(draw,x1,y1,x2,y2,color,rounding)
  end
end

local function resize_lane(lane, value)
  if value>lane.step_count then
    for i=lane.step_count+1,value do lane.steps[i]=model.new_step() end
  else
    for i=lane.step_count,value+1,-1 do lane.steps[i]=nil end
  end
  lane.step_count=value
end

local function gcd(a,b)
  a,b=math.abs(math.floor(a)),math.abs(math.floor(b))
  while b~=0 do a,b=b,a%b end
  return math.max(1,a)
end

local function repeat_divide(lane,step)
  local spacing=step.repeat_spacing or {numerator=1,denominator=16}
  local numerator=math.max(1,spacing.numerator or 1);local denominator=math.max(1,spacing.denominator or 16)
  return math.max(1,math.min(16,math.floor((lane.division_num*denominator)/(lane.division_den*numerator)+.5)))
end

function UI.new(host, app)
  assert(host.ImGui_CreateContext, "ReaImGui is required. Install ReaImGui through ReaPack.")
  local flags = host.ImGui_ConfigFlags_DockingEnable and host.ImGui_ConfigFlags_DockingEnable() or 0
  local saved_tooltips=host.GetExtState and host.GetExtState("ReaDrum5k","show_tooltips") or ""
  local saved_track_colors=host.GetExtState and host.GetExtState("ReaDrum5k","apply_pad_track_colors") or ""
  local saved_audition=host.GetExtState and host.GetExtState("ReaDrum5k","audition_while_editing") or ""
  local saved_waveform_adsr=host.GetExtState and host.GetExtState("ReaDrum5k","show_adsr_on_waveform") or ""
  local saved_pad_step_colors=host.GetExtState and host.GetExtState("ReaDrum5k","color_steps_by_pad") or ""
  if host.DeleteExtState then host.DeleteExtState("ReaDrum5k","performance_probe",true) end
  local saved_max_outputs=tonumber(host.GetExtState and host.GetExtState("ReaDrum5k","max_stereo_outputs") or "")
  local max_outputs=saved_max_outputs==16 and 16 or 8
  local separator=package.config:sub(1,1)
  local groove_root=host.GetResourcePath()..separator.."Data"..separator.."ReaDrum"..separator.."Grooves"
  app.audition_notes=saved_audition~="0"
  app.max_outputs=max_outputs
  local theme_state=theme.new(host);theme.apply(theme_state,C)
  local self=setmetatable({
    host=host, app=app, ctx=host.ImGui_CreateContext("ReaDrumXT", flags), open=true,
    property=1, info_open=false, info_tab="variations", parameter_open=false, editor_mode="properties", lane_toolbar_open=true, inspector_open=true, parameter_height=190, main_view="sequencer",
    inspector_mode="pads", edit_focus="steps", multi_select=false, pad_pitch_mode="transpose",
    selected_pads={}, pad_flash_until={}, pad_trigger_tokens=false, mixer_clip_until={}, mixer_meter_hold={}, mixer_meter_time={}, engine_trigger_token=false, waveform_cache={}, waveform_duration={}, waveform_queue={}, waveform_queue_set={}, waveform_jobs={}, waveform_failures={}, live_pad_controls_pending=false, next_live_control_sync=0, audition_due=false, audition_token=0, audition_release_token=0, paint_active=false, paint_value=false, paint_button=0, paint_lane=false, paint_last_step=false, paint_accent=false,
    property_paint_active=false, property_paint_lane=false, property_paint_key=false, property_paint_position=false, property_paint_value=false,
    property_line_active=false, property_line_lane=false, property_line_key=false, property_line_position=false, property_line_value=false,
    property_reset_active=false, property_reset_lane=false, property_reset_key=false, property_reset_position=false,
    follow_played_pad=true, recent_midi_signature=false,
    pad_drag_select=false, pad_drag_origin=false, pad_drag_moved=false, pad_rearrange_drag=false, pad_selection_anchor=false, lane_press_latch={},
    pad_right_drag=false, pad_right_drag_origin=false, pad_right_drag_moved=false, pad_right_drag_base={}, pad_rects={},
    piano_selected_steps={}, piano_selection_pad=false, piano_pointer=false, piano_marquee=false,
    knob_start={}, knob_scroll={}, knob_value_until={}, wheel_commit=false, focus_frames=2,
    mixer_meter_state={},mixer_show_outputs=true,mixer_show_aux=true,
    grid_scroll_x=0, tooltips_enabled=saved_tooltips~="0", track_colors_enabled=saved_track_colors=="1", audition_enabled=saved_audition~="0",
    show_adsr_on_waveform=saved_waveform_adsr=="1",
    color_steps_by_pad=saved_pad_step_colors=="1",
    perf_probe=false,perf_stats={},perf_last_frame=false,perf_report_path=false,max_outputs=max_outputs,
    lane_sustain_cache=setmetatable({}, {__mode="k"}),
    track_color_pref_initialized=saved_track_colors~="", theme=theme_state, preferences_tab="general",
    eula_view_open=false,eula_text=false,eula_error=false,
    groove_root=groove_root,groove_entries=false,groove_cache={},groove_filter="",groove_popup_seen=false,groove_popup_active=false,groove_preview_entry=false,
    groove_categories={},groove_category="",groove_nav_index=1,groove_nav_entry=false,
  }, UI)
  app.perf_callback=function(name,seconds) self:perf_record(name,seconds) end
  app.ui_invalidate=function() self.lane_sustain_cache=setmetatable({}, {__mode="k"}) end
  return self
end

function UI:perf_record(name,seconds)
  if not self.perf_probe then return end
  local stat=self.perf_stats[name]or{count=0,total=0,max=0,last=0,over_2ms=0};self.perf_stats[name]=stat
  stat.count=stat.count+1;stat.total=stat.total+seconds;stat.last=seconds;stat.max=math.max(stat.max,seconds)
  local threshold=name=="defer gap" and .020 or .002
  if seconds>=threshold then stat.over_2ms=stat.over_2ms+1 end
end

function UI:perf_begin()
  return self.perf_probe and self.host.time_precise() or false
end

function UI:perf_end(name,started)
  if started then self:perf_record(name,self.host.time_precise()-started) end
end

function UI:perf_reset()
  self.perf_stats={};self.perf_last_frame=self.host.time_precise();self.perf_report_path=false;self.perf_frame=0;self.perf_detail_frame=false
end

function UI:perf_write_report()
  local r=self.host;local directory=r.GetResourcePath()..package.config:sub(1,1).."Data"..package.config:sub(1,1).."ReaDrum"
  if r.RecursiveCreateDirectory then r.RecursiveCreateDirectory(directory,0) end
  local path=directory..package.config:sub(1,1).."performance_probe_"..os.date("%Y%m%d_%H%M%S")..".txt"
  local file=io.open(path,"wb");if not file then return false end
  file:write("ReaDrum performance probe\n")
  file:write("Generated: ",os.date("%Y-%m-%d %H:%M:%S"),"\n")
  local frame=self.perf_stats["loop total"] or self.perf_stats["frame total"] or self.perf_stats["ReaDrum frame"]
  local frame_total=frame and frame.total or 0
  file:write("Percentages are accumulated section wall-time / accumulated deferred-loop wall-time.\n")
  file:write("Nested sections intentionally overlap and should not be summed.\n\n")
  file:write("Detailed lane/cell sections are sampled once every 30 frames to avoid profiler-induced GUI load.\n")
  file:write("Their averages are representative sampled durations; their totals/frame percentages are intentionally omitted.\n\n")
  local names={};for name in pairs(self.perf_stats)do names[#names+1]=name end;table.sort(names)
  for _,name in ipairs(names)do
    local stat=self.perf_stats[name]
    local sampled=name:find("sampled ",1,true)==1
    local percent=not sampled and frame_total>0 and stat.total/frame_total*100 or 0
    file:write(string.format("%-28s count=%-7d avg=%8.3f ms max=%8.3f ms total=%10.1f ms frame%%=%7s over2ms=%d\n",name,stat.count,stat.total/stat.count*1000,stat.max*1000,stat.total*1000,sampled and "sample" or string.format("%.2f",percent),stat.over_2ms))
  end
  file:write("\nDispatcher diagnostics\n")
  file:write("controller_revision=",tostring(self.app and self.app.revision),"\n")
  file:write("controller_status=",tostring(self.app and self.app.status),"\n")
  if self.app then
    local track=self.app:find_track("sequencer")
    if track and r.TrackFX_GetParam then
      local fx=self.app:dispatcher(track)
      local diagnostics={
        {"active_revision",34},{"pending_revision",35},{"budget_status",44},
        {"required_future_ons",45},{"required_block_clocks",46},{"required_block_ons",47},
        {"required_retained_offs",48},{"required_off_slots",49},{"required_reconstruction_clocks",50},
        {"budget_rejection",52},{"runtime_guard",53},{"future_queue_current",54},
        {"future_queue_peak",55},{"off_queue_current",56},{"off_queue_peak",57},
        {"runtime_fault_latch",58},{"stage_blocks",59},{"stage_current_ons",60},
        {"stage_future_ons",61},{"stage_owned_ons",62},{"stage_result",63},
        {"sample_rate",67},{"active_variation",71},{"transport_playing",79},
      }
      for _,item in ipairs(diagnostics)do file:write(item[1],"=",tostring(r.TrackFX_GetParam(track,fx,item[2])),"\n") end
      file:write("\nSampler bank diagnostics\n")
      for bank_fx=0,r.TrackFX_GetCount(track)-1 do
        local ok,name=r.TrackFX_GetFXName(track,bank_fx,"")
        if ok and name:find("ReaDrum Sampler Bank",1,true) then
          file:write(string.format("bank_fx_%d name=%s bank=%s audio_heartbeat=%s note_ons=%s voices_started=%s active=%s peak=%s\n",
            bank_fx,name,tostring(r.TrackFX_GetParam(track,bank_fx,0)),tostring(r.TrackFX_GetParam(track,bank_fx,1)),
            tostring(r.TrackFX_GetParam(track,bank_fx,5)),tostring(r.TrackFX_GetParam(track,bank_fx,6)),
            tostring(r.TrackFX_GetParam(track,bank_fx,7)),tostring(r.TrackFX_GetParam(track,bank_fx,8))))
        end
      end
    else file:write("dispatcher=unavailable\n") end
  end
  file:close();self.perf_report_path=path;return path
end

function UI:tooltip(text)
  local r,c=self.host,self.ctx
  if self.tooltips_enabled~=false and text and r.ImGui_IsItemHovered(c) and r.ImGui_SetItemTooltip then
    r.ImGui_SetItemTooltip(c,text)
  end
end

function UI:bind_app(app)
  if self.app and self.app.groove_preview then self.app:cancel_groove_preview(true) end
  self.app=app
  app.audition_notes=self.audition_enabled~=false
  self.selected_pads={}
  self.pad_flash_until={};self.pad_trigger_tokens=false;self.engine_trigger_token=false;self.recent_midi_signature=false
  self.audition_due=false;self.paint_active=false;self.paint_lane=false;self.paint_last_step=false
  self.groove_popup_seen=false;self.groove_popup_active=false;self.groove_preview_entry=false;self.groove_nav_index=1;self.groove_nav_entry=false
  self.property_line_active=false;self.property_line_lane=false;self.property_line_key=false
  self.pad_drag_select=false;self.pad_drag_origin=false;self.pad_rearrange_drag=false
  self.lane_press_latch={}
  for _,job in pairs(self.waveform_jobs or {}) do if job.source and self.host.PCM_Source_Destroy then self.host.PCM_Source_Destroy(job.source) end end
  self.waveform_queue={};self.waveform_queue_set={};self.waveform_jobs={};self.waveform_failures={}
  self.grid_scroll_x=0
end

function UI:lane_play_step(lane)
  local r=self.host
  local play_state=r.GetPlayStateEx and r.GetPlayStateEx(self.app.project) or r.GetPlayState()
  if (play_state&5)==0 then return nil end
  local play_position=r.GetPlayPositionEx and r.GetPlayPositionEx(self.app.project) or r.GetPlayPosition2()
  local qn=r.TimeMap2_timeToQN(self.app.project,play_position)
  local unit=4*lane.division_num/lane.division_den
  if unit<=0 then return nil end
  local clock=math.floor(math.max(0,qn)/unit)
  return ((clock+(lane.phase or 0))%lane.step_count)+1
end

function UI:audition_pad(index, velocity, replace_voice, pitch_semitones)
  local r,app=self.host,self.app
  if not app:pad(index) or app:pad(index).sample==false then return false end
  -- Piano editing is monophonic even when the pad itself is polyphonic.
  -- Release the prior preview request before queueing its replacement so
  -- rapid key presses cannot stack audition voices between UI frames.
  if replace_voice then self:flush_audition(true) end
  if not app:audition_pad(index,velocity,pitch_semitones) then return false end
  self.audition_active_pad=replace_voice and index or self.audition_active_pad
  self.pad_flash_until[index]=r.time_precise()+.12
  -- One shared audition voice must have one note-off deadline. Keeping old
  -- deadlines lets a previous click release a newer trigger prematurely.
  -- Pad/lane previews are one-shots. Piano replacement previews remain
  -- short and monophonic so rapidly clicked keys cannot stack indefinitely.
  self.audition_due=replace_voice and (r.time_precise()+.14) or false
  return true
end

function UI:poll_triggered_pad()
  local r,app=self.host,self.app
  if r.gmem_attach and r.gmem_read then
    r.gmem_attach("ReaDrumSnapshot")
    local tokens=self.pad_trigger_tokens
    if tokens==false then
      tokens={};for index=1,128 do tokens[index]=math.floor((r.gmem_read(1399999+index) or 0)+.5) end
      self.pad_trigger_tokens=tokens
      return
    end
    local now=r.time_precise()
    for index=1,128 do
      local token=math.floor((r.gmem_read(1399999+index) or 0)+.5)
      if token~=tokens[index] then tokens[index]=token;self.pad_flash_until[index]=now+.12 end
    end
    return
  end
  -- Compatibility fallback for hosts without the per-pad gmem mailbox.
  local track=app:find_track("sequencer");if not track then return end
  local fx=app:dispatcher(track);local token=math.floor((r.TrackFX_GetParam(track,fx,87) or 0)+.5)
  if self.engine_trigger_token==false then self.engine_trigger_token=token;return end
  if token~=self.engine_trigger_token then
    self.engine_trigger_token=token;local index=math.floor((r.TrackFX_GetParam(track,fx,86) or 0)+.5)
    if index>=1 and index<=128 then self.pad_flash_until[index]=r.time_precise()+.12 end
  end
end

function UI:pad_triggered(index)
  local until_time=self.pad_flash_until[index]
  if not until_time then return false end
  if self.host.time_precise()<until_time then return true end
  self.pad_flash_until[index]=nil;return false
end

function UI:pad_velocity_from_item(fallback)
  local r,c=self.host,self.ctx
  if not (r.ImGui_GetItemRectMin and r.ImGui_GetItemRectMax and r.ImGui_GetMousePos) then return fallback or 100 end
  local _,top=r.ImGui_GetItemRectMin(c);local _,bottom=r.ImGui_GetItemRectMax(c);local _,mouse_y=r.ImGui_GetMousePos(c)
  if bottom<=top then return fallback or 100 end
  return math.max(1,math.min(127,math.floor((1-(mouse_y-top)/(bottom-top))*126+1.5)))
end

function UI:key_modifiers()
  local r,c=self.host,self.ctx;local mods=r.ImGui_GetKeyMods and r.ImGui_GetKeyMods(c) or 0
  local ctrl=r.ImGui_Mod_Ctrl and (mods&r.ImGui_Mod_Ctrl())~=0 or false
  local shift=r.ImGui_Mod_Shift and (mods&r.ImGui_Mod_Shift())~=0 or false
  local alt=r.ImGui_Mod_Alt and (mods&r.ImGui_Mod_Alt())~=0 or false
  return ctrl,shift,alt
end

function UI:item_hovered_for_drag()
  local r,c=self.host,self.ctx
  local flags=r.ImGui_HoveredFlags_AllowWhenBlockedByActiveItem and r.ImGui_HoveredFlags_AllowWhenBlockedByActiveItem() or 0
  return r.ImGui_IsItemHovered(c,flags)
end

function UI:wheel_adjust(value,minimum,maximum,step,integer,reverse)
  local r,c=self.host,self.ctx
  if not (r.ImGui_GetMouseWheel and r.ImGui_IsItemHovered(c)) then return false,value end
  local wheel=r.ImGui_GetMouseWheel(c)
  if wheel==0 then return false,value end
  self.control_wheel_consumed=true
  if r.ImGui_SetItemUsingMouseWheel then r.ImGui_SetItemUsingMouseWheel(c) end
  -- The hovered control owns this wheel gesture. Restore the child scroll
  -- position so adjusting lane controls cannot also move the Lanes panel.
  if r.ImGui_GetScrollY and r.ImGui_SetScrollY then r.ImGui_SetScrollY(c,r.ImGui_GetScrollY(c)) end
  self.sequence_wheel_consumed=true
  local direction=wheel>0 and 1 or -1;if reverse then direction=-direction end
  local next_value=math.max(minimum,math.min(maximum,value+direction*step))
  if integer then next_value=math.floor(next_value+.5) end
  if next_value~=value then self.wheel_commit=true end
  return next_value~=value,next_value
end

function UI:number_field(label,value,minimum,maximum,width)
  local r,c=self.host,self.ctx
  if width then r.ImGui_SetNextItemWidth(c,width) end
  local changed,next_value=r.ImGui_InputInt(c,label,value,0,0)
  if changed then next_value=math.max(minimum,math.min(maximum,next_value)) end
  local wheel_changed,wheel_value=self:wheel_adjust(next_value,minimum,maximum,1,true,false)
  return changed or wheel_changed,wheel_changed and wheel_value or next_value
end

function UI:double_field(label,value,minimum,maximum,step,format,width)
  local r,c=self.host,self.ctx
  if width then r.ImGui_SetNextItemWidth(c,width) end
  local changed,next_value=r.ImGui_InputDouble(c,label,value,0,0,format or "%.2f")
  if changed then next_value=math.max(minimum,math.min(maximum,next_value)) end
  local wheel_changed,wheel_value=self:wheel_adjust(next_value,minimum,maximum,step or .01,false,false)
  return changed or wheel_changed,wheel_changed and wheel_value or next_value
end

function UI:combo_field(label,value,items,count,width)
  local r,c=self.host,self.ctx
  if width then r.ImGui_SetNextItemWidth(c,width) end
  local changed,next_value=r.ImGui_Combo(c,label,value,items,count)
  local wheel_changed,wheel_value=self:wheel_adjust(next_value,0,count-1,1,true,true)
  return changed or wheel_changed,wheel_changed and wheel_value or next_value
end

function UI:slider_int(label,value,minimum,maximum,format,step,width)
  local r,c=self.host,self.ctx
  if width then r.ImGui_SetNextItemWidth(c,width) end
  local changed,next_value=r.ImGui_SliderInt(c,label,value,minimum,maximum,format)
  local wheel_changed,wheel_value=self:wheel_adjust(next_value,minimum,maximum,step or 1,true,false)
  return changed or wheel_changed,wheel_changed and wheel_value or next_value
end

function UI:slider_double(label,value,minimum,maximum,format,step,width)
  local r,c=self.host,self.ctx
  if width then r.ImGui_SetNextItemWidth(c,width) end
  local changed,next_value=r.ImGui_SliderDouble(c,label,value,minimum,maximum,format)
  local wheel_changed,wheel_value=self:wheel_adjust(next_value,minimum,maximum,step or .01,false,false)
  return changed or wheel_changed,wheel_changed and wheel_value or next_value
end

function UI:wheel_box(id,value,minimum,maximum,step,format,width,integer,tooltip,default,click_action)
  local r,c=self.host,self.ctx
  r.ImGui_SetNextItemWidth(c,width or 64)
  local changed,next_value
  if integer~=false then
    -- Knob edits and older saved projects may provide fractional numeric state
    -- for fields displayed as integers. ReaImGui's DragInt requires an actual
    -- integer-representable Lua number, so normalize and repair it here.
    local numeric=tonumber(value)
    if not numeric or numeric~=numeric or numeric==math.huge or numeric==-math.huge then numeric=tonumber(default) or minimum end
    local integral=math.floor(math.max(minimum,math.min(maximum,numeric))+.5)
    local normalized=integral~=value
    changed,next_value=r.ImGui_DragInt(c,"##"..id,integral,step or 1,minimum,maximum,format or "%d")
    changed=changed or normalized
  else
    changed,next_value=r.ImGui_DragDouble(c,"##"..id,value,step or .01,minimum,maximum,format or "%.2f")
  end
  local wheel_changed,wheel_value=self:wheel_adjust(next_value,minimum,maximum,step or 1,integer~=false,false)
  if wheel_changed then changed,next_value=true,wheel_value end
  local left_clicked=r.ImGui_IsItemClicked and r.ImGui_IsItemClicked(c,0)
  if r.ImGui_IsItemClicked and r.ImGui_IsItemClicked(c,1) and default~=nil then changed,next_value=default~=value,default end
  self:tooltip((tooltip or "Adjust value")..(click_action and "\nUse the mouse wheel to adjust" or "\nDrag left/right or use the mouse wheel")..(default~=nil and "\nRight-click to reset" or ""))
  return changed,next_value,left_clicked
end

function UI:shortcuts()
  local r,c,app=self.host,self.ctx,self.app
  -- The groove popup owns arrows/Enter while open so REAPER and the main pad
  -- selection cannot react to the same navigation keystrokes.
  if self.groove_popup_active then
    if r.ImGui_SetNextFrameWantCaptureKeyboard then r.ImGui_SetNextFrameWantCaptureKeyboard(c,true) end
    return
  end
  if not (r.ImGui_IsKeyPressed and r.ImGui_IsWindowFocused) then return end
  local focus_flags=r.ImGui_FocusedFlags_RootAndChildWindows and r.ImGui_FocusedFlags_RootAndChildWindows() or 0
  if not r.ImGui_IsWindowFocused(c,focus_flags) then return end
  if r.ImGui_GetIO_WantTextInput and r.ImGui_GetIO_WantTextInput(c) then return end
  local ctrl,shift=self:key_modifiers()
  local function pressed(key_name)
    local key=r[key_name];return key and r.ImGui_IsKeyPressed(c,key(),false)
  end
  if ctrl and pressed("ImGui_Key_Z") then app:undo();return end
  if ctrl and pressed("ImGui_Key_Y") then app:redo();return end
  -- Flush deferred rack persistence before REAPER handles the project save.
  if ctrl and pressed("ImGui_Key_S") then app:save_if_due(true) end
  local duplicate_pressed=pressed("ImGui_Key_D")
  if duplicate_pressed and self.edit_focus=="steps" then
    -- ReaDrum owns bare D while its step editor is focused. Ask ReaImGui to
    -- capture the key so the same press does not trigger a REAPER shortcut.
    if r.ImGui_SetNextFrameWantCaptureKeyboard then r.ImGui_SetNextFrameWantCaptureKeyboard(c,true) end
    app:duplicate_lane_steps(self:selected_pad_indices());return
  end
  if ctrl and shift and pressed("ImGui_Key_C") then app:copy_lane();return end
  if ctrl and shift and pressed("ImGui_Key_V") then app:paste_lane();return end
  if pressed("ImGui_Key_Delete") or pressed("ImGui_Key_Backspace") then
    if self.edit_focus=="pads" then
      local targets=self:selected_pad_indices();if #targets==0 then targets={app.selected_pad} end;app:clear_pads(targets)
    else app:clear_step() end
    return
  end
  if pressed("ImGui_Key_LeftArrow") then app.selected_step=math.max(1,app.selected_step-1);return end
  if pressed("ImGui_Key_RightArrow") then app.selected_step=math.min(app:lane().step_count,app.selected_step+1);return end
  if pressed("ImGui_Key_UpArrow") or pressed("ImGui_Key_DownArrow") then
    local delta=pressed("ImGui_Key_UpArrow") and -1 or 1
    local index=math.max(1,math.min(#app.rack.pads,app.selected_pad+delta));app.rack.selected_bank=math.floor((index-1)/16)+1;app:select_pad(index);app:mark_dirty(false);return
  end
  if pressed("ImGui_Key_F") then app:set_fill(not app.fill);return end
  if pressed("ImGui_Key_I") then self.info_open=not self.info_open;return end
  if pressed("ImGui_Key_E") then self.parameter_open=not self.parameter_open;return end
  if pressed("ImGui_Key_O") then self.inspector_open=not self.inspector_open;return end
  if pressed("ImGui_Key_Space") then if (r.GetPlayState()&1)~=0 then r.OnStopButton() else r.OnPlayButton() end end
end

function UI:flush_audition(force)
  local r,app=self.host,self.app;local release=self.audition_due and (force or r.time_precise()>=self.audition_due)
  if release then
    self.audition_due=false
    if self.audition_active_pad then app:release_pad_audition(self.audition_active_pad);self.audition_active_pad=false end
  end
end

function UI:poll_played_pad()
  local r,app=self.host,self.app
  if not self.follow_played_pad or not r.MIDI_GetRecentInputEvent then return end
  local ok,message,timestamp,device=r.MIDI_GetRecentInputEvent(0)
  if not ok or type(message)~="string" or #message<3 then return end
  local status,note,velocity=message:byte(1,3)
  local signature=table.concat({tostring(timestamp),tostring(device),tostring(status),tostring(note),tostring(velocity)},":")
  if signature==self.recent_midi_signature then return end
  self.recent_midi_signature=signature
  if (status&0xF0)==0x90 and velocity>0 and note>=0 and note<=127 then
    app:select_pad(((note-PAD_MIDI_BASE+128)%128)+1)
  end
end

function UI:button(label, width, height, color)
  local r,c=self.host,self.ctx
  local special_text=color==C.selected
  if special_text then r.ImGui_PushStyleColor(c,r.ImGui_Col_Text(),C.selected_text or C.text)end
  r.ImGui_PushStyleColor(c,r.ImGui_Col_Button(),color or C.button)
  if r.ImGui_Col_ButtonHovered then r.ImGui_PushStyleColor(c,r.ImGui_Col_ButtonHovered(),color or C.hover) end
  if r.ImGui_Col_ButtonActive then r.ImGui_PushStyleColor(c,r.ImGui_Col_ButtonActive(),color or C.selected) end
  local hit=r.ImGui_Button(c,label,width or 0,height or 0)
  if r.ImGui_Col_ButtonActive then r.ImGui_PopStyleColor(c) end
  if r.ImGui_Col_ButtonHovered then r.ImGui_PopStyleColor(c) end
  r.ImGui_PopStyleColor(c)
  if special_text then r.ImGui_PopStyleColor(c)end
  return hit
end

function UI:centered_text_button(id,text,width,height,color)
  local r,c=self.host,self.ctx
  r.ImGui_PushStyleColor(c,r.ImGui_Col_Button(),color or C.button)
  r.ImGui_PushStyleColor(c,r.ImGui_Col_ButtonHovered(),color or C.hover)
  r.ImGui_PushStyleColor(c,r.ImGui_Col_ButtonActive(),color or C.selected)
  local hit=r.ImGui_Button(c,id,width,height)
  r.ImGui_PopStyleColor(c,3)
  local x1,y1=r.ImGui_GetItemRectMin(c);local x2,y2=r.ImGui_GetItemRectMax(c)
  local tw,th=r.ImGui_CalcTextSize(c,text)
  r.ImGui_DrawList_AddText(r.ImGui_GetWindowDrawList(c),(x1+x2-tw)*.5,(y1+y2-th)*.5,color==C.selected and (C.selected_text or C.text)or C.text,text)
  return hit
end

function UI:icon_button(id,kind,tooltip,width,height,selected,color,passive,boxed)
  local r,c=self.host,self.ctx
  width,height=width or 32,height or 30
  local hit=false
  if passive then
    -- Decorative toolbar labels reserve layout space without owning an ID or
    -- capturing mouse input; the adjacent value widget is the only control.
    r.ImGui_Dummy(c,width,height)
  else
    r.ImGui_PushStyleColor(c,r.ImGui_Col_Button(),boxed and (selected and C.selected or C.button) or (selected and 0x1687D51C or 0x00000000))
    r.ImGui_PushStyleColor(c,r.ImGui_Col_ButtonHovered(),boxed and (selected and C.selected or C.hover) or (selected and 0x1687D538 or 0xFFFFFF12))
    r.ImGui_PushStyleColor(c,r.ImGui_Col_ButtonActive(),boxed and C.hover or 0x1687D558)
    hit=r.ImGui_Button(c,id,width,height)
    r.ImGui_PopStyleColor(c,3)
  end
  local hovered=not passive and r.ImGui_IsItemHovered(c);local held=not passive and r.ImGui_IsItemActive(c)
  local x1,y1=r.ImGui_GetItemRectMin(c);local x2,y2=r.ImGui_GetItemRectMax(c)
  local draw=r.ImGui_GetWindowDrawList(c)
  local cx,cy=(x1+x2)*.5,(y1+y2)*.5;local s=math.min(width,height)*.44
  local ink=color or (boxed and selected and (C.selected_text or C.text) or ((selected or held) and C.accent or (hovered and C.playhead or C.text)))
  if kind=="oneshot" or kind=="play" then
    -- One Shot is represented by a simple, familiar play trigger.
    r.ImGui_DrawList_AddTriangleFilled(draw,cx-s*.26,cy-s*.48,cx-s*.26,cy+s*.48,cx+s*.52,cy,ink)
  elseif kind=="stop" then
    r.ImGui_DrawList_AddRectFilled(draw,cx-s*.38,cy-s*.38,cx+s*.38,cy+s*.38,ink,1)
  elseif kind=="info" then
    r.ImGui_DrawList_AddCircle(draw,cx,cy,s*.54,ink,20,1.5);r.ImGui_DrawList_AddCircleFilled(draw,cx,cy-s*.26,1.5,ink,8);r.ImGui_DrawList_AddLine(draw,cx,cy-s*.05,cx,cy+s*.34,ink,2)
  elseif kind=="settings" then
    r.ImGui_DrawList_AddCircle(draw,cx,cy,s*.27,ink,16,2)
    for i=0,7 do
      local angle=i*math.pi*.25;local ax,ay=math.cos(angle),math.sin(angle)
      r.ImGui_DrawList_AddLine(draw,cx+ax*s*.39,cy+ay*s*.39,cx+ax*s*.58,cy+ay*s*.58,ink,2.5)
    end
  elseif kind=="lanes" then
    -- Stacked, slightly offset rows distinguish lane/variation tools from
    -- both the help glyph and the drum-pad grid at the opposite edge.
    for i=-1,1 do
      local ay=cy+i*s*.40
      local offset=i*s*.10
      r.ImGui_DrawList_AddRectFilled(draw,cx-s*.55+offset,ay-s*.10,cx+s*.43+offset,ay+s*.10,i==0 and C.accent or ink,1)
      r.ImGui_DrawList_AddCircleFilled(draw,cx-s*.68+offset,ay,s*.10,ink,8)
    end
  elseif kind=="pattern" or kind=="pads" or kind=="instrument" then
    local count=kind=="pattern" and 3 or 2;local gap=2;local cell=(s*1.2-gap*(count-1))/count;local ox=cx-s*.6;local oy=cy-s*.6
    for row=0,count-1 do for col=0,count-1 do local ax=ox+col*(cell+gap);local ay=oy+row*(cell+gap);r.ImGui_DrawList_AddRectFilled(draw,ax,ay,ax+cell,ay+cell,(row==0 and col==0 and selected) and C.accent or ink,1) end end
  elseif kind=="undo" or kind=="redo" then
    local direction=kind=="undo" and 1 or -1
    local start=direction<0 and -.15 or 3.29;local finish=direction<0 and 4.25 or -.95
    r.ImGui_DrawList_PathArcTo(draw,cx,cy+s*.12,s*.48,start,finish,18);r.ImGui_DrawList_PathStroke(draw,ink,0,2.2)
    local tx=cx+direction*s*.48
    r.ImGui_DrawList_AddTriangleFilled(draw,tx,cy-s*.28,tx-direction*s*.42,cy-s*.43,tx-direction*s*.32,cy-.01*s,ink)
  elseif kind=="fill" then
    for i=0,3 do local bh=({.35,.78,.52,1})[i+1]*s;r.ImGui_DrawList_AddRectFilled(draw,cx-s*.62+i*s*.34,cy+bh*.5,cx-s*.43+i*s*.34,cy-bh*.5,ink,1) end
  elseif kind=="signal" then
    for i=0,3 do
      local height=s*(.28+i*.22);local ax=cx-s*.58+i*s*.36
      r.ImGui_DrawList_AddRectFilled(draw,ax,cy+s*.52-height,ax+s*.12,cy+s*.52,ink,1)
    end
  elseif kind=="steps" then
    for i=0,3 do local ax=cx-s*.62+i*s*.41;r.ImGui_DrawList_AddRectFilled(draw,ax,cy-s*.23,ax+s*.27,cy+s*.23,i==0 and C.accent or ink,1) end
  elseif kind=="rate" then
    r.ImGui_DrawList_AddLine(draw,cx-s*.12,cy-s*.58,cx-s*.12,cy+s*.30,ink,2);r.ImGui_DrawList_AddLine(draw,cx-s*.12,cy-s*.58,cx+s*.48,cy-s*.42,ink,2);r.ImGui_DrawList_AddCircleFilled(draw,cx-s*.32,cy+s*.38,s*.25,ink,16)
  elseif kind=="swing" then
    r.ImGui_DrawList_AddCircleFilled(draw,cx-s*.42,cy+s*.24,s*.18,ink,14);r.ImGui_DrawList_AddCircleFilled(draw,cx+s*.42,cy-s*.20,s*.18,C.accent,14);r.ImGui_DrawList_AddLine(draw,cx-s*.24,cy+s*.20,cx+s*.24,cy-s*.16,ink,2)
  elseif kind=="humanize" then
    for i=0,2 do
      local ax=cx+(i-1)*s*.43;local ay=cy+({.28,-.22,.08})[i+1]*s
      r.ImGui_DrawList_AddLine(draw,ax,cy-s*.52,ax,cy+s*.52,ink,1.25)
      r.ImGui_DrawList_AddCircleFilled(draw,ax,ay,s*.15,i==1 and C.accent or ink,12)
    end
  elseif kind=="velocity" then
    for i=0,2 do local bh=({.38,.72,1})[i+1]*s;r.ImGui_DrawList_AddRectFilled(draw,cx-s*.55+i*s*.42,cy+bh*.5,cx-s*.34+i*s*.42,cy-bh*.5,i==2 and C.accent or ink,1) end
  elseif kind=="timing" then
    r.ImGui_DrawList_AddCircle(draw,cx,cy,s*.53,ink,20,1.5)
    r.ImGui_DrawList_AddLine(draw,cx,cy,cx,cy-s*.34,ink,2)
    r.ImGui_DrawList_AddLine(draw,cx,cy,cx+s*.30,cy+s*.13,C.accent,2)
  elseif kind=="lfo" then
    local previous_x,previous_y
    for point=0,18 do
      local px=cx-s*.62+point*s*1.24/18
      local py=cy-math.sin(point/18*2*math.pi)*s*.38
      if previous_x then r.ImGui_DrawList_AddLine(draw,previous_x,previous_y,px,py,ink,1.8) end
      previous_x,previous_y=px,py
    end
  elseif kind=="piano" then
    local key_h=s*.24
    for row=0,4 do
      local ay=cy-s*.62+row*key_h
      r.ImGui_DrawList_AddRect(draw,cx-s*.52,ay,cx+s*.52,ay+key_h,ink,1,0,1)
    end
    r.ImGui_DrawList_AddRectFilled(draw,cx-s*.52,cy-s*.46,cx+s*.08,cy-s*.30,C.panel2,1)
    r.ImGui_DrawList_AddRectFilled(draw,cx-s*.52,cy-s*.02,cx+s*.08,cy+s*.14,C.panel2,1)
  elseif kind=="random" then
    r.ImGui_DrawList_AddRect(draw,cx-s*.55,cy-s*.48,cx+s*.12,cy+s*.19,ink,2,0,1.6)
    r.ImGui_DrawList_AddRect(draw,cx-s*.05,cy-s*.08,cx+s*.55,cy+s*.52,ink,2,0,1.6)
    r.ImGui_DrawList_AddCircleFilled(draw,cx-s*.33,cy-s*.25,s*.07,ink,8)
    r.ImGui_DrawList_AddCircleFilled(draw,cx+s*.34,cy+s*.30,s*.07,ink,8)
  elseif kind=="gate" then
    r.ImGui_DrawList_AddLine(draw,cx-s*.50,cy-s*.42,cx-s*.50,cy+s*.42,ink,2);r.ImGui_DrawList_AddLine(draw,cx+s*.50,cy-s*.42,cx+s*.50,cy+s*.42,ink,2);r.ImGui_DrawList_AddLine(draw,cx-s*.42,cy,cx+s*.42,cy,C.accent,2.5)
  elseif kind=="adsr" then
    -- Four-segment envelope: attack, decay, sustain, release.
    local x1=cx-s*.58;local x2=cx-s*.28;local x3=cx+s*.02;local x4=cx+s*.30;local x5=cx+s*.58
    local y0=cy+s*.38;local y1=cy-s*.42;local ys=cy-s*.10
    r.ImGui_DrawList_AddLine(draw,x1,y0,x2,y1,ink,2)
    r.ImGui_DrawList_AddLine(draw,x2,y1,x3,ys,ink,2)
    r.ImGui_DrawList_AddLine(draw,x3,ys,x4,ys,ink,2)
    r.ImGui_DrawList_AddLine(draw,x4,ys,x5,y0,ink,2)
  elseif kind=="retrigger" then
    r.ImGui_DrawList_PathArcTo(draw,cx,cy,s*.48,.55,5.55,18);r.ImGui_DrawList_PathStroke(draw,ink,0,2.1)
    r.ImGui_DrawList_AddTriangleFilled(draw,cx+s*.47,cy-s*.28,cx+s*.62,cy-s*.02,cx+s*.30,cy-s*.02,ink)
  elseif kind=="accent" then
    r.ImGui_DrawList_AddLine(draw,cx-s*.52,cy+s*.35,cx,cy-s*.48,ink,2.5);r.ImGui_DrawList_AddLine(draw,cx,cy-s*.48,cx+s*.52,cy+s*.35,ink,2.5);r.ImGui_DrawList_AddLine(draw,cx-s*.30,cy+s*.06,cx+s*.30,cy+s*.06,C.accent,2)
  elseif kind=="save" then
    r.ImGui_DrawList_AddRect(draw,cx-s*.55,cy-s*.6,cx+s*.55,cy+s*.6,ink,1,0,2);r.ImGui_DrawList_AddRectFilled(draw,cx-s*.28,cy-s*.6,cx+s*.25,cy-s*.18,ink,1);r.ImGui_DrawList_AddRect(draw,cx-s*.32,cy+s*.08,cx+s*.32,cy+s*.48,ink,1,0,1.5)
  elseif kind=="load" then
    r.ImGui_DrawList_AddRect(draw,cx-s*.62,cy-s*.28,cx+s*.62,cy+s*.48,ink,2,0,2);r.ImGui_DrawList_AddLine(draw,cx-s*.55,cy-s*.28,cx-s*.30,cy-s*.58,ink,2);r.ImGui_DrawList_AddLine(draw,cx-s*.30,cy-s*.58,cx+s*.05,cy-s*.58,ink,2)
  elseif kind=="plus" or kind=="minus" then
    r.ImGui_DrawList_AddLine(draw,cx-s*.45,cy,cx+s*.45,cy,ink,2.5);if kind=="plus" then r.ImGui_DrawList_AddLine(draw,cx,cy-s*.45,cx,cy+s*.45,ink,2.5) end
  elseif kind=="duplicate" then
    r.ImGui_DrawList_AddRect(draw,cx-s*.52,cy-s*.46,cx+s*.18,cy+s*.34,ink,1,0,1.5)
    r.ImGui_DrawList_AddRect(draw,cx-s*.16,cy-s*.16,cx+s*.54,cy+s*.58,ink,1,0,1.5)
    r.ImGui_DrawList_AddLine(draw,cx+s*.20,cy+s*.05,cx+s*.20,cy+s*.39,C.accent,2)
    r.ImGui_DrawList_AddLine(draw,cx+s*.03,cy+s*.22,cx+s*.37,cy+s*.22,C.accent,2)
  elseif kind=="copy" then
    r.ImGui_DrawList_AddRect(draw,cx-s*.52,cy-s*.46,cx+s*.24,cy+s*.42,ink,1,0,1.5);r.ImGui_DrawList_AddRect(draw,cx-s*.18,cy-s*.18,cx+s*.55,cy+s*.58,ink,1,0,1.5)
  elseif kind=="paste" then
    r.ImGui_DrawList_AddRect(draw,cx-s*.45,cy-s*.34,cx+s*.45,cy+s*.55,ink,1,0,1.6);r.ImGui_DrawList_AddRectFilled(draw,cx-s*.22,cy-s*.56,cx+s*.22,cy-s*.27,ink,2)
  elseif kind=="trash" then
    r.ImGui_DrawList_AddRect(draw,cx-s*.38,cy-s*.28,cx+s*.38,cy+s*.55,ink,1,0,1.8);r.ImGui_DrawList_AddLine(draw,cx-s*.48,cy-s*.42,cx+s*.48,cy-s*.42,ink,2);r.ImGui_DrawList_AddLine(draw,cx-s*.18,cy-s*.57,cx+s*.18,cy-s*.57,ink,2)
  elseif kind=="more" then
    for i=-1,1 do r.ImGui_DrawList_AddCircleFilled(draw,cx+i*s*.42,cy,s*.10,ink,8) end
  elseif kind=="wave" then
    local points={};for i=0,8 do local px=cx-s*.62+i*s*.155;local py=cy+math.sin(i*1.55)*s*(i%2==0 and .22 or .42);points[#points+1]={px,py} end
    for i=1,#points-1 do r.ImGui_DrawList_AddLine(draw,points[i][1],points[i][2],points[i+1][1],points[i+1][2],ink,1.8) end
  elseif kind=="reset" then
    r.ImGui_DrawList_AddCircle(draw,cx,cy,s*.46,ink,18,1.8);r.ImGui_DrawList_AddTriangleFilled(draw,cx-s*.56,cy-s*.20,cx-s*.14,cy-s*.42,cx-s*.18,cy+s*.02,ink)
  elseif kind=="rampup" or kind=="rampdown" then
    local direction=kind=="rampup" and -1 or 1
    local y1=cy-direction*s*.42;local y2=cy+direction*s*.42
    r.ImGui_DrawList_AddLine(draw,cx-s*.55,y1,cx+s*.42,y2,ink,2)
    r.ImGui_DrawList_AddTriangleFilled(draw,cx+s*.55,y2,cx+s*.18,y2-direction*s*.18,cx+s*.35,y2+direction*s*.25,ink)
  elseif kind=="scale" then
    r.ImGui_DrawList_AddLine(draw,cx-s*.52,cy+s*.42,cx+s*.52,cy-s*.42,ink,2)
    r.ImGui_DrawList_AddCircle(draw,cx-s*.38,cy-s*.32,s*.18,ink,12,1.6)
    r.ImGui_DrawList_AddCircle(draw,cx+s*.38,cy+s*.32,s*.18,ink,12,1.6)
  elseif kind=="link" then
    -- Two clean interlocking rings read as a pad-trigger link at small sizes.
    local ls=s*1.22
    r.ImGui_DrawList_AddCircle(draw,cx-ls*.28,cy,ls*.31,ink,18,2.4)
    r.ImGui_DrawList_AddCircle(draw,cx+ls*.28,cy,ls*.31,ink,18,2.4)
    r.ImGui_DrawList_AddLine(draw,cx-ls*.12,cy,cx+ls*.12,cy,selected and C.accent or ink,2.8)
  elseif kind=="roundrobin" then
    local shown="RR";local tw,th=r.ImGui_CalcTextSize(c,shown);local text_x,text_y=cx-tw*.5,cy-th*.5
    r.ImGui_DrawList_AddText(draw,text_x,text_y,ink,shown)
    r.ImGui_DrawList_AddText(draw,text_x+.75,text_y,ink,shown)
  elseif kind=="mute" then
    r.ImGui_DrawList_AddRectFilled(draw,cx-s*.52,cy-s*.18,cx-s*.25,cy+s*.18,ink,1);r.ImGui_DrawList_AddTriangleFilled(draw,cx-s*.25,cy-s*.18,cx+s*.10,cy-s*.46,cx+s*.10,cy+s*.46,ink);r.ImGui_DrawList_AddLine(draw,cx+s*.26,cy-s*.35,cx+s*.56,cy+s*.35,ink,2);r.ImGui_DrawList_AddLine(draw,cx+s*.56,cy-s*.35,cx+s*.26,cy+s*.35,ink,2)
  elseif kind=="solo" then
    local shown="S";local tw=r.ImGui_CalcTextSize(c,shown);r.ImGui_DrawList_AddText(draw,cx-tw*.5,cy-s*.55,ink,shown)
  elseif kind=="editor" then
    r.ImGui_DrawList_AddLine(draw,cx-s*.62,cy-s*.48,cx+s*.62,cy-s*.48,ink,1.5);for i=0,3 do local ax=cx-s*.54+i*s*.36;r.ImGui_DrawList_AddRectFilled(draw,ax,cy-s*.15,ax+s*.20,cy+s*.55,i==1 and C.playhead or ink,1) end
  elseif kind=="mixer" then
    for i=0,2 do
      local ax=cx-s*.48+i*s*.48
      r.ImGui_DrawList_AddLine(draw,ax,cy-s*.55,ax,cy+s*.55,ink,1.7)
      local knob_y=cy+({-.22,.28,-.08})[i+1]*s
      r.ImGui_DrawList_AddCircleFilled(draw,ax,knob_y,s*.14,i==1 and C.accent or ink,12)
    end
  elseif kind=="outputs" then
    -- Three bus lanes terminating at a shared output edge.
    for i=-1,1 do
      local ay=cy+i*s*.38
      r.ImGui_DrawList_AddLine(draw,cx-s*.58,ay,cx+s*.20,ay,ink,1.8)
      r.ImGui_DrawList_AddTriangleFilled(draw,cx+s*.48,ay,cx+s*.12,ay-s*.18,cx+s*.12,ay+s*.18,i==0 and C.accent or ink)
    end
  elseif kind=="aux" then
    -- A split send path reads clearly as auxiliary routing at toolbar size.
    r.ImGui_DrawList_AddLine(draw,cx-s*.55,cy,cx-s*.10,cy,ink,2)
    r.ImGui_DrawList_AddLine(draw,cx-s*.10,cy,cx+s*.38,cy-s*.42,ink,2)
    r.ImGui_DrawList_AddLine(draw,cx-s*.10,cy,cx+s*.38,cy+s*.42,ink,2)
    r.ImGui_DrawList_AddCircleFilled(draw,cx+s*.43,cy-s*.43,s*.11,C.accent,10)
    r.ImGui_DrawList_AddCircleFilled(draw,cx+s*.43,cy+s*.43,s*.11,C.accent,10)
  elseif kind=="tcp" then
    for i=-1,1 do
      local ay=cy+i*s*.42
      r.ImGui_DrawList_AddRect(draw,cx-s*.60,ay-s*.14,cx+s*.60,ay+s*.14,ink,1,0,1.4)
      r.ImGui_DrawList_AddRectFilled(draw,cx-s*.51,ay-s*.07,cx-s*.31,ay+s*.07,i==0 and C.accent or ink,1)
      r.ImGui_DrawList_AddLine(draw,cx-s*.20,ay,cx+s*.48,ay,ink,1.2)
    end
  elseif kind=="item" then
    r.ImGui_DrawList_AddRect(draw,cx-s*.62,cy-s*.46,cx+s*.62,cy+s*.46,ink,2,0,1.5);for i=1,3 do local ax=cx-s*.62+i*s*.31;r.ImGui_DrawList_AddLine(draw,ax,cy-s*.46,ax,cy+s*.46,ink,1) end
  elseif kind=="previous" or kind=="next" then
    local direction=kind=="previous" and -1 or 1
    r.ImGui_DrawList_AddLine(draw,cx+direction*s*.28,cy-s*.45,cx-direction*s*.22,cy,ink,2)
    r.ImGui_DrawList_AddLine(draw,cx-direction*s*.22,cy,cx+direction*s*.28,cy+s*.45,ink,2)
  end
  if hovered and tooltip and self.tooltips_enabled~=false and r.ImGui_SetItemTooltip then r.ImGui_SetItemTooltip(c,tooltip) end
  return hit
end

function UI:gain_lfo_popup()
  local r,c,app=self.host,self.ctx,self.app
  if not r.ImGui_BeginPopup(c,"##accentuator_popup") then return end
  local settings=app.rack.accentuator or {enabled=true,amount=100,bands={0,0,0,0}}
  settings.bands=settings.bands or {0,0,0,0}
  local enabled=settings.enabled~=false
  local changed
  changed,enabled=r.ImGui_Checkbox(c,"ACCENTUATOR",enabled)
  if changed then settings.enabled=enabled;app:mark_dirty(false) end
  r.ImGui_SameLine(c);r.ImGui_TextDisabled(c,"Event accents (per enabled lane)")
  local values={}
  for parameter=1,4 do values[parameter]=math.floor((settings.bands and settings.bands[parameter] or 0)+.5) end
  local amount=math.floor((settings.amount or 100)+.5)
  local preview_width,preview_height=310,72
  local px,py=r.ImGui_GetCursorScreenPos(c)
  r.ImGui_InvisibleButton(c,"##accentuator_curve",preview_width,preview_height)
  local draw=r.ImGui_GetWindowDrawList(c)
  r.ImGui_DrawList_AddRectFilled(draw,px,py,px+preview_width,py+preview_height,C.panel2,3)
  for cell=0,15 do if cell%2==0 then local left=px+cell*preview_width/16;r.ImGui_DrawList_AddRectFilled(draw,left,py,left+preview_width/16,py+preview_height,0xFFFFFF08) end end
  local center=py+preview_height*.5
  r.ImGui_DrawList_AddLine(draw,px,center,px+preview_width,center,C.border,1)
  local previous_x,previous_y
  for point=0,127 do
    local x=point/127;local raw=0;local periods={2,1,4/6,.5}
    for index=1,4 do raw=raw+(values[index]/100)*math.sin(2*math.pi*x*4/periods[index]) end
    -- Show the complete bipolar curve in the editor.  Runtime playback still
    -- clamps ordinary-note modulation to attenuation only in controller.lua.
    local modulation=math.max(-1,math.min(1,raw*.25*(amount/100)))
    local line_x=px+x*preview_width;local line_y=center-modulation*preview_height*.43
    if previous_x then r.ImGui_DrawList_AddLine(draw,previous_x,previous_y,line_x,line_y,enabled and C.text or C.muted,1.8) end
    previous_x,previous_y=line_x,line_y
  end
  local labels={"1/2","1/4","1/6","1/8"};local slider_width=48
  for index=1,4 do
    if index>1 then r.ImGui_SameLine(c,0,8) end
    r.ImGui_BeginGroup(c)
    -- ReaImGui exposes the vertical double slider on all supported builds;
    -- round it here so the control still behaves as an integer percentage.
    local slider_changed,new_value=r.ImGui_VSliderDouble(c,"##accentuator_band"..index,slider_width,82,values[index],-100,100,"%.0f")
    local wheel_changed,wheel_value=self:wheel_adjust(new_value,-100,100,1,true,false)
    if wheel_changed then new_value=wheel_value;slider_changed=true end
    if r.ImGui_IsItemHovered(c) and r.ImGui_IsMouseClicked and r.ImGui_IsMouseClicked(c,1) then new_value=0;slider_changed=true end
    if slider_changed then settings.bands[index]=new_value>=0 and math.floor(new_value+.5) or math.ceil(new_value-.5);app:mark_dirty(false) end
    local tw=r.ImGui_CalcTextSize(c,labels[index]);r.ImGui_SetCursorPosX(c,r.ImGui_GetCursorPosX(c)+(slider_width-tw)*.5);r.ImGui_TextDisabled(c,labels[index])
    r.ImGui_EndGroup(c)
  end
  r.ImGui_SameLine(c,0,12);r.ImGui_BeginGroup(c);r.ImGui_TextDisabled(c,"TOOLS")
  if self:icon_button("##accentuator_random","random","Randomize the four waves",32,28,false,nil,false,true) then for parameter=1,4 do settings.bands[parameter]=math.random(-100,100) end;app:mark_dirty(false) end
  r.ImGui_SameLine(c,0,4)
  if self:icon_button("##accentuator_reset","reset","Reset to a flat curve",32,28,false,nil,false,true) then for parameter=1,4 do settings.bands[parameter]=0 end;app:mark_dirty(false) end
  r.ImGui_TextDisabled(c,"RATE")
  r.ImGui_TextDisabled(c,"Phase locked to the pattern bar")
  r.ImGui_EndGroup(c);r.ImGui_Separator(c);r.ImGui_TextDisabled(c,"AMOUNT");r.ImGui_SameLine(c)
  local amount_changed,new_amount=self:slider_int("##accentuator_amount",amount,0,200,"%d%%",1,220)
  if r.ImGui_IsItemHovered(c) and r.ImGui_IsMouseClicked and r.ImGui_IsMouseClicked(c,1) then new_amount=100;amount_changed=true end
  if amount_changed then settings.amount=new_amount;app:mark_dirty(false) end
  r.ImGui_EndPopup(c)
end

function UI:pad_button(label,width,height,border,selected,triggered)
  local r,c=self.host,self.ctx
  local pad_color=border or C.border
  local function dim(color,factor)
    local red=(color>>24)&0xFF;local green=(color>>16)&0xFF;local blue=(color>>8)&0xFF
    return (math.floor(red*factor)<<24)|(math.floor(green*factor)<<16)|(math.floor(blue*factor)<<8)|0xFF
  end
  if selected then r.ImGui_PushStyleColor(c,r.ImGui_Col_Text(),C.selected_text or C.text) end
  r.ImGui_PushStyleColor(c,r.ImGui_Col_Button(),triggered and dim(pad_color,.52) or (selected and C.selected or C.panel2))
  r.ImGui_PushStyleColor(c,r.ImGui_Col_ButtonHovered(),triggered and dim(pad_color,.62) or (selected and C.selected or C.hover))
  r.ImGui_PushStyleColor(c,r.ImGui_Col_Border(),pad_color)
  r.ImGui_PushStyleVar(c,r.ImGui_StyleVar_FrameBorderSize(),(selected or triggered) and 3 or 2)
  local hit=r.ImGui_Button(c,label,width,height)
  r.ImGui_PopStyleVar(c)
  r.ImGui_PopStyleColor(c,3)
  if selected then r.ImGui_PopStyleColor(c) end
  return hit
end

function UI:selected_pad_indices()
  local result={};for index,selected in pairs(self.selected_pads) do if selected then result[#result+1]=index end end
  table.sort(result);return result
end

function UI:pad_control_targets()
  local targets=self:selected_pad_indices()
  if #targets==0 then targets={self.app.selected_pad} end
  return targets
end

function UI:queue_live_pad_controls(index)
  self.app:queue_pad_controls(index,false)
  self.live_pad_controls_pending=true
end

function UI:apply_selected_pad_control_edit(edit,immediate)
  local app=self.app
  for _,index in ipairs(self:pad_control_targets()) do
    local pad=app:pad(index);local controls=pad.default_controls or {};pad.default_controls=controls
    edit(controls,index);self:queue_live_pad_controls(index)
  end
  -- Continuous controls are coalesced in UI:frame. The `immediate` argument
  -- remains part of the call contract, but no longer blocks the drag frame.
  if immediate then self.live_pad_controls_pending=true end
end

function UI:apply_selected_pad_controls(values,immediate)
  self:apply_selected_pad_control_edit(function(controls)
    for key,value in pairs(values) do controls[key]=value end
  end,immediate)
end

function UI:pad_choke_value(pad)
  if pad.choke_group~=false and pad.choke_group then return pad.choke_group+1 end
  return pad.self_choke==true and 1 or 0
end

function UI:set_pad_choke_value(indices,value)
  for _,index in ipairs(indices or {}) do
    local pad=self.app:pad(index)
    pad.choke_group=value>=2 and value-1 or false
    pad.self_choke=value>=1
    self.app:queue_pad_controls(index,true)
  end
  self.app:mark_dirty(false)
end

function UI:select_pad_for_interaction(index,ctrl,shift)
  local app=self.app
  local previous=app.selected_pad
  if shift then
    local anchor=self.pad_selection_anchor or previous or index
    self.selected_pads={}
    for target=math.min(anchor,index),math.max(anchor,index) do self.selected_pads[target]=true end
    app:select_pad(index)
  elseif ctrl then
    if self.selected_pads[index] then
      self.selected_pads[index]=nil
      -- Selection may be empty; focus deliberately remains on the last pad so
      -- the inspector and step editor always retain a valid target.
    else
      self.selected_pads[index]=true
      app:select_pad(index)
    end
    self.pad_selection_anchor=index
  else
    -- A plain click always replaces the selection. Keeping the old set here
    -- left empty pads highlighted and made them silent round-robin members.
    self.selected_pads={[index]=true}
    self.pad_selection_anchor=index
    app:select_pad(index)
  end
end

function UI:handle_pad_interaction(index,clicked,audition_velocity)
  local r,c,app=self.host,self.ctx,self.app
  local hovered=self:item_hovered_for_drag();local activated=r.ImGui_IsItemActivated and r.ImGui_IsItemActivated(c)
  local ctrl,shift=self:key_modifiers()
  local x1,y1=r.ImGui_GetItemRectMin(c);local x2,y2=r.ImGui_GetItemRectMax(c)
  self.pad_rects[index]={x1=x1,y1=y1,x2=x2,y2=y2}
  if activated then
    self.edit_focus="pads"
    self:select_pad_for_interaction(index,ctrl,shift)
    self.pad_drag_select=not ctrl;self.pad_drag_origin=index;self.pad_drag_moved=false
    if app.audition_notes~=false and app:pad(index).sample~=false then
      self:audition_pad(index,self:pad_velocity_from_item(audition_velocity or 100))
    end
  elseif self.pad_drag_select and not self.pad_rearrange_drag and r.ImGui_IsMouseDown(c,0) and hovered then
    self.selected_pads[index]=true
    if index~=self.pad_drag_origin then self.pad_drag_moved=true end
  end
  local right_activated=hovered and r.ImGui_IsMouseClicked and r.ImGui_IsMouseClicked(c,1)
  if right_activated then
    self.edit_focus="pads"
    -- Preserve a multi-selection only when the context-clicked pad is already
    -- part of it. Right-clicking any other pad starts a new one-pad selection.
    if not self.selected_pads[index] then self.selected_pads={[index]=true} end
    app:select_pad(index)
    local mouse_x,mouse_y=r.ImGui_GetMousePos(c)
    self.pad_right_drag_base={}
    -- A context click on one member of a multi-selection operates on that
    -- selection. It must not silently collapse the group to one pad.
    for selected_index,selected in pairs(self.selected_pads) do if selected then self.pad_right_drag_base[selected_index]=true end end
    self.selected_pads={};for selected_index,selected in pairs(self.pad_right_drag_base) do self.selected_pads[selected_index]=selected end
    self.pad_right_drag=true;self.pad_right_drag_origin={x=mouse_x,y=mouse_y};self.pad_right_drag_moved=false
  end
  -- Older ReaImGui builds without activation reporting fall back to the
  -- release event. Current builds audition above on mouse-down.
  if not r.ImGui_IsItemActivated and clicked and not self.pad_drag_moved and app.audition_notes~=false and app:pad(index).sample~=false then
    self:audition_pad(index,self:pad_velocity_from_item(audition_velocity or 100))
  end
end

function UI:finish_pad_drag()
  local r,c=self.host,self.ctx
  if self.pad_drag_select and not r.ImGui_IsMouseDown(c,0) then self.pad_drag_select=false;self.pad_drag_origin=false;self.pad_rearrange_drag=false end
  if self.pad_right_drag and r.ImGui_IsMouseDown(c,1) and self.pad_right_drag_origin then
    local mouse_x,mouse_y=r.ImGui_GetMousePos(c);local origin=self.pad_right_drag_origin
    local left,right=math.min(origin.x,mouse_x),math.max(origin.x,mouse_x)
    local top,bottom=math.min(origin.y,mouse_y),math.max(origin.y,mouse_y)
    if math.abs(mouse_x-origin.x)>3 or math.abs(mouse_y-origin.y)>3 then
      self.pad_right_drag_moved=true;self.selected_pads={}
      for index,rect in pairs(self.pad_rects or {}) do
        if rect.x2>=left and rect.x1<=right and rect.y2>=top and rect.y1<=bottom then self.selected_pads[index]=true end
      end
      local draw=r.ImGui_GetWindowDrawList(c)
      r.ImGui_DrawList_AddRectFilled(draw,left,top,right,bottom,0x1687D528,2)
      r.ImGui_DrawList_AddRect(draw,left,top,right,bottom,C.selected,2,0,1.5)
    end
  elseif self.pad_right_drag and not r.ImGui_IsMouseDown(c,1) then
    self.pad_right_drag=false;self.pad_right_drag_origin=false;self.pad_right_drag_moved=false;self.pad_right_drag_base={}
  end
end

function UI:pad_context_menu(index,context)
  local r,c,app=self.host,self.ctx,self.app
  if self.pad_right_drag_moved then return end
  context=context or "pad"
  if not r.ImGui_BeginPopupContextItem or not r.ImGui_BeginPopupContextItem(c,"##"..context.."_context"..index) then return end
  app:select_pad(index);self.selected_pads[index]=true
  local pad=app:pad(index)
  local function section(label) r.ImGui_Separator(c);r.ImGui_TextDisabled(c,label) end
  r.ImGui_TextDisabled(c,(context=="lane" and "SEQUENCER LANE  •  " or "PAD  •  ")..(pad.name or ("Pad "..index)))
  if context=="lane" then
    section("STEPS")
    local lane_targets=self:selected_pad_indices();if #lane_targets==0 then lane_targets={index} end
    if r.ImGui_MenuItem(c,"Duplicate") then app:duplicate_lane_steps(lane_targets) end
    section("LANE")
    if r.ImGui_MenuItem(c,"Copy Entire Lane") then app:copy_lane() end
    if r.ImGui_MenuItem(c,"Paste Into Lane") then app:paste_lane() end
    if r.ImGui_MenuItem(c,#lane_targets>1 and ("Clear "..#lane_targets.." Selected Lanes") or "Clear Lane") then app:clear_lanes(lane_targets) end
    if r.ImGui_BeginMenu(c,"Transform Lane") then
      if r.ImGui_MenuItem(c,"Rotate left") then app:rotate_lane(-1) end
      if r.ImGui_MenuItem(c,"Rotate right") then app:rotate_lane(1) end
      if r.ImGui_MenuItem(c,"Reverse") then app:reverse_lane() end
      if r.ImGui_MenuItem(c,"Randomize") then app:randomize_lane(50) end
      if r.ImGui_MenuItem(c,"Euclidean fill") then app:euclidean_lane(4) end
      if r.ImGui_MenuItem(c,"Half length") then app:half_lane() end
      if r.ImGui_MenuItem(c,"Double length") then app:double_lane() end
      r.ImGui_EndMenu(c)
    end
    section("REMOVE")
    if r.ImGui_MenuItem(c,#lane_targets>1 and ("Clear "..#lane_targets.." Selected Pads") or "Clear Pad") then app:clear_pads(lane_targets) end
  else
    section("PAD EDIT")
    if r.ImGui_MenuItem(c,"Copy Pad") then app:copy_pad() end
    if r.ImGui_MenuItem(c,"Paste Pad") then app:paste_pad() end
    section("RELATIONSHIPS")
    local selected=self:selected_pad_indices()
    if r.ImGui_MenuItem(c,"Clear Pad Relationships") then app:clear_pad_relationships(selected) end
    section("REMOVE")
    local clear_targets=self:selected_pad_indices();if #clear_targets==0 then clear_targets={index} end
    if r.ImGui_MenuItem(c,#clear_targets>1 and ("Clear "..#clear_targets.." Selected Pads") or "Clear Pad") then app:clear_pads(clear_targets) end
    local bank=math.floor((index-1)/16);local bank_targets={};for pad_index=bank*16+1,bank*16+16 do bank_targets[#bank_targets+1]=pad_index end
    if r.ImGui_MenuItem(c,"Clear Entire Bank "..string.char(65+bank)) then app:clear_pads(bank_targets) end
    local all_targets={};for pad_index=1,#app.rack.pads do all_targets[#all_targets+1]=pad_index end
    if r.ImGui_MenuItem(c,"Clear All Pads") then app:clear_pads(all_targets) end
  end
  r.ImGui_EndPopup(c)
end

function UI:lane_button(label,width,height,accent,selected,accentuator_enabled)
  local r,c=self.host,self.ctx
  if selected then r.ImGui_PushStyleColor(c,r.ImGui_Col_Text(),C.selected_text or C.text) end
  r.ImGui_PushStyleColor(c,r.ImGui_Col_Button(),selected and C.selected or C.panel2)
  r.ImGui_PushStyleColor(c,r.ImGui_Col_ButtonHovered(),C.hover)
  local hit=r.ImGui_Button(c,label,width,height)
  local x1,y1=r.ImGui_GetItemRectMin(c);local x2,y2=r.ImGui_GetItemRectMax(c)
  local badge_active=r.ImGui_IsItemActivated and r.ImGui_IsItemActivated(c) or false
  local accent_hit=false
  if (hit or badge_active) and ((r.ImGui_IsMouseClicked and r.ImGui_IsMouseClicked(c,0)) or (r.ImGui_IsItemClicked and r.ImGui_IsItemClicked(c,0))) then
    local mx=r.ImGui_GetMousePos(c);accent_hit=mx>=x2-29
  end
  local marker=accent or C.border
  local draw=r.ImGui_GetWindowDrawList(c)
  r.ImGui_DrawList_AddRectFilled(draw,x1,y1,x1+3,y2,marker,1)
  -- The Accentuator switch lives inside the badge, so it does not change the
  -- lane row's column alignment. Its stroke is the pad color only when on.
  local cx,cy=x2-15,(y1+y2)*.5;local s=math.min(22,height)*.44
  r.ImGui_DrawList_AddRectFilled(draw,x2-29,y1+1,x2-1,y2-1,selected and C.selected or C.panel2,1)
  local ink=accentuator_enabled and marker or C.muted;local previous_x,previous_y
  for point=0,12 do
    local px=cx-s*.62+point*s*1.24/12
    local py=cy-math.sin(point/12*2*math.pi)*s*.38
    if previous_x then r.ImGui_DrawList_AddLine(draw,previous_x,previous_y,px,py,ink,1.6) end
    previous_x,previous_y=px,py
  end
  r.ImGui_PopStyleColor(c,2)
  if selected then r.ImGui_PopStyleColor(c) end
  return hit,badge_active,accent_hit
end

function UI:pitch_context_menu()
  local r,c,app=self.host,self.ctx,self.app
  if r.ImGui_MenuItem(c,"Detect pitch") then app:detect_selected_pitch(false) end
  if r.ImGui_MenuItem(c,"Detect and snap to C") then app:detect_selected_pitch(true) end
  if r.ImGui_MenuItem(c,"Snap detected pitch to C") then app:snap_detected_pitch_to_c() end
  if r.ImGui_MenuItem(c,"Revert pitch snap") then app:revert_pitch_snap() end
  local controls=app:pad().default_controls or {}
  local hz=tonumber(controls.detected_pitch_hz)
  local confidence=tonumber(controls.pitch_confidence)
  if hz and hz>0 then
    r.ImGui_Separator(c)
    r.ImGui_TextDisabled(c,string.format("Detected %.1f Hz%s",hz,confidence and string.format("  (%d%% confidence)",math.floor(confidence*100+.5)) or ""))
  end
end

function UI:knob(id,label,value,default,size,options)
  local r,c=self.host,self.ctx
  options=options or {}
  local minimum=options.minimum or 0
  local maximum=options.maximum or 1
  local range=maximum-minimum
  size=size or 52
  r.ImGui_BeginGroup(c)
  local x,y=r.ImGui_GetCursorScreenPos(c)
  r.ImGui_InvisibleButton(c,id,size,size)
  if options.context_menu and r.ImGui_BeginPopupContextItem then
    if r.ImGui_BeginPopupContextItem(c,id.."##context") then
      options.context_menu()
      r.ImGui_EndPopup(c)
    end
  end
  local active=r.ImGui_IsItemActive(c); local hovered=r.ImGui_IsItemHovered(c)
  local mods=r.ImGui_GetKeyMods and r.ImGui_GetKeyMods(c) or 0
  local shift=r.ImGui_Mod_Shift and (mods&r.ImGui_Mod_Shift())~=0 or false
  local shift_clicked=hovered and shift and options.on_shift_click and r.ImGui_IsMouseClicked and r.ImGui_IsMouseClicked(c,0)
  if shift_clicked then options.on_shift_click();self.knob_shift_action=id end
  if self.knob_shift_action==id and r.ImGui_IsMouseDown and not r.ImGui_IsMouseDown(c,0) then self.knob_shift_action=nil end
  if r.ImGui_IsItemActivated(c) then self.knob_start[id]=value end
  local changed,new_value=false,value
  if active and self.knob_shift_action~=id then
    local _,dy=r.ImGui_GetMouseDragDelta(c,0,0)
    new_value=math.max(minimum,math.min(maximum,(self.knob_start[id] or value)-dy/180*range))
    changed=math.abs(new_value-value)>0.000001
  elseif hovered and not options.context_menu and r.ImGui_IsMouseClicked and r.ImGui_IsMouseClicked(c,1) then
    new_value=default or .5; changed=math.abs(new_value-value)>0.000001
  elseif hovered and r.ImGui_IsMouseDoubleClicked and r.ImGui_IsMouseDoubleClicked(c,0) then
    new_value=default or .5; changed=math.abs(new_value-value)>0.000001
  elseif hovered and r.ImGui_GetMouseWheel then
    local wheel=r.ImGui_GetMouseWheel(c)
    if wheel~=0 then
      -- A hovered knob owns the gesture even at its min/max, where its value
      -- cannot change. Otherwise the same wheel event scrolls the inspector.
      self.control_wheel_consumed=true
      if r.ImGui_SetItemUsingMouseWheel then r.ImGui_SetItemUsingMouseWheel(c) end
      local increment=options.wheel_step or range*.02
      new_value=math.max(minimum,math.min(maximum,value+(wheel>0 and increment or -increment)));changed=new_value~=value
      if changed then self.wheel_commit=true end
      if changed then self.knob_value_until[id]=(r.time_precise and r.time_precise() or 0)+.8 end
      -- Dear ImGui otherwise applies the same wheel event to the containing
      -- inspector. Restore its pre-gesture position so only the knob moves.
      if r.ImGui_SetScrollY and self.knob_scroll[id] then r.ImGui_SetScrollY(c,self.knob_scroll[id]) end
    end
  end
  if hovered and r.ImGui_GetScrollY and (not r.ImGui_GetMouseWheel or r.ImGui_GetMouseWheel(c)==0) then self.knob_scroll[id]=r.ImGui_GetScrollY(c) end
  local draw=r.ImGui_GetWindowDrawList(c); local cx,cy=x+size/2,y+size/2
  -- Compact hardware-style knob: recessed bezel, subtly domed cap, a blue
  -- value arc and a small white position marker.  Keeping this in the shared
  -- renderer gives the instrument, pad and master controls one visual language.
  -- Leave enough inset for the value-arc stroke at child-window edges. The
  -- former radius exactly touched the clip rect, cutting off the first knob.
  local outer=size*.39
  local light_theme=theme.luminance(C.panel)>=145
  local shadow=light_theme and 0x00000038 or 0x080A0CBA
  local bezel=active and C.hover or (hovered and C.hover or C.border)
  r.ImGui_DrawList_AddCircleFilled(draw,cx+1,cy+2,outer+2,shadow,32)
  r.ImGui_DrawList_AddCircleFilled(draw,cx,cy,outer+1,bezel,32)
  r.ImGui_DrawList_AddCircle(draw,cx,cy,outer+1,C.border,32,2)
  r.ImGui_DrawList_AddCircleFilled(draw,cx,cy,outer*.82,C.button,32)
  r.ImGui_DrawList_AddCircleFilled(draw,cx,cy+outer*.07,outer*.70,C.panel2,32)
  r.ImGui_DrawList_AddCircle(draw,cx,cy,outer*.82,C.border,32,1)
  -- A neutral/bipolar value points straight up; minimum and maximum fan to
  -- the lower-left and lower-right like hardware drum-machine controls.
  local normalized=range==0 and .5 or (new_value-minimum)/range
  local arc_start,arc_end=-3.93,.79
  local angle=arc_start+normalized*(arc_end-arc_start)
  local default_normalized=range==0 and .5 or ((default~=nil and default or (minimum+maximum)*.5)-minimum)/range
  default_normalized=math.max(0,math.min(1,default_normalized))
  local default_angle=arc_start+default_normalized*(arc_end-arc_start)
  if r.ImGui_DrawList_PathArcTo and r.ImGui_DrawList_PathStroke then
    -- Only show deviation from the control's default. At 12 o'clock the arc
    -- disappears; moving left or right grows it in that direction.
    local deviation=math.abs(normalized-default_normalized)
    if deviation>.001 then
      local from_angle,to_angle=math.min(default_angle,angle),math.max(default_angle,angle)
      r.ImGui_DrawList_PathArcTo(draw,cx,cy,outer+2,from_angle,to_angle,math.max(2,math.floor(28*deviation)))
      r.ImGui_DrawList_PathStroke(draw,active and 0x63BAFFFF or C.playhead,0,2.8)
    end
  end
  local marker_r=outer*.58
  local marker_x,marker_y=cx+math.cos(angle)*marker_r,cy+math.sin(angle)*marker_r
  if not options.inside_label then
    r.ImGui_DrawList_AddCircleFilled(draw,marker_x+1,marker_y+1,2.5,0x00000099,10)
    r.ImGui_DrawList_AddCircleFilled(draw,marker_x,marker_y,2.1,0xF3F6F9FF,10)
  end
  if options.inside_label then
    local tw,th=r.ImGui_CalcTextSize(c,options.inside_label)
    r.ImGui_DrawList_AddText(draw,cx-tw*.5,cy-th*.5,C.text,options.inside_label)
  end
  local shown=options.formatter and options.formatter(new_value) or string.format("%.0f",new_value*100)
  local show_wheel_value=hovered and (self.knob_value_until[id] or 0)>(r.time_precise and r.time_precise() or 0)
  if active or show_wheel_value then
    if r.ImGui_BeginTooltip and r.ImGui_EndTooltip then
      r.ImGui_BeginTooltip(c);r.ImGui_Text(c,shown);r.ImGui_EndTooltip(c)
    elseif r.ImGui_SetTooltip then r.ImGui_SetTooltip(c,shown) end
  end
  local label_clicked=false
  if not options.hide_label then
    local lw,lh=r.ImGui_CalcTextSize(c,label)
    r.ImGui_SetCursorPosX(c,r.ImGui_GetCursorPosX(c)+math.max(0,(size-lw)/2))
    if options.label_clickable then
      local lx,ly=r.ImGui_GetCursorScreenPos(c)
      r.ImGui_InvisibleButton(c,id.."##label",lw,lh)
      if options.context_menu and r.ImGui_BeginPopupContextItem then
        if r.ImGui_BeginPopupContextItem(c,id.."##label_context") then
          options.context_menu()
          r.ImGui_EndPopup(c)
        end
      end
      label_clicked=r.ImGui_IsItemClicked and r.ImGui_IsItemClicked(c,0) or false
      r.ImGui_DrawList_AddText(draw,lx,ly,options.label_color or C.text,label)
    elseif options.label_color and r.ImGui_TextColored then r.ImGui_TextColored(c,options.label_color,label) else r.ImGui_TextDisabled(c,label) end
  end
  r.ImGui_EndGroup(c)
  return changed,new_value,label_clicked
end

function UI:pan_slider(id,value,width)
  local r,c=self.host,self.ctx
  r.ImGui_SetNextItemWidth(c,width or -1)
  local changed,next_value=r.ImGui_SliderDouble(c,id,value,0,1,"")
  local wheel=r.ImGui_IsItemHovered(c) and r.ImGui_GetMouseWheel and r.ImGui_GetMouseWheel(c) or 0
  -- Five pan points per wheel notch is quick enough for mixer work while
  -- retaining useful control around center.
  local wheel_changed,wheel_value=self:wheel_adjust(next_value,0,1,.025,false,false)
  if wheel_changed then changed,next_value=true,wheel_value end
  if wheel~=0 then self.knob_value_until[id]=(r.time_precise and r.time_precise() or 0)+.8 end
  if r.ImGui_IsItemHovered(c) and r.ImGui_IsMouseClicked and r.ImGui_IsMouseClicked(c,1) then changed,next_value=next_value~=.5,.5 end
  local x1,y1=r.ImGui_GetItemRectMin(c);local x2,y2=r.ImGui_GetItemRectMax(c)
  r.ImGui_DrawList_AddLine(r.ImGui_GetWindowDrawList(c),(x1+x2)*.5,y1+2,(x1+x2)*.5,y2-2,C.text,1)
  local amount=math.floor(math.abs((next_value-.5)*200)+.5)
  local shown=amount==0 and "C" or ((next_value<.5 and "L " or "R ")..amount.."%")
  local active=r.ImGui_IsItemActive(c)
  local show_wheel=r.ImGui_IsItemHovered(c) and (self.knob_value_until[id] or 0)>(r.time_precise and r.time_precise() or 0)
  if active or show_wheel then
    if r.ImGui_BeginTooltip and r.ImGui_EndTooltip then r.ImGui_BeginTooltip(c);r.ImGui_Text(c,shown);r.ImGui_EndTooltip(c)
    elseif r.ImGui_SetTooltip then r.ImGui_SetTooltip(c,shown) end
  else self:tooltip("Pan — mouse wheel\nRight-click to center") end
  return changed,next_value
end

local function meter_normalized(value)
  if not value or value<=.001 then return 0 end
  return math.max(0,math.min(1,(20*math.log(value,10)+60)/60))
end

local function meter_decay(value,raw,dt)
  local floor_db=-60
  local shown_db=value and value>.001 and math.max(floor_db,20*math.log(value,10)) or floor_db
  local raw_db=raw and raw>.001 and math.max(floor_db,20*math.log(raw,10)) or floor_db
  local next_db=math.max(raw_db,shown_db-dt*30)
  return next_db<=floor_db and 0 or 10^(next_db/20)
end

local function fader_position(amplitude,maximum_db)
  if not amplitude or amplitude<=0 then return 0 end
  local floor_db=-60;local db=math.max(floor_db,math.min(maximum_db,20*math.log(amplitude,10)))
  return (db-floor_db)/(maximum_db-floor_db)
end

local function fader_amplitude(position,maximum_db)
  position=math.max(0,math.min(1,position or 0))
  if position<=0 then return 0 end
  return 10^((-60+position*(maximum_db+60))/20)
end

function UI:stereo_meter(id,left,right,width,height)
  local r,c=self.host,self.ctx;local now=r.time_precise();local state=self.mixer_meter_state[id]or{time=now,display={0,0},peak={0,0},hold={0,0},clip=false};self.mixer_meter_state[id]=state
  local dt=math.max(0,math.min(.1,now-(state.time or now)));state.time=now
  local raw={math.max(0,left or 0),math.max(0,right or 0)}
  for channel=1,2 do
    -- A fixed dB release makes the bar travel at a uniform visual speed.
    -- 30 dB/s takes exactly two seconds to cross the visible 0..-60 dB range.
    state.display[channel]=meter_decay(state.display[channel]or 0,raw[channel],dt)
    if raw[channel]>=(state.peak[channel]or 0) then state.peak[channel]=raw[channel];state.hold[channel]=now+1
    elseif now>(state.hold[channel]or 0) then state.peak[channel]=state.display[channel] end
    if raw[channel]>=1 then state.clip=true end
  end
  width,height=width or 18,height or 120
  local x,y=r.ImGui_GetCursorScreenPos(c);r.ImGui_InvisibleButton(c,"##meter_"..id,width,height)
  if r.ImGui_IsItemClicked and r.ImGui_IsItemClicked(c,0) then state.clip=false;state.peak={state.display[1],state.display[2]} end
  local draw=r.ImGui_GetWindowDrawList(c);local gap=2;local bar=(width-gap)/2
  for channel=1,2 do
    local bx=x+(channel-1)*(bar+gap);local bottom=y+height
    r.ImGui_DrawList_AddRectFilled(draw,bx,y,bx+bar,bottom,C.step,1)
    local level=meter_normalized(state.display[channel]);local top=bottom-level*height
    if level>0 then
      local bright=blend_color(C.selected,0xFFFFFFFF,.28)
      local dark=blend_color(C.selected,0x000000FF,.48)
      if r.ImGui_DrawList_AddRectFilledMultiColor then
        r.ImGui_DrawList_AddRectFilledMultiColor(draw,bx+1,top,bx+bar-1,bottom,bright,bright,dark,dark)
      else r.ImGui_DrawList_AddRectFilled(draw,bx+1,top,bx+bar-1,bottom,C.selected,1) end
    end
    local peak_y=bottom-meter_normalized(state.peak[channel])*height
    r.ImGui_DrawList_AddLine(draw,bx,peak_y,bx+bar,peak_y,state.peak[channel]>=1 and C.red or C.text,1)
  end
  if state.clip then r.ImGui_DrawList_AddRectFilled(draw,x,y,x+width,y+3,C.red,1) end
  self:tooltip(state.clip and "Clipped — click to clear" or "Stereo peak meter")
  return state.clip
end

function UI:fader_cap(value,minimum,maximum,accent)
  local r,c=self.host,self.ctx
  local x1,y1=r.ImGui_GetItemRectMin(c);local x2,y2=r.ImGui_GetItemRectMax(c)
  local normalized=math.max(0,math.min(1,((value or minimum)-minimum)/math.max(.000001,maximum-minimum)))
  local cap_h=math.min(40,math.max(1,y2-y1))
  local center_top,center_bottom=y1+cap_h*.5,y2-cap_h*.5
  local cy=center_bottom-normalized*math.max(0,center_bottom-center_top)
  local left,right=x1-4,x2+4;local top,bottom=cy-cap_h*.5,cy+cap_h*.5;local draw=r.ImGui_GetWindowDrawList(c)
  r.ImGui_DrawList_AddRectFilled(draw,left+2,top+3,right+3,bottom+4,0x00000042,3)
  if r.ImGui_DrawList_AddRectFilledMultiColor then
    r.ImGui_DrawList_AddRectFilledMultiColor(draw,left,top,right,bottom,C.hover,C.hover,C.button,C.button)
  else r.ImGui_DrawList_AddRectFilled(draw,left,top,right,bottom,C.button,3) end
  r.ImGui_DrawList_AddRect(draw,left,top,right,bottom,C.border,3,0,2)
  r.ImGui_DrawList_AddRect(draw,left+2,top+2,right-2,bottom-2,(C.text&0xFFFFFF00)|0x38,2,0,1)
  for offset=-13,13,4 do r.ImGui_DrawList_AddLine(draw,left+4,cy+offset,right-4,cy+offset,C.muted,1) end
  r.ImGui_DrawList_AddLine(draw,left+3,cy,right-3,cy,accent or C.selected,2.5)
end

function UI:begin_panel(id,width,height,flags)
  -- Layout regions are not controls. Keep them visually flat; selection and
  -- editable widgets provide their own deliberate outlines where useful.
  return self.host.ImGui_BeginChild(self.ctx,id,width,height,0,flags or 0)
end

function UI:begin_unframed(id,width,height,flags)
  return self.host.ImGui_BeginChild(self.ctx,id,width,height,0,flags or 0)
end

function UI:end_panel(visible)
  -- ReaImGui does not leave a child window on the stack when BeginChild
  -- returns false. Calling EndChild on that clipped path asserts, so pair it
  -- only when the binding reports that the child was entered.
  if visible then self.host.ImGui_EndChild(self.ctx) end
end

function UI:sync_grid_scroll(source)
  local r,c=self.host,self.ctx
  if not (r.ImGui_GetScrollX and r.ImGui_SetScrollX) then return end
  if source=="sequence" then self.grid_scroll_x=r.ImGui_GetScrollX(c)
  else r.ImGui_SetScrollX(c,self.grid_scroll_x or 0) end
end

function UI:theme_swatch(id,color,tooltip,active)
  local r,c=self.host,self.ctx;local width,height=38,23;local x,y=r.ImGui_GetCursorScreenPos(c)
  r.ImGui_PushStyleColor(c,r.ImGui_Col_Text(),0x00000000);r.ImGui_PushStyleColor(c,r.ImGui_Col_Button(),0x00000000);r.ImGui_PushStyleColor(c,r.ImGui_Col_ButtonHovered(),0x00000000);r.ImGui_PushStyleColor(c,r.ImGui_Col_ButtonActive(),0x00000000)
  local clicked=r.ImGui_Button(c,id,width,height);r.ImGui_PopStyleColor(c,4)
  local draw=r.ImGui_GetWindowDrawList(c);r.ImGui_DrawList_AddRectFilled(draw,x+2,y+3,x+width+2,y+height+3,0x0000004C,5);r.ImGui_DrawList_AddRectFilled(draw,x,y,x+width,y+height,color,5)
  local outline=theme.luminance(color)>=128 and 0x303030D0 or 0xE0E0E0B0;r.ImGui_DrawList_AddRect(draw,x,y,x+width,y+height,outline,5,0,active and 2 or 1)
  if active then r.ImGui_DrawList_AddCircleFilled(draw,x+width-6,y+6,3,outline)end
  if r.ImGui_IsItemHovered(c)and tooltip and self.tooltips_enabled~=false then self:tooltip(tooltip)end
  return clicked
end

function UI:theme_color_row(key)
  local r,c=self.host,self.ctx;local colors=self.theme.colors;local row_x=r.ImGui_GetCursorPosX(c);r.ImGui_Text(c,theme.LABELS[key]);r.ImGui_SameLine(c);r.ImGui_SetCursorPosX(c,row_x+178)
  if self:theme_swatch("##theme_active_"..key,colors[key],"Edit "..theme.LABELS[key],true)then r.ImGui_OpenPopup(c,"##theme_edit_"..key)end
  if r.ImGui_BeginPopup(c,"##theme_edit_"..key)then
    local changed,value=r.ImGui_ColorEdit4(c,"##theme_picker_"..key,colors[key]);if changed then colors[key]=value;theme.apply(self.theme,C);theme.save(r,self.theme)end;r.ImGui_EndPopup(c)
  end
  for index,choice in ipairs(self.theme.suggestions[key]or{})do
    r.ImGui_SameLine(c);if index==1 then r.ImGui_SetCursorPosX(c,row_x+244)end
    if self:theme_swatch("##theme_choice_"..key..index,choice.color,choice.label,choice.color==colors[key])then colors[key]=choice.color;theme.apply(self.theme,C);theme.save(r,self.theme)end
  end
end

function UI:theme_settings()
  local r,c=self.host,self.ctx
  r.ImGui_TextDisabled(c,"Import from the current REAPER theme")
  if r.ImGui_Button(c,"Auto Detect")then theme.import(r,self.theme,"auto");theme.apply(self.theme,C)end;r.ImGui_SameLine(c)
  if r.ImGui_Button(c,"Import Dark")then theme.import(r,self.theme,"dark");theme.apply(self.theme,C)end;r.ImGui_SameLine(c)
  if r.ImGui_Button(c,"Import Light")then theme.import(r,self.theme,"light");theme.apply(self.theme,C)end
  r.ImGui_Spacing(c);local alternatives=false;for _,key in ipairs(theme.KEYS)do if #(self.theme.suggestions[key]or{})>0 then alternatives=true;break end end
  local x=r.ImGui_GetCursorPosX(c);r.ImGui_SetCursorPosX(c,x+178);r.ImGui_TextDisabled(c,"Active");if alternatives then r.ImGui_SameLine(c);r.ImGui_SetCursorPosX(c,x+244);r.ImGui_TextDisabled(c,"Alternates")end;r.ImGui_Separator(c)
  for _,key in ipairs(theme.KEYS)do self:theme_color_row(key)end
  r.ImGui_Spacing(c)
  if r.ImGui_Button(c,"Preset: ReaDrumXT (Default)")then theme.reset(r,self.theme,"default");theme.apply(self.theme,C)end;r.ImGui_SameLine(c)
  if r.ImGui_Button(c,"Preset: Light")then theme.reset(r,self.theme,"light");theme.apply(self.theme,C)end
end

function UI:eula_viewer()
  if not self.eula_view_open then return end
  local r,c=self.host,self.ctx
  r.ImGui_SetNextWindowSize(c,720,640,r.ImGui_Cond_FirstUseEver())
  local flags=r.ImGui_WindowFlags_NoCollapse and r.ImGui_WindowFlags_NoCollapse() or 0
  local visible,open=r.ImGui_Begin(c,"ReaDrumXT EULA",true,flags)
  self.eula_view_open=open
  if visible then
    r.ImGui_TextColored(c,C.selected,"ReaDrumXT End User License Agreement")
    r.ImGui_SameLine(c);r.ImGui_TextDisabled(c,"Version "..eula.VERSION)
    r.ImGui_Separator(c)
    local _,available_height=r.ImGui_GetContentRegionAvail(c)
    local child_flags=r.ImGui_ChildFlags_Borders and r.ImGui_ChildFlags_Borders() or 0
    local child_visible=r.ImGui_BeginChild(c,"##settings_eula_text",0,math.max(220,available_height-38),child_flags)
    if child_visible then
      if self.eula_text then eula.render(r,c,self.eula_text,C.selected)
      else r.ImGui_TextWrapped(c,self.eula_error or "The agreement could not be loaded.") end
    end
    r.ImGui_EndChild(c)
    local width=r.ImGui_GetContentRegionAvail(c)
    r.ImGui_SetCursorPosX(c,r.ImGui_GetCursorPosX(c)+math.max(0,(width-100)*.5))
    if r.ImGui_Button(c,"Close",100,25) then self.eula_view_open=false end
  end
  r.ImGui_End(c)
end

function UI:rescan_grooves()
  local entries,failure=groove.scan(self.host,self.groove_root)
  self.groove_entries=entries or{};self.groove_cache={}
  local categories,seen={},{}
  for _,entry in ipairs(self.groove_entries)do
    local path="";local depth=0
    for part in (entry.category or""):gmatch("[^/]+")do
      part=part:match("^%s*(.-)%s*$");depth=depth+1;path=path==""and part or(path.." / "..part)
      if not seen[path]then seen[path]=true;categories[#categories+1]={path=path,name=part,depth=depth}end
    end
  end
  table.sort(categories,function(a,b)return a.path:lower()<b.path:lower()end);self.groove_categories=categories
  if self.groove_category~=""and not seen[self.groove_category]then self.groove_category=""end
  self.groove_nav_index=1;self.groove_nav_entry=false
  if failure then self.app.status="Could not scan grooves: "..tostring(failure)
  else self.app.status=string.format("Found %d MIDI groove%s",#self.groove_entries,#self.groove_entries==1 and""or"s")end
  return not failure
end

function UI:visible_grooves()
  local visible={{entry=false,label="Classic Swing"}};local filter=(self.groove_filter or""):lower();local category=self.groove_category or""
  for _,entry in ipairs(self.groove_entries or{})do
    local full=(entry.category~=""and entry.category.." / "or"")..entry.name
    local in_category=category==""or entry.category==category or entry.category:sub(1,#category+3)==category.." / "
    if filter~=""then in_category=full:lower():find(filter,1,true)~=nil end
    if in_category then visible[#visible+1]={entry=entry,label=filter~=""and full or entry.name}end
  end
  return visible
end

function UI:open_grooves_folder()
  local r=self.host;if r.RecursiveCreateDirectory then r.RecursiveCreateDirectory(self.groove_root,0)end
  if r.CF_ShellExecute then r.CF_ShellExecute(self.groove_root);return true end
  if r.ExecProcess then
    local safe=self.groove_root:gsub('"','\\"');local system=r.GetOS and r.GetOS()or""
    local command=system:match("Win")and('explorer.exe "'..safe..'"')or system:match("OSX")and('open "'..safe..'"')or('xdg-open "'..safe..'"')
    r.ExecProcess(command,0);return true
  end
  if r.ImGui_SetClipboardText then r.ImGui_SetClipboardText(self.ctx,self.groove_root)end
  self.app.status="Groove folder path copied: "..self.groove_root;return false
end

function UI:load_groove_entry(entry)
  local cached=self.groove_cache[entry.path]
  if cached then return cached.value,cached.failure end
  local value,failure=groove.load(entry.path,entry.name,entry.relative)
  self.groove_cache[entry.path]={value=value,failure=failure};return value,failure
end

function UI:preview_groove_entry(entry)
  if entry==false then local ok=self.app:preview_groove(false);self.groove_preview_entry=false;return ok~=false end
  local value,failure=self:load_groove_entry(entry)
  if not value then self.app.status="Cannot preview "..entry.name..": "..tostring(failure);return false end
  local ok=self.app:preview_groove(value);self.groove_preview_entry=entry;return ok~=false
end

function UI:apply_groove_entry(entry)
  if entry==false then self.app:apply_groove(false);self.groove_preview_entry=false;return true end
  local value,failure=self:load_groove_entry(entry)
  if not value then self.app.status="Cannot apply "..entry.name..": "..tostring(failure);return false end
  self.app:apply_groove(value);self.groove_preview_entry=false;return true
end

function UI:groove_browser()
  local r,c=self.host,self.ctx;local visible=r.ImGui_BeginPopup(c,"##groove_browser")
  if not visible then
    self.groove_popup_active=false
    if self.groove_popup_seen then self.groove_popup_seen=false;if self.app.groove_preview then self.app:cancel_groove_preview()end;self.groove_preview_entry=false end
    return
  end
  self.groove_popup_seen=true;self.groove_popup_active=true
  if r.ImGui_SetNextFrameWantCaptureKeyboard then r.ImGui_SetNextFrameWantCaptureKeyboard(c,true)end
  if self.groove_entries==false then self:rescan_grooves()end
  r.ImGui_Text(c,"MIDI GROOVES");r.ImGui_SameLine(c);r.ImGui_TextDisabled(c,string.format("%d files",#self.groove_entries))
  r.ImGui_SetNextItemWidth(c,548);local changed,value=r.ImGui_InputText(c,"##groove_filter",self.groove_filter or"");if changed then self.groove_filter=value;self.groove_nav_index=1;self.groove_nav_entry=false end
  self:tooltip("Search groove names and folders")
  local child_flags=r.ImGui_ChildFlags_Borders and r.ImGui_ChildFlags_Borders()or 0
  local folders_visible=r.ImGui_BeginChild(c,"##groove_folders",176,310,child_flags)
  if folders_visible then
    local clicked=r.ImGui_Selectable(c,"All Grooves##groove_folder_all",self.groove_category=="")
    if clicked then self.groove_category="";self.groove_nav_index=1;self.groove_nav_entry=false end
    for index,category in ipairs(self.groove_categories or{})do
      local label=string.rep("   ",math.max(0,category.depth-1)).."> "..category.name.."##groove_folder_"..index
      clicked=r.ImGui_Selectable(c,label,self.groove_category==category.path)
      if clicked then self.groove_category=category.path;self.groove_filter="";self.groove_nav_index=1;self.groove_nav_entry=false end
    end
  end
  r.ImGui_EndChild(c)
  r.ImGui_SameLine(c,0,4)
  local files=self:visible_grooves();self.groove_nav_index=math.max(1,math.min(#files,self.groove_nav_index or 1))
  local files_visible=r.ImGui_BeginChild(c,"##groove_files",368,310,child_flags)
  if files_visible then
    local key_delta=0
    if r.ImGui_IsKeyPressed then
      local up=r.ImGui_Key_UpArrow and r.ImGui_IsKeyPressed(c,r.ImGui_Key_UpArrow(),true)
      local down=r.ImGui_Key_DownArrow and r.ImGui_IsKeyPressed(c,r.ImGui_Key_DownArrow(),true)
      key_delta=up and -1 or(down and 1 or 0)
    end
    if key_delta~=0 and #files>0 then
      self.groove_nav_index=math.max(1,math.min(#files,self.groove_nav_index+key_delta));local target=files[self.groove_nav_index]
      if target and target.entry~=self.groove_nav_entry and self:preview_groove_entry(target.entry)then self.groove_nav_entry=target.entry end
    end
    for index,item in ipairs(files)do
      local entry=item.entry;local selected=self.groove_nav_index==index
      local clicked=r.ImGui_Selectable(c,item.label.."##groove_file_"..index,selected)
      if clicked then
        self.groove_nav_index=index;self.groove_nav_entry=entry
        local ok=self:preview_groove_entry(entry)
        if ok and r.ImGui_IsMouseDoubleClicked and r.ImGui_IsMouseDoubleClicked(c,0)then self:apply_groove_entry(entry);r.ImGui_CloseCurrentPopup(c)end
      end
      if selected and key_delta~=0 and r.ImGui_SetScrollHereY then r.ImGui_SetScrollHereY(c,.5)end
    end
    local enter=r.ImGui_IsKeyPressed and r.ImGui_Key_Enter and r.ImGui_IsKeyPressed(c,r.ImGui_Key_Enter(),false)
    if enter and files[self.groove_nav_index]then self:apply_groove_entry(files[self.groove_nav_index].entry);r.ImGui_CloseCurrentPopup(c)end
  end
  r.ImGui_EndChild(c)
  local can_apply=self.app.groove_preview~=nil
  if not can_apply and r.ImGui_BeginDisabled then r.ImGui_BeginDisabled(c,true)end
  if r.ImGui_Button(c,"Apply",88,25)and can_apply then self:apply_groove_entry(self.groove_preview_entry);r.ImGui_CloseCurrentPopup(c)end
  if not can_apply and r.ImGui_EndDisabled then r.ImGui_EndDisabled(c)end
  r.ImGui_SameLine(c);if r.ImGui_Button(c,"Cancel",88,25)then self.app:cancel_groove_preview();self.groove_preview_entry=false;r.ImGui_CloseCurrentPopup(c)end
  r.ImGui_SameLine(c);if r.ImGui_Button(c,"Open Folder",104,25)then self:open_grooves_folder()end
  r.ImGui_SameLine(c);if r.ImGui_Button(c,"Rescan",88,25)then self:rescan_grooves()end
  r.ImGui_EndPopup(c)
end

function UI:top_toolbar()
  local r,c,app=self.host,self.ctx,self.app
  if not self.track_color_pref_initialized then
    self.track_color_pref_initialized=true
    app:set_pad_track_color_sync(false)
  end
  local toolbar_width=r.ImGui_GetContentRegionAvail(c)
  local function tight(spacing) r.ImGui_SameLine(c,0,spacing or 3) end
  local row_y=r.ImGui_GetCursorPosY(c)
  local function icon_y() r.ImGui_SetCursorPosY(c,row_y+1) end
  local function field_y() r.ImGui_SetCursorPosY(c,row_y+4) end
  local function divider()
    r.ImGui_SameLine(c,0,7)
    icon_y()
    local x,y=r.ImGui_GetCursorScreenPos(c)
    r.ImGui_Dummy(c,1,30)
    r.ImGui_DrawList_AddLine(r.ImGui_GetWindowDrawList(c),x,y+6,x,y+24,C.border,1)
    r.ImGui_SameLine(c,0,7);icon_y()
  end
  if self:icon_button("##toggleinfo","lanes","Variations and lane tools",34,32,self.info_open) then self.info_open=not self.info_open end
  -- Center the complete middle toolbar from its measured rendered width. This
  -- stays correct as controls are added, removed, or resized.
  local middle_width=self.toolbar_middle_width or 1120
  r.ImGui_SameLine(c,math.max(42,(toolbar_width-middle_width)*.5))
  r.ImGui_SetCursorPosY(c,row_y+1)
  r.ImGui_BeginGroup(c)
  local mixer_view=self.main_view=="mixer"
  if self:icon_button("##main_view_toggle",mixer_view and "steps" or "mixer",mixer_view and "Switch to sequencer" or "Switch to mixer",32,30,false) then
    self.main_view=mixer_view and "sequencer" or "mixer"
  end
  tight(10)
  local playing=(r.GetPlayState() & 1)~=0
  if self:icon_button("##transport",playing and "stop" or "play",playing and "Stop" or "Play",34,30,playing,playing and C.active or nil) then
    if playing then r.OnStopButton() else r.OnPlayButton() end
  end
  local can_undo=#app.undo_stack>0 or app.dirty;local can_redo=#app.redo_stack>0
  tight();if self:icon_button("##undo","undo","Undo",30,30,false,can_undo and C.playhead or C.muted,not can_undo) then app:undo() end
  tight();if self:icon_button("##redo","redo","Redo",30,30,false,can_redo and C.playhead or C.muted,not can_redo) then app:redo() end
  divider()
  local variations={}; for _,v in ipairs(app:pattern().variations) do variations[#variations+1]=v.name end
  field_y()
  local changed,value=self:combo_field("##variation",app.variation_index-1,table.concat(variations,"\0").."\0",#variations,100)
  if changed then app:select_variation(value+1) end
  local function toolbar_tab(id,label,width,selected,tooltip,tone)
    r.ImGui_PushStyleVar(c,r.ImGui_StyleVar_FrameRounding(),2)
    local solid=selected and not tone
    r.ImGui_PushStyleColor(c,r.ImGui_Col_Button(),solid and C.selected or C.panel2)
    r.ImGui_PushStyleColor(c,r.ImGui_Col_ButtonHovered(),solid and C.selected or C.hover)
    r.ImGui_PushStyleColor(c,r.ImGui_Col_ButtonActive(),solid and C.selected or C.button)
    -- Toolbar actions remain readable when inactive; the underline communicates
    -- state without making ordinary actions look disabled.
    r.ImGui_PushStyleColor(c,r.ImGui_Col_Text(),solid and (C.selected_text or C.text) or C.text)
    local hit=r.ImGui_Button(c,label.."##"..id,width,30)
    r.ImGui_PopStyleColor(c,4);r.ImGui_PopStyleVar(c)
    local x1,y1=r.ImGui_GetItemRectMin(c);local x2,y2=r.ImGui_GetItemRectMax(c)
    local underline=tone
    if underline then r.ImGui_DrawList_AddLine(r.ImGui_GetWindowDrawList(c),x1+7,y2-2,x2-7,y2-2,underline,2) end
    self:tooltip(tooltip)
    return hit
  end
  tight();icon_y();if self:button("ADD EVENT",78,30,C.active) then app:create_variation_event() end
    self:tooltip("Add a live variation event at the REAPER edit cursor. Selecting the event recalls this variation.")
    tight();icon_y();if self:button("CREATE MIDI",84,30,C.selected) then app:render_variation_to_midi() end
    self:tooltip("Create an editable MIDI item from this variation at the REAPER edit cursor.")
    -- Both variation events and rendered MIDI hand playback to REAPER. Treat
    -- either as one hosted state so a single click always returns to the live
    -- sequencer, including after the rendered MIDI item has been deleted.
    local hosted=app.rack.playback_mode~="continuous"
    tight();icon_y();if toolbar_tab("host","HOST",52,hosted,hosted and "Host playback is active: REAPER MIDI/items trigger pads; live pattern playback is disabled." or "Enable host playback so REAPER MIDI/items trigger pads without live pattern playback.") then app:set_playback_mode(hosted and "continuous" or "events") end
    local lane=app:lane()
    divider()
    field_y();r.ImGui_TextDisabled(c,"GLOBAL")
    tight(5);icon_y();self:icon_button("##stepsicon","steps",nil,26,30,false,C.muted,true)
    tight(1);field_y();local changed,value=self:wheel_box("globalsteps",lane.step_count,1,64,1,"%d",40,true,"Variation steps — mouse wheel",16)
    if changed then
      for _,item in ipairs(app:variation().lanes) do resize_lane(item,value) end
      app.selected_step=math.min(app.selected_step,value); app:mark_dirty(false)
    end
    local division_labels={};for _,item in ipairs(DIVISIONS) do division_labels[#division_labels+1]=item[1] end
    local selected_division=division_index(lane)-1
    tight(3);icon_y();self:icon_button("##rateicon","rate",nil,26,30,false,C.muted,true)
    tight(1);field_y();changed,value=self:combo_field("##globaldivision",selected_division,table.concat(division_labels,"\0").."\0",#division_labels,60)
    if r.ImGui_IsItemClicked and r.ImGui_IsItemClicked(c,1) then
      for i,item in ipairs(DIVISIONS) do if item[2]==1 and item[3]==16 then value=i-1;changed=value~=selected_division;break end end
    end
    self:tooltip("Variation rate\nRight-click to reset to 1/16")
    if changed then
      local division=DIVISIONS[value+1]
      for _,item in ipairs(app:variation().lanes) do item.division_num,item.division_den=division[2],division[3] end
      app:mark_dirty(false)
    end
    tight(3);field_y();changed,value=self:wheel_box("globalswing",app:variation().swing or 0,0,100,1,"S %d%%",56,true,"Global swing or MIDI groove amount — mouse wheel",0)
    if changed then
      app:variation().swing=value
      if app.groove_preview then app.groove_preview.strength=value end
      app:mark_dirty(false)
    end
    tight(3);icon_y()
    local selected_groove=app.groove_preview and app.groove_preview.groove or app:variation().groove
    local groove_name=selected_groove and selected_groove.name or "Classic"
    local groove_label=#groove_name>10 and groove_name:sub(1,9).."…" or groove_name
    if self:button(groove_label.."##groove_select",78,30,selected_groove and C.selected or nil) then r.ImGui_OpenPopup(c,"##groove_browser") end
    self:tooltip("Groove: "..groove_name.."\nSingle-click previews; double-click applies")
    self:groove_browser()
    tight(3);field_y();changed,value=self:wheel_box("accentmultiplier",app.rack.accent_multiplier or 130,100,200,1,"A %d%%",56,true,"Accent multiplier — mouse wheel",130)
    if changed then app.rack.accent_multiplier=value;app:mark_dirty(false) end
    tight(3);field_y();changed,value=self:wheel_box("globalgate",app.rack.global_gate_scale or 100,0,200,1,"G %d%%",56,true,"Global Gate scale — mouse wheel",100)
    if changed then app.rack.global_gate_scale=value;app:reset_dispatcher_schedule();app:mark_dirty(false) end
    tight(3);field_y();changed,value=self:wheel_box("globalvelsens",app.rack.global_velocity_sensitivity or 100,0,200,1,"VS %d%%",62,true,"Global velocity sensitivity — mouse wheel",100)
    if changed then app.rack.global_velocity_sensitivity=value;app:mark_dirty(false) end
    tight(3);field_y();changed,value=self:wheel_box("globalvelocityhumanize",app:variation().velocity_humanize or 0,0,100,1,"V %d%%",56,true,"Global velocity humanize — mouse wheel",0)
    if changed then app:variation().velocity_humanize=value;app:mark_dirty(false) end
    tight(3);icon_y()
    local accentuator_enabled=app.rack.accentuator and app.rack.accentuator.enabled~=false
    if self:icon_button("##accentuator","lfo","Accentuator — event accents for enabled lanes",30,30,accentuator_enabled) then
      app.rack.accentuator=app.rack.accentuator or {enabled=true,amount=100,bands={0,0,0,0}}
      app.rack.accentuator.enabled=true;app:mark_dirty(false);r.ImGui_OpenPopup(c,"##accentuator_popup")
    end
    self:gain_lfo_popup()
    divider()
    if self:icon_button("##toolbar_utilities","more","More: Save, Load and Preferences",32,30,false) then r.ImGui_OpenPopup(c,"##toolbar_utilities_popup") end
    local open_preferences=false
    if r.ImGui_BeginPopup(c,"##toolbar_utilities_popup") then
      if r.ImGui_MenuItem(c,"Save kit") then app:save_kit() end
      if r.ImGui_MenuItem(c,"Load kit") then app:load_kit() end
      r.ImGui_Separator(c)
      if r.ImGui_MenuItem(c,"Preferences") then open_preferences=true end
      r.ImGui_EndPopup(c)
    end
    if open_preferences then r.ImGui_OpenPopup(c,"##preferences_popup") end
    -- General stays compact; Appearance gets only the extra room its swatch
    -- rows need. The remembered tab lets the popup resize on the next frame.
    local popup_flags=r.ImGui_WindowFlags_AlwaysAutoResize and r.ImGui_WindowFlags_AlwaysAutoResize() or 0
    if r.ImGui_BeginPopup(c,"##preferences_popup",popup_flags) then
      if r.ImGui_BeginTabBar(c,"##preferences_tabs")then
        if r.ImGui_BeginTabItem(c,"General")then
          self.preferences_tab="general"
          local changed,value=r.ImGui_Checkbox(c,"Show tooltips",self.tooltips_enabled~=false)
          if changed then self.tooltips_enabled=value;if r.SetExtState then r.SetExtState("ReaDrum5k","show_tooltips",value and "1" or "0",true)end end
          changed,value=r.ImGui_Checkbox(c,"Apply pad colors to REAPER tracks",self.track_colors_enabled==true)
          if changed then self.track_colors_enabled=value;app:set_pad_track_color_sync(value)end
          changed,value=r.ImGui_Checkbox(c,"Audition pads while editing",self.audition_enabled~=false)
          if changed then self.audition_enabled=value;app.audition_notes=value;if r.SetExtState then r.SetExtState("ReaDrum5k","audition_while_editing",value and "1" or "0",true)end end
          changed,value=r.ImGui_Checkbox(c,"Show ADSR on waveform",self.show_adsr_on_waveform==true)
          if changed then self.show_adsr_on_waveform=value;if r.SetExtState then r.SetExtState("ReaDrum5k","show_adsr_on_waveform",value and "1" or "0",true)end end
           changed,value=r.ImGui_Checkbox(c,"Color active steps by pad",self.color_steps_by_pad==true)
           if changed then self.color_steps_by_pad=value;if r.SetExtState then r.SetExtState("ReaDrum5k","color_steps_by_pad",value and "1" or "0",true)end end
           r.ImGui_TextDisabled(c,"Available stereo outputs (created automatically)")
           r.ImGui_SetNextItemWidth(c,190)
           local output_choice=self.max_outputs==16 and 1 or 0
           changed,output_choice=r.ImGui_Combo(c,"##max_stereo_outputs",output_choice,table.concat({"8 stereo outputs","16 stereo outputs"},"\0").."\0\0",2)
           if changed then
             self.max_outputs=output_choice==1 and 16 or 8;app.max_outputs=self.max_outputs
             if r.SetExtState then r.SetExtState("ReaDrum5k","max_stereo_outputs",tostring(self.max_outputs),true) end
           end
          r.ImGui_Separator(c)
          if r.ImGui_Button(c,"View EULA",110,25) then
            self.eula_text,self.eula_error=eula.load(product_directory)
            self.eula_view_open=true
          end
          r.ImGui_SameLine(c);if r.ImGui_Button(c,"Grooves Folder",120,25)then self:open_grooves_folder()end
          r.ImGui_SameLine(c);if r.ImGui_Button(c,"Rescan Grooves",120,25)then self:rescan_grooves()end
          r.ImGui_EndTabItem(c)
        end
        if r.ImGui_BeginTabItem(c,"Appearance")then
          self.preferences_tab="appearance"
          self:theme_settings();r.ImGui_EndTabItem(c)
        end
        r.ImGui_EndTabBar(c)
      end
      r.ImGui_EndPopup(c)
    end
    r.ImGui_EndGroup(c)
    local middle_x1=r.ImGui_GetItemRectMin(c);local middle_x2=r.ImGui_GetItemRectMax(c)
    self.toolbar_middle_width=math.max(1,middle_x2-middle_x1)
    r.ImGui_SameLine(c,toolbar_width-34);r.ImGui_SetCursorPosY(c,row_y)
    if self:icon_button("##togglepads","pads","Pad inspector",34,32,self.inspector_open) then self.inspector_open=not self.inspector_open end
  r.ImGui_Separator(c)
end

function UI:info_panel(height)
  local r,c,app=self.host,self.ctx,self.app
  if not self.info_open then return end
  local visible=self:begin_panel("##info",238,height,controlled_scroll_flags(r))
  if visible then
    local info_scroll_y=r.ImGui_GetScrollY and r.ImGui_GetScrollY(c) or 0
    self.control_wheel_consumed=false
    if self:button("VARIATIONS##infotab",108,25,self.info_tab=="variations" and C.selected or C.panel2) then self.info_tab="variations" end
    r.ImGui_SameLine(c);if self:button("LANES##infotab",108,25,self.info_tab=="lanes" and C.selected or C.panel2) then self.info_tab="lanes" end
    r.ImGui_Separator(c)
    if self.info_tab=="variations" then
      r.ImGui_TextDisabled(c,"VARIATIONS")
      for index,variation in ipairs(app:pattern().variations) do
        local selected=index==app.variation_index;local variation_lane=variation.lanes[app.selected_pad]
        local label=string.format("%d   %-13s  %2d  1/%d##variationrow%d",index,variation.name:sub(1,13),variation_lane.step_count,variation_lane.division_den,index)
        if self:button(label,210,25,selected and C.selected or C.panel2) then app:select_variation(index) end
      end
      r.ImGui_SetCursorPosX(c,r.ImGui_GetCursorPosX(c)+10)
      if self:icon_button("##newvariation","plus","New variation",34,28,false,nil,false,true) then app:add_variation(false) end
      r.ImGui_SameLine(c,0,5);if self:icon_button("##duplicatevariation","copy","Duplicate variation",34,28,false,nil,false,true) then app:add_variation(true) end
      r.ImGui_SameLine(c,0,5);if self:icon_button("##deletevariation","trash","Delete variation",34,28,false,nil,false,true) then app:delete_variation() end
      r.ImGui_SameLine(c,0,5);if self:icon_button("##copyvariation","item","Copy variation",34,28,false,nil,false,true) then app:copy_variation() end
      r.ImGui_SameLine(c,0,5);if self:icon_button("##pastevariation","paste","Paste into variation",34,28,false,nil,false,true) then app:paste_variation() end
      r.ImGui_SetNextItemWidth(c,210);local renamed,name=r.ImGui_InputText(c,"##variation_name",app:variation().name);if renamed then app:rename_variation(name) end
    else
      local indices=self:selected_pad_indices();if #indices==0 then indices={app.selected_pad} end
      local function common(key,default)
        local value=app:lane(indices[1])[key];for i=2,#indices do if app:lane(indices[i])[key]~=value then return nil end end;return value==nil and default or value
      end
      -- One compact row controls whether each selected lane receives the four
      -- continuous global modifiers. Match the restrained toolbar treatment,
      -- with a slightly larger target here in the full lane panel.
      local global_links={
        {"global_swing_enabled","SW",36,"Global Swing / Groove"},
        {"global_gate_enabled","GT",36,"Global Gate"},
        {"global_velocity_sensitivity_enabled","VS",36,"Global velocity sensitivity"},
        {"global_velocity_humanize_enabled","VH",36,"Global velocity humanize"},
      }
      local global_row_x=r.ImGui_GetCursorPosX(c)
      r.ImGui_TextDisabled(c,"GLOBAL")
      for position,spec in ipairs(global_links) do
        if position==1 then r.ImGui_SameLine(c,global_row_x+58,0) else r.ImGui_SameLine(c,0,4) end
        local shared=common(spec[1],true);local mixed=shared==nil
        local tooltip=spec[4]..(mixed and ": mixed selection" or (shared and ": linked" or ": bypassed"))
        r.ImGui_PushStyleColor(c,r.ImGui_Col_Button(),C.panel2)
        r.ImGui_PushStyleColor(c,r.ImGui_Col_ButtonHovered(),C.hover)
        r.ImGui_PushStyleColor(c,r.ImGui_Col_ButtonActive(),C.button)
        r.ImGui_PushStyleColor(c,r.ImGui_Col_Text(),mixed and C.playhead or(shared and C.text or C.muted))
        local hit=r.ImGui_Button(c,spec[2].."##lane_global_"..spec[1],spec[3],26)
        r.ImGui_PopStyleColor(c,4)
        local x1,y1=r.ImGui_GetItemRectMin(c);local x2,y2=r.ImGui_GetItemRectMax(c)
        if shared==true then
          r.ImGui_DrawList_AddLine(r.ImGui_GetWindowDrawList(c),x1+6,y2-2,x2-6,y2-2,C.playhead,2)
        elseif mixed then
          r.ImGui_DrawList_AddLine(r.ImGui_GetWindowDrawList(c),x1+6,y2-2,(x1+x2)*.5,y2-2,C.playhead,2)
        end
        if hit then
          local enabled=shared~=true
          for _,index in ipairs(indices) do app:lane(index)[spec[1]]=enabled end
          app:mark_dirty(false)
        end
        self:tooltip(tooltip)
      end
      r.ImGui_Separator(c);r.ImGui_TextDisabled(c,"PLAYBACK")
      local function lane_slider(label,id,key,default,minimum,maximum)
        local row_x=r.ImGui_GetCursorPosX(c);local available=r.ImGui_GetContentRegionAvail(c)
        r.ImGui_TextDisabled(c,label)
        r.ImGui_SameLine(c,row_x+58)
        local changed,value=self:slider_int("##"..id,common(key,default) or default,minimum or 0,maximum or 100,"%d%%",1,math.max(80,available-63))
        if r.ImGui_IsItemClicked and r.ImGui_IsItemClicked(c,1) then value=default;changed=true end
        if changed then for _,i in ipairs(indices) do app:lane(i)[key]=value end;app:mark_dirty(false) end
      end
      lane_slider("Gate","lanegate","gate_scale",100,0,200)
      r.ImGui_TextDisabled(c,"DYNAMICS")
      lane_slider("Scale","lanevelocityscale","velocity_scale",100,25,200)
      lane_slider("VelSens","lanevelsens","velocity_sensitivity",100,0,200)
      r.ImGui_TextDisabled(c,"TIMING")
      local row_x=r.ImGui_GetCursorPosX(c);local available=r.ImGui_GetContentRegionAvail(c)
      r.ImGui_TextDisabled(c,"Offset")
      r.ImGui_SameLine(c,row_x+58)
      local offset_changed,offset_value=self:slider_int("##laneoffset",common("timing_offset",0) or 0,-48,48,"%+d",1,math.max(80,available-63))
      if r.ImGui_IsItemClicked and r.ImGui_IsItemClicked(c,1) then offset_value=0;offset_changed=true end
      if offset_changed then for _,i in ipairs(indices) do app:lane(i).timing_offset=offset_value end;app:mark_dirty(false) end
      lane_slider("Swing","laneswing","swing",0,-100,100)
      r.ImGui_TextDisabled(c,"HUMANIZE")
      local humanize={{"VEL","lanevelocity","velocity_humanize"},{"TIME","lanetiming","timing_humanize"},{"PITCH","lanepitch","pitch_humanize"},{"PAN","lanepan","pan_humanize"}}
      for position,spec in ipairs(humanize) do
        if position>1 then r.ImGui_SameLine(c,0,8) end
        local current=common(spec[3],0) or 0
        local changed,value=self:knob("##"..spec[2],spec[1],current,0,46,{minimum=0,maximum=100,wheel_step=1,formatter=function(v)return string.format("%.0f%%",v)end})
        if changed then for _,i in ipairs(indices) do app:lane(i)[spec[3]]=value end;app:mark_dirty(false) end
      end
      r.ImGui_Separator(c);r.ImGui_TextDisabled(c,"FILL")
      for _,n in ipairs({2,4,8}) do if self:button("Every "..n.."##lanefill",66,24) then for _,i in ipairs(indices) do local lane=app:lane(i);for s,step in ipairs(lane.steps) do step.enabled=(s-1)%n==0;step.cut=false end end;app:mark_dirty(false) end;r.ImGui_SameLine(c) end
      r.ImGui_NewLine(c)
      if self:button("Random##lanefill",100,24) then for _,i in ipairs(indices) do local lane=app:lane(i);for _,step in ipairs(lane.steps) do step.enabled=math.random()<.5;step.cut=false end end;app:mark_dirty(false) end
      r.ImGui_SameLine(c);if self:button("Euclidean##lanefill",100,24) then for _,i in ipairs(indices) do local lane=app:lane(i);for s,step in ipairs(lane.steps) do step.enabled=((s-1)*4%lane.step_count)<4;step.cut=false end end;app:mark_dirty(false) end
      r.ImGui_Separator(c);r.ImGui_TextDisabled(c,"TRANSFORM")
      if self:button("Rotate <##lane",66,24) then for _,i in ipairs(indices) do local t=table.remove(app:lane(i).steps,1);table.insert(app:lane(i).steps,t) end;app:mark_dirty(false) end
      r.ImGui_SameLine(c);if self:button("Rotate >##lane",66,24) then for _,i in ipairs(indices) do local lane=app:lane(i);local t=table.remove(lane.steps);table.insert(lane.steps,1,t) end;app:mark_dirty(false) end
      r.ImGui_SameLine(c);if self:button("Reverse##lane",66,24) then for _,i in ipairs(indices) do local lane=app:lane(i);local out={};for s=#lane.steps,1,-1 do out[#out+1]=lane.steps[s] end;lane.steps=out end;app:mark_dirty(false) end
      if self:button("Half length##lane",100,24) then for _,i in ipairs(indices) do local lane=app:lane(i);resize_lane(lane,math.max(1,math.floor(lane.step_count/2))) end;app:mark_dirty(false) end
      r.ImGui_SameLine(c);if self:button("Double length##lane",100,24) then for _,i in ipairs(indices) do local lane=app:lane(i);resize_lane(lane,math.min(64,lane.step_count*2)) end;app:mark_dirty(false) end
      r.ImGui_Separator(c);r.ImGui_TextDisabled(c,"CLIPBOARD")
      if self:button("Copy##lanes",66,24) then app:copy_lanes(indices) end
      r.ImGui_SameLine(c);if self:button("Paste##lanes",66,24) then app:paste_lanes(indices) end
      r.ImGui_SameLine(c);if self:button("Clear##lanes",66,24,C.red) then app:clear_lanes(indices) end
      if self:button("Reset lane settings",210,24) then for _,i in ipairs(indices) do local lane=app:lane(i);lane.timing_offset=0;lane.velocity_scale=100;lane.velocity_sensitivity=100;lane.gate_scale=100;lane.accentuator_enabled=true;lane.global_swing_enabled=true;lane.global_gate_enabled=true;lane.global_velocity_sensitivity_enabled=true;lane.global_velocity_humanize_enabled=true;lane.velocity_humanize=0;lane.timing_humanize=0;lane.pitch_humanize=0;lane.pan_humanize=0;lane.swing=0 end;app:mark_dirty(false) end
    end
    if r.ImGui_SetScrollY then
      if self.control_wheel_consumed then r.ImGui_SetScrollY(c,info_scroll_y)
      elseif r.ImGui_IsWindowHovered(c) and r.ImGui_GetMouseWheel then
        local wheel=r.ImGui_GetMouseWheel(c)
        if wheel~=0 then r.ImGui_SetScrollY(c,math.max(0,info_scroll_y-wheel*38)) end
      end
    end
  end
  self:end_panel(visible)
  r.ImGui_SameLine(c)
end

function UI:lane_toolbar(height)
  local r,c,app=self.host,self.ctx,self.app
  r.ImGui_PushStyleVar(c,r.ImGui_StyleVar_WindowPadding(),3,0)
  local visible=self:begin_panel("##lane_toolbar",0,height,no_scroll_flags(r))
  r.ImGui_PopStyleVar(c)
  local toolbar_failure
  if visible then
    local toolbar_ok
    toolbar_ok,toolbar_failure=xpcall(function()
    local indices=self:selected_pad_indices();if #indices==0 then indices={app.selected_pad} end
    local function common(key,default)
      local value=app:lane(indices[1])[key]
      for position=2,#indices do if app:lane(indices[position])[key]~=value then return nil end end
      return value==nil and default or value
    end
    local function set_lane_value(key,value)
      for _,index in ipairs(indices) do app:lane(index)[key]=value end
      app:mark_dirty(false)
    end
    local function field(id,key,default,minimum,maximum,format,width,tooltip)
      local shared=common(key,default);local shown=shared==nil and (app:lane(indices[1])[key] or default) or shared
      local changed,value=self:wheel_box("lane_toolbar_"..id,shown,minimum,maximum,1,format,width,true,tooltip,default)
      if changed then set_lane_value(key,value) end
    end
    local function tight(gap) r.ImGui_SameLine(c,0,gap or 3) end
    local row_x,row_y=r.ImGui_GetCursorPosX(c),r.ImGui_GetCursorPosY(c)
    local available_x,available_y=r.ImGui_GetContentRegionAvail(c)
    -- Exact complete-row width, including the four global-link buttons, keeps
    -- the toolbar centered after controls are added or removed.
    local toolbar_width=950
    r.ImGui_SetCursorPosX(c,row_x+math.max(0,(available_x-toolbar_width)*.5))
    r.ImGui_SetCursorPosY(c,row_y+math.max(0,(available_y-24)*.5))
    field("gate","gate_scale",100,0,200,"G %d%%",58,"Lane gate scale — mouse wheel")
    tight();field("scale","velocity_scale",100,25,200,"SC %d%%",62,"Lane velocity scale — mouse wheel")
    tight();field("velsens","velocity_sensitivity",100,0,200,"VS %d%%",62,"Lane velocity sensitivity — mouse wheel")
    tight();field("offset","timing_offset",0,-48,48,"O %+d",58,"Lane timing offset — mouse wheel")
    tight();field("swing","swing",0,-100,100,"SW %d%%",62,"Lane swing trim — negative reduces the global amount; effective swing is clamped to 0–100%")
    tight();field("human_vel","velocity_humanize",0,0,100,"HV %d%%",58,"Velocity humanize — mouse wheel")
    tight();field("human_time","timing_humanize",0,0,100,"HT %d%%",58,"Timing humanize — mouse wheel")
    tight();field("human_pitch","pitch_humanize",0,0,100,"HP %d%%",58,"Pitch humanize — mouse wheel")
    tight();field("human_pan","pan_humanize",0,0,100,"HN %d%%",58,"Pan humanize — mouse wheel")

    local function global_letter(label,key,width,tooltip)
      local shared=common(key,true);local mixed=shared==nil
      r.ImGui_PushStyleColor(c,r.ImGui_Col_Button(),C.panel2)
      r.ImGui_PushStyleColor(c,r.ImGui_Col_ButtonHovered(),C.hover)
      r.ImGui_PushStyleColor(c,r.ImGui_Col_ButtonActive(),C.button)
      r.ImGui_PushStyleColor(c,r.ImGui_Col_Text(),mixed and C.playhead or (shared and C.text or C.muted))
      local hit=r.ImGui_Button(c,label.."##lane_toolbar_"..key,width,24)
      r.ImGui_PopStyleColor(c,4)
      local x1,y1=r.ImGui_GetItemRectMin(c);local x2,y2=r.ImGui_GetItemRectMax(c)
      if shared==true then
        r.ImGui_DrawList_AddLine(r.ImGui_GetWindowDrawList(c),x1+5,y2-2,x2-5,y2-2,C.playhead,2)
      elseif mixed then
        r.ImGui_DrawList_AddLine(r.ImGui_GetWindowDrawList(c),x1+5,y2-2,(x1+x2)*.5,y2-2,C.playhead,2)
      end
      if hit then
        set_lane_value(key,shared~=true)
      end
      self:tooltip(tooltip..(shared==nil and " — mixed selection" or (shared and " — linked" or " — bypassed")))
    end
    tight(7);global_letter("SW","global_swing_enabled",30,"Global Swing / Groove")
    tight();global_letter("GT","global_gate_enabled",28,"Global Gate")
    tight();global_letter("VS","global_velocity_sensitivity_enabled",30,"Global VelSens")
    tight();global_letter("VH","global_velocity_humanize_enabled",30,"Global velocity humanize")

    tight(7)
    if self:button("FILL##lane_toolbar",54,24,C.panel2) then r.ImGui_OpenPopup(c,"##lane_toolbar_fill") end
    if r.ImGui_BeginPopup(c,"##lane_toolbar_fill") then
      for _,count in ipairs({2,4,8}) do
        if r.ImGui_MenuItem(c,"Every "..count) then
          for _,index in ipairs(indices) do local lane=app:lane(index);for step_index,step in ipairs(lane.steps) do step.enabled=(step_index-1)%count==0;step.cut=false end end
          app:mark_dirty(false)
        end
      end
      if r.ImGui_MenuItem(c,"Random") then
        for _,index in ipairs(indices) do for _,step in ipairs(app:lane(index).steps) do step.enabled=math.random()<.5;step.cut=false end end
        app:mark_dirty(false)
      end
      if r.ImGui_MenuItem(c,"Euclidean") then
        for _,index in ipairs(indices) do local lane=app:lane(index);for step_index,step in ipairs(lane.steps) do step.enabled=((step_index-1)*4%lane.step_count)<4;step.cut=false end end
        app:mark_dirty(false)
      end
      r.ImGui_EndPopup(c)
    end

    tight()
    if self:button("TRANSFORM##lane_toolbar",82,24,C.panel2) then r.ImGui_OpenPopup(c,"##lane_toolbar_transform") end
    if r.ImGui_BeginPopup(c,"##lane_toolbar_transform") then
      if r.ImGui_MenuItem(c,"Rotate left") then for _,index in ipairs(indices) do local lane=app:lane(index);local step=table.remove(lane.steps,1);table.insert(lane.steps,step) end;app:mark_dirty(false) end
      if r.ImGui_MenuItem(c,"Rotate right") then for _,index in ipairs(indices) do local lane=app:lane(index);local step=table.remove(lane.steps);table.insert(lane.steps,1,step) end;app:mark_dirty(false) end
      if r.ImGui_MenuItem(c,"Reverse") then for _,index in ipairs(indices) do local lane=app:lane(index);local reversed={};for step_index=#lane.steps,1,-1 do reversed[#reversed+1]=lane.steps[step_index] end;lane.steps=reversed end;app:mark_dirty(false) end
      if r.ImGui_MenuItem(c,"Half length") then for _,index in ipairs(indices) do local lane=app:lane(index);resize_lane(lane,math.max(1,math.floor(lane.step_count/2))) end;app:mark_dirty(false) end
      if r.ImGui_MenuItem(c,"Double length") then for _,index in ipairs(indices) do local lane=app:lane(index);resize_lane(lane,math.min(64,lane.step_count*2)) end;app:mark_dirty(false) end
      r.ImGui_Separator(c)
      if r.ImGui_MenuItem(c,"Reset lane settings") then
        for _,index in ipairs(indices) do local lane=app:lane(index);lane.timing_offset=0;lane.velocity_scale=100;lane.velocity_sensitivity=100;lane.gate_scale=100;lane.accentuator_enabled=true;lane.global_swing_enabled=true;lane.global_gate_enabled=true;lane.global_velocity_sensitivity_enabled=true;lane.global_velocity_humanize_enabled=true;lane.velocity_humanize=0;lane.timing_humanize=0;lane.pitch_humanize=0;lane.pan_humanize=0;lane.swing=0 end
        app:mark_dirty(false)
      end
      r.ImGui_EndPopup(c)
    end

    tight(7);if self:icon_button("##lane_toolbar_duplicate","duplicate","Duplicate selected lane pattern (D)",28,24,false,nil,false,true) then app:duplicate_lane_steps(indices) end
    tight();if self:icon_button("##lane_toolbar_copy","copy","Copy selected lanes",28,24,false,nil,false,true) then app:copy_lanes(indices) end
    tight();if self:icon_button("##lane_toolbar_paste","paste","Paste into selected lanes",28,24,false,nil,false,true) then app:paste_lanes(indices) end
    tight();if self:icon_button("##lane_toolbar_clear","trash","Clear selected lanes",28,24,false,C.red,false,true) then app:clear_lanes(indices) end
    end,debug.traceback)
  end
  self:end_panel(visible)
  if toolbar_failure then
    log_ui_error("ReaDrumXT lane toolbar",toolbar_failure)
    self.lane_toolbar_open=false
    app.status="Lane toolbar was closed after an internal error; details were saved to ReaDrum-error.log"
  end
end

function UI:pad_drag_source(index)
  local r,c=self.host,self.ctx
  if not (r.ImGui_BeginDragDropSource and r.ImGui_SetDragDropPayload and r.ImGui_EndDragDropSource) then return end
  if r.ImGui_BeginDragDropSource(c) then
    self.pad_rearrange_drag=true
    local sources=self:selected_pad_indices()
    local included=false;for _,source in ipairs(sources) do if source==index then included=true;break end end
    if not included then sources={index} end
    r.ImGui_SetDragDropPayload(c,"READRUM_PADS",table.concat(sources,","))
    r.ImGui_Text(c,#sources==1 and ("Move "..state.sample_label(self.app:pad(index))) or ("Move "..#sources.." pads"))
    r.ImGui_EndDragDropSource(c)
  end
end

function UI:accept_sample_drop(start_index,allow_pad_move)
  local r,c=self.host,self.ctx
  if not (r.ImGui_BeginDragDropTarget and r.ImGui_AcceptDragDropPayloadFiles) then return end
  if r.ImGui_BeginDragDropTarget(c) then
    if allow_pad_move and r.ImGui_AcceptDragDropPayload then
      local accepted,payload=r.ImGui_AcceptDragDropPayload(c,"READRUM_PADS")
      if accepted and type(payload)=="string" then
        local sources={};for value in payload:gmatch("%d+") do sources[#sources+1]=tonumber(value) end
        local destinations=self.app:move_pads(sources,start_index)
        if destinations then
          self.selected_pads={};for _,slot in ipairs(destinations) do self.selected_pads[slot]=true end
          self.pad_selection_anchor=destinations[1];self.pad_rearrange_drag=false
        end
      end
    end
    -- The optional second argument is a drag/drop flags bitmask, not a file
    -- count. Omitting it accepts the complete OS payload; the controller then
    -- applies capacity from the target pad through Pad 128.
    local accepted,count=r.ImGui_AcceptDragDropPayloadFiles(c)
    if accepted then
      local paths={}
      for i=0,count-1 do
        local ok,path=r.ImGui_GetDragDropPayloadFile(c,i)
        if ok and path then paths[#paths+1]=path end
      end
      if #paths>0 then
        local loaded,loaded_count,overflow=self.app:load_sample_paths(start_index,paths)
        if not loaded then
          self.drop_error=self.app.status or "Samples could not be loaded"
          self.drop_error_color=C.red
          self.drop_error_until=r.time_precise()+6
        elseif (overflow or 0)>0 then
          self.drop_error=self.app.status
          self.drop_error_color=C.red
          self.drop_error_until=r.time_precise()+6
        end
      end
    end
    r.ImGui_EndDragDropTarget(c)
  end
end

function UI:apply_step_paint(lane,target_step)
  local first=math.min(self.paint_last_step or target_step,target_step)
  local last=math.max(self.paint_last_step or target_step,target_step)
  local changed=false
  for position=first,last do
    local step=lane.steps[position]
    if self.paint_accent then
      local accented=self.paint_accent=="on"
      if not step.enabled or step.accent~=accented or step.cut then step.enabled=true;step.cut=false;step.accent=accented;changed=true end
    elseif step.enabled~=self.paint_value or step.accent or step.cut then
      step.enabled=self.paint_value;step.cut=false;step.accent=false;changed=true
      if not self.paint_value then step.pitch_semitones=0;step.pitch_cents=0;step.gate=100 end
    end
  end
  self.paint_last_step=target_step
  return changed
end

local function note_span_steps(lane,start_index)
  local step=lane.steps[start_index]
  if not (step and step.enabled) then return 0 end
  local span=math.max(1,math.ceil(math.max(0,tonumber(step.gate) or 100)/100))
  local next_start=lane.step_count+1
  for index=start_index+1,lane.step_count do if lane.steps[index].enabled then next_start=index;break end end
  return math.max(1,math.min(span,next_start-start_index,lane.step_count-start_index+1))
end

local function piano_note_right(grid_left,start_index,span)
  local start=grid_left+(start_index-1)*GRID_CELL_STRIDE
  return span>1 and (start+span*GRID_CELL_STRIDE) or (start+GRID_CELL_WIDTH)
end

local function note_owner_at(lane,index)
  for start=index,1,-1 do
    local step=lane.steps[start]
    if step and step.enabled then return start+note_span_steps(lane,start)-1>=index and start or false end
  end
  return false
end

function UI:lane_sustain_owners(lane)
  local cached=self.lane_sustain_cache[lane]
  if cached then return cached end
  local owners={}
  -- Build the complete sustain map once after an edit. At idle the same table
  -- is reused instead of scanning backward (and repeatedly scanning forward)
  -- for every disabled visible cell on every frame.
  for start=1,lane.step_count do
    local step=lane.steps[start]
    if step and step.enabled then
      local finish=start+note_span_steps(lane,start)-1
      for position=start+1,finish do owners[position]=start end
    end
  end
  self.lane_sustain_cache[lane]=owners
  return owners
end

local function truncate_sustain_before(lane,index)
  local owner=note_owner_at(lane,index)
  if owner and owner<index then lane.steps[owner].gate=(index-owner)*100 end
end

local function available_note_span(lane,start_index,ignore)
  local next_start=lane.step_count+1
  for index=start_index+1,lane.step_count do
    if lane.steps[index].enabled and not (ignore and ignore[index]) then next_start=index;break end
  end
  return math.max(1,next_start-start_index)
end

local function clear_piano_note(step)
  step.enabled=false;step.cut=false;step.slide=false;step.pitch_semitones=0;step.pitch_cents=0;step.gate=100
end

local function trim_piano_overlaps(lane,first,last,ignore)
  local edits={}
  for index=1,lane.step_count do
    local step=lane.steps[index]
    if step.enabled and not (ignore and ignore[index]) then
      local finish=index+note_span_steps(lane,index)-1
      if finish>=first and index<=last then
        if index<first then step.gate=math.max(1,first-index)*100
        elseif finish>last then edits[#edits+1]={from=index,to=last+1,span=finish-last,step=model.deep_copy(step)}
        else clear_piano_note(step) end
      end
    end
  end
  for _,edit in ipairs(edits) do
    clear_piano_note(lane.steps[edit.from])
    if edit.to<=lane.step_count then
      local destination=lane.steps[edit.to]
      for key,value in pairs(edit.step) do destination[key]=value end
      destination.enabled=true;destination.cut=false;destination.gate=edit.span*100
    end
  end
end

function UI:sequence_grid(height)
  local r,c,app=self.host,self.ctx,self.app
  local flags=r.ImGui_WindowFlags_HorizontalScrollbar and r.ImGui_WindowFlags_HorizontalScrollbar() or 0
  if r.ImGui_WindowFlags_NoScrollWithMouse then flags=flags|r.ImGui_WindowFlags_NoScrollWithMouse() end
  local visible=self:begin_panel("##sequence",0,height,no_scroll_flags(r))
  if visible then
    self.sequence_wheel_consumed=false
    local grid_part_started=self:perf_begin()
    local indices={}
    -- The sequencer is a bank editor, matching the sampler's eight 16-pad
    -- processing banks. All 128 pads remain available through bank selection,
    -- but the GUI never submits unrelated banks as hidden/overview rows.
    local first=(math.max(1,math.min(8,app.rack.selected_bank or 1))-1)*16+1
    for index=first,math.min(first+15,#app.rack.pads) do indices[#indices+1]=index end
    self:perf_end("grid lane discovery",grid_part_started)
    grid_part_started=self:perf_begin()
    -- Keep the full 64-step canvas available. Each lane still owns its active
    -- length; cells beyond it are only a dim, read-only preview.
    local max_steps=64
    local header_left,header_top=r.ImGui_GetCursorScreenPos(c)
    r.ImGui_TextColored(c,C.selected,"LANE LEVEL")
    r.ImGui_SameLine(c,91)
    local properties_selected=self.parameter_open and self.editor_mode=="properties"
    if self:icon_button("##toggleeditor","signal",properties_selected and "Hide step properties" or "Show step properties",24,22,properties_selected,nil,false,true) then
      if properties_selected then self.parameter_open=false else self.parameter_open=true;self.editor_mode="properties" end
    end
    r.ImGui_SameLine(c,0,3)
    local piano_selected=self.parameter_open and self.editor_mode=="piano"
    if self:icon_button("##togglepiano","piano",piano_selected and "Hide melodic step view" or "Show melodic step view",24,22,piano_selected,nil,false,true) then
      if piano_selected then self.parameter_open=false else self.parameter_open=true;self.editor_mode="piano" end
    end
    r.ImGui_SameLine(c,0,3)
    if self:icon_button("##toggle_lane_toolbar","humanize",self.lane_toolbar_open and "Hide lane toolbar" or "Show lane toolbar",24,22,self.lane_toolbar_open,nil,false,true) then self.lane_toolbar_open=not self.lane_toolbar_open end
    r.ImGui_SameLine(c,209);r.ImGui_TextDisabled(c,"M")
    r.ImGui_SameLine(c,239);r.ImGui_TextDisabled(c,"S")
    r.ImGui_SameLine(c,261);r.ImGui_TextDisabled(c,"STEPS")
    r.ImGui_SameLine(c,315);r.ImGui_TextDisabled(c,"DIV")
    local header_draw=r.ImGui_GetWindowDrawList(c);local scroll_x=self.grid_scroll_x or 0
    local header_width=r.ImGui_GetContentRegionAvail(c);local header_right=header_left+header_width
    if r.ImGui_DrawList_PushClipRect then r.ImGui_DrawList_PushClipRect(header_draw,header_left+GRID_STEP_X,header_top,header_right,header_top+24,true) end
    for step=1,max_steps do
      local text=tostring(step);local text_width=r.ImGui_CalcTextSize(c,text)
      r.ImGui_DrawList_AddText(header_draw,header_left+GRID_STEP_X+(step-1)*GRID_CELL_STRIDE+math.max(0,(GRID_CELL_WIDTH-text_width)/2)-scroll_x,header_top+3,C.muted,text)
    end
    if r.ImGui_DrawList_PopClipRect then r.ImGui_DrawList_PopClipRect(header_draw) end
    local _,lanes_height=r.ImGui_GetContentRegionAvail(c)
    self:perf_end("grid header UI",grid_part_started)
    local lane_row_height=28
    local virtual_width=GRID_STEP_X+max_steps*GRID_CELL_STRIDE+8
    -- The bank has exactly 16 rows. The former dynamic-lane drop target used
    -- an extra 48 px tail here; retaining it lets ImGui drag auto-scroll into
    -- phantom content and makes the boundary lane flash.
    local virtual_height=math.max(40,#indices*lane_row_height+1)
    if r.ImGui_SetNextWindowContentSize then r.ImGui_SetNextWindowContentSize(c,virtual_width,virtual_height) end
    local lanes_visible=self:begin_unframed("##sequence_lanes",0,math.max(40,lanes_height),flags)
    if lanes_visible then
    local scroll_y=r.ImGui_GetScrollY and r.ImGui_GetScrollY(c) or 0
    local scroll_x_now=r.ImGui_GetScrollX and r.ImGui_GetScrollX(c) or 0
    local viewport_width,viewport_height=r.ImGui_GetWindowSize(c)
    local first_row=math.max(1,math.floor(scroll_y/lane_row_height)-1)
    local last_row=math.min(#indices,math.ceil((scroll_y+viewport_height)/lane_row_height)+1)
    local visible_grid_width=math.max(GRID_CELL_STRIDE,viewport_width-GRID_STEP_X)
    local first_visible_step=math.max(1,math.floor(scroll_x_now/GRID_CELL_STRIDE))
    local last_visible_step=math.min(max_steps,math.ceil((scroll_x_now+visible_grid_width)/GRID_CELL_STRIDE)+1)
    local lane_origin_y=r.ImGui_GetCursorPosY(c)
    -- These values are frame-global. Querying the ImGui bridge for them in
    -- every cell was pure repeated work and made a static grid CPU-heavy.
    local frame_mouse_x=r.ImGui_GetMousePos(c)
    local _,frame_shift,frame_alt=self:key_modifiers()
    local frame_draw=r.ImGui_GetWindowDrawList(c)
    local frame_window_x=r.ImGui_GetWindowPos(c)
    local frame_window_width=r.ImGui_GetWindowSize(c)
    local active_base_colors={C.step,C.beat}
    local future_base_colors={blend_color(C.step,C.panel,.84),blend_color(C.beat,C.panel,.84)}
    if first_row>1 then r.ImGui_SetCursorPosY(c,lane_origin_y+(first_row-1)*lane_row_height) end
    for row_index=first_row,last_row do
      local index=indices[row_index]
      local lane_row_started=self.perf_detail_frame and self.host.time_precise() or false
      local pad,lane=app:pad(index),app:lane(index)
      local sustain_owners=self:lane_sustain_owners(lane)
      local row_scroll=r.ImGui_GetScrollX and r.ImGui_GetScrollX(c) or 0
      r.ImGui_SetCursorPosX(c,8+row_scroll)
      local fixed_left=r.ImGui_GetCursorScreenPos(c)
      local selected=self.selected_pads[index] or index==app.selected_pad
      local play_step=self:lane_play_step(lane)
      local label=string.format("%s %s  %-12s   ##lane%d",pad_bank_letter(index),note_name(pad_midi_note(index)),(pad.name or ("Pad "..index)):sub(1,12),index)
      local row_color=pad_color(index,pad)
      local lane_released,badge_active,accent_clicked=self:lane_button(label,190,25,row_color,selected,lane.accentuator_enabled==true)
      local lane_triggered
      lane_triggered=(r.ImGui_IsItemActivated and badge_active) or ((not r.ImGui_IsItemActivated) and lane_released)
      local selected_indices=self:selected_pad_indices()
      local function row_targets()
        local targets={}
        if #selected_indices>0 and self.selected_pads[index] then
          for _,target in ipairs(selected_indices) do targets[#targets+1]=target end
        else targets[1]=index end
        return targets
      end
      if accent_clicked then
        local targets=row_targets();local enabled=not lane.accentuator_enabled
        for _,target in ipairs(targets) do app:lane(target).accentuator_enabled=enabled end
        app:mark_dirty(false);lane_triggered=false
      end
      if lane_triggered and not accent_clicked then
        local ctrl,shift=self:key_modifiers();self:select_pad_for_interaction(index,ctrl,shift)
        if app.audition_notes~=false and pad.sample~=false then self:audition_pad(index,110) end
      end
      self:accept_sample_drop(index)
      self:pad_context_menu(index,"lane")
      self:tooltip(accent_clicked and nil or (r.ImGui_IsItemHovered(c) and "Click the sine icon to toggle Accentuator for the selected lane set" or nil))
      r.ImGui_SameLine(c); if self:button("M##m"..index,25,25,app:pad_muted(index) and C.red or nil) then
        local targets=row_targets();app:set_pad_mute_many(targets,not app:pad_muted(index))
      end
      r.ImGui_SameLine(c); if self:button("S##s"..index,25,25,app:pad_soloed(index) and C.accent or nil) then
        local targets=row_targets();app:set_pad_solo_many(targets,not app:pad_soloed(index))
      end
      r.ImGui_SameLine(c);local steps_changed,steps_value=self:wheel_box("lanesteps"..index,lane.step_count,1,64,1,"%d",38,true,"Lane steps",16)
      if r.ImGui_IsItemHovered(c) and r.ImGui_GetMouseWheel and r.ImGui_GetMouseWheel(c)~=0 then self.sequence_wheel_consumed=true end
      if steps_changed then resize_lane(lane,steps_value);app:select_pad(index);app.selected_step=math.min(app.selected_step,lane.step_count);app:mark_dirty(false) end
      r.ImGui_SameLine(c)
      local selected_division=division_index(lane)
      local division_changed,division_value=self:wheel_box("lanediv"..index,selected_division,1,#DIVISIONS,1,DIVISIONS[selected_division][1],48,true,"Lane division",3)
      if r.ImGui_IsItemHovered(c) and r.ImGui_GetMouseWheel and r.ImGui_GetMouseWheel(c)~=0 then self.sequence_wheel_consumed=true end
      if division_changed then
        local division=DIVISIONS[division_value]
        lane.division_num,lane.division_den=division[2],division[3];app:select_pad(index);app:mark_dirty(false)
      end
      local _,row_top=r.ImGui_GetItemRectMin(c);local _,row_bottom=r.ImGui_GetItemRectMax(c)
      -- This clip exists to protect the fixed lane controls horizontally.
      -- Leave vertical AA fringe outside the item bounds so lower rounded
      -- corners are not cut at the row's exact bottom edge.
      r.ImGui_PushClipRect(c,fixed_left+(GRID_STEP_X-8),row_top-4,frame_window_x+frame_window_width,row_bottom+4,true)
      local cells_started=self.perf_detail_frame and self.host.time_precise() or false
      local active_first=math.max(1,first_visible_step)
      local active_last=math.min(lane.step_count,last_visible_step)
      for step_index=active_first,active_last do
        local step_content_x=GRID_STEP_X+(step_index-1)*GRID_CELL_STRIDE
        r.ImGui_SameLine(c,step_content_x)
        local step=lane.steps[step_index]
        local sustain_owner=not step.enabled and sustain_owners[step_index] or false
        local alternate=math.floor((step_index-1)/4)%2==1
        local base_color=active_base_colors[alternate and 2 or 1]
        local accented=step.enabled and step.accent==true
        -- Invisible input keeps step hover completely borderless. The cell is
        -- rendered explicitly so focus/navigation styling cannot leak in.
        r.ImGui_InvisibleButton(c,"##step"..index..":"..step_index,GRID_CELL_WIDTH,25)
        local clicked=r.ImGui_IsItemClicked and r.ImGui_IsItemClicked(c,0) or false
        local cell_x1,cell_y1=r.ImGui_GetItemRectMin(c);local cell_x2,cell_y2=r.ImGui_GetItemRectMax(c);local draw=frame_draw
        add_rounded_rect(r,draw,cell_x1,cell_y1,cell_x2,cell_y2,base_color,4)
        if step.enabled or step.cut then
          local enabled_color=self.color_steps_by_pad and active_step_color(row_color,step.enabled and step.velocity or 100) or ((C.selected&0xFFFFFF00)|0xA0)
          add_rounded_rect(r,draw,cell_x1,cell_y1,cell_x2,cell_y2,enabled_color,4)
          if accented or step.cut then
            if step.cut then
              local backing=theme.luminance(enabled_color)>=145 and 0x101215FF or 0xFFFFFFFF
              r.ImGui_DrawList_AddLine(draw,cell_x1+8,cell_y1+7,cell_x2-8,cell_y2-7,backing,5)
              r.ImGui_DrawList_AddLine(draw,cell_x1+8,cell_y2-7,cell_x2-8,cell_y1+7,backing,5)
              r.ImGui_DrawList_AddLine(draw,cell_x1+8,cell_y1+7,cell_x2-8,cell_y2-7,C.red,3)
              r.ImGui_DrawList_AddLine(draw,cell_x1+8,cell_y2-7,cell_x2-8,cell_y1+7,C.red,3)
            else
              r.ImGui_DrawList_AddTriangleFilled(draw,cell_x2-4,cell_y1+4,cell_x2-10,cell_y1+4,cell_x2-4,cell_y1+10,0xF4F6F8EE)
            end
          end
        elseif sustain_owner then
          local owner_step=lane.steps[sustain_owner]
          local sustain_color=self.color_steps_by_pad
            and active_step_color(row_color,owner_step.velocity) or C.selected
          sustain_color=(sustain_color&0xFFFFFF00)|0x48
          r.ImGui_DrawList_AddRectFilled(draw,cell_x1+2,cell_y1+2,cell_x2-2,cell_y2-2,sustain_color,2)
        end
        if play_step==step_index then
          r.ImGui_DrawList_AddRectFilled(draw,cell_x1+3,cell_y2-7,cell_x2-3,cell_y2-3,playback_accent_color(),1)
        end
        local has_activation=r.ImGui_IsItemActivated~=nil
        local activated=has_activation and r.ImGui_IsItemActivated(c) or false
        local begin_paint=(has_activation and activated) or ((not has_activation) and clicked)
        local hovered=self:item_hovered_for_drag()
        local origin_lane_x_hovered=self.paint_active and self.paint_lane==index and frame_mouse_x>=cell_x1 and frame_mouse_x<cell_x1+GRID_CELL_STRIDE
        local right_begin=hovered and r.ImGui_IsMouseClicked and r.ImGui_IsMouseClicked(c,1)
        if begin_paint and frame_shift then
          app:select_pad(index);app.selected_step=step_index;self.edit_focus="steps"
          step.cut=not step.cut;step.enabled=false;step.accent=false;step.pitch_semitones=0;step.pitch_cents=0;step.gate=100;app:mark_dirty(false)
        elseif begin_paint and frame_alt then
          app:select_pad(index);app.selected_step=step_index
          self.edit_focus="steps"
          self.paint_active=true;self.paint_button=0;self.paint_lane=index;self.paint_last_step=step_index
          self.paint_accent=accented and "off" or "on";self.paint_value=true
          step.enabled=true;step.cut=false;step.accent=self.paint_accent=="on";app:mark_dirty(false)
        elseif right_begin then
          app:select_pad(index); app.selected_step=step_index
          self.edit_focus="steps"
          self.paint_value=true;self.paint_active=true;self.paint_button=1;self.paint_lane=index;self.paint_last_step=step_index;self.paint_accent=accented and "off" or "on"
          step.enabled=true;step.cut=false;step.accent=self.paint_accent=="on";app:mark_dirty(false)
        elseif begin_paint then
          app:select_pad(index); app.selected_step=step_index
          self.edit_focus="steps"
          self.paint_value=not step.enabled; self.paint_active=true;self.paint_button=0;self.paint_lane=index;self.paint_last_step=step_index;self.paint_accent=false
          if self.paint_value then truncate_sustain_before(lane,step_index) end
          step.enabled=self.paint_value;step.cut=false;step.accent=false
          if not self.paint_value then step.pitch_semitones=0;step.pitch_cents=0;step.gate=100 end
          app:mark_dirty(false)
        elseif self.paint_active and self.paint_lane==index and r.ImGui_IsMouseDown(c,self.paint_button) and origin_lane_x_hovered then
          app:select_pad(index); app.selected_step=step_index
          if self.paint_value then truncate_sustain_before(lane,step_index) end
          if self:apply_step_paint(lane,step_index) then app:mark_dirty(false) end
        end
        if hovered and r.ImGui_BeginTooltip then
          r.ImGui_BeginTooltip(c)
          r.ImGui_Text(c,string.format("%s  Step %d",pad.name or ("Pad "..index),step_index))
          if step.cut then r.ImGui_TextDisabled(c,"CUT — stops active voices for this lane") else
            local effective=app:effective_step_velocity(lane,step,step_index)
            r.ImGui_TextDisabled(c,string.format("Velocity %d → %d%s   Pitch %+d.%02d   Pan %s",step.velocity,effective,accented and "  Accent" or "",step.pitch_semitones,math.abs(step.pitch_cents),step.pan_lock==false and "Pad" or string.format("%+d",step.pan_lock)))
            r.ImGui_TextDisabled(c,string.format("Repeat %d   Probability %.0f%%   Timing %+d   Gate %.0f%%",step.repeat_count,step.probability,step.timing_offset,step.gate))
          end
          r.ImGui_TextDisabled(c,"Shift-click: Cut   Right-click: toggle Accent")
          r.ImGui_EndTooltip(c)
        end
      end
      self:perf_end("sampled active step cells",cells_started)
      cells_started=self.perf_detail_frame and self.host.time_precise() or false
      local future_first=math.max(lane.step_count+1,first_visible_step)
      local future_last=math.min(max_steps,last_visible_step)
      for step_index=future_first,future_last do
        local step_content_x=GRID_STEP_X+(step_index-1)*GRID_CELL_STRIDE
        r.ImGui_SameLine(c,step_content_x)
        r.ImGui_InvisibleButton(c,"##future_step"..index..":"..step_index,GRID_CELL_WIDTH,25)
        local cell_x1,cell_y1=r.ImGui_GetItemRectMin(c);local cell_x2,cell_y2=r.ImGui_GetItemRectMax(c)
        local alternate=math.floor((step_index-1)/4)%2==1
        local dim_color=future_base_colors[alternate and 2 or 1]
        local future_draw=frame_draw
        add_rounded_rect(r,future_draw,cell_x1,cell_y1,cell_x2,cell_y2,dim_color,4)
        r.ImGui_DrawList_AddRect(future_draw,cell_x1+.5,cell_y1+.5,cell_x2-.5,cell_y2-.5,(C.border&0xFFFFFF00)|0x28,3,0,1)
        if r.ImGui_IsItemHovered(c) then self:tooltip(string.format("Step %d — increase this lane's step count to activate",step_index)) end
      end
      self:perf_end("sampled future step cells",cells_started)
      r.ImGui_PopClipRect(c)
      self:perf_end("sampled lane row",lane_row_started)
    end
    -- Advance layout to the end of the virtual lane list. SetNextWindowContentSize
    -- preserves both scrollbar ranges without submitting the skipped widgets.
    r.ImGui_SetCursorPosY(c,lane_origin_y+#indices*lane_row_height)
    -- Dear ImGui requires an actual item after SetCursorPos extends a child
    -- boundary, even when SetNextWindowContentSize already declares it.
    r.ImGui_SetCursorPosX(c,r.ImGui_SetNextWindowContentSize and 8 or virtual_width-1)
    r.ImGui_Dummy(c,1,1)
    if self.paint_active and not r.ImGui_IsMouseDown(c,self.paint_button) then self.paint_active=false;self.paint_lane=false;self.paint_last_step=false;self.paint_accent=false end
    if app.follow_cursor then
      local followed=self:lane_play_step(app:lane())
      if followed then app.selected_step=followed end
    end
    if not self.sequence_wheel_consumed and r.ImGui_IsWindowHovered(c) and r.ImGui_GetMouseWheel then
      local wheel=r.ImGui_GetMouseWheel(c)
      if wheel~=0 then
        local _,shift=self:key_modifiers()
        -- Plain wheel always scrolls lanes vertically. Horizontal movement is
        -- explicit (Shift+wheel or the scrollbar), preventing a casual wheel
        -- gesture over step cells from hiding every short lane off to the left.
        if shift and r.ImGui_GetScrollX and r.ImGui_SetScrollX then
          local next_x=math.max(0,r.ImGui_GetScrollX(c)+wheel*64)
          r.ImGui_SetScrollX(c,next_x);self.grid_scroll_x=next_x
        elseif r.ImGui_GetScrollY and r.ImGui_SetScrollY then
          r.ImGui_SetScrollY(c,math.max(0,r.ImGui_GetScrollY(c)-wheel*38))
        end
      end
    end
    self:sync_grid_scroll("sequence")
    end
    self:end_panel(lanes_visible)
  end
  self:end_panel(visible)
end

function UI:sample_waveform_points(path,defer_analysis)
  local r=self.host
  local points=self.waveform_cache[path or ""]
  if not points and defer_analysis and type(path)=="string" and path~="" then
    local failure=self.waveform_failures[path]
    if type(failure)=="table" and (r.time_precise and r.time_precise() or 0)<(failure.retry_at or 0) then return nil end
    if not self.waveform_queue_set[path] then
      self.waveform_queue[#self.waveform_queue+1]=path;self.waveform_queue_set[path]=true
    end
    return nil
  end
  if not points then
    self:step_waveform_job(path)
    points=self.waveform_cache[path or ""]
  end
  return points
end

function UI:step_waveform_job(path)
  local r=self.host
  if type(path)~="string" or path=="" or not (r.PCM_Source_CreateFromFile and r.PCM_Source_GetPeaks and r.new_array) then return false end
  local function fail(reason,source)
    local prior=self.waveform_failures[path];local attempts=type(prior)=="table" and (prior.attempts or 0)+1 or 1
    local now=r.time_precise and r.time_precise() or 0
    self.waveform_failures[path]={reason=reason,attempts=attempts,retry_at=now+math.min(30,2^attempts)}
    if source and r.PCM_Source_Destroy then r.PCM_Source_Destroy(source) end
    self.waveform_jobs[path]=nil
    return false
  end
  local job=self.waveform_jobs[path]
  if not job then
    local source=r.PCM_Source_CreateFromFile(path)
    if not source then return fail("open_failed") end
    local duration=math.max(.001,r.GetMediaSourceLength(source) or 1)
    local channels=math.max(1,math.floor((r.GetMediaSourceNumChannels and r.GetMediaSourceNumChannels(source)) or 1))
    -- Keep enough cached source detail for useful editing at the maximum
    -- waveform zoom. This remains a one-time peak extraction, never per-frame
    -- audio decoding.
    job={source=source,duration=duration,channels=channels,count=WAVEFORM_PEAK_COUNT,building=false}
    self.waveform_jobs[path]=job
  end
  local function extract()
    local count,channels=job.count,job.channels
    local buffer=r.new_array(count*channels*2)
    local packed=r.PCM_Source_GetPeaks(job.source,count/job.duration,0,channels,count,0,buffer)
    local got=(packed or 0)&0xFFFFF
    if got<=0 then return false end
    local values=buffer.table and buffer.table(1,count*channels*2) or {}
    local result={}
    local minimum_base=count*channels
    for sample=1,got do
      local amplitude=0;local sample_base=(sample-1)*channels
      for channel=1,channels do
        local maximum=values[sample_base+channel] or 0
        local minimum=values[minimum_base+sample_base+channel] or 0
        amplitude=math.max(amplitude,math.abs(maximum),math.abs(minimum))
      end
      result[sample]=amplitude
    end
    self.waveform_cache[path]=result;self.waveform_duration[path]=job.duration;self.waveform_failures[path]=nil
    if r.PCM_Source_Destroy then r.PCM_Source_Destroy(job.source) end
    self.waveform_jobs[path]=nil
    return true
  end
  if extract() then return true end
  if not r.PCM_Source_BuildPeaks then
    return fail("peaks_unavailable",job.source)
  end
  if not job.building then
    local remaining=r.PCM_Source_BuildPeaks(job.source,0) or 0
    if remaining==0 then
      if extract() then return true end
      return fail("no_peak_data",job.source)
    end
    job.building=true;return nil
  end
  local remaining=r.PCM_Source_BuildPeaks(job.source,1) or 0
  if remaining~=0 then return nil end
  r.PCM_Source_BuildPeaks(job.source,2)
  if extract() then return true end
  return fail("build_produced_no_data",job.source)
end

function UI:process_waveform_queue(limit)
  local processed=0
  while processed<(limit or 1) and #self.waveform_queue>0 do
    local path=table.remove(self.waveform_queue,1);self.waveform_queue_set[path]=nil
    local complete=self:step_waveform_job(path)
    if complete==nil and not self.waveform_queue_set[path] then self.waveform_queue[#self.waveform_queue+1]=path;self.waveform_queue_set[path]=true end
    processed=processed+1
  end
  return processed
end

function UI:pad_waveform_overlay(path,color)
  if type(path)~="string" or path=="" then return end
  -- Queue uncached pads from the visible bank, but leave peak extraction to
  -- the throttled idle worker so opening a bank never blocks the UI.
  local r,c=self.host,self.ctx;local points=self:sample_waveform_points(path,true)
  if not points or #points<2 then return end
  local x1,y1=r.ImGui_GetItemRectMin(c);local x2,y2=r.ImGui_GetItemRectMax(c)
  local left,right=x1+6,x2-6;local mid=(y1+y2)*.5;local height=(y2-y1)*.22
  local columns=math.max(12,math.min(48,math.floor((right-left)/3)))
  local ink=((color or C.waveform)&0xFFFFFF00)|0x90;local draw=r.ImGui_GetWindowDrawList(c)
  for column=0,columns-1 do
    local point_index=math.floor(column*(#points-1)/math.max(1,columns-1))+1
    local px=left+column*(right-left)/math.max(1,columns-1)
    local amp=math.min(1,points[point_index] or 0)*height
    r.ImGui_DrawList_AddLine(draw,px,mid-amp,px,mid+amp,ink,1)
  end
end

function UI:waveform(path,width,height,start_pos,end_pos,id,envelope)
  local r,c=self.host,self.ctx
  width=math.max(80,width); height=math.max(54,height)
  start_pos=math.max(0,math.min(1,start_pos or 0));end_pos=math.max(start_pos,math.min(1,end_pos or 1))
  envelope=envelope or {}
  local show_adsr=self.show_adsr_on_waveform==true and (envelope.envelope_enabled==true or envelope.envelope_enabled==1)
  local attack=math.max(0,math.min(1,envelope.attack or DEFAULTS.attack))
  local decay=math.max(0,math.min(1,envelope.decay or DEFAULTS.decay))
  local sustain=math.max(0,math.min(1,envelope.sustain or DEFAULTS.sustain))
  local release=math.max(0,math.min(1,envelope.release or DEFAULTS.release))
  local fade_in=math.max(0,math.min(1,envelope.fade_in or 0))
  local fade_out=math.max(0,math.min(1,envelope.fade_out or 0))
  local fade_in_curve=math.max(0,math.min(1,envelope.fade_in_curve or DEFAULTS.fade_in_curve))
  local fade_out_curve=math.max(0,math.min(1,envelope.fade_out_curve or DEFAULTS.fade_out_curve))
  local x,y=r.ImGui_GetCursorScreenPos(c)
  local draw=r.ImGui_GetWindowDrawList(c)
  local light_theme=theme.luminance(C.panel)>=145
  local canvas_color=C.panel2
  local trim_color=((light_theme and C.step or C.window)&0xFFFFFF00)|0xD8
  r.ImGui_DrawList_AddRectFilled(draw,x,y,x+width,y+height,canvas_color,4)
  -- Analyze only the pad the user actually opened, and do it through the idle
  -- queue rather than blocking this UI frame.
  local points=self:sample_waveform_points(path,true) or {}
  local mid=y+height/2
  r.ImGui_DrawList_AddLine(draw,x,mid,x+width,mid,C.border,1)
  local display_gain=math.max(0,math.min(4,((tonumber(envelope.volume)or .5)/.5)^2))
  local visible_first,visible_last=1,#points
  local visible_count=math.max(0,visible_last-visible_first+1)
  local columns=math.min(math.max(1,math.floor(width)),visible_count)
  for column=0,columns-1 do
    local bucket_first=visible_first+math.floor(column*visible_count/columns)
    local bucket_last=math.min(visible_last,visible_first+math.floor((column+1)*visible_count/columns)-1)
    local peak=0
    for point_index=bucket_first,bucket_last do peak=math.max(peak,points[point_index] or 0) end
    local px=x+(column+.5)*width/columns
    local amp=math.min(1,peak*display_gain)*(height*0.44)
    r.ImGui_DrawList_AddLine(draw,px,mid-amp,px,mid+amp,C.waveform,1)
  end
  local sx,ex=x+start_pos*width,x+end_pos*width
  if sx>x then r.ImGui_DrawList_AddRectFilled(draw,x,y,sx,y+height,trim_color,4) end
  if ex<x+width then r.ImGui_DrawList_AddRectFilled(draw,ex,y,x+width,y+height,trim_color,4) end
  local trim_active=self.wave_drag=="start" or self.wave_drag=="end"
  local start_color,end_color=(C.red&0xFFFFFF00)|(trim_active and 0xFF or 0xB8),(C.red&0xFFFFFF00)|(trim_active and 0xFF or 0xB8)
  r.ImGui_DrawList_AddLine(draw,sx,y,sx,y+height,start_color,2)
  r.ImGui_DrawList_AddLine(draw,ex,y,ex,y+height,end_color,2)
  local span=math.max(1,ex-sx);local top_y=y+9;local bottom_y=y+height-9;local sustain_y=bottom_y-sustain*(bottom_y-top_y)
  local source_duration=math.max(.001,(self.waveform_duration and self.waveform_duration[path or ""]) or 1)
  local trimmed_duration=math.max(.001,source_duration*math.max(.001,end_pos-start_pos))
  local transpose,cents
  if envelope.transpose_semitones~=nil or envelope.tune_cents~=nil then
    transpose=tonumber(envelope.transpose_semitones) or 0;cents=tonumber(envelope.tune_cents) or 0
  else
    local total=((tonumber(envelope.pitch) or DEFAULTS.pitch)-.5)*160
    transpose=math.floor(total+(total>=0 and .5 or -.5));cents=(total-transpose)*100
  end
  local playback_rate=math.max(.000001,2^((transpose+cents/100)/12))
  local attack_seconds=envelope_math.time_seconds(attack,envelope_math.ATTACK_MAX_SECONDS)
  local decay_seconds=envelope_math.time_seconds(decay,envelope_math.DECAY_MAX_SECONDS)
  local attack_x=math.min(ex,sx+span*math.min(1,attack_seconds*playback_rate/trimmed_duration))
  local decay_x=math.min(ex,attack_x+span*math.min(1,(decay_seconds*playback_rate)/trimmed_duration))
  local sustain_x=decay_x+(ex-decay_x)*.55
  local envelope_active=self.wave_drag=="attack" or self.wave_drag=="decay" or self.wave_drag=="sustain"
  local envelope_base=C.value_marker or C.accent
  local envelope_color=(envelope_base&0xFFFFFF00)|(envelope_active and 0xFF or 0x94)
  local envelope_width=envelope_active and 2.0 or 1.25
  local function envelope_handle(px,py,label,align)
    r.ImGui_DrawList_AddCircleFilled(draw,px,py,4.5,(C.border&0xFFFFFF00)|(envelope_active and 0xFF or 0xA8),12)
    r.ImGui_DrawList_AddCircleFilled(draw,px,py,3,envelope_color,12)
    local text_width=r.ImGui_CalcTextSize(c,label);local tx=align=="left" and px-text_width-8 or px+8;local ty=py+6
    r.ImGui_DrawList_AddRectFilled(draw,tx-3,ty-2,tx+text_width+3,ty+13,(C.panel&0xFFFFFF00)|0xEC,3)
    r.ImGui_DrawList_AddText(draw,tx,ty,C.text,label)
  end
  if show_adsr then
    r.ImGui_DrawList_AddLine(draw,sx,bottom_y,attack_x,top_y,envelope_color,envelope_width)
    r.ImGui_DrawList_AddLine(draw,attack_x,top_y,decay_x,sustain_y,envelope_color,envelope_width)
    r.ImGui_DrawList_AddLine(draw,decay_x,sustain_y,ex,sustain_y,(envelope_base&0xFFFFFF00)|(envelope_active and 0xE8 or 0x70),envelope_active and 1.8 or 1.0)
    envelope_handle(attack_x,top_y,"A","right")
    envelope_handle(decay_x,sustain_y,"D","right")
    envelope_handle(sustain_x,sustain_y,"S",sustain_x>x+width*.8 and "left" or "right")
  end
  local fade_in_seconds=envelope_math.time_seconds(fade_in,envelope_math.FADE_MAX_SECONDS)
  local fade_out_seconds=envelope_math.time_seconds(fade_out,envelope_math.FADE_MAX_SECONDS)
  local fi_x=sx+span*math.min(1,fade_in_seconds/trimmed_duration)
  local fo_x=ex-span*math.min(1,fade_out_seconds/trimmed_duration)
  local fade_active=self.wave_drag=="fade_in" or self.wave_drag=="fade_out" or self.wave_drag=="fade_in_curve" or self.wave_drag=="fade_out_curve"
  local fade_color=0x2DAA6200|(fade_active and 0xF0 or 0x88)
  local fade_fill=0x2DAA6218
  local fade_top=y+12
  local fi_mid_x=(sx+fi_x)*.5;local fo_mid_x=(fo_x+ex)*.5
  local fi_mid_y=bottom_y-(bottom_y-fade_top)*fade_in_curve
  local fo_mid_y=bottom_y-(bottom_y-fade_top)*fade_out_curve
  local function curve_point(x0,y0,xc,yc,x1,y1,t)
    local a=1-t
    return a*a*x0+2*a*t*xc+t*t*x1,a*a*y0+2*a*t*yc+t*t*y1
  end
  if fade_in>0 then r.ImGui_DrawList_AddRectFilled(draw,sx,y,fi_x,y+height,fade_fill,0) end
  if fade_out>0 then r.ImGui_DrawList_AddRectFilled(draw,fo_x,y,ex,y+height,fade_fill,0) end
  if fade_in>0 then
    local previous_x,previous_y=sx,bottom_y
    for segment=1,8 do
      local px,py=curve_point(sx,bottom_y,fi_mid_x,fi_mid_y,fi_x,fade_top,segment/8)
      r.ImGui_DrawList_AddLine(draw,previous_x,previous_y,px,py,fade_color,fade_active and 2 or 1.25)
      previous_x,previous_y=px,py
    end
  end
  if fade_out>0 then
    local previous_x,previous_y=fo_x,fade_top
    for segment=1,8 do
      local px,py=curve_point(fo_x,fade_top,fo_mid_x,fo_mid_y,ex,bottom_y,segment/8)
      r.ImGui_DrawList_AddLine(draw,previous_x,previous_y,px,py,fade_color,fade_active and 2 or 1.25)
      previous_x,previous_y=px,py
    end
  end
  if r.ImGui_DrawList_AddTriangleFilled then
    local trim_handle=(C.red&0xFFFFFF00)|(trim_active and 0xFF or 0xC0)
    r.ImGui_DrawList_AddTriangleFilled(draw,sx,y+height-1,sx+9,y+height-1,sx,y+height-10,trim_handle)
    r.ImGui_DrawList_AddTriangleFilled(draw,ex,y+height-1,ex-9,y+height-1,ex,y+height-10,trim_handle)
    -- Fade handles stay visible even at zero so the feature is discoverable.
    -- They sit on the top edge, while the green/red bottom triangles remain
    -- the trim handles.
    local fade_ink=fade_color
    local fade_out_ink=fade_color
    r.ImGui_DrawList_AddTriangleFilled(draw,fi_x,y+1,fi_x+8,y+1,fi_x,y+9,fade_ink)
    r.ImGui_DrawList_AddTriangleFilled(draw,fo_x,y+1,fo_x-8,y+1,fo_x,y+9,fade_out_ink)
    if fade_in>0 then r.ImGui_DrawList_AddCircleFilled(draw,fi_mid_x,fi_mid_y,4,fade_color,12) end
    if fade_out>0 then r.ImGui_DrawList_AddCircleFilled(draw,fo_mid_x,fo_mid_y,4,fade_color,12) end
  end
  r.ImGui_InvisibleButton(c,id or "##waveform",width,height)
  local candidates={{"start",sx,y+height-2},{"end",ex,y+height-2},{"fade_in",fi_x,y+8},{"fade_out",fo_x,y+8}}
  if fade_in>0 then candidates[#candidates+1]={"fade_in_curve",fi_mid_x,fi_mid_y} end
  if fade_out>0 then candidates[#candidates+1]={"fade_out_curve",fo_mid_x,fo_mid_y} end
  if show_adsr then
    candidates[#candidates+1]={"attack",attack_x,top_y};candidates[#candidates+1]={"decay",decay_x,sustain_y}
    candidates[#candidates+1]={"sustain",sustain_x,sustain_y}
  end
  local function nearest_handle()
    local mx,my=r.ImGui_GetMousePos(c);local nearest,distance="start",math.huge
    for _,candidate in ipairs(candidates) do local dx,dy=mx-candidate[2],my-candidate[3];local next_distance=dx*dx+dy*dy;if next_distance<distance then nearest,distance=candidate[1],next_distance end end
    return nearest
  end
  if r.ImGui_IsItemActivated(c) then
    self.wave_drag=nearest_handle()
  end
  local changed=false
  if r.ImGui_IsItemHovered(c) and r.ImGui_IsMouseClicked and r.ImGui_IsMouseClicked(c,1) then
    local target=nearest_handle()
    if target=="start" then start_pos=0 elseif target=="end" then end_pos=1 elseif target=="fade_in" then fade_in=0 elseif target=="fade_out" then fade_out=0 elseif target=="fade_in_curve" then fade_in_curve=DEFAULTS.fade_in_curve elseif target=="fade_out_curve" then fade_out_curve=DEFAULTS.fade_out_curve elseif target=="attack" then attack=DEFAULTS.attack elseif target=="decay" then decay=DEFAULTS.decay elseif target=="sustain" then sustain=DEFAULTS.sustain end
    changed=true
  end
  if r.ImGui_IsItemActive(c) and self.wave_drag then
    local mx,my=r.ImGui_GetMousePos(c);local point=math.max(0,math.min(1,(mx-x)/width))
    if self.wave_drag=="start" then local value=math.min(point,end_pos-.001);changed=value~=start_pos;start_pos=value
    elseif self.wave_drag=="end" then local value=math.max(point,start_pos+.001);changed=value~=end_pos;end_pos=value
    elseif self.wave_drag=="fade_in" then local seconds=math.max(0,math.min(envelope_math.FADE_MAX_SECONDS,(point-start_pos)/math.max(.001,end_pos-start_pos)*trimmed_duration));local value=envelope_math.time_control(seconds,envelope_math.FADE_MAX_SECONDS);changed=value~=fade_in;fade_in=value
    elseif self.wave_drag=="fade_out" then local seconds=math.max(0,math.min(envelope_math.FADE_MAX_SECONDS,(end_pos-point)/math.max(.001,end_pos-start_pos)*trimmed_duration));local value=envelope_math.time_control(seconds,envelope_math.FADE_MAX_SECONDS);changed=value~=fade_out;fade_out=value
    elseif self.wave_drag=="fade_in_curve" then local value=math.max(0,math.min(1,1-(my-fade_top)/math.max(1,mid-fade_top)));changed=value~=fade_in_curve;fade_in_curve=value
    elseif self.wave_drag=="fade_out_curve" then local value=math.max(0,math.min(1,1-(my-fade_top)/math.max(1,mid-fade_top)));changed=value~=fade_out_curve;fade_out_curve=value
    elseif self.wave_drag=="attack" then local clamped=math.max(sx,math.min(ex,mx));local seconds=(clamped-sx)/span*trimmed_duration/playback_rate;local value=envelope_math.time_control(seconds,envelope_math.ATTACK_MAX_SECONDS);changed=value~=attack;attack=value
    elseif self.wave_drag=="decay" then local clamped=math.max(attack_x,math.min(ex,mx));local seconds=(clamped-attack_x)/span*trimmed_duration/playback_rate;local value=envelope_math.time_control(seconds,envelope_math.DECAY_MAX_SECONDS);changed=value~=decay;decay=value
    elseif self.wave_drag=="sustain" then local value=math.max(0,math.min(1,1-(my-top_y)/math.max(1,bottom_y-top_y)));changed=value~=sustain;sustain=value end
  elseif not r.ImGui_IsMouseDown(c,0) then self.wave_drag=nil end
  local fade_summary=string.format("Fade In %s   Fade Out %s",
    envelope_math.format_time(envelope_math.time_seconds(fade_in,envelope_math.FADE_MAX_SECONDS)),
    envelope_math.format_time(envelope_math.time_seconds(fade_out,envelope_math.FADE_MAX_SECONDS)))
  local tooltip=show_adsr and string.format("Drag Start/End, fade triangles, or A/D/S handles\nA %s   D %s   S %s   R %s (generic)\n%s\nRight-click the nearest handle to reset it",
    envelope_value_text("attack",attack),envelope_value_text("decay",decay),envelope_value_text("sustain",sustain),envelope_value_text("release",release),fade_summary)
    or "Drag Start, End, or the small fade triangles\n"..fade_summary.."\nRight-click the nearest handle to reset it"
  self:tooltip(tooltip)
  return changed,start_pos,end_pos,attack,decay,sustain,release,fade_in,fade_out,fade_in_curve,fade_out_curve
end

function UI:sampler_controls()
  local r,c,app=self.host,self.ctx,self.app
  local pad=app:pad(); local controls=pad.default_controls
  local path=type(pad.sample)=="table" and pad.sample.path or pad.sample
  local avail=r.ImGui_GetContentRegionAvail(c)
  local trim_changed,trim_start,trim_end,attack,decay,sustain,release,fade_in,fade_out,fade_in_curve,fade_out_curve=self:waveform(path,avail,108,controls.sample_start or DEFAULTS.sample_start,controls.sample_end or DEFAULTS.sample_end,"##inspector_waveform",controls)
  if trim_changed then controls.sample_start,controls.sample_end,controls.attack,controls.decay,controls.sustain,controls.release,controls.fade_in,controls.fade_out,controls.fade_in_curve,controls.fade_out_curve=trim_start,trim_end,attack,decay,sustain,release,fade_in,fade_out,fade_in_curve,fade_out_curve;self:queue_live_pad_controls() end
  r.ImGui_Text(c,state.sample_label(pad))
  r.ImGui_SameLine(c);if self:icon_button("##wave_previous","previous","Previous sample",27,24) then app:cycle_sample(-1) end
  r.ImGui_SameLine(c);if self:icon_button("##wave_next","next","Next sample",27,24) then app:cycle_sample(1) end
  r.ImGui_SameLine(c);if self:icon_button("##wave_replace","load","Load or replace sample",27,24) then app:load_selected_sample() end
  r.ImGui_SameLine(c);if self:icon_button("##wave_clear","trash","Clear sample",27,24) then app:clear_selected_sample() end
  r.ImGui_SameLine(c);if self:button("NORMALIZE",82,24) then app:normalize_selected_sample() end
  r.ImGui_SameLine(c);if self:button("DETECT C",72,24) then app:detect_selected_pitch() end
  r.ImGui_SameLine(c);if self:icon_button("##wave_reset","reset","Reset sample controls",27,24) then app:reset_pad_controls() end
  r.ImGui_Separator(c)
  local fields={
    {label="GAIN",key="volume",minimum=0,maximum=1,step=.01},{label="PAN",key="pan",minimum=0,maximum=1,step=.01},{label="TUNE",key="pitch",minimum=0,maximum=1,step=.01},
    {label="START",key="sample_start",minimum=0,maximum=1,step=.005},{label="END",key="sample_end",minimum=0,maximum=1,step=.005},
    {label="ATTACK",key="attack",time_max=envelope.ATTACK_MAX_SECONDS,step_ms=1},
    {label="DECAY",key="decay",time_max=envelope.DECAY_MAX_SECONDS,step_ms=10},
    {label="SUSTAIN",key="sustain",sustain_db=true},
    {label="RELEASE",key="release",time_max=envelope.RELEASE_MAX_SECONDS,step_ms=1},
    {label="FADE IN",key="fade_in",time_max=envelope.FADE_MAX_SECONDS,step_ms=1},
    {label="FADE OUT",key="fade_out",time_max=envelope.FADE_MAX_SECONDS,step_ms=1},
  }
  local field_width=math.max(72,math.min(112,(avail-12)/4))
  for index,f in ipairs(fields) do
    if index>1 and (index-1)%4~=0 then r.ImGui_SameLine(c) end
    r.ImGui_BeginGroup(c)
    r.ImGui_TextDisabled(c,f.label)
    local current=controls[f.key]; if current==nil then current=DEFAULTS[f.key] end
    local changed,value
    if f.time_max then
      local milliseconds=envelope.time_seconds(current,f.time_max)*1000
      changed,value=self:double_field("##wave_"..f.key,milliseconds,0,f.time_max*1000,f.step_ms,"%.1f ms",field_width)
      if changed then controls[f.key]=envelope.time_control(value/1000,f.time_max) end
    elseif f.sustain_db then
      local db=envelope.sustain_db(current);if db==-math.huge then db=envelope.SUSTAIN_FLOOR_DB end
      changed,value=self:double_field("##wave_"..f.key,db,envelope.SUSTAIN_FLOOR_DB,0,.5,"%.1f dB",field_width)
      if changed then controls[f.key]=envelope.sustain_from_db(value) end
    else
      changed,value=self:double_field("##wave_"..f.key,current,f.minimum,f.maximum,f.step,"%.3f",field_width)
      if changed then controls[f.key]=value end
    end
    if changed then self:queue_live_pad_controls() end
    r.ImGui_EndGroup(c)
  end
  r.ImGui_Separator(c)
end

function UI:pads()
  local r,c,app=self.host,self.ctx,self.app
  self.pad_rects={}
  local first=(app.rack.selected_bank-1)*16+1
  local avail,avail_height=r.ImGui_GetContentRegionAvail(c)
  -- The compact waveform is optional vertical content. Drop it completely
  -- before squeezing the pad grid, then let the grid and controls reflow using
  -- the full remaining panel height.
  local show_quick_wave=avail_height>=430
  local quick_wave_height=show_quick_wave and math.max(90,math.min(120,avail_height-330)) or 0
  local top_height=avail_height-(show_quick_wave and quick_wave_height+8 or 0)
  local controls_reserve=66
  local layout_gap=3
  local bank_width=34
  -- Account for the bank-to-grid gap and the three inter-pad gaps exactly.
  -- The previous fixed 54 px allowance left an unintended strip on the right.
  local pad_width=math.max(54,(avail-bank_width-layout_gap-layout_gap*3)/4)
  local pad_height=math.max(42,math.min(62,math.floor((top_height-controls_reserve)/4)))
  local pad_grid_height=pad_height*4+layout_gap*3
  local bank_height=math.max(18,(pad_grid_height-layout_gap*7)/8)
  r.ImGui_BeginGroup(c)
  for bank=1,8 do if self:button(string.char(64+bank).."##inspectorbank",bank_width,bank_height,bank==app.rack.selected_bank and C.selected or nil) then app:set_bank(bank) end end
  r.ImGui_EndGroup(c);r.ImGui_SameLine(c);r.ImGui_BeginGroup(c)
  for row=0,3 do
    for col=0,3 do
      if col>0 then r.ImGui_SameLine(c) end
      local index=first+(3-row)*4+col; local pad=app:pad(index)
      local chosen=self.selected_pads[index]
      local label=string.format("%s\n%s##pad%d",note_name(pad_midi_note(index)),state.sample_label(pad):sub(1,12),index)
      local border=pad.sample~=false and pad_color(index,pad) or C.border
      local clicked=self:pad_button(label,pad_width,pad_height,border,index==app.selected_pad or chosen,self:pad_triggered(index))
      local sample_path=type(pad.sample)=="table" and pad.sample.path or pad.sample
      self:pad_waveform_overlay(sample_path,border)
      self:handle_pad_interaction(index,clicked,100);self:pad_drag_source(index);self:accept_sample_drop(index,true);self:pad_context_menu(index)
    end
  end
  r.ImGui_EndGroup(c);self:finish_pad_drag()
  r.ImGui_Separator(c)
  local pad=app:pad();local controls=pad.default_controls
  local control_row_x,control_row_y=r.ImGui_GetCursorPosX(c),r.ImGui_GetCursorPosY(c)
  local control_row_right=control_row_x+r.ImGui_GetContentRegionAvail(c)
  local compact_size=38
  local changed,value=self:knob("##padquickgain","GAIN",controls.volume or DEFAULTS.volume,DEFAULTS.volume,compact_size,{on_shift_click=function()app:normalize_selected_sample()end,shift_hint="Normalize"})
  if changed then self:apply_selected_pad_controls({volume=value}) end
  local pan_options={formatter=function(v) return string.format("%+.0f",(v-.5)*200) end}
  r.ImGui_SameLine(c,0,6);changed,value=self:knob("##padquickpan","PAN",controls.pan or DEFAULTS.pan,DEFAULTS.pan,compact_size,pan_options)
  if changed then self:apply_selected_pad_controls({pan=value}) end
  local transpose,cents=pad_pitch_values(controls)
  local pitch_mode=self.pad_pitch_mode=="tune" and "tune" or "transpose"
  local pitch_label=pitch_mode=="tune" and "TUNE" or "TRANS"
  local pitch_value=pitch_mode=="tune" and cents or transpose
  local pitch_options=pitch_mode=="tune"
    and {minimum=-100,maximum=100,wheel_step=1,label_color=C.text,label_clickable=true,on_shift_click=function()app:detect_selected_pitch()end,context_menu=function()self:pitch_context_menu()end,shift_hint="Detect pitch and snap to C",formatter=function(v)return string.format("%+.0f",v)end}
    or {minimum=-48,maximum=48,wheel_step=1,label_color=C.playhead,label_clickable=true,on_shift_click=function()app:detect_selected_pitch()end,context_menu=function()self:pitch_context_menu()end,shift_hint="Detect pitch and snap to C",formatter=function(v)return string.format("%+.0f",v)end}
  local pitch_label_clicked
  r.ImGui_SameLine(c,0,6);changed,value,pitch_label_clicked=self:knob("##padquickpitch",pitch_label,pitch_value,0,compact_size,pitch_options)
  if changed then
    local next_transpose,next_cents=transpose,cents
    if pitch_mode=="tune" then next_cents=value else next_transpose=value end
    self:apply_selected_pad_control_edit(function(target_controls) set_pad_pitch(target_controls,next_transpose,next_cents) end)
  end
  if pitch_label_clicked then self.pad_pitch_mode=pitch_mode=="tune" and "transpose" or "tune" end
  local utility_width=30*3+3*2
  -- Keep the two sends beside TRANS as a compact horizontal A/B pair.
  local send_size=26
  r.ImGui_SameLine(c,0,5);r.ImGui_BeginGroup(c)
  local send_a=tonumber(controls.reverb_send) or 0
  changed,value=self:knob("##padquicksenda","A",send_a,0,send_size,{minimum=0,maximum=1,wheel_step=.01,hide_label=true,inside_label="A",formatter=function(v)return string.format("%.0f%%",v*100)end,on_shift_click=function()app:show_track_fx_chain(app:aux_track("aux_a"))end,shift_hint="Shift-click: open AUX A FX chain"})
  if changed then self:apply_selected_pad_controls({reverb_send=value}) end
  r.ImGui_SameLine(c,0,3)
  local send_b=tonumber(controls.delay_send) or 0
  changed,value=self:knob("##padquicksendb","B",send_b,0,send_size,{minimum=0,maximum=1,wheel_step=.01,hide_label=true,inside_label="B",formatter=function(v)return string.format("%.0f%%",v*100)end,on_shift_click=function()app:show_track_fx_chain(app:aux_track("aux_b"))end,shift_hint="Shift-click: open AUX B FX chain"})
  if changed then self:apply_selected_pad_controls({delay_send=value}) end
  r.ImGui_EndGroup(c)
  local choke=self:pad_choke_value(pad)
  local choke_labels={"Off","Self"};for i=1,32 do choke_labels[#choke_labels+1]=tostring(i) end
  -- The choke selector is anchored against the utility buttons instead of
  -- flowing after the sound controls, which keeps the row stable at narrow
  -- widths.  Its text label is intentionally omitted.
  local choke_x=control_row_right-utility_width-6-62
  -- Include both send knobs and every explicit SameLine gap in the left-hand
  -- boundary. The old estimate counted only one send knob, so a scrollbar's
  -- reduced content width allowed the choke combo to move over send B.
  local sound_controls_right=control_row_x+compact_size*3+6*2+5+send_size*2+3
  r.ImGui_SetCursorPosX(c,math.max(sound_controls_right+5,choke_x))
  r.ImGui_SetCursorPosY(c,control_row_y)
  changed,value=self:combo_field("##padquickchoke",choke,table.concat(choke_labels,"\0").."\0",#choke_labels,62)
  if changed then
    self:set_pad_choke_value(self:pad_control_targets(),value)
  end
  -- Keep the compact utility controls independent of the knob/choke widths:
  -- one tight row pinned to the top-right, with M/S sharing its right edge.
  r.ImGui_SetCursorPosX(c,math.max(control_row_x,control_row_right-utility_width))
  r.ImGui_SetCursorPosY(c,control_row_y)
  local targets=pad.simultaneous_play_targets or {};local selected=self:selected_pad_indices()
  local link_hint=#targets>0 and string.format("Trigger link: %d pads. Click to unlink.",#targets+1) or (#selected>1 and string.format("Link %d selected pads",#selected) or "Select two or more pads to create a trigger link")
  if self:icon_button("##padquicklink","link",link_hint,30,26,#targets>0,nil,false,true) then
    if #targets>0 then app:link_pads({}) elseif #selected>1 then app:link_pads(selected) end
  end
  local group=app:round_robin_for_pad(app.selected_pad)
  r.ImGui_SameLine(c,0,3)
  local rr_hint=group and string.format("Round robin: %d pads. Click to remove.",#group.member_pad_ids) or (#selected>1 and string.format("Create round robin from %d selected pads",#selected) or "Select two or more pads to create round robin")
  if self:icon_button("##padquickrr","roundrobin",rr_hint,30,26,group~=nil,nil,false,true) then
    if group then app:remove_round_robin() elseif #selected>1 then app:make_round_robin(selected) end
  end
  if group and r.ImGui_IsItemClicked and r.ImGui_IsItemClicked(c,1) then r.ImGui_OpenPopup(c,"##quick_rr_settings") end
  if r.ImGui_BeginPopup(c,"##quick_rr_settings") then
    group=app:round_robin_for_pad(app.selected_pad)
    if group then
      r.ImGui_Text(c,"ROUND ROBIN SETTINGS");r.ImGui_Separator(c)
      local modes={"sequential","ping_pong","random","random_no_repeat"};local mode_index=0
      for i,item in ipairs(modes) do if item==group.mode then mode_index=i-1;break end end
      local did,next_value=r.ImGui_Combo(c,"Mode##quickrr",mode_index,table.concat(modes,"\0").."\0",#modes)
      if did then group.mode=modes[next_value+1];app:mark_dirty(false) end
      did,next_value=r.ImGui_SliderDouble(c,"Probability##quickrr",group.probability,0,100,"%.0f%%")
      if did then group.probability=next_value;app:mark_dirty(false) end
      local resets={"never","pattern","transport","trigger"};local reset_labels={"Never","Variation","Transport","Trigger"};local reset_index=0
      for i,item in ipairs(resets) do if item==group.reset_policy then reset_index=i-1;break end end
      did,next_value=r.ImGui_Combo(c,"Reset##quickrr",reset_index,table.concat(reset_labels,"\0").."\0",#reset_labels)
      if did then group.reset_policy=resets[next_value+1];app:mark_dirty(false) end
      did,next_value=r.ImGui_Checkbox(c,"Advance on skip##quickrr",group.advance_on_skip==true)
      if did then group.advance_on_skip=next_value;app:mark_dirty(false) end
      did,next_value=r.ImGui_Checkbox(c,"Advance each repeat##quickrr",group.advance_each_repeat==true)
      if did then group.advance_each_repeat=next_value;app:mark_dirty(false) end
      local master_index=app:pad_index_for_id(group.master_pad_id)
      r.ImGui_TextDisabled(c,string.format("%d pads  |  Master: %s",#group.member_pad_ids,master_index and note_name(pad_midi_note(master_index)) or "?"))
      if master_index~=app.selected_pad and r.ImGui_MenuItem(c,"Make Selected Pad Master") then app:set_round_robin_master(app.selected_pad) end
      if r.ImGui_MenuItem(c,"Remove Round Robin") then app:remove_round_robin() end
    else
      r.ImGui_TextDisabled(c,"No round robin assigned")
    end
    r.ImGui_EndPopup(c)
  end
  r.ImGui_SameLine(c,0,3)
  local selected_color=pad_color(app.selected_pad,pad)
  r.ImGui_PushStyleColor(c,r.ImGui_Col_Button(),selected_color)
  r.ImGui_PushStyleColor(c,r.ImGui_Col_ButtonHovered(),selected_color)
  r.ImGui_PushStyleColor(c,r.ImGui_Col_ButtonActive(),selected_color)
  local color_hit=r.ImGui_Button(c,"##padquickcolor",30,26)
  r.ImGui_PopStyleColor(c,3)
  if color_hit then r.ImGui_OpenPopup(c,"##padquickcolorpicker") end
  self:tooltip("Pad and lane color")
  if r.ImGui_BeginPopup(c,"##padquickcolorpicker") then
    r.ImGui_TextDisabled(c,"PAD COLOR")
    for color_index,hex in ipairs(PAD_HEX) do
      if color_index>1 then r.ImGui_SameLine(c) end
      local color=(tonumber(hex:sub(2),16)<<8)|0xFF
      if self:button("##quickpadcolor"..color_index,22,22,color) then
        local color_targets=self:selected_pad_indices();if #color_targets==0 then color_targets={app.selected_pad} end
        app:set_pad_colors(color_targets,hex);r.ImGui_CloseCurrentPopup(c)
      end
    end
    r.ImGui_EndPopup(c)
  end
  local control_bottom=control_row_y+52
  -- This utility row is independently right-anchored so adding the sampler
  -- shortcut cannot shift the existing knobs, choke, utility icons, or M/S.
  local output_width,output_gap=48,5
  r.ImGui_SetCursorPosX(c,math.max(control_row_x,control_row_right-41-output_gap-output_width))
  r.ImGui_SetCursorPosY(c,control_bottom-18)
  local function output_number(item,index)return item.id=="main" and 1 or tonumber(item.id:match("(%d+)$")) or index end
  local output_index=1;for i,item in ipairs(app.rack.outputs or {})do if item.id==pad.output_id then output_index=i;break end end
  local shown_output=output_number(app.rack.outputs[output_index],output_index)
      if self:centered_text_button("##padquickoutput","OUT "..shown_output,output_width,18,nil) then r.ImGui_OpenPopup(c,"##padquickoutput_select") end
  local output_changed,output_value=self:wheel_adjust(shown_output,1,self.max_outputs,1,true,false)
  if output_changed then app:set_pad_output_number(self:pad_control_targets(),output_value) end
  self:tooltip(string.format("Pad output 1–%d — unused output tracks are removed automatically",self.max_outputs))
  if r.ImGui_BeginPopup(c,"##padquickoutput_select") then
    for number=1,self.max_outputs do
      if r.ImGui_Selectable(c,"Output "..number.."##pad_output_select_"..number,number==shown_output) then
        app:set_pad_output_number(self:pad_control_targets(),number);r.ImGui_CloseCurrentPopup(c)
      end
    end
    r.ImGui_EndPopup(c)
  end
  r.ImGui_SetCursorPosX(c,math.max(control_row_x,control_row_right-41))
  r.ImGui_SetCursorPosY(c,control_bottom-18)
  if self:centered_text_button("##padquickmute","M",20,18,app:pad_muted(app.selected_pad) and C.red or nil) then app:set_pad_mute_many(self:pad_control_targets(),not app:pad_muted(app.selected_pad)) end
  r.ImGui_SameLine(c,0,1)
  if self:centered_text_button("##padquicksolo","S",20,18,app:pad_soloed(app.selected_pad) and C.accent or nil) then app:set_pad_solo_many(self:pad_control_targets(),not app:pad_soloed(app.selected_pad)) end
  r.ImGui_SetCursorPosY(c,math.max(r.ImGui_GetCursorPosY(c),control_bottom))
  -- SetCursorPos is used only to place the compact M/S controls inside the
  -- row's existing reserve. Submit a zero-width item at that boundary so
  -- ReaImGui can account for it without adding visible padding.
  r.ImGui_Dummy(c,0,1)
  if show_quick_wave then
    r.ImGui_Separator(c)
    local path=type(pad.sample)=="table" and pad.sample.path or pad.sample
    local changed,start_pos,end_pos,attack,decay,sustain,release,fade_in,fade_out,fade_in_curve,fade_out_curve=self:waveform(path,avail,quick_wave_height,controls.sample_start or DEFAULTS.sample_start,controls.sample_end or DEFAULTS.sample_end,"##quick_pad_waveform",controls)
    if changed then
      self:apply_selected_pad_control_edit(function(target_controls)
        target_controls.sample_start,target_controls.sample_end,target_controls.attack,target_controls.decay,target_controls.sustain,target_controls.release,target_controls.fade_in,target_controls.fade_out,target_controls.fade_in_curve,target_controls.fade_out_curve=start_pos,end_pos,attack,decay,sustain,release,fade_in,fade_out,fade_in_curve,fade_out_curve
      end,true)
    end
     r.ImGui_Separator(c)
     r.ImGui_TextDisabled(c,"PLAYBACK")
     r.ImGui_SameLine(c,0,8)
     -- Use the same restrained, underlined tabs as the lane global links,
     -- while spelling these important playback modes out in full.
     local playback_gap=4
     local function playback_tab(id,label,width,selected,tooltip)
       r.ImGui_PushStyleColor(c,r.ImGui_Col_Button(),C.panel2)
       r.ImGui_PushStyleColor(c,r.ImGui_Col_ButtonHovered(),C.hover)
       r.ImGui_PushStyleColor(c,r.ImGui_Col_ButtonActive(),C.button)
       r.ImGui_PushStyleColor(c,r.ImGui_Col_Text(),selected and C.text or C.muted)
       local hit=r.ImGui_Button(c,label.."##"..id,width,26)
       r.ImGui_PopStyleColor(c,4)
       local x1,y1=r.ImGui_GetItemRectMin(c);local x2,y2=r.ImGui_GetItemRectMax(c)
       if selected then r.ImGui_DrawList_AddLine(r.ImGui_GetWindowDrawList(c),x1+6,y2-2,x2-6,y2-2,C.playhead,2) end
       self:tooltip(tooltip)
       return hit
     end
     local gate_mode=controls.playback_mode=="gate"
     if playback_tab("quick_playback_one","ONE SHOT",76,not gate_mode,"One Shot: play the full sample") then self:apply_selected_pad_controls({playback_mode="one_shot"},true) end
     r.ImGui_SameLine(c,0,playback_gap)
     if playback_tab("quick_playback_gate","GATE",52,gate_mode,"Gate: follow note length and note-off") then self:apply_selected_pad_controls({playback_mode="gate"},true) end
     r.ImGui_SameLine(c,0,playback_gap)
     local envelope_enabled=controls.envelope_enabled==true or controls.envelope_enabled==1
     if playback_tab("quick_envelope_enabled","ADSR",52,envelope_enabled,"ADSR: use the waveform envelope") then self:apply_selected_pad_controls({envelope_enabled=not envelope_enabled},true) end
     r.ImGui_SameLine(c,0,playback_gap)
     local slide_retrigger=controls.slide_retrigger~=false
     if playback_tab("quick_slide_retrigger","RETRIG",66,slide_retrigger,"Retrigger slides from the sample start") then self:apply_selected_pad_controls({slide_retrigger=not slide_retrigger,playback_mode="gate"},true) end
 
     -- Start the engine-control footer just below the playback icons without
     -- adding a full extra line of vertical padding.
     local _,playback_bottom_screen=r.ImGui_GetItemRectMax(c)
     local _,window_screen_y=r.ImGui_GetWindowPos(c)
     -- Cursor positions are content coordinates, while item/window positions
     -- above are screen coordinates. Restore the child scroll offset so the
     -- knob row remains below PLAYBACK when a condensed inspector is scrolled.
     local scroll_y=r.ImGui_GetScrollY and r.ImGui_GetScrollY(c) or 0
     local knob_row_y=playback_bottom_screen-window_screen_y+scroll_y+4
     -- Use the same audible timeline as the waveform: source duration after
     -- trim, divided by the pitch playback rate. Knob travel therefore never
     -- extends into time that cannot occur for the selected sample.
     local source_duration=math.max(.001,(self.waveform_duration and self.waveform_duration[path or ""]) or 1)
     local trim_start=math.max(0,math.min(1,tonumber(controls.sample_start) or DEFAULTS.sample_start))
     local trim_end=math.max(trim_start,math.min(1,tonumber(controls.sample_end) or DEFAULTS.sample_end))
     local duration_transpose,duration_cents=pad_pitch_values(controls)
     local playback_rate=math.max(.000001,2^((duration_transpose+duration_cents/100)/12))
     local playable_duration=math.max(.001,source_duration*math.max(.001,trim_end-trim_start)/playback_rate)
     local attack_seconds=envelope.time_seconds(tonumber(controls.attack) or DEFAULTS.attack,envelope.ATTACK_MAX_SECONDS)
     local attack_limit=envelope.time_control(math.min(envelope.ATTACK_MAX_SECONDS,playable_duration),envelope.ATTACK_MAX_SECONDS)
     local decay_limit=envelope.time_control(math.min(envelope.DECAY_MAX_SECONDS,math.max(0,playable_duration-attack_seconds)),envelope.DECAY_MAX_SECONDS)
     local release_limit=envelope.time_control(math.min(envelope.RELEASE_MAX_SECONDS,playable_duration),envelope.RELEASE_MAX_SECONDS)
     local gate_release_limit=envelope.time_control(math.min(envelope.GATE_RELEASE_MAX_SECONDS,playable_duration),envelope.GATE_RELEASE_MAX_SECONDS)
     local engine_knobs={
      {id="gate_release",label="GREL",value=math.min(gate_release_limit,envelope.time_control((tonumber(controls.gate_release_ms) or 10)/1000,envelope.GATE_RELEASE_MAX_SECONDS)),default=math.min(gate_release_limit,envelope.time_control(.01,envelope.GATE_RELEASE_MAX_SECONDS)),min=0,max=gate_release_limit,step=.01,
        format=function(v)return envelope.format_time(envelope.time_seconds(v,envelope.GATE_RELEASE_MAX_SECONDS))end,
        store=function(target,v)target.gate_release_ms=envelope.time_seconds(v,envelope.GATE_RELEASE_MAX_SECONDS)*1000 end},
      {id="attack",label="A",value=math.min(attack_limit,tonumber(controls.attack) or DEFAULTS.attack),default=math.min(attack_limit,DEFAULTS.attack),min=0,max=attack_limit,step=.01,
        format=function(v)return envelope_value_text("attack",v)end,store=function(target,v)target.attack=v;target.envelope_enabled=true end},
      {id="decay",label="D",value=math.min(decay_limit,tonumber(controls.decay) or DEFAULTS.decay),default=math.min(decay_limit,DEFAULTS.decay),min=0,max=decay_limit,step=.01,
        format=function(v)return envelope_value_text("decay",v)end,store=function(target,v)target.decay=v;target.envelope_enabled=true end},
      {id="sustain",label="S",value=tonumber(controls.sustain) or DEFAULTS.sustain,default=DEFAULTS.sustain,min=0,max=1,step=.01,
        format=function(v)return envelope_value_text("sustain",v)end,store=function(target,v)target.sustain=v;target.envelope_enabled=true end},
      {id="release",label="R",value=math.min(release_limit,tonumber(controls.release) or DEFAULTS.release),default=math.min(release_limit,DEFAULTS.release),min=0,max=release_limit,step=.01,
        format=function(v)return envelope_value_text("release",v)end,store=function(target,v)target.release=v;target.envelope_enabled=true end},
    }
    local knob_count=#engine_knobs
    local footer_width=math.max(0,control_row_right-control_row_x)
    -- Five equal-width columns give the essential envelope controls room to
    -- breathe while keeping their centers evenly distributed across the row.
    local column_width=math.floor(footer_width/knob_count)
    local knob_size=math.max(32,math.min(46,column_width-8))
    local knob_row_width=column_width*knob_count
    local knob_row_start=control_row_x+math.max(0,(footer_width-knob_row_width)*.5)
    for index,item in ipairs(engine_knobs) do
      r.ImGui_SetCursorPosX(c,knob_row_start+(index-1)*column_width+(column_width-knob_size)*.5)
      r.ImGui_SetCursorPosY(c,knob_row_y)
      local did,next_value=self:knob("##quick_engine_"..item.id,item.label,item.value,item.default,knob_size,{minimum=item.min,maximum=item.max,wheel_step=item.step,formatter=item.format})
      if did then self:apply_selected_pad_control_edit(function(target_controls) item.store(target_controls,next_value) end,true) end
    end
  end
end

function UI:mixer_strip(index,width,height)
  local r,c,app=self.host,self.ctx,self.app
  local pad=app:pad(index);local controls=pad.default_controls or {}
  local visible=self:begin_panel("##mixer_strip_"..index,width,height,no_scroll_flags(r))
  if visible then
    local color=pad_color(index,pad)
    local accent_x,accent_y=r.ImGui_GetCursorScreenPos(c)
    -- A substantial color footer identifies the channel without turning the
    -- full strip into a rainbow or stealing horizontal meter space.
    r.ImGui_DrawList_AddRectFilled(r.ImGui_GetWindowDrawList(c),accent_x,accent_y+height-15,accent_x+width-16,accent_y+height-9,(color&0xFFFFFF00)|0xE8,0)
    local pad_name=(pad.name or ("Pad "..index)):gsub("[\r\n]"," ")
    if #pad_name>13 then pad_name=pad_name:sub(1,12).."…" end
    r.ImGui_PushStyleVar(c,r.ImGui_StyleVar_FrameRounding(),0)
    local name_selected=self.selected_pads[index] or index==app.selected_pad
    r.ImGui_PushStyleColor(c,r.ImGui_Col_Text(),name_selected and (C.selected_text or C.text) or C.text)
    r.ImGui_PushStyleColor(c,r.ImGui_Col_Button(),name_selected and C.selected or C.panel2)
    r.ImGui_PushStyleColor(c,r.ImGui_Col_ButtonHovered(),name_selected and C.selected or C.hover)
    r.ImGui_PushStyleColor(c,r.ImGui_Col_ButtonActive(),C.selected)
    local name_hit=r.ImGui_Button(c,pad_name.."##mixselect"..index,-1,20)
    r.ImGui_PopStyleColor(c,4);r.ImGui_PopStyleVar(c)
    local badge_draw=r.ImGui_GetWindowDrawList(c);local badge_x1,badge_y1=r.ImGui_GetItemRectMin(c);local _,badge_y2=r.ImGui_GetItemRectMax(c)
    r.ImGui_DrawList_AddRectFilled(badge_draw,badge_x1,badge_y1,badge_x1+3,badge_y2,color,0)
    local name_activated=r.ImGui_IsItemActivated and r.ImGui_IsItemActivated(c) or false
    if name_activated or ((not r.ImGui_IsItemActivated) and name_hit) then
      local ctrl,shift=self:key_modifiers();self:select_pad_for_interaction(index,ctrl,shift)
    end
    r.ImGui_Separator(c)
    local function targets()
      local selected=self:selected_pad_indices()
      return self.selected_pads[index] and #selected>0 and selected or {index}
    end
    local function set_control(key,value)
      for _,target in ipairs(targets()) do
        local target_controls=app:pad(target).default_controls or {};app:pad(target).default_controls=target_controls
        target_controls[key]=value;self:queue_live_pad_controls(target)
      end
    end
    local outputs={};for i=1,self.max_outputs do outputs[i]="OUT "..i end
    local output_index=pad.output_id=="main" and 1 or tonumber(tostring(pad.output_id):match("(%d+)$")) or 1
    r.ImGui_SetNextItemWidth(c,-1)
    local changed,value=r.ImGui_Combo(c,"##mixout"..index,output_index-1,table.concat(outputs,"\0").."\0",#outputs)
    if changed then app:set_pad_output_number(targets(),value+1) end
    local pan=controls.pan;if pan==nil then pan=DEFAULTS.pan end
    changed,pan=self:pan_slider("##mixpan"..index,pan,-1)
    if changed then set_control("pan",pan) end
    local show_sends=height>=300
    local mixer_row_x,mixer_row_y=r.ImGui_GetCursorPosX(c),r.ImGui_GetCursorPosY(c)
    local mixer_row_screen_x=r.ImGui_GetCursorScreenPos(c)
    local mixer_row_width=r.ImGui_GetContentRegionAvail(c)
    local left,right=app:pad_meter(index);local meter_h=math.max(100,height-(show_sends and 146 or 111))
    self:stereo_meter("pad"..index,left,right,30,meter_h)
    r.ImGui_SameLine(c)
    local volume=controls.volume;if volume==nil then volume=DEFAULTS.volume end
    r.ImGui_PushStyleColor(c,r.ImGui_Col_FrameBg(),C.step)
    r.ImGui_PushStyleColor(c,r.ImGui_Col_FrameBgHovered(),C.step)
    r.ImGui_PushStyleColor(c,r.ImGui_Col_FrameBgActive(),C.step)
    r.ImGui_PushStyleColor(c,r.ImGui_Col_SliderGrab(),0x00000000)
    r.ImGui_PushStyleColor(c,r.ImGui_Col_SliderGrabActive(),0x00000000)
    local pad_max_db=20*math.log(4,10);local fader_value=fader_position((volume/.5)^2,pad_max_db)
    changed,fader_value=r.ImGui_VSliderDouble(c,"##mixfader"..index,16,meter_h,fader_value,0,1,"")
    r.ImGui_PopStyleColor(c,5)
    if changed then volume=.5*math.sqrt(fader_amplitude(fader_value,pad_max_db)) end
    local wheel_changed,wheel_value=self:wheel_adjust(volume,0,1,.01,false,false)
    if wheel_changed then changed,volume=true,wheel_value end
    if r.ImGui_IsItemHovered(c) and r.ImGui_IsMouseClicked and r.ImGui_IsMouseClicked(c,1) then changed,volume=true,DEFAULTS.volume end
    self:tooltip("Pad level — mouse wheel\nRight-click to reset")
    if changed then set_control("volume",volume) end
    fader_value=fader_position((volume/.5)^2,pad_max_db)
    local draw=r.ImGui_GetWindowDrawList(c);local fx1,fy1=r.ImGui_GetItemRectMin(c);local fx2,fy2=r.ImGui_GetItemRectMax(c);local unity_y=fy2-(fy2-fy1)*fader_position(1,pad_max_db)
    r.ImGui_DrawList_AddLine(draw,fx1-2,unity_y,fx2+2,unity_y,C.text,1)
    self:fader_cap(fader_value,0,1,color)
    -- Pin the utility column to the padded right edge. Together with the
    -- channel's reserved width, this leaves a deliberate gap from the cap.
    local utility_left=fx2+4
    local utility_right=mixer_row_screen_x+mixer_row_width
    local utility_screen_x=math.max(utility_left,utility_right-23)
    r.ImGui_SameLine(c)
    r.ImGui_SetCursorPosX(c,mixer_row_x+(utility_screen_x-mixer_row_screen_x))
    r.ImGui_SetCursorPosY(c,mixer_row_y)
    r.ImGui_BeginGroup(c)
    r.ImGui_PushStyleColor(c,r.ImGui_Col_Button(),color)
    r.ImGui_PushStyleColor(c,r.ImGui_Col_ButtonHovered(),color)
    r.ImGui_PushStyleColor(c,r.ImGui_Col_ButtonActive(),color)
    local color_hit=r.ImGui_Button(c,"##mixcolor"..index,20,18)
    r.ImGui_PopStyleColor(c,3)
    if color_hit then r.ImGui_OpenPopup(c,"##mixcolorpicker"..index) end
    self:tooltip("Pad color")
    if r.ImGui_BeginPopup(c,"##mixcolorpicker"..index) then
      r.ImGui_TextDisabled(c,"PAD COLOR")
      for color_index,hex in ipairs(PAD_HEX) do
        if color_index>1 then r.ImGui_SameLine(c) end
        local choice=(tonumber(hex:sub(2),16)<<8)|0xFF
        if self:button("##mixcolorchoice"..index.."_"..color_index,22,22,choice) then app:set_pad_colors(targets(),hex);r.ImGui_CloseCurrentPopup(c) end
      end
      r.ImGui_EndPopup(c)
    end
    -- Mixer mute/solo always targets the strip that was clicked. Pad
    -- multi-selection is an editing aid and must not make channel state
    -- toggles depend on hidden selections elsewhere in the bank.
    if self:button("M##mixmute"..index,20,24,app:pad_muted(index) and C.red or nil) then app:set_pad_mute_many({index},not app:pad_muted(index)) end
    if self:button("S##mixsolo"..index,20,24,app:pad_soloed(index) and C.accent or nil) then app:set_pad_solo_many({index},not app:pad_soloed(index)) end
    r.ImGui_EndGroup(c)
    r.ImGui_Text(c,string.format("%.1f dB",20*math.log(math.max(.0001,(volume/.5)^2),10)))
    if show_sends then
      local reverb_send=controls.reverb_send or 0
      changed,reverb_send=self:knob("##mixrev"..index,"A",reverb_send,0,30,{hide_label=true,inside_label="A",on_shift_click=function()app:show_track_fx_chain(app:aux_track("aux_a"))end,shift_hint="Shift-click: open AUX A FX chain"})
      if changed then set_control("reverb_send",reverb_send) end
      r.ImGui_SameLine(c);local delay_send=controls.delay_send or 0
      changed,delay_send=self:knob("##mixdelay"..index,"B",delay_send,0,30,{hide_label=true,inside_label="B",on_shift_click=function()app:show_track_fx_chain(app:aux_track("aux_b"))end,shift_hint="Shift-click: open AUX B FX chain"})
      if changed then set_control("delay_send",delay_send) end
    end
    -- Empty channel space is also a selection target. Interactive widgets keep
    -- their own clicks, so selecting a strip never changes a control value.
    if r.ImGui_IsWindowHovered and r.ImGui_IsWindowHovered(c) and r.ImGui_IsMouseClicked and r.ImGui_IsMouseClicked(c,0)
      and (not r.ImGui_IsAnyItemHovered or not r.ImGui_IsAnyItemHovered(c)) then
      local ctrl,shift=self:key_modifiers();self:select_pad_for_interaction(index,ctrl,shift)
    end
  end
  self:end_panel(visible)
end

function UI:reverb_settings()
  local r,c,app=self.host,self.ctx,self.app
  r.ImGui_TextDisabled(c,"REVERB")
  local enabled=app:send_fx_value(9)>=.5
  if self:button("ENABLED##reverb_enabled",120,24,enabled and C.accent or nil) then app:set_send_fx_value(9,enabled and 0 or 1) end
  for _,spec in ipairs({{"Size",1,0,1,.7},{"Decay",2,0,.99,.65},{"Damping",3,0,1,.45}}) do
    r.ImGui_TextDisabled(c,spec[1]);local value=app:send_fx_value(spec[2]);local changed,new=self:wheel_box("reverb"..spec[2],value,spec[3],spec[4],.01,"%.2f",120,false,spec[1],spec[5])
    if changed then app:set_send_fx_value(spec[2],new) end
  end
end

function UI:delay_settings()
  local r,c,app=self.host,self.ctx,self.app
  r.ImGui_TextDisabled(c,"DELAY")
  local labels=table.concat({"1/4","1/8","1/8 dotted","1/16","1/16 dotted","1/32","1/4 triplet"},"\0").."\0\0"
  local division=math.floor(app:send_fx_value(5)+.5);local changed,value=self:combo_field("Division##delay",division,labels,7,120)
  if r.ImGui_IsItemClicked and r.ImGui_IsItemClicked(c,1) then changed,value=true,3 end
  if changed then app:set_send_fx_value(5,value) end
  for _,spec in ipairs({{"Feedback",6,0,.92,.35},{"Tone",7,0,1,.55}}) do
    r.ImGui_TextDisabled(c,spec[1]);value=app:send_fx_value(spec[2]);changed,value=self:wheel_box("delay"..spec[2],value,spec[3],spec[4],.01,"%.2f",120,false,spec[1],spec[5])
    if changed then app:set_send_fx_value(spec[2],value) end
  end
  local pingpong=app:send_fx_value(8)>=.5;if self:button("PING PONG##delay_mode",120,24,pingpong and C.accent or nil) then app:set_send_fx_value(8,pingpong and 0 or 1) end
end

function UI:mixer_master_strip(width,height)
  local r,c,app=self.host,self.ctx,self.app
  local visible=self:begin_panel("##mixer_master",width,height,no_scroll_flags(r))
  if visible then
    r.ImGui_TextColored(c,C.accent,"MASTER")
    r.ImGui_Separator(c)
    local track=app:master_track();local left=track and r.Track_GetPeakInfo and math.max(0,r.Track_GetPeakInfo(track,0)) or 0
    local right=track and r.Track_GetPeakInfo and math.max(0,r.Track_GetPeakInfo(track,1)) or 0
    local now=r.time_precise();local raw=math.max(left,right);local held=self.mixer_master_meter_hold or 0;local last=self.mixer_master_meter_time or now
    if raw>=held then held=raw;self.mixer_master_peak_time=now elseif now-(self.mixer_master_peak_time or now)>.75 then held=math.max(raw,held-(now-last)*1.8) end
    self.mixer_master_meter_hold=held;self.mixer_master_meter_time=now
    local meter=math.min(1,held);local x,y=r.ImGui_GetCursorScreenPos(c);local h=math.max(120,height-225)
    r.ImGui_Dummy(c,14,h);local draw=r.ImGui_GetWindowDrawList(c)
    r.ImGui_DrawList_AddRectFilled(draw,x,y,x+12,y+h,C.panel2,2)
    r.ImGui_DrawList_AddRectFilled(draw,x+1,y+h-(h-2)*meter,x+11,y+h-1,meter>.92 and C.red or C.accent,1)
    r.ImGui_DrawList_AddLine(draw,x-2,y,x+14,y,C.text,1)
    r.ImGui_SameLine(c)
    local volume=math.max(0,math.min(2,app:master_value("D_VOL")))
    local changed,value=r.ImGui_VSliderDouble(c,"##mixer_master_fader",34,h,volume,0,2,"")
    local wheel_changed,wheel_value=self:wheel_adjust(value,0,2,.02,false,false)
    if wheel_changed then changed,value=true,wheel_value end
    if r.ImGui_IsItemHovered(c) and r.ImGui_IsMouseClicked and r.ImGui_IsMouseClicked(c,1) then changed,value=true,1 end
    self:tooltip("Master level — mouse wheel\nRight-click to reset to unity")
    if changed then app:set_master_value("D_VOL",value) end
    local fx1,fy1=r.ImGui_GetItemRectMin(c);local fx2,fy2=r.ImGui_GetItemRectMax(c);local unity_y=fy2-(fy2-fy1)*.5
    r.ImGui_DrawList_AddLine(draw,fx1-2,unity_y,fx2+2,unity_y,C.text,1)
    if held>=1 then self.mixer_master_clip_until=r.time_precise()+2.5 end
    if r.time_precise()<(self.mixer_master_clip_until or 0) then r.ImGui_TextColored(c,C.red,"CLIP") end
    r.ImGui_Text(c,string.format("%.1f dB",20*math.log(math.max(.0001,volume),10)))
    if self:button("M##mixer_master_mute",32,24,app:master_value("B_MUTE")>0 and C.red or nil) then app:toggle_master_mute() end
    local clip_enabled=app:clipper_value(2)>=.5
    r.ImGui_SameLine(c);if self:button("CLIP##mixer_master_clip",43,24,clip_enabled and C.accent or nil) then app:set_clipper_value(2,clip_enabled and 0 or 1) end
    if r.ImGui_BeginPopupContextItem and r.ImGui_BeginPopupContextItem(c,"##master_clip_settings") then
      r.ImGui_TextDisabled(c,"SOFT CLIPPER")
      local threshold=app:clipper_value(0);local changed,value=self:double_field("Threshold##mixer_clip_threshold",threshold,-18,0,.1,"%.1f dB",132)
      if changed then app:set_clipper_value(0,value) end
      local post=app:clipper_value(1);changed,value=self:double_field("Post Gain##mixer_clip_post",post,-18,12,.1,"%.1f dB",132)
      if changed then app:set_clipper_value(1,value) end
      r.ImGui_EndPopup(c)
    end
    self:tooltip("Click to enable/bypass. Right-click for threshold and post gain.")
    r.ImGui_Separator(c);r.ImGui_TextDisabled(c,"RETURNS")
    local rev=app:send_fx_value(0);local changed,value,label_clicked=self:knob("##mixer_rev_return","REV",rev,-12,38,{minimum=-60,maximum=6,wheel_step=.5,formatter=function(v)return string.format("%.1f dB",v)end,label_clickable=true,label_color=C.playhead})
    if changed then app:set_send_fx_value(0,value) end
    if label_clicked then r.ImGui_OpenPopup(c,"##master_reverb_settings") end
    r.ImGui_SameLine(c);local dly=app:send_fx_value(4);changed,value,label_clicked=self:knob("##mixer_dly_return","DLY",dly,-12,38,{minimum=-60,maximum=6,wheel_step=.5,formatter=function(v)return string.format("%.1f dB",v)end,label_clickable=true,label_color=C.playhead})
    if changed then app:set_send_fx_value(4,value) end
    if label_clicked then r.ImGui_OpenPopup(c,"##master_delay_settings") end
    if r.ImGui_BeginPopup(c,"##master_reverb_settings") then self:reverb_settings();r.ImGui_EndPopup(c) end
    if r.ImGui_BeginPopup(c,"##master_delay_settings") then self:delay_settings();r.ImGui_EndPopup(c) end
  end
  self:end_panel(visible)
end

function UI:mixer_bus_strip(id,label,track,width,height,output)
  local r,c,app=self.host,self.ctx,self.app
  local visible=self:begin_panel("##mixer_bus_"..id,width,height,no_scroll_flags(r))
  if visible then
    r.ImGui_TextColored(c,id=="master" and C.accent or C.text,label)
    r.ImGui_Separator(c)
    local pan=math.max(0,math.min(1,(app:track_value(track,"D_PAN",0)+1)/2))
    local changed,value=self:pan_slider("##buspan"..id,pan,-1)
    if changed then app:set_track_value(track,"D_PAN",value*2-1) end
    -- Every fixed strip uses the same tall meter/fader span. Output send knobs
    -- consume the otherwise-empty footer instead of shortening OUT faders.
    local mixer_row_x,mixer_row_y=r.ImGui_GetCursorPosX(c),r.ImGui_GetCursorPosY(c)
    local mixer_row_screen_x=r.ImGui_GetCursorScreenPos(c)
    local mixer_row_width=r.ImGui_GetContentRegionAvail(c)
    local left,right=app:track_meter(track);local meter_h=math.max(120,height-70)
    self:stereo_meter("bus"..id,left,right,30,meter_h)
    r.ImGui_SameLine(c)
    local volume=math.max(0,math.min(2,app:track_value(track,"D_VOL",1)))
    r.ImGui_PushStyleColor(c,r.ImGui_Col_FrameBg(),C.step)
    r.ImGui_PushStyleColor(c,r.ImGui_Col_FrameBgHovered(),C.step)
    r.ImGui_PushStyleColor(c,r.ImGui_Col_FrameBgActive(),C.step)
    r.ImGui_PushStyleColor(c,r.ImGui_Col_SliderGrab(),0x00000000)
    r.ImGui_PushStyleColor(c,r.ImGui_Col_SliderGrabActive(),0x00000000)
    local bus_max_db=20*math.log(2,10);local fader_value=fader_position(volume,bus_max_db)
    changed,fader_value=r.ImGui_VSliderDouble(c,"##busfader"..id,16,meter_h,fader_value,0,1,"")
    r.ImGui_PopStyleColor(c,5)
    if changed then value=fader_amplitude(fader_value,bus_max_db) else value=volume end
    local wheel_changed,wheel_value=self:wheel_adjust(value,0,2,.02,false,false);if wheel_changed then changed,value=true,wheel_value end
    if r.ImGui_IsItemHovered(c) and r.ImGui_IsMouseClicked and r.ImGui_IsMouseClicked(c,1) then changed,value=value~=1,1 end
    if changed then app:set_track_value(track,"D_VOL",value) end
    fader_value=fader_position(value,bus_max_db)
    local draw=r.ImGui_GetWindowDrawList(c);local fx1,fy1=r.ImGui_GetItemRectMin(c);local fx2,fy2=r.ImGui_GetItemRectMax(c);local unity_y=fy2-(fy2-fy1)*fader_position(1,bus_max_db)
    r.ImGui_DrawList_AddLine(draw,fx1-2,unity_y,fx2+2,unity_y,C.text,1)
    self:fader_cap(fader_value,0,1)
    local utility_left=fx2+4
    local utility_right=mixer_row_screen_x+mixer_row_width
    local utility_screen_x=math.max(utility_left,utility_right-23)
    r.ImGui_SameLine(c)
    r.ImGui_SetCursorPosX(c,mixer_row_x+(utility_screen_x-mixer_row_screen_x))
    r.ImGui_SetCursorPosY(c,mixer_row_y)
    r.ImGui_BeginGroup(c)
    local bus_muted=app:track_value(track,"B_MUTE",0)>0
    local bus_soloed=app:track_value(track,"I_SOLO",0)>0
    if self:button("M##busmute"..id,20,22,bus_muted and C.red or nil) then app:set_mixer_track_mute(track,not bus_muted) end
    if self:button("S##bussolo"..id,20,22,bus_soloed and C.accent or nil) then app:set_mixer_track_solo(track,not bus_soloed) end
    local fx_count=app:track_fx_count(track)
    if self:button("FX##busfx"..id,20,22,fx_count>0 and C.selected or nil) then app:show_track_fx_chain(track) end
    self:tooltip(fx_count==0 and "Open empty FX chain" or ("Open FX chain ("..fx_count..")"))
    if output then
      -- Keep output sends in a low footer so their small knobs only cross the
      -- quiet bottom of the fader travel instead of its normal working range.
      r.ImGui_SetCursorPosY(c,math.max(r.ImGui_GetCursorPosY(c),height-66))
      local send_a=output.aux_a_send or 0;changed,value=self:knob("##outauxa"..id,"A",send_a,0,20,{hide_label=true,inside_label="A",on_shift_click=function()app:show_track_fx_chain(app:aux_track("aux_a"))end,shift_hint="Shift-click: open AUX A FX chain"})
      if changed then app:set_output_aux_send(output,"aux_a_send",value) end
      local send_b=output.aux_b_send or 0;changed,value=self:knob("##outauxb"..id,"B",send_b,0,20,{hide_label=true,inside_label="B",on_shift_click=function()app:show_track_fx_chain(app:aux_track("aux_b"))end,shift_hint="Shift-click: open AUX B FX chain"})
      if changed then app:set_output_aux_send(output,"aux_b_send",value) end
    end
    r.ImGui_EndGroup(c)
    r.ImGui_Text(c,string.format("%.1f dB",20*math.log(math.max(.0001,volume),10)))
  end
  self:end_panel(visible)
end

function UI:mixer_view(width,height)
  local r,c,app=self.host,self.ctx,self.app
  local bank=app.rack.selected_bank or 1
  local outputs=app:active_outputs();local strip_width=92
  local fixed_count=1+(self.mixer_show_aux and 2 or 0)+(self.mixer_show_outputs and #outputs or 0)
  local desired_fixed=fixed_count*(strip_width+3)+6
  local rail_width=42;local mixer_width=math.max(200,width-rail_width-4)
  local fixed_width=math.min(math.max(strip_width+6,desired_fixed),math.max(strip_width+6,mixer_width*.62))
  local body_height=math.max(100,height)
  local flags=r.ImGui_WindowFlags_HorizontalScrollbar and r.ImGui_WindowFlags_HorizontalScrollbar() or 0
  local rail=self:begin_panel("##mixer_rail",rail_width,body_height,no_scroll_flags(r))
  if rail then
    for i=1,8 do
      if self:button(string.char(64+i).."##mixer_bank_"..i,34,27,i==bank and C.selected or nil) then app:set_bank(i);bank=i end
    end
    r.ImGui_Separator(c)
    if self:icon_button("##mixer_outputs_toggle","outputs","Show or hide output submixes",34,30,self.mixer_show_outputs,nil,false,true) then self.mixer_show_outputs=not self.mixer_show_outputs end
    if self:icon_button("##mixer_aux_toggle","aux","Show or hide auxiliary returns",34,30,self.mixer_show_aux,nil,false,true) then self.mixer_show_aux=not self.mixer_show_aux end
  end
  self:end_panel(rail)
  r.ImGui_SameLine(c)
  local visible=self:begin_panel("##mixer_channels",-fixed_width-4,body_height,flags)
  if visible then
    local first=(bank-1)*16+1
    for offset=0,15 do
      if offset>0 then r.ImGui_SameLine(c) end
      self:mixer_strip(first+offset,92,body_height-18)
    end
  end
  self:end_panel(visible)
  r.ImGui_SameLine(c)
  local divider_x,divider_y=r.ImGui_GetCursorScreenPos(c)
  r.ImGui_DrawList_AddLine(r.ImGui_GetWindowDrawList(c),divider_x-3,divider_y,divider_x-3,divider_y+body_height,C.border,2)
  r.ImGui_PushStyleColor(c,r.ImGui_Col_ChildBg(),C.panel)
  local fixed=self:begin_panel("##mixer_fixed",fixed_width,body_height,flags)
  if fixed then
    local first=true
    local function place(callback)
      if not first then r.ImGui_SameLine(c) end;first=false;callback()
    end
    if self.mixer_show_outputs then for _,output in ipairs(outputs) do place(function()self:mixer_bus_strip(output.id,output.id=="main"and "OUT 1"or output.name,app:output_track(output.id),strip_width,body_height-18,output)end) end end
    if self.mixer_show_aux then
      place(function()self:mixer_bus_strip("aux_a","AUX A",app:aux_track("aux_a"),strip_width,body_height-18)end)
      place(function()self:mixer_bus_strip("aux_b","AUX B",app:aux_track("aux_b"),strip_width,body_height-18)end)
    end
    place(function()self:mixer_bus_strip("master","MASTER",app:master_track(),strip_width,body_height-18)end)
  end
  self:end_panel(fixed)
  r.ImGui_PopStyleColor(c)
end

function UI:instrument_pad_grid(width,height)
  local r,c,app=self.host,self.ctx,self.app
  local visible=self:begin_panel("##instrumentpads",width,height)
  if visible then
    self.pad_rects={}
    r.ImGui_BeginGroup(c)
    local bank_height=math.max(24,math.floor((height-30)/8))
    for bank=1,8 do
      if self:button(string.char(64+bank).."##instrumentbank",42,bank_height,bank==app.rack.selected_bank and C.selected or nil) then app:set_bank(bank) end
    end
    r.ImGui_EndGroup(c)
    r.ImGui_SameLine(c)
    r.ImGui_BeginGroup(c)
    local panel_width=r.ImGui_GetContentRegionAvail(c)
    local grid_width=math.max(280,panel_width)
    local pad_width=math.floor((grid_width-20)/4)
    local pad_height=math.max(48,math.floor((height-30)/4))
    local first=(app.rack.selected_bank-1)*16+1
    for row=0,3 do
      for col=0,3 do
        if col>0 then r.ImGui_SameLine(c) end
        local index=first+(3-row)*4+col; local pad=app:pad(index)
        local chosen=self.selected_pads[index]
        local group=app:round_robin_for_pad(index);local badges={}
        if app:pad_muted(index) then badges[#badges+1]="M" end;if app:pad_soloed(index) then badges[#badges+1]="S" end
        if #(pad.simultaneous_play_targets or {})>0 then badges[#badges+1]="L"..#pad.simultaneous_play_targets end;if group then badges[#badges+1]="RR" end
        local label=string.format("%s\n%s\n%s##instrumentpad%d",note_name(pad_midi_note(index)),pad.name or "Pad",table.concat(badges,"  "),index)
        local border=pad.sample~=false and pad_color(index,pad) or C.border
        local clicked=self:pad_button(label,pad_width,pad_height,border,index==app.selected_pad or chosen,self:pad_triggered(index))
        local sample_path=type(pad.sample)=="table" and pad.sample.path or pad.sample
        self:pad_waveform_overlay(sample_path,border)
        self:handle_pad_interaction(index,clicked,110);self:pad_drag_source(index);self:accept_sample_drop(index,true);self:pad_context_menu(index)
      end
    end
    r.ImGui_EndGroup(c)
    self:finish_pad_drag()
  end
  self:end_panel(visible)
end

function UI:instrument_wave_panel(width,height)
  local r,c,app=self.host,self.ctx,self.app
  local visible=self:begin_unframed("##instrumentwave",width,height,no_scroll_flags(r))
  if visible then
    local pad=app:pad(); local controls=pad.default_controls
    local path=type(pad.sample)=="table" and pad.sample.path or pad.sample
    r.ImGui_TextDisabled(c,string.format("Bank %s  %s",pad_bank_letter(pad.logical_index),note_name(pad_midi_note(pad.logical_index))))
    r.ImGui_SameLine(c); r.ImGui_SetNextItemWidth(c,210)
    local renamed,name=r.ImGui_InputText(c,"##instrument_pad_name",pad.name or "Pad")
    if renamed then app:rename_pad(name) end
    r.ImGui_SameLine(c); r.ImGui_TextDisabled(c,state.sample_label(pad))
    local available=r.ImGui_GetContentRegionAvail(c)
    local trim_changed,trim_start,trim_end,attack,decay,sustain,release,fade_in,fade_out,fade_in_curve,fade_out_curve=self:waveform(path,available,math.max(82,height-82),controls.sample_start or DEFAULTS.sample_start,controls.sample_end or DEFAULTS.sample_end,"##instrument_waveform",controls)
    if trim_changed then controls.sample_start,controls.sample_end,controls.attack,controls.decay,controls.sustain,controls.release,controls.fade_in,controls.fade_out,controls.fade_in_curve,controls.fade_out_curve=trim_start,trim_end,attack,decay,sustain,release,fade_in,fade_out,fade_in_curve,fade_out_curve;self:queue_live_pad_controls() end
    if self:icon_button("##instrument_load","load","Load or replace sample",30,27,false,C.playhead) then app:load_selected_sample() end
    r.ImGui_SameLine(c);if self:icon_button("##instrument_previous_sample","previous","Previous sample in folder",28,27) then app:cycle_sample(-1) end
    r.ImGui_SameLine(c);if self:icon_button("##instrument_next_sample","next","Next sample in folder",28,27) then app:cycle_sample(1) end
    r.ImGui_SameLine(c);if self:icon_button("##instrument_clear","trash","Clear sample",28,27) then app:clear_selected_sample() end
    r.ImGui_SameLine(c);if self:button("NORMALIZE",88,27) then app:normalize_selected_sample() end
    r.ImGui_SameLine(c);if self:button("DETECT C",78,27) then app:detect_selected_pitch() end
    r.ImGui_SameLine(c);r.ImGui_TextDisabled(c,"Drag waveform handles to trim")
  end
  self:end_panel(visible)
end

function UI:instrument_sampler(width,height)
  local r,c,app=self.host,self.ctx,self.app
  local visible=self:begin_panel("##instrumentsampler",width,height)
  if visible then
    local pad=app:pad(); local controls=pad.default_controls
    r.ImGui_Text(c,"PAD SETTINGS")
    r.ImGui_SameLine(c); if self:button("Reset##instrumentcontrols",52,24) then app:reset_pad_controls() end
    r.ImGui_SameLine(c); if self:button("M##instrumentmute",28,24,app:pad_muted(app.selected_pad) and C.red or nil) then app:toggle_pad_mute(app.selected_pad) end
    r.ImGui_SameLine(c); if self:button("S##instrumentsolo",28,24,app:pad_soloed(app.selected_pad) and C.accent or nil) then app:toggle_pad_solo(app.selected_pad) end
    r.ImGui_SameLine(c); if self:icon_button("##instrumentaudition","play","Audition selected pad",28,24) then self:audition_pad(app.selected_pad,110) end
    r.ImGui_SameLine(c);local focus_changed;focus_changed,self.follow_played_pad=r.ImGui_Checkbox(c,"Pad Focus",self.follow_played_pad)
    r.ImGui_TextDisabled(c,"Color")
    for color_index,hex in ipairs(PAD_HEX) do
      r.ImGui_SameLine(c);if self:pad_button("##padcolor"..color_index,20,20,(tonumber(hex:sub(2),16)<<8)|0xFF,pad.color==hex) then app:set_pad_colors({app.selected_pad},hex) end
    end
    r.ImGui_Separator(c)
    local knob_fields={{"Gain","volume",.5},{"Pan","pan",.5},{"Tune","pitch",.5}}
    for i,f in ipairs(knob_fields) do
      if i>1 then r.ImGui_SameLine(c) end
      local value=controls[f[2]]; if value==nil then value=DEFAULTS[f[2]] end
      local knob_options
      if f[2]=="pitch" then
        knob_options={minimum=0,maximum=1,on_shift_click=function()app:detect_selected_pitch()end,context_menu=function()self:pitch_context_menu()end,shift_hint="Detect pitch and snap to C"}
      end
      local changed,next_value=self:knob("##instrument_"..f[2],f[1],value,f[3],62,knob_options)
      if changed then controls[f[2]]=next_value; app:queue_pad_controls() end
    end
    r.ImGui_Separator(c)
    r.ImGui_Text(c,"SAMPLE")
    local changed,value=self:slider_double("Start",controls.sample_start or DEFAULTS.sample_start,0,1,"%.3f",.005)
    if changed then controls.sample_start=value; app:queue_pad_controls() end
    changed,value=self:slider_double("End",controls.sample_end or DEFAULTS.sample_end,0,1,"%.3f",.005)
    if changed then controls.sample_end=value; app:queue_pad_controls() end
    r.ImGui_Text(c,"ENVELOPE")
    local env={{"Attack","attack",DEFAULTS.attack},{"Decay","decay",DEFAULTS.decay},{"Release","release",DEFAULTS.release}}
    for i,f in ipairs(env) do
      if i>1 then r.ImGui_SameLine(c) end
      local current=controls[f[2]]; if current==nil then current=f[3] end
      local did,next_value=self:knob("##instrument_"..f[2],f[1],current,f[3],56,{formatter=function(v)return envelope_value_text(f[2],v)end,wheel_step=.01})
      if did then controls[f[2]]=next_value; self:queue_live_pad_controls() end
    end
    r.ImGui_Separator(c)
    r.ImGui_Text(c,"PAD GROUPS")
    local choke=self:pad_choke_value(pad)
    local choke_labels={"Off","Self"};for i=1,32 do choke_labels[#choke_labels+1]="Group "..tostring(i) end
    did,choke=self:combo_field("Choke",choke,table.concat(choke_labels,"\0").."\0",#choke_labels)
    if did then self:set_pad_choke_value({app.selected_pad},choke) end
    r.ImGui_SameLine(c); r.ImGui_TextDisabled(c,string.format("Targets: %d",#(pad.mute_targets or {})))
    local linked_count=#(pad.simultaneous_play_targets or {})
    r.ImGui_TextDisabled(c,string.format("Link group: %d pads (%d targets)    Choke targets: %d",linked_count>0 and linked_count+1 or 0,linked_count,#(pad.mute_targets or {})))
    local group=app:round_robin_for_pad(app.selected_pad)
    if group then
      r.ImGui_Separator(c);r.ImGui_Text(c,"ROUND ROBIN")
      local modes={"sequential","ping_pong","random","random_no_repeat"};local current=0
      for i,v in ipairs(modes) do if group.mode==v then current=i-1 end end
      did,value=r.ImGui_Combo(c,"Mode##instrumentrr",current,table.concat(modes,"\0").."\0",#modes)
      if did then group.mode=modes[value+1];app:mark_dirty(false) end
      did,value=r.ImGui_SliderDouble(c,"Probability##instrumentrr",group.probability,0,100,"%.0f%%")
      if did then group.probability=value;app:mark_dirty(false) end
      local resets={"never","pattern","transport","trigger"};local reset_labels={"never","variation","transport","trigger"};local reset_index=0
      for i,v in ipairs(resets) do if v==group.reset_policy then reset_index=i-1 end end
      did,value=r.ImGui_Combo(c,"Reset##instrumentrr",reset_index,table.concat(reset_labels,"\0").."\0",#reset_labels)
      if did then group.reset_policy=resets[value+1];app:mark_dirty(false) end
      did,value=r.ImGui_Checkbox(c,"Advance on skip",group.advance_on_skip==true)
      if did then group.advance_on_skip=value;app:mark_dirty(false) end
      r.ImGui_SameLine(c);did,value=r.ImGui_Checkbox(c,"Per-repeat",group.advance_each_repeat==true)
      if did then group.advance_each_repeat=value;app:mark_dirty(false) end
      local master_index=app:pad_index_for_id(group.master_pad_id)
      r.ImGui_TextDisabled(c,string.format("%d members  |  Master %s",#group.member_pad_ids,master_index and (pad_bank_letter(master_index).." "..note_name(pad_midi_note(master_index))) or "?"))
      if master_index~=app.selected_pad and self:button("Make Selected Master",148,25) then app:set_round_robin_master(app.selected_pad) end
      r.ImGui_SameLine(c)
      if self:button("Remove Round Robin",136,25) then app:remove_round_robin() end
    end
  end
  self:end_panel(visible)
end

function UI:instrument_master(width,height)
  local r,c,app=self.host,self.ctx,self.app
  local visible=self:begin_panel("##instrumentmaster",width,height)
  if visible then
    r.ImGui_Text(c,"MASTER OUTPUT")
    r.ImGui_Separator(c)
    r.ImGui_SetNextItemWidth(c,-1)
    local renamed,name=r.ImGui_InputText(c,"##rackname",app.rack.name or "ReaDrumXT")
    if renamed and name~="" then app.rack.name=name:sub(1,64);app:mark_dirty(false) end
    local volume=app:master_value("D_VOL");local changed,value=self:knob("##mastervolume","LEVEL",math.max(0,math.min(1,volume/2)),.5,66)
    if changed then app:set_master_value("D_VOL",value*2) end
    r.ImGui_SameLine(c)
    local pan=app:master_value("D_PAN");changed,value=self:knob("##masterpan","PAN",math.max(0,math.min(1,(pan+1)/2)),.5,66)
    if changed then app:set_master_value("D_PAN",value*2-1) end
    if self:icon_button("##mastermute","mute","Mute master",34,30,app:master_value("B_MUTE")>0,app:master_value("B_MUTE")>0 and C.red or nil) then app:toggle_master_mute() end
    r.ImGui_SameLine(c);if self:icon_button("##mastersolo","solo","Solo master",34,30,app:master_value("I_SOLO")>0,app:master_value("I_SOLO")>0 and C.accent or nil) then app:toggle_master_solo() end
    r.ImGui_Separator(c)
    r.ImGui_TextDisabled(c,"KIT")
    if self:icon_button("##savekit","save","Save kit",34,30) then app:save_kit() end
    r.ImGui_SameLine(c);if self:icon_button("##loadkit","load","Load kit",34,30) then app:load_kit() end
    if r.Track_GetPeakInfo then
      local track=app:master_track();local left=track and math.max(0,r.Track_GetPeakInfo(track,0)) or 0;local right=track and math.max(0,r.Track_GetPeakInfo(track,1)) or 0
      r.ImGui_TextDisabled(c,"OUTPUT METER")
      if r.ImGui_ProgressBar then
        r.ImGui_ProgressBar(c,math.min(1,left),-1,7,"L")
        r.ImGui_ProgressBar(c,math.min(1,right),-1,7,"R")
      end
    end
  end
  self:end_panel(visible)
end

function UI:instrument_sampler_docked(width,height)
  local r,c,app=self.host,self.ctx,self.app
  local visible=self:begin_unframed("##instrumentdockedsampler",width,height,no_scroll_flags(r))
  if visible then
    local pad=app:pad();local controls=pad.default_controls
    r.ImGui_TextDisabled(c,"PAD")
    r.ImGui_SameLine(c);r.ImGui_Text(c,string.format("%s  %s",note_name(pad_midi_note(pad.logical_index)),pad.name or "Pad"))
    r.ImGui_SameLine(c);if self:icon_button("##dockedplay","play","Audition pad",28,24) then self:audition_pad(app.selected_pad,110) end
    r.ImGui_SameLine(c);if self:icon_button("##dockedmute","mute","Mute pad",28,24,app:pad_muted(app.selected_pad),app:pad_muted(app.selected_pad) and C.red or nil) then app:toggle_pad_mute(app.selected_pad) end
    r.ImGui_SameLine(c);if self:icon_button("##dockedsolo","solo","Solo pad",28,24,app:pad_soloed(app.selected_pad),app:pad_soloed(app.selected_pad) and C.accent or nil) then app:toggle_pad_solo(app.selected_pad) end
    r.ImGui_SameLine(c);if self:icon_button("##dockedreset","reset","Reset pad controls",28,24) then app:reset_pad_controls() end
    r.ImGui_SameLine(c);if self:button("PAD GROUP",92,24) then r.ImGui_OpenPopup(c,"##pad_group_settings") end
    r.ImGui_SameLine(c);r.ImGui_TextDisabled(c,"COLOR")
    for color_index,hex in ipairs(PAD_HEX) do
      r.ImGui_SameLine(c);if self:pad_button("##dockedcolor"..color_index,18,18,(tonumber(hex:sub(2),16)<<8)|0xFF,pad.color==hex) then app:set_pad_colors({app.selected_pad},hex) end
    end
    if r.ImGui_BeginPopup(c,"##pad_group_settings") then
      r.ImGui_Text(c,"PAD GROUP")
      r.ImGui_Separator(c)
      local choke=self:pad_choke_value(pad)
      local choke_labels={"Off","Self"};for i=1,32 do choke_labels[#choke_labels+1]="Group "..tostring(i) end
      local changed,value=self:combo_field("Choke",choke,table.concat(choke_labels,"\0").."\0",#choke_labels,180)
      if changed then self:set_pad_choke_value({app.selected_pad},value) end
      local linked_count=#(pad.simultaneous_play_targets or {})
      r.ImGui_TextDisabled(c,string.format("Link group %d pads (%d targets)   Choke targets %d",linked_count>0 and linked_count+1 or 0,linked_count,#(pad.mute_targets or {})))
      local group=app:round_robin_for_pad(app.selected_pad)
      if group then r.ImGui_TextColored(c,C.accent,string.format("Round robin: %s  %.0f%%",group.mode:gsub("_"," "),group.probability)) end
      r.ImGui_TextDisabled(c,"Right-click pads to link, choke or round robin.")
      r.ImGui_EndPopup(c)
    end
    r.ImGui_Separator(c)
    r.ImGui_BeginGroup(c)
    r.ImGui_TextDisabled(c,"TONE")
    local tone={{"Gain","volume",.5},{"Pan","pan",.5}}
    for i,field in ipairs(tone) do
      if i>1 then r.ImGui_SameLine(c) end
      local current=controls[field[2]];if current==nil then current=DEFAULTS[field[2]] end
      local options=field[2]=="pan" and {formatter=function(v)return string.format("%+.0f",(v-.5)*200)end} or nil
      local changed,value=self:knob("##docked_"..field[2],field[1],current,field[3],50,options)
      if changed then controls[field[2]]=value;app:queue_pad_controls() end
    end
    local transpose,cents=pad_pitch_values(controls)
    r.ImGui_SameLine(c)
    local changed,value=self:knob("##docked_transpose","TRANSPOSE",transpose,0,50,{minimum=-48,maximum=48,wheel_step=1,formatter=function(v)return string.format("%+.0f",v)end})
    if changed then set_pad_pitch(controls,value,cents);transpose=value;app:queue_pad_controls() end
    r.ImGui_SameLine(c)
    changed,value=self:knob("##docked_tune","TUNE",cents,0,50,{minimum=-100,maximum=100,wheel_step=1,formatter=function(v)return string.format("%+.0f",v)end})
    if changed then set_pad_pitch(controls,transpose,value);app:queue_pad_controls() end
    r.ImGui_EndGroup(c)
    r.ImGui_SameLine(c);r.ImGui_BeginGroup(c)
    r.ImGui_TextDisabled(c,"ADSR")
    local env={{"A","attack",DEFAULTS.attack},{"D","decay",DEFAULTS.decay},{"S","sustain",DEFAULTS.sustain},{"R","release",DEFAULTS.release}}
    for i,field in ipairs(env) do
      if i>1 then r.ImGui_SameLine(c) end
      local current=controls[field[2]];if current==nil then current=field[3] end
      local changed,value=r.ImGui_VSliderDouble(c,"##docked_"..field[2],26,68,current,0,1,"")
      if r.ImGui_IsItemHovered(c) then self:tooltip(envelope_value_text(field[2],value)) end
      if r.ImGui_IsItemHovered(c) and r.ImGui_IsMouseClicked and r.ImGui_IsMouseClicked(c,1) then value=field[3];changed=true end
      if changed then controls[field[2]]=value;self:queue_live_pad_controls() end
      local label_width=r.ImGui_CalcTextSize(c,field[1]);r.ImGui_SetCursorPosX(c,r.ImGui_GetCursorPosX(c)+math.max(0,(26-label_width)/2));r.ImGui_TextDisabled(c,field[1])
    end
    r.ImGui_EndGroup(c)
    r.ImGui_SameLine(c);r.ImGui_BeginGroup(c)
    r.ImGui_TextDisabled(c,"TRIM")
    local changed,value=self:double_field("Start##docked",controls.sample_start or DEFAULTS.sample_start,0,1,.005,"%.3f",112)
    if changed then controls.sample_start=value;if controls.sample_end and value>controls.sample_end then controls.sample_end=value end;app:queue_pad_controls() end
    changed,value=self:double_field("End##docked",controls.sample_end or DEFAULTS.sample_end,0,1,.005,"%.3f",112)
    if changed then controls.sample_end=value;if value<(controls.sample_start or 0) then controls.sample_start=value end;app:queue_pad_controls() end
    r.ImGui_EndGroup(c)
  end
  self:end_panel(visible)
end

function UI:instrument_view(width,height)
  local r,c=self.host,self.ctx
  local master_width=math.max(200,math.min(240,width*.15))
  local rack_width=math.max(520,math.min(700,width*.36))
  local editor_width=width-rack_width-master_width-6
  if editor_width<500 then rack_width=math.max(430,rack_width-(500-editor_width));editor_width=width-rack_width-master_width-6 end
  self:instrument_pad_grid(rack_width,height)
  r.ImGui_SameLine(c)
  local editor_visible=self:begin_panel("##instrumentedit",editor_width,height,no_scroll_flags(r))
  if editor_visible then
    local wave_height=math.max(112,math.min(185,height*.38))
    self:instrument_wave_panel(0,wave_height)
    self:instrument_sampler_docked(0,math.max(150,height-wave_height-5))
  end
  self:end_panel(editor_visible)
  r.ImGui_SameLine(c)
  self:instrument_master(master_width,height)
end

function UI:right_inspector(width,height)
  local r,c=self.host,self.ctx
  local visible=self:begin_panel("##inspector",width,height,controlled_scroll_flags(r))
  if visible then
    local inspector_scroll_y=r.ImGui_GetScrollY and r.ImGui_GetScrollY(c) or 0
    self.control_wheel_consumed=false
    self:pads()
    -- Custom controls use the wheel for value adjustment. Dear ImGui may also
    -- apply that event to this scrollable child, so restore the pre-gesture
    -- position after the controls have declared ownership.
    if r.ImGui_SetScrollY then
      if self.control_wheel_consumed then r.ImGui_SetScrollY(c,inspector_scroll_y)
      elseif r.ImGui_IsWindowHovered(c) and r.ImGui_GetMouseWheel then
        local wheel=r.ImGui_GetMouseWheel(c)
        if wheel~=0 then r.ImGui_SetScrollY(c,math.max(0,inspector_scroll_y-wheel*38)) end
      end
    end
  end
  self:end_panel(visible)
end

function UI:parameter_splitter()
  local r,c=self.host,self.ctx;local width=r.ImGui_GetContentRegionAvail(c)
  r.ImGui_InvisibleButton(c,"##parameter_splitter",width,6)
  if r.ImGui_IsItemActivated(c) then self.parameter_drag_start=self.parameter_height end
  if r.ImGui_IsItemActive(c) then
    local _,dy=r.ImGui_GetMouseDragDelta(c,0,0)
    self.parameter_height=math.max(110,math.min(420,(self.parameter_drag_start or self.parameter_height)-dy))
  end
  local x1,y1=r.ImGui_GetItemRectMin(c);local x2,y2=r.ImGui_GetItemRectMax(c);local color=r.ImGui_IsItemHovered(c) and C.selected or C.border
  r.ImGui_DrawList_AddRectFilled(r.ImGui_GetWindowDrawList(c),x1,y1+2,x2,y2-2,color,1)
end

function UI:property_value_from_mouse(property,top,bottom)
  local _,mouse_y=self.host.ImGui_GetMousePos(self.ctx)
  local normalized=1-math.max(0,math.min(1,(mouse_y-top)/math.max(1,bottom-top)))
  local value=property.min+normalized*(property.max-property.min)
  if property.kind~="double" then value=math.floor(value+.5) end
  return math.max(property.min,math.min(property.max,value))
end

function UI:step_property_value(lane,step,property)
  if property.kind=="divide" then return repeat_divide(lane,step) end
  local value=step[property.key]
  if property.kind=="pan" and value==false then return 0 end
  return value
end

function UI:set_step_property_value(lane,step,property,value)
  if property.kind=="divide" then
    value=math.max(1,math.min(16,math.floor(value+.5)))
    local numerator=lane.division_num;local denominator=lane.division_den*value;local factor=gcd(numerator,denominator)
    step.repeat_spacing={numerator=numerator/factor,denominator=denominator/factor}
    -- Ratchet xN is an audible musical operation, not merely a spacing hint:
    -- create N hits inside the source step at the corresponding subdivision.
    step.repeat_count=value
  else
    step[property.key]=value
  end
end

function UI:reset_step_property_value(lane,step,property)
  if property.kind=="divide" then
    self:set_step_property_value(lane,step,property,property.default or 1)
  else
    step[property.key]=model.deep_copy(property.default)
  end
end

function UI:reset_step_property_range(lane,property,target)
  local first=math.min(self.property_reset_position or target,target)
  local last=math.max(self.property_reset_position or target,target)
  for position=first,last do self:reset_step_property_value(lane,lane.steps[position],property) end
  self.property_reset_position=target
end

function UI:paint_step_property(lane,property,position,value)
  local from_position=self.property_paint_position or position
  local from_value=self.property_paint_value or value
  local first,last=math.min(from_position,position),math.max(from_position,position)
  local changed=false
  for step_index=first,last do
    local step=lane.steps[step_index]
    if step and step.enabled then
      local amount=position==from_position and 1 or (step_index-from_position)/(position-from_position)
      local next_value=from_value+(value-from_value)*amount
      if property.kind~="double" then next_value=math.floor(next_value+.5) end
      next_value=math.max(property.min,math.min(property.max,next_value))
      if self:step_property_value(lane,step,property)~=next_value then self:set_step_property_value(lane,step,property,next_value);changed=true end
    end
  end
  self.property_paint_position=position;self.property_paint_value=value
  return changed
end

function UI:parameter_editor(height)
  local r,c,app=self.host,self.ctx,self.app
  local visible=self:begin_panel("##parameters",0,height,no_scroll_flags(r))
  if visible then
    local property=PROPERTIES[self.property]
    local ramp_min,ramp_max=property.min,property.max
    if property.key=="velocity" then ramp_min=40
    elseif property.key=="pitch_semitones" then ramp_min,ramp_max=-12,24
    elseif property.key=="pitch_cents" then ramp_min,ramp_max=-50,50
    elseif property.key=="repeat_count" then ramp_max=8
    elseif property.kind=="divide" then ramp_min,ramp_max=1,8
    elseif property.key=="timing_offset" then ramp_min,ramp_max=-48,48
    elseif property.key=="gate" or property.key=="probability" then ramp_min=25 end
    local lane=app:lane();local play_step=self:lane_play_step(lane)
    -- One canvas owns the entire curve gesture. Per-column sliders capture the
    -- mouse and make cross-column painting impossible in Dear ImGui.
    local header_y=r.ImGui_GetCursorPosY(c)
    local canvas_start_y=header_y
    r.ImGui_SetCursorPosX(c,GRID_STEP_X)
    r.ImGui_SetCursorPosY(c,canvas_start_y)
    local available_width,available_height=r.ImGui_GetContentRegionAvail(c)
    -- The selector occupies the unused lane-control gutter. Property columns
    -- therefore begin at the panel top without sacrificing graph height.
    local canvas_height=math.max(64,available_height-5)
    local canvas_width=math.max(GRID_CELL_WIDTH,available_width)
    r.ImGui_InvisibleButton(c,"##property_canvas",canvas_width,canvas_height)
    local left,top=r.ImGui_GetItemRectMin(c);local right,bottom=r.ImGui_GetItemRectMax(c)
    local draw=r.ImGui_GetWindowDrawList(c)
    local scroll_x=self.grid_scroll_x or 0
    local function display_value(step)
      return self:step_property_value(lane,step,property)
    end
    if r.ImGui_DrawList_PushClipRect then r.ImGui_DrawList_PushClipRect(draw,left,top,right,bottom,true) end
    for i=1,lane.step_count do
      local step=lane.steps[i];local value=display_value(step);local effective
      local x1=left+(i-1)*GRID_CELL_STRIDE-scroll_x;local x2=x1+GRID_CELL_WIDTH
      local column_bottom=bottom;local column_top=top
      local background=math.floor((i-1)/4)%2==0 and C.step or C.beat
      r.ImGui_DrawList_AddRectFilled(draw,x1,column_top,x2,column_bottom,background,2)
      local normalized=(value-property.min)/(property.max-property.min)
      normalized=math.max(0,math.min(1,normalized))
      local fill_top=column_bottom-normalized*(column_bottom-column_top)
      if step.enabled then r.ImGui_DrawList_AddRectFilled(draw,x1+2,fill_top,x2-2,column_bottom,C.selected,1) end
      if step.enabled and property.key=="velocity" then
        effective=app:effective_step_velocity(lane,step,i)
        local effective_y=column_bottom-(effective-property.min)/(property.max-property.min)*(column_bottom-column_top)
        effective_y=math.max(column_top,math.min(column_bottom,effective_y))
        r.ImGui_DrawList_AddLine(draw,(x1+x2)/2,fill_top,(x1+x2)/2,effective_y,0xF0A02B88,1)
        r.ImGui_DrawList_AddLine(draw,x1+2,effective_y,x2-2,effective_y,C.value_marker or 0xF0A02BFF,2)
      end
      local shown=string.format(property.format,effective or value)
      local text_width=r.ImGui_CalcTextSize(c,shown)
      r.ImGui_DrawList_AddText(draw,x1+math.max(0,(GRID_CELL_WIDTH-text_width)/2),column_top+2,step.enabled and C.text or C.muted,shown)
      if play_step==i then r.ImGui_DrawList_AddRectFilled(draw,x1+2,column_bottom-5,x2-2,column_bottom-1,playback_accent_color(),1) end
    end
    if r.ImGui_DrawList_PopClipRect then r.ImGui_DrawList_PopClipRect(draw) end
    local mouse_x=r.ImGui_GetMousePos(c)
    local target=math.max(1,math.min(lane.step_count,math.floor((mouse_x-left+scroll_x)/GRID_CELL_STRIDE)+1))
    local activated=r.ImGui_IsItemActivated and r.ImGui_IsItemActivated(c)
    local active=r.ImGui_IsItemActive and r.ImGui_IsItemActive(c)
    local right_clicked=r.ImGui_IsItemHovered(c) and r.ImGui_IsMouseClicked and r.ImGui_IsMouseClicked(c,1)
    local _,shift=self:key_modifiers()
    if right_clicked then
      self.property_reset_active=true;self.property_reset_lane=app.selected_pad;self.property_reset_key=property.key;self.property_reset_position=target
      self:reset_step_property_value(lane,lane.steps[target],property);app.selected_step=target;app:mark_dirty(false)
    elseif self.property_reset_active and self.property_reset_lane==app.selected_pad and self.property_reset_key==property.key and r.ImGui_IsMouseDown(c,1) then
      self:reset_step_property_range(lane,property,target);app.selected_step=target;app:mark_dirty(false)
    elseif activated and shift then
      local value=self:property_value_from_mouse(property,top,bottom)
      self.property_line_active=true;self.property_line_lane=app.selected_pad;self.property_line_key=property.key
      self.property_line_position=target;self.property_line_value=value;app.selected_step=target
    elseif activated then
      local painted=self:property_value_from_mouse(property,top,bottom)
      self.property_paint_active=true;self.property_paint_lane=app.selected_pad;self.property_paint_key=property.key
      self.property_paint_position=target;self.property_paint_value=painted;app.selected_step=target
      local step=lane.steps[target];if step.enabled then self:set_step_property_value(lane,step,property,painted);app:mark_dirty(false) end
    elseif self.property_line_active and self.property_line_lane==app.selected_pad and self.property_line_key==property.key and r.ImGui_IsMouseDown(c,0) then
      local endpoint=self:property_value_from_mouse(property,top,bottom)
      local first,last=self.property_line_position,target
      local start_value,end_value=self.property_line_value,endpoint
      if first>last then first,last=last,first;start_value,end_value=end_value,start_value end
      local span=math.max(1,last-first);local changed=false
      for position=first,last do
        local step=lane.steps[position]
        if step and step.enabled then
          local value=start_value+(end_value-start_value)*(position-first)/span
          if property.kind~="double" then value=math.floor(value+.5) end
          value=math.max(property.min,math.min(property.max,value))
          if self:step_property_value(lane,step,property)~=value then self:set_step_property_value(lane,step,property,value);changed=true end
        end
      end
      if changed then app.selected_step=target;app:mark_dirty(false) end
    elseif self.property_paint_active and self.property_paint_lane==app.selected_pad and self.property_paint_key==property.key and r.ImGui_IsMouseDown(c,0) then
      local painted=self:property_value_from_mouse(property,top,bottom)
      if self:paint_step_property(lane,property,target,painted) then app.selected_step=target;app:mark_dirty(false) end
    end
    if r.ImGui_IsItemHovered(c) and r.ImGui_GetMouseWheel then
      local wheel=r.ImGui_GetMouseWheel(c)
      if wheel~=0 then
        local step=lane.steps[target];local value=display_value(step);local increment=property.kind=="double" and 1 or 1
        local next_value=math.max(property.min,math.min(property.max,value+(wheel>0 and increment or -increment)))
        if property.kind~="double" then next_value=math.floor(next_value+.5) end
        if step.enabled and display_value(step)~=next_value then self:set_step_property_value(lane,step,property,next_value);app.selected_step=target;app:mark_dirty(false);self.wheel_commit=true end
      end
    end
    if self.property_paint_active and not r.ImGui_IsMouseDown(c,0) then
      self.property_paint_active=false;self.property_paint_lane=false;self.property_paint_key=false
      self.property_paint_position=false;self.property_paint_value=false
    end
    if self.property_line_active and not r.ImGui_IsMouseDown(c,0) then
      self.property_line_active=false;self.property_line_lane=false;self.property_line_key=false
      self.property_line_position=false;self.property_line_value=false
    end
    if self.property_reset_active and not r.ImGui_IsMouseDown(c,1) then
      self.property_reset_active=false;self.property_reset_lane=false;self.property_reset_key=false;self.property_reset_position=false
    end
    local canvas_end_y=r.ImGui_GetCursorPosY(c)
    r.ImGui_SetCursorPosX(c,8)
    r.ImGui_SetCursorPosY(c,canvas_start_y)
    r.ImGui_BeginGroup(c)
    if self:icon_button("##propertycopy","copy","Copy "..property.label.." curve",28,24,false,nil,false,true) then
      if property.kind=="divide" then self.divide_curve_clipboard={};for i,item in ipairs(lane.steps) do self.divide_curve_clipboard[i]=repeat_divide(lane,item) end else app:copy_step_property(property.key) end
    end
    r.ImGui_SameLine(c,0,4)
    if self:icon_button("##propertypaste","paste","Paste "..property.label.." curve",28,24,false,nil,false,true) then
      if property.kind=="divide" then if self.divide_curve_clipboard then for i,value in ipairs(self.divide_curve_clipboard) do if lane.steps[i] then self:set_step_property_value(lane,lane.steps[i],property,value) end end;app:mark_dirty(false) end else app:paste_step_property(property.key) end
    end
    r.ImGui_SameLine(c,0,4)
    if self:icon_button("##propertyrampup","rampup",property.kind=="divide" and "Ramp ratchets 1x to 8x" or "Ramp "..property.label.." up",28,24,false,nil,false,true) then
      if property.kind=="divide" then for i,item in ipairs(lane.steps) do self:set_step_property_value(lane,item,property,1+math.floor(7*(i-1)/math.max(1,lane.step_count-1)+.5)) end;app:mark_dirty(false) else app:ramp_step_property(property.key,ramp_min,ramp_max) end
    end
    r.ImGui_SameLine(c,0,4)
    if self:icon_button("##propertyrampdown","rampdown",property.kind=="divide" and "Ramp ratchets 8x to 1x" or "Ramp "..property.label.." down",28,24,false,nil,false,true) then
      if property.kind=="divide" then for i,item in ipairs(lane.steps) do self:set_step_property_value(lane,item,property,8-math.floor(7*(i-1)/math.max(1,lane.step_count-1)+.5)) end;app:mark_dirty(false) else app:ramp_step_property(property.key,ramp_max,ramp_min) end
    end
    if property.kind~="divide" then
      r.ImGui_SameLine(c,0,4)
      if self:icon_button("##propertyscale","scale","Scale "..property.label.." to 80%",28,24,false,nil,false,true) then app:scale_step_property(property.key,.8) end
    end
    r.ImGui_SameLine(c,0,4)
    if self:icon_button("##propertyreset","reset",property.kind=="divide" and "Reset ratchets to 1x" or "Reset "..property.label.." values",28,24,false,nil,false,true) then
      if property.kind=="divide" then for _,item in ipairs(lane.steps) do self:set_step_property_value(lane,item,property,1) end;app:mark_dirty(false) else app:reset_step_property(property.key) end
    end
    r.ImGui_SameLine(c,0,5)
    r.ImGui_SetNextItemWidth(c,150)
    if r.ImGui_BeginCombo(c,"##propertyselector",property.label) then
      for property_index,item in ipairs(PROPERTIES) do
        if r.ImGui_Selectable(c,item.label,property_index==self.property) then self.property=property_index end
      end
      r.ImGui_EndCombo(c)
    end
    local selector_hovered=r.ImGui_IsItemHovered(c)
    if selector_hovered and r.ImGui_GetMouseWheel then
      local wheel=r.ImGui_GetMouseWheel(c)
      if wheel~=0 then self.property=math.max(1,math.min(#PROPERTIES,self.property+(wheel>0 and -1 or 1))) end
    end
    if selector_hovered and self.tooltips_enabled~=false and r.ImGui_SetItemTooltip then r.ImGui_SetItemTooltip(c,"Choose a step property — mouse wheel cycles") end
    r.ImGui_EndGroup(c)
    r.ImGui_SetCursorPosY(c,math.max(canvas_end_y,canvas_start_y+canvas_height))
    r.ImGui_Dummy(c,1,1)
  end
  self:end_panel(visible)
end

function UI:piano_roll_editor(height)
  local r,c,app=self.host,self.ctx,self.app
  -- The tool rail is fixed. Only the keyboard/note canvas owns vertical
  -- scrolling; horizontal movement remains mirrored from the sequencer.
  local visible=self:begin_panel("##piano_roll",0,height,no_scroll_flags(r))
  if visible then
    local lane=app:lane();local pad=app:pad();local top_pitch,bottom_pitch=24,-12;local row_count=top_pitch-bottom_pitch+1;local play_step=self:lane_play_step(lane)
    local keyboard_width=58;local tool_width=GRID_STEP_X-keyboard_width-3
    local tools=self:begin_panel("##piano_tools",tool_width,height,no_scroll_flags(r))
    if tools then
      local piano_controls=pad.default_controls or {};pad.default_controls=piano_controls
      r.ImGui_TextDisabled(c,"PITCH TOOLS")
      local detected_midi=tonumber(piano_controls.detected_pitch_midi)
      local detected_text=detected_midi and ("Detected: "..note_name(math.floor(detected_midi+.5))) or "Detected: —"
      local detected_width=r.ImGui_CalcTextSize(c,detected_text)
      r.ImGui_SameLine(c,math.max(82,tool_width-detected_width-10));r.ImGui_TextDisabled(c,detected_text)
      if self:button("DETECT##piano_detect",84,26,C.selected) then app:detect_selected_pitch(false) end
      r.ImGui_SameLine(c,0,5);if self:button("SNAP C##piano_snap",82,26) then app:snap_detected_pitch_to_c() end
      r.ImGui_SameLine(c,0,5);if self:button("REVERT##piano_revert",82,26) then app:revert_pitch_snap() end
      r.ImGui_Dummy(c,1,3)
      if self:button("OCT -##piano_oct_down",72,26) then app:adjust_sample_octave(-1) end
      r.ImGui_SameLine(c,0,5);if self:button("OCT +##piano_oct_up",72,26) then app:adjust_sample_octave(1) end
      r.ImGui_SameLine(c,0,14)
      local retrigger=piano_controls.slide_retrigger~=false
      local retrigger_changed,retrigger_value=r.ImGui_Checkbox(c,"RETRIG##piano_slide_retrigger",retrigger)
      if retrigger_changed then self:apply_selected_pad_controls({slide_retrigger=retrigger_value,playback_mode="gate"},true) end
      r.ImGui_TextDisabled(c,"PLAYBACK")
      r.ImGui_SameLine(c,0,8)
      local gate_mode=piano_controls.playback_mode=="gate"
      if self:button("ONE SHOT##piano_playback_one",76,24,not gate_mode and C.selected or nil) then
        self:apply_selected_pad_controls({playback_mode="one_shot"},true)
      end
      r.ImGui_SameLine(c,0,4)
      if self:button("GATE##piano_playback_gate",54,24,gate_mode and C.selected or nil) then
        self:apply_selected_pad_controls({playback_mode="gate"},true)
      end
      r.ImGui_Dummy(c,1,5)
      local glide=math.max(0,math.min(.5,tonumber(piano_controls.glide) or 0))
      local glide_changed,glide_value=self:knob("##piano_glide","GLIDE",glide,0,40,{minimum=0,maximum=.5,wheel_step=.005,formatter=function(v)return v<=0 and "OFF" or string.format("%.0f ms",v*1000)end})
      if glide_changed then
        -- Glide is intentionally a one-control workflow. Enabling it places
        -- the pad in Gate mode so touching notes can hand off the active voice;
        -- turning it off does not silently change the user's playback mode.
        self:apply_selected_pad_control_edit(function(target_controls)
          target_controls.glide=glide_value
          if glide_value>0 then target_controls.playback_mode="gate" end
        end,true)
      end
      self:tooltip("Alt-click or Alt-drag a note to mark it as Slide.\nMouse wheel adjusts; right-click resets")
      r.ImGui_SameLine(c,0,12)
      local xfade=math.max(0,math.min(100,tonumber(piano_controls.slide_crossfade_ms) or 20))
      local xfade_changed,xfade_value=self:knob("##piano_slide_xfade","XFADE",xfade,20,40,{minimum=0,maximum=100,wheel_step=1,formatter=function(v)return string.format("%.0f ms",v)end})
      if xfade_changed then self:apply_selected_pad_controls({slide_crossfade_ms=xfade_value},true) end
    end
    self:end_panel(tools)
    r.ImGui_SameLine(c,0,0)
    local piano_visible=self:begin_panel("##piano_canvas_scroll",0,height,0)
    if piano_visible then
    local available_width=r.ImGui_GetContentRegionAvail(c);local row_height=20;local canvas_height=row_height*row_count;local content_width=available_width
    local start_x,start_y=r.ImGui_GetCursorPosX(c),r.ImGui_GetCursorPosY(c);r.ImGui_InvisibleButton(c,"##piano_roll_canvas",content_width,canvas_height)
    local left,top=r.ImGui_GetItemRectMin(c);local right,bottom=r.ImGui_GetItemRectMax(c)
    local draw=r.ImGui_GetWindowDrawList(c);local scroll_x=self.grid_scroll_x or 0
    local fixed_origin=left;local keyboard_left=fixed_origin
    local grid_left=left+keyboard_width+3-scroll_x;local grid_clip_left=fixed_origin+keyboard_width+3
    -- Pad notes are trigger mappings (bank/channel inputs), not the pitch the
    -- sampler plays. Sequenced pitch_semitones is relative to the engine's
    -- A4/MIDI-69 playback root, so the piano roll must use that same root.
    local controls=pad.default_controls or {};local transpose,cents=pad_pitch_values(controls)
    local detected=tonumber(controls.detected_pitch_midi)
    local pitch_known=detected~=nil
    local base_note=pitch_known and math.max(0,math.min(127,math.floor(detected+transpose+cents/100+.5))) or 60
    local mouse_x,mouse_y=r.ImGui_GetMousePos(c)
    local hover_row=mouse_y>=top and mouse_y<bottom and math.floor((mouse_y-top)/row_height) or -1
    local piano_steps=lane.step_count
    if self.piano_selection_pad~=app.selected_pad then self.piano_selected_steps={};self.piano_selection_pad=app.selected_pad end
    -- The grid is clipped at its fixed viewport edge. The keyboard is drawn
    -- afterwards, on top, so horizontal scrolling can never cover the keys.
    if r.ImGui_DrawList_PushClipRect then r.ImGui_DrawList_PushClipRect(draw,grid_clip_left,top,right,bottom,true) end
    for row=0,row_count-1 do
      local semitone=top_pitch-row;local midi=math.max(0,math.min(127,base_note+semitone));local y1=top+row*row_height;local y2=y1+row_height
      for step_index=1,piano_steps do
        local x1=grid_left+(step_index-1)*GRID_CELL_STRIDE;local x2=x1+GRID_CELL_STRIDE
        local pitch_class=midi%12
        local black=pitch_class==1 or pitch_class==3 or pitch_class==6 or pitch_class==8 or pitch_class==10
        -- Use the exact same two colors as the main sequencer: white-key rows
        -- get its lighter step color and black-key rows get its darker color.
        -- Four-step groups receive only a slight tonal shift. Vertical line
        -- weight carries the hierarchy: step, beat, then bar.
        local background=black and C.step or C.beat
        if math.floor((step_index-1)/4)%2==1 then background=blend_color(background,C.panel2,.07) end
        r.ImGui_DrawList_AddRectFilled(draw,x1,y1,x2,y2,background,1)
        r.ImGui_DrawList_AddLine(draw,x1,y2-1,x2,y2-1,(C.preview_grid&0xFFFFFF00)|0x48,1)
        local boundary=step_index-1
        local line_color,line_width=(C.text&0xFFFFFF00)|0x28,1
        if boundary%16==0 then line_color,line_width=(C.text&0xFFFFFF00)|0x68,2.5
        elseif boundary%4==0 then line_color,line_width=(C.text&0xFFFFFF00)|0x45,1.75 end
        r.ImGui_DrawList_AddLine(draw,x1,y1,x1,y2,line_color,line_width)
      end
      for owner,step in ipairs(lane.steps) do
        if step.enabled and math.floor((step.pitch_semitones or 0)+.5)==semitone then
          local span=note_span_steps(lane,owner)
          local x1=grid_left+(owner-1)*GRID_CELL_STRIDE;local x2=piano_note_right(grid_left,owner,span)
          local note_color=self.color_steps_by_pad
            and active_step_color(pad_color(app.selected_pad,pad),app:effective_step_velocity(lane,step,owner))
            or C.selected
          r.ImGui_DrawList_AddRectFilled(draw,x1+1,y1+1,x2-1,y2-1,note_color,2)
          if step.slide and r.ImGui_DrawList_AddTriangleFilled then
            r.ImGui_DrawList_AddTriangleFilled(draw,x1+1,y1+1,x1+9,y1+1,x1+1,y1+9,C.playhead)
          end
          local selected=self.piano_selected_steps[owner] or owner==app.selected_step
          local note_hovered=hover_row==row and mouse_x>=x1 and mouse_x<=x2
          if selected or note_hovered then
            r.ImGui_DrawList_AddRect(draw,x1+1,y1+1,x2-1,y2-1,C.playhead,2,0,1.5)
            r.ImGui_DrawList_AddRectFilled(draw,x1+1,y1+4,x1+4,y2-4,C.playhead,1)
            r.ImGui_DrawList_AddRectFilled(draw,x2-4,y1+4,x2-1,y2-4,C.playhead,1)
          end
        end
      end
    end
    if play_step then
      local play_x=grid_left+(play_step-1)*GRID_CELL_STRIDE
      local _,window_y=r.ImGui_GetWindowPos(c);local _,window_height=r.ImGui_GetWindowSize(c)
      local marker_bottom=math.min(bottom,window_y+window_height-4)
      r.ImGui_DrawList_AddRectFilled(draw,play_x+2,marker_bottom-5,play_x+GRID_CELL_WIDTH-2,marker_bottom-1,playback_accent_color(),1)
    end
    if r.ImGui_DrawList_PopClipRect then r.ImGui_DrawList_PopClipRect(draw) end
    -- Keyboard overlay: fixed horizontally, naturally scrolled vertically.
    for row=0,row_count-1 do
      local semitone=top_pitch-row;local midi=math.max(0,math.min(127,base_note+semitone));local y1=top+row*row_height;local y2=y1+row_height
      local pitch_class=midi%12;local black=pitch_class==1 or pitch_class==3 or pitch_class==6 or pitch_class==8 or pitch_class==10
      -- Chromatic rows share a continuous white key bed. Accidentals are
      -- short black overlays, leaving the right side white like a piano.
      local is_c=pitch_class==0
      local key_color=row==hover_row and (is_c and 0x82B8DAFF or 0x9CCCEBFF) or (is_c and 0xBCC2C8FF or 0xD6D9DDFF)
      r.ImGui_DrawList_AddRectFilled(draw,keyboard_left,y1,keyboard_left+keyboard_width,y2,key_color,1)
      if black then r.ImGui_DrawList_AddRectFilled(draw,keyboard_left,y1,keyboard_left+keyboard_width*.52,y2,row==hover_row and C.selected or 0x07090CFF,1) end
      r.ImGui_DrawList_AddRect(draw,keyboard_left,y1,keyboard_left+keyboard_width,y2,0x252B31FF,1,0,1)
      if not black then
        local label=pitch_known and note_name(midi) or (semitone==0 and "ROOT" or string.format("%+d",semitone))
        r.ImGui_DrawList_AddText(draw,keyboard_left+keyboard_width-36,y1+3,0x252A30FF,label)
      end
    end
    local hovered=r.ImGui_IsItemHovered(c)
    if hovered and mouse_x>=keyboard_left and mouse_x<grid_clip_left and hover_row>=0 and hover_row<row_count then
      if r.ImGui_IsMouseClicked and r.ImGui_IsMouseClicked(c,0) and app.audition_notes~=false then self:audition_pad(app.selected_pad,110,false,top_pitch-hover_row) end
    elseif hovered and mouse_x>=grid_clip_left then
      local step_index=math.floor((mouse_x-grid_left)/GRID_CELL_STRIDE)+1
      local row=math.floor((mouse_y-top)/row_height);local semitone=top_pitch-row
      if step_index>=1 and step_index<=lane.step_count and row>=0 and row<row_count then
        local left_click=r.ImGui_IsMouseClicked and r.ImGui_IsMouseClicked(c,0)
        local right_click=r.ImGui_IsMouseClicked and r.ImGui_IsMouseClicked(c,1)
        local ctrl,_,alt=self:key_modifiers();local owner=note_owner_at(lane,step_index);local step=owner and lane.steps[owner] or lane.steps[step_index]
        local on_note=owner and math.floor((step.pitch_semitones or 0)+.5)==semitone
        if left_click then
          if alt and on_note then
            step.slide=not step.slide;app.selected_step=owner;self.piano_selected_steps={[owner]=true};app:mark_dirty(false)
          elseif ctrl and on_note then
            self.piano_selected_steps[owner]=not self.piano_selected_steps[owner]
            app.selected_step=owner
          elseif on_note then
            -- Any note can begin a move immediately. Preserve an existing
            -- multi-selection only when the grabbed note belongs to it.
            if not self.piano_selected_steps[owner] then self.piano_selected_steps={[owner]=true} end
            app.selected_step=owner
            local note_start=grid_left+(owner-1)*GRID_CELL_STRIDE;local note_end=piano_note_right(grid_left,owner,note_span_steps(lane,owner))
            local mode=math.abs(mouse_x-note_start)<=6 and "resize_left" or (math.abs(mouse_x-note_end)<=6 and "resize_right" or "move")
            self.piano_pointer={mode=mode,source_step=owner,source_pitch=semitone,
              source_span=note_span_steps(lane,owner),start_x=mouse_x,start_y=mouse_y,duplicate=false,moved=false}
          else
            self.piano_selected_steps={}
            self.piano_pointer={mode="paint",source_step=step_index,source_pitch=semitone,start_x=mouse_x,start_y=mouse_y,last_cell=false,moved=false,slide=alt==true}
          end
        elseif right_click then
          self.piano_marquee={source_step=step_index,source_pitch=semitone,start_x=mouse_x,start_y=mouse_y}
        end
      end
    end
    local pointer=self.piano_pointer
    if pointer and r.ImGui_IsMouseDown(c,0) then
      if math.abs(mouse_x-pointer.start_x)>3 or math.abs(mouse_y-pointer.start_y)>3 then pointer.moved=true end
      -- Empty-space dragging previews one sustained note. It intentionally
      -- does not paint a trail of independent triggers.
    end
    if pointer and (pointer.mode=="move" or pointer.mode=="resize_left" or pointer.mode=="resize_right" or pointer.mode=="paint") and pointer.moved and r.ImGui_IsMouseDown(c,0) and mouse_x>=grid_clip_left and hover_row>=0 and hover_row<row_count then
      local target_step=math.floor((mouse_x-grid_left)/GRID_CELL_STRIDE)+1;local target_pitch=top_pitch-hover_row
      local step_delta=target_step-pointer.source_step;local pitch_delta=target_pitch-pointer.source_pitch
      if r.ImGui_DrawList_PushClipRect then r.ImGui_DrawList_PushClipRect(draw,grid_clip_left,top,right,bottom,true) end
      if pointer.mode=="paint" then
        local first=math.max(1,math.min(pointer.source_step,target_step));local last=math.min(lane.step_count,math.max(pointer.source_step,target_step))
        local ghost_x=grid_left+(first-1)*GRID_CELL_STRIDE;local ghost_right=piano_note_right(grid_left,first,last-first+1)
        local ghost_y=top+(top_pitch-pointer.source_pitch)*row_height
        r.ImGui_DrawList_AddRectFilled(draw,ghost_x+1,ghost_y+1,ghost_right-1,ghost_y+row_height-1,(C.selected&0xFFFFFF00)|0x70,2)
        r.ImGui_DrawList_AddRect(draw,ghost_x+1,ghost_y+1,ghost_right-1,ghost_y+row_height-1,C.playhead,2,0,2)
      elseif pointer.mode=="resize_left" or pointer.mode=="resize_right" then
        local first=pointer.mode=="resize_left" and math.min(pointer.source_step+pointer.source_span-1,math.max(1,target_step)) or pointer.source_step
        local last=pointer.mode=="resize_right" and math.max(pointer.source_step,math.min(lane.step_count,target_step)) or pointer.source_step+pointer.source_span-1
        local ghost_x=grid_left+(first-1)*GRID_CELL_STRIDE;local ghost_right=piano_note_right(grid_left,first,last-first+1)
        local ghost_y=top+(top_pitch-pointer.source_pitch)*row_height
        r.ImGui_DrawList_AddRect(draw,ghost_x+1,ghost_y+1,ghost_right-1,ghost_y+row_height-1,C.playhead,2,0,2)
      else
        for source_step in pairs(self.piano_selected_steps) do
          local source=lane.steps[source_step]
          if source and source.enabled then
            local destination_step=source_step+step_delta;local destination_pitch=(source.pitch_semitones or 0)+pitch_delta
            local span=note_span_steps(lane,source_step)
            if destination_step>=1 and destination_step+span-1<=lane.step_count and destination_pitch>=bottom_pitch and destination_pitch<=top_pitch then
              local ghost_x=grid_left+(destination_step-1)*GRID_CELL_STRIDE;local ghost_right=piano_note_right(grid_left,destination_step,span);local ghost_y=top+(top_pitch-destination_pitch)*row_height
              r.ImGui_DrawList_AddRectFilled(draw,ghost_x+1,ghost_y+1,ghost_right-1,ghost_y+row_height-1,(C.selected&0xFFFFFF00)|0x70,2)
              r.ImGui_DrawList_AddRect(draw,ghost_x+1,ghost_y+1,ghost_right-1,ghost_y+row_height-1,pointer.duplicate and C.accent or C.playhead,2,0,2)
            end
          end
        end
      end
      if r.ImGui_SetTooltip then
        local shown_first=pointer.mode=="resize_left" and math.min(pointer.source_step+pointer.source_span-1,math.max(1,target_step)) or (pointer.mode=="move" and pointer.source_step+step_delta or pointer.source_step)
        local shown_span=pointer.mode=="resize_left" and pointer.source_step+pointer.source_span-shown_first or (pointer.mode=="resize_right" and math.max(1,target_step-pointer.source_step+1) or (pointer.mode=="paint" and math.abs(target_step-pointer.source_step)+1 or pointer.source_span))
        local shown_midi=math.max(0,math.min(127,math.floor(base_note+target_pitch+.5)))
        r.ImGui_SetTooltip(c,string.format("%s   Step %d   Length %d",note_name(shown_midi),shown_first,shown_span))
      end
      if r.ImGui_DrawList_PopClipRect then r.ImGui_DrawList_PopClipRect(draw) end
    end
    if pointer and not r.ImGui_IsMouseDown(c,0) then
      local target_step=math.max(1,math.min(lane.step_count,math.floor((mouse_x-grid_left)/GRID_CELL_STRIDE)+1));local target_pitch=math.max(bottom_pitch,math.min(top_pitch,top_pitch-hover_row))
      if pointer.mode=="move" and pointer.moved and mouse_x>=grid_clip_left and hover_row>=0 and hover_row<row_count then
        local step_delta=target_step-pointer.source_step;local pitch_delta=target_pitch-pointer.source_pitch;local copies={}
        for source_step in pairs(self.piano_selected_steps) do local source=lane.steps[source_step];if source and source.enabled then copies[#copies+1]={index=source_step,step=model.deep_copy(source)} end end
        table.sort(copies,function(a,b)return a.index<b.index end)
        local valid=true
        for _,item in ipairs(copies) do
          local destination_index=item.index+step_delta;local span=math.max(1,math.ceil(math.max(0,tonumber(item.step.gate) or 100)/100))
          if destination_index<1 or destination_index+span-1>lane.step_count then valid=false;break end
          item.destination_span=span
          if not valid then break end
        end
        if valid then
          if not pointer.duplicate then for _,item in ipairs(copies) do clear_piano_note(lane.steps[item.index]) end end
          local selection={};for _,item in ipairs(copies) do local destination_index=item.index+step_delta;trim_piano_overlaps(lane,destination_index,destination_index+item.destination_span-1);local destination=lane.steps[destination_index];if destination then for key,value in pairs(item.step) do destination[key]=value end;destination.enabled=true;destination.cut=false;destination.gate=item.destination_span*100;destination.pitch_semitones=math.max(bottom_pitch,math.min(top_pitch,(item.step.pitch_semitones or 0)+pitch_delta));selection[destination_index]=true end end
          self.piano_selected_steps=selection;app.selected_step=target_step;app:mark_dirty(false)
          if pitch_delta~=0 and app.audition_notes~=false then self:audition_pad(app.selected_pad,110,false,target_pitch) end
        end
      elseif (pointer.mode=="resize_left" or pointer.mode=="resize_right") and pointer.moved then
        local old_first=pointer.source_step;local old_last=old_first+pointer.source_span-1;local source=model.deep_copy(lane.steps[old_first])
        local first=pointer.mode=="resize_left" and math.min(old_last,math.max(1,target_step)) or old_first
        local last=pointer.mode=="resize_right" and math.max(old_first,math.min(lane.step_count,target_step)) or old_last
        clear_piano_note(lane.steps[old_first]);trim_piano_overlaps(lane,first,last)
        local destination=lane.steps[first];for key,value in pairs(source) do destination[key]=value end
        destination.enabled=true;destination.cut=false;destination.gate=(last-first+1)*100
        self.piano_selected_steps={[first]=true};app.selected_step=first;app:mark_dirty(false)
      elseif pointer.mode=="move" and not pointer.moved then
        local source=lane.steps[pointer.source_step]
        if source and source.enabled and math.floor((source.pitch_semitones or 0)+.5)==pointer.source_pitch then
          source.enabled=false;source.cut=false;source.slide=false;source.pitch_semitones=0;source.pitch_cents=0;source.gate=100;self.piano_selected_steps[pointer.source_step]=nil
          app.selected_step=pointer.source_step;app:mark_dirty(false)
        end
      elseif (pointer.mode=="resize_left" or pointer.mode=="resize_right") and not pointer.moved then
        local source=lane.steps[pointer.source_step];clear_piano_note(source)
        self.piano_selected_steps[pointer.source_step]=nil;app.selected_step=pointer.source_step;app:mark_dirty(false)
      elseif pointer.mode=="paint" and pointer.moved then
        local first=math.max(1,math.min(pointer.source_step,target_step));local last=math.min(lane.step_count,math.max(pointer.source_step,target_step))
        trim_piano_overlaps(lane,first,last)
        local source=lane.steps[first];source.enabled=true;source.cut=false;source.slide=pointer.slide==true;source.pitch_semitones=pointer.source_pitch;source.gate=(last-first+1)*100
        self.piano_selected_steps={[first]=true};app.selected_step=first;app:mark_dirty(false)
      elseif not pointer.moved and pointer.mode=="paint" then
        local source=lane.steps[pointer.source_step]
        trim_piano_overlaps(lane,pointer.source_step,pointer.source_step)
        source.enabled=true;source.cut=false;source.slide=pointer.slide==true;source.pitch_semitones=pointer.source_pitch;source.gate=100
        app.selected_step=pointer.source_step;app:mark_dirty(false)
      end
      self.piano_pointer=false
    end
    if self.piano_marquee and r.ImGui_IsMouseDown(c,1) then
      local marquee=self.piano_marquee;local x1,x2=math.min(marquee.start_x,mouse_x),math.max(marquee.start_x,mouse_x);local y1,y2=math.min(marquee.start_y,mouse_y),math.max(marquee.start_y,mouse_y)
      r.ImGui_DrawList_AddRectFilled(draw,x1,y1,x2,y2,0x1687D528,1);r.ImGui_DrawList_AddRect(draw,x1,y1,x2,y2,C.playhead,1,0,1)
      local first_step=math.max(1,math.floor((x1-grid_left)/GRID_CELL_STRIDE)+1);local last_step=math.min(lane.step_count,math.floor((x2-grid_left)/GRID_CELL_STRIDE)+1)
      local high_pitch=math.max(bottom_pitch,math.min(top_pitch,top_pitch-math.floor((y1-top)/row_height)));local low_pitch=math.max(bottom_pitch,math.min(top_pitch,top_pitch-math.floor((y2-top)/row_height)))
      local selection={};for index=first_step,last_step do local note=lane.steps[index];local pitch=math.floor((note.pitch_semitones or 0)+.5);if note.enabled and pitch>=low_pitch and pitch<=high_pitch then selection[index]=true end end
      self.piano_selected_steps=selection
    elseif self.piano_marquee and not r.ImGui_IsMouseDown(c,1) then self.piano_marquee=false end
    r.ImGui_SetCursorPosX(c,start_x);r.ImGui_SetCursorPosY(c,start_y+canvas_height);r.ImGui_Dummy(c,1,1)
    end
    self:end_panel(piano_visible)
  end
  self:end_panel(visible)
end

function UI:project_save_dialog_open()
  local r=self.host
  local get_active=r.JS_Window_GetForeground or r.JS_Window_GetFocus
  if not get_active or not r.JS_Window_GetTitle or not r.JS_Window_GetParent then return false end
  -- REAPER continues deferred ReaScripts while this modal copy window is up.
  -- Do not analyze samples, reconcile tracks, publish, or write project state
  -- behind it: those operations can contend with REAPER's media-copy/save pass.
  -- Inspect only the active window's parent chain. JS_Window_Find enumerates
  -- the complete native window tree and some VST editors make that operation
  -- block for more than a second on every UI frame.
  local window=get_active()
  for _=1,12 do
    if not window or window==0 then break end
    local title=(r.JS_Window_GetTitle(window) or ""):lower()
    if title:find("save project with media copy",1,true) or title:find("copying project media",1,true) or title=="save project" then return true end
    local parent=r.JS_Window_GetParent(window)
    if not parent or parent==0 or parent==window then break end
    window=parent
  end
  return false
end

function UI:frame()
  local r,c=self.host,self.ctx
  -- Mouse-wheel edits are complete transactions even though ImGui may keep
  -- the hovered slider active until the next click. Allow their dirty state
  -- to flush on the normal 30 ms debounce instead of waiting for focus loss.
  self.wheel_commit=false
  if self:project_save_dialog_open() then
    -- ReaImGui contexts must be advanced every deferred cycle. Keep the same
    -- window alive with a minimal frame, but do not inspect samples or touch
    -- any REAPER project state while the native save/copy operation is modal.
    r.ImGui_SetNextWindowSize(c,1480,820,r.ImGui_Cond_FirstUseEver())
    local visible
    visible,self.open=r.ImGui_Begin(c,"ReaDrumXT",self.open,r.ImGui_WindowFlags_NoCollapse())
    if visible then r.ImGui_TextDisabled(c,"REAPER is saving project media…") end
    r.ImGui_End(c)
    return self.open
  end
  local now=r.time_precise()
  local frame_started=now
  self.perf_frame=(self.perf_frame or 0)+1
  self.perf_detail_frame=self.perf_probe and self.perf_frame%30==0
  if self.perf_probe and self.perf_last_frame then self:perf_record("defer gap",math.max(0,now-self.perf_last_frame)) end
  self.perf_last_frame=now
  local section_started=self:perf_begin()
  if now>=(self.next_project_poll or 0) then
    self.next_project_poll=now+.05
    self.app:sync_engine_variation()
    self.app:follow_engine_variation_display()
    if self.app.follow_variation_events then self.app:poll_variation_event_selection(false) end
  end
  self:perf_end("project/playback poll",section_started)
  section_started=self:perf_begin()
  r.ImGui_SetNextWindowSize(c,1480,820,r.ImGui_Cond_FirstUseEver())
  if (self.focus_frames or 0)>0 and r.ImGui_SetNextWindowFocus then
    r.ImGui_SetNextWindowFocus(c)
    self.focus_frames=self.focus_frames-1
  end
  theme.apply(self.theme,C)
  r.ImGui_PushStyleColor(c,r.ImGui_Col_WindowBg(),C.window)
  r.ImGui_PushStyleColor(c,r.ImGui_Col_ChildBg(),C.panel)
  r.ImGui_PushStyleColor(c,r.ImGui_Col_PopupBg(),C.panel)
  r.ImGui_PushStyleColor(c,r.ImGui_Col_Text(),C.text)
  r.ImGui_PushStyleColor(c,r.ImGui_Col_TextDisabled(),C.muted)
  r.ImGui_PushStyleColor(c,r.ImGui_Col_TextSelectedBg(),(C.selected&0xFFFFFF00)|0x70)
  r.ImGui_PushStyleColor(c,r.ImGui_Col_Border(),C.border)
  r.ImGui_PushStyleColor(c,r.ImGui_Col_Separator(),C.border)
  r.ImGui_PushStyleColor(c,r.ImGui_Col_FrameBg(),C.panel2)
  r.ImGui_PushStyleColor(c,r.ImGui_Col_FrameBgHovered(),C.hover)
  r.ImGui_PushStyleColor(c,r.ImGui_Col_Button(),C.button)
  r.ImGui_PushStyleColor(c,r.ImGui_Col_ButtonHovered(),C.hover)
  r.ImGui_PushStyleColor(c,r.ImGui_Col_ButtonActive(),C.selected)
  r.ImGui_PushStyleColor(c,r.ImGui_Col_SliderGrab(),C.selected)
  r.ImGui_PushStyleColor(c,r.ImGui_Col_SliderGrabActive(),C.accent)
  r.ImGui_PushStyleColor(c,r.ImGui_Col_CheckMark(),C.selected)
  r.ImGui_PushStyleColor(c,r.ImGui_Col_Header(),(C.selected&0xFFFFFF00)|0x48)
  r.ImGui_PushStyleColor(c,r.ImGui_Col_HeaderHovered(),(C.selected&0xFFFFFF00)|0x70)
  r.ImGui_PushStyleColor(c,r.ImGui_Col_HeaderActive(),(C.selected&0xFFFFFF00)|0x90)
  r.ImGui_PushStyleVar(c,r.ImGui_StyleVar_FrameRounding(),3)
  r.ImGui_PushStyleVar(c,r.ImGui_StyleVar_GrabRounding(),3)
  r.ImGui_PushStyleVar(c,r.ImGui_StyleVar_ItemSpacing(),3,3)
  r.ImGui_PushStyleVar(c,r.ImGui_StyleVar_FramePadding(),5,3)
  r.ImGui_PushStyleVar(c,r.ImGui_StyleVar_ChildRounding(),0)
  r.ImGui_PushStyleVar(c,r.ImGui_StyleVar_WindowPadding(),3,3)
  local visible
  visible,self.open=r.ImGui_Begin(c,"ReaDrumXT",self.open,r.ImGui_WindowFlags_NoCollapse())
  self:perf_end("window/style setup",section_started)
  if visible then
    section_started=self:perf_begin()
    self:poll_played_pad()
    self:perf_end("recent MIDI poll",section_started)
    section_started=self:perf_begin()
    self:poll_triggered_pad()
    self:perf_end("trigger mailbox poll",section_started)
    section_started=self:perf_begin()
    self:shortcuts()
    if self.drop_error and r.time_precise()<(self.drop_error_until or 0) then
      r.ImGui_PushStyleColor(c,r.ImGui_Col_Text(),self.drop_error_color or C.red)
      r.ImGui_TextWrapped(c,self.drop_error)
      r.ImGui_PopStyleColor(c)
      r.ImGui_Separator(c)
    elseif self.drop_error then
      self.drop_error=nil;self.drop_error_color=nil;self.drop_error_until=0
    end
    self:perf_end("input/status UI",section_started)
    section_started=self:perf_begin()
    self:top_toolbar()
    self:perf_end("top toolbar UI",section_started)
    local available_width,available_height=r.ImGui_GetContentRegionAvail(c)
    section_started=self:perf_begin()
    if self.main_view=="mixer" then
      local view_started=self:perf_begin()
      self:mixer_view(available_width,available_height)
      self:perf_end("mixer view UI",view_started)
      self:perf_end("main content UI",section_started)
    else
    local bottom_height=0
      if self.parameter_open then
        local maximum=math.max(110,available_height-110)
        self.parameter_height=math.max(110,math.min(maximum,self.parameter_height or 190));bottom_height=self.parameter_height
      end
      local view_started=self:perf_begin()
      self:info_panel(available_height)
      self:perf_end("info panel UI",view_started)
      local right_width=self.inspector_open and 360 or 0
      local center_width=self.inspector_open and (-right_width-4) or 0
      local center_visible=self:begin_panel("##center",center_width,available_height,no_scroll_flags(r))
      if center_visible then
        local lane_toolbar_height=self.lane_toolbar_open and LANE_TOOLBAR_HEIGHT or 0
        local reserved=lane_toolbar_height+(self.lane_toolbar_open and 3 or 0)
        local grid_height=self.parameter_open and math.max(90,available_height-bottom_height-reserved-6) or math.max(90,available_height-reserved)
        view_started=self:perf_begin()
        self:sequence_grid(grid_height)
        self:perf_end("sequence grid UI",view_started)
        if self.lane_toolbar_open then
          view_started=self:perf_begin()
          self:lane_toolbar(LANE_TOOLBAR_HEIGHT)
          self:perf_end("lane toolbar UI",view_started)
        end
        if self.parameter_open then
          view_started=self:perf_begin()
          self:parameter_splitter()
          self:perf_end("parameter splitter UI",view_started)
          view_started=self:perf_begin()
          if self.editor_mode=="piano" then
            self:piano_roll_editor(bottom_height)
            self:perf_end("piano roll UI",view_started)
          else
            self:parameter_editor(bottom_height)
            self:perf_end("parameter editor UI",view_started)
          end
        end
      end
      self:end_panel(center_visible)
    self:perf_end("main content UI",section_started)
    if self.inspector_open then
      section_started=self:perf_begin()
      r.ImGui_SameLine(c)
      self:right_inspector(right_width,available_height)
      self:perf_end("right inspector UI",section_started)
    end
    end
  end
  r.ImGui_End(c)
  section_started=self:perf_begin()
  self:eula_viewer()
  r.ImGui_PopStyleVar(c,6)
  r.ImGui_PopStyleColor(c,19)
  self:flush_audition(not self.open)
  self:perf_end("window finalize UI",section_started)
  section_started=self:perf_begin()
  if now>=(self.next_bridge_poll or 0) then self.next_bridge_poll=now+.05;self.app:poll_bridge() end
  self:perf_end("bridge poll",section_started)
  -- Publishing rebuilds the runtime image and may reconcile REAPER tracks.
  -- Never do that in the middle of a mouse gesture; commit immediately after
  -- the active control is released instead.
  local control_active=r.ImGui_IsAnyItemActive and r.ImGui_IsAnyItemActive(c)
  -- Keep REAPER/gmem calls out of the active mouse gesture. Even the compact
  -- control packet can occasionally block on the host and delay delivery of
  -- the next UI frame, making waveform handles visibly trail the pointer.
  -- The model and overlay still update every frame; audio commits on release.
  if self.live_pad_controls_pending and not control_active then
    section_started=self:perf_begin()
    self.app:sync_pending_pad_controls()
    self.live_pad_controls_pending=false
    self:perf_end("live control commit",section_started)
  end
  section_started=self:perf_begin()
  if not control_active or self.wheel_commit then
    -- Structural reconciliation has substantial fixed overhead. Coalesce a
    -- multi-sample drop into one delayed transaction instead of repeatedly
    -- rebuilding REAPER tracks and stuttering the GUI for every few pads.
    if #self.app.structural_queue>0 and now>=(self.next_structural_work or 0) then
      self.next_structural_work=now+.25
      self.app:process_structural_queue(math.huge)
    elseif #self.waveform_queue>0 and now>=(self.next_waveform_work or 0) then
      self.next_waveform_work=now+.10
      self:process_waveform_queue(1)
    end
    if self.app.dirty and now>=(self.app.due or math.huge) then local started=r.time_precise();self.app:flush(false);self:perf_record("flush prepare",r.time_precise()-started) end
    if self.app.checkpoint_task then local started=r.time_precise();self.app:process_checkpoint();self:perf_record("checkpoint slice",r.time_precise()-started) end
    if self.app.state_pending and now>=(self.app.state_due or math.huge) then local started=r.time_precise();self.app:save_if_due(false);self:perf_record("state begin/slice",r.time_precise()-started) end
  end
  self:perf_end("idle/background work",section_started)
  -- Shared-memory payloads are staged with a strict per-frame budget and only
  -- committed after both runtime and transport pages are complete.
  local publish_started=r.time_precise();self.app:process_publish(4096);self:perf_record("publish slice",r.time_precise()-publish_started)
  section_started=self:perf_begin()
  self.app:poll_sampler_loads(4)
  self:perf_end("sampler status poll",section_started)
  self:perf_record("frame total",r.time_precise()-frame_started)
  return self.open
end

function UI:loading_frame()
  local r,c=self.host,self.ctx
  r.ImGui_SetNextWindowSize(c,1480,820,r.ImGui_Cond_FirstUseEver())
  local visible
  visible,self.open=r.ImGui_Begin(c,"ReaDrumXT",self.open,r.ImGui_WindowFlags_NoCollapse())
  if visible then r.ImGui_TextDisabled(c,"Loading ReaDrumXT project state…") end
  r.ImGui_End(c)
  return self.open
end

return UI
