-- @noindex
local M={}
M.SECTION="ReaDrum5k.Theme"
M.KEYS={"window_bg","panel_bg","text","selected_text","folder_text","accent","header_icon","value_marker","border","midi_note","preview_bg","step_dark","step_light","preview_grid"}
M.LABELS={window_bg="Window Background",panel_bg="Panel Background",text="Normal Text",selected_text="Selected / Hover Text",folder_text="Secondary Highlight",accent="Accent (highlight)",header_icon="Header Icons",value_marker="Relevant Value",border="Border",midi_note="MIDI Notes",preview_bg="Grid Background",step_dark="Step Grid — Dark",step_light="Step Grid — Light",preview_grid="Grid Lines"}
M.DEFAULT={window_bg=0x101215FF,panel_bg=0x171A1EFF,text=0xDCE1E7FF,selected_text=0xFFFFFFFF,folder_text=0x42A5F5FF,accent=0x1687D5FF,header_icon=0xF0A02BFF,value_marker=0xF0A02BFF,border=0x30363EFF,midi_note=0x1687D5FF,preview_bg=0x20242AFF,step_dark=0x24292FFF,step_light=0x2C3239FF,preview_grid=0x30363EFF}
M.LIGHT={window_bg=0xE3E5E8FF,panel_bg=0xF2F3F5FF,text=0x202327FF,selected_text=0xFFFFFFFF,folder_text=0x245F9FFF,accent=0x2F78CFFF,header_icon=0x2F78CFFF,value_marker=0xC97800FF,border=0xA9AFB6FF,midi_note=0x287FC8FF,preview_bg=0xE6E8EBFF,step_dark=0xC7CBD0FF,step_light=0xD8DBDFFF,preview_grid=0xAEB4BAFF}

local function copy(source)local out={};for k,v in pairs(source)do out[k]=v end;return out end
local function luminance(col)return ((col>>24)&255)*.299+((col>>16)&255)*.587+((col>>8)&255)*.114 end
local function adjust(col,amount)
  local function one(value)return math.max(0,math.min(255,math.floor((amount>=0 and value+(255-value)*amount or value+value*amount)+.5)))end
  return (one((col>>24)&255)<<24)|(one((col>>16)&255)<<16)|(one((col>>8)&255)<<8)|(col&255)
end
local function blend(a,b,amount)
  local inverse=1-amount;local function channel(shift)return math.floor((((a>>shift)&255)*inverse)+(((b>>shift)&255)*amount)+.5)end
  return (channel(24)<<24)|(channel(16)<<16)|(channel(8)<<8)|(a&255)
end
local function contrast(foreground,background,minimum)
  local value=foreground;local bg=luminance(background)
  for _=1,8 do if math.abs(luminance(value)-bg)>=minimum then break end;value=adjust(value,bg<128 and .14 or -.14)end
  return value
end
local function surface_contrast(foreground,background,minimum)
  local value=foreground;local bg=luminance(background)
  for _=1,12 do
    if math.abs(luminance(value)-bg)>=minimum then break end
    value=adjust(value,bg<145 and .025 or -.025)
  end
  return value
end
local function readable(foreground,background,minimum)
  if math.abs(luminance(foreground)-luminance(background))>=(minimum or 90)then return foreground end
  return luminance(background)>=128 and 0x181818FF or 0xEEEEEEFF
end
local function native(host,key,default,optional)
  local ok,value=pcall(host.GetThemeColor,key,0);if not ok or value==-1 then return optional and nil or default end
  local red,green,blue=host.ColorFromNative(value&0xFFFFFF);if red==nil then return optional and nil or default end
  return (red<<24)|(green<<16)|(blue<<8)|255
end
local function chroma(color)local a,b,c=(color>>24)&255,(color>>16)&255,(color>>8)&255;return math.max(a,b,c)-math.min(a,b,c)end
local function add(state,row,label,color)
  if not color or row=="accent" and chroma(color)<20 then return end
  local choices=state.suggestions[row]or{}
  for _,choice in ipairs(choices)do local dr=math.abs(((choice.color>>24)&255)-((color>>24)&255));local dg=math.abs(((choice.color>>16)&255)-((color>>16)&255));local db=math.abs(((choice.color>>8)&255)-((color>>8)&255));if dr+dg+db<24 then return end end
  if #choices<4 then choices[#choices+1]={label=label,color=color};state.suggestions[row]=choices end
end

function M.save(host,state)
  for _,key in ipairs(M.KEYS)do
    host.SetExtState(M.SECTION,"theme_"..key,tostring(state.colors[key]),true)
    local parts={};for _,choice in ipairs(state.suggestions[key]or{})do parts[#parts+1]=choice.label:gsub("[|;]","").."|"..choice.color end
    host.SetExtState(M.SECTION,"suggestions_"..key,table.concat(parts,";"),true)
  end
end
function M.new(host)
  local state={colors=copy(M.DEFAULT),suggestions={}}
  for _,key in ipairs(M.KEYS)do
    state.colors[key]=tonumber(host.GetExtState(M.SECTION,"theme_"..key))or state.colors[key]
    local choices={};for part in (host.GetExtState(M.SECTION,"suggestions_"..key)or""):gmatch("[^;]+")do local label,value=part:match("^(.-)|(%d+)$");if label and value then choices[#choices+1]={label=label,color=tonumber(value)}end end;state.suggestions[key]=choices
  end
  return state
end
function M.reset(host,state,preset)
  state.colors=copy(preset=="light"and M.LIGHT or M.DEFAULT);state.suggestions={};M.save(host,state)
end
function M.import(host,state,mode)
  state.suggestions={};local main=native(host,"col_main_bg2",0x333333FF);local lum=luminance(main);local light=mode=="light"or(mode=="auto"and lum>=145);if mode=="dark"then light=false end;local c=state.colors
  if light then
    -- Preserve a hint of the current REAPER theme, but enforce a real light
    -- surface hierarchy. Relative-only adjustment made mid-gray REAPER themes
    -- collapse into one flat sheet with nearly indistinguishable controls.
    c.window_bg=blend(main,0xD9DDE2FF,lum<170 and .92 or .68)
    c.panel_bg=blend(c.window_bg,0xFFFFFFFF,.25)
    c.text=0x202327FF;c.border=adjust(c.panel_bg,-.25)
    c.preview_bg=adjust(c.window_bg,-.045)
    c.step_dark=adjust(c.preview_bg,-.14);c.step_light=adjust(c.preview_bg,-.07)
    c.preview_grid=adjust(c.preview_bg,-.22)
  else c.window_bg=blend(main,0x101215FF,lum>85 and .72 or .34);c.panel_bg=adjust(c.window_bg,.065);c.text=0xE2E2E2FF;c.border=adjust(c.panel_bg,-.30);c.preview_bg=adjust(c.panel_bg,-.16);c.step_dark=adjust(c.preview_bg,.025);c.step_light=adjust(c.preview_bg,.10);c.preview_grid=adjust(c.preview_bg,.14)end
  -- Imported themes can provide usable colors that are nevertheless too close
  -- together on low-contrast displays. Preserve their hue while guaranteeing
  -- a readable active-grid hierarchy; native presets and manual edits remain
  -- untouched because this normalization runs only during import.
  if light then
    -- Light surfaces need a restrained beat alternation. Large luminance
    -- jumps read as broad stripes, so keep both active shades distinct from
    -- the canvas while separating them from each other by only a small step.
    c.step_dark=blend(c.preview_bg,0x000000FF,.14)
    c.step_light=blend(c.preview_bg,0x000000FF,.08)
  else
    c.step_dark=surface_contrast(c.step_dark,c.preview_bg,14)
    c.step_light=surface_contrast(c.step_light,c.preview_bg,25)
  end
  local list=native(host,"genlist_selbg",M.DEFAULT.accent);local toolbar=native(host,"col_toolbar_text_on",M.DEFAULT.folder_text);local selected=native(host,"genlist_selfg",0xFFFFFFFF);local accent=blend(list,toolbar,.46);local notes=blend(accent,toolbar,.56);local secondary=blend(toolbar,selected,.18)
  c.accent=contrast(accent,c.panel_bg,68);c.header_icon=contrast(accent,c.window_bg,86);c.selected_text=readable(selected,c.accent,105);c.folder_text=contrast(secondary,c.panel_bg,86);c.midi_note=contrast(notes,c.preview_bg,100)
  add(state,"accent","Auto choice",c.accent);add(state,"header_icon","Auto choice",c.header_icon)
  local candidates={window_bg={{"Main background","col_main_bg2"},{"Main surface","col_main_bg"}},panel_bg={{"List background","genlist_bg"},{"Track-list background","col_tracklistbg"},{"Arrange background","col_arrangebg"}},text={{"List text","genlist_fg"},{"Main text","col_main_text"},{"Toolbar text","col_toolbar_text"}},selected_text={{"Selected-list text","genlist_selfg"},{"Active toolbar text","col_toolbar_text_on"}},accent={{"List selection","genlist_selbg"},{"Toolbar highlight","col_toolbar_text_on"},{"Pressed toolbar","toolbararmed_color"},{"Selected highlight","genlist_hilite_sel"}},header_icon={{"Toolbar highlight","col_toolbar_text_on"},{"Pressed toolbar","toolbararmed_color"},{"List selection","genlist_selbg"}},border={{"Toolbar frame","col_toolbar_frame"},{"3D shadow","col_main_3dsh"}},preview_bg={{"Editor background","col_main_editbk"},{"Arrange background","col_arrangebg"}},step_dark={{"Editor background","col_main_editbk"},{"Arrange background","col_arrangebg"},{"List background","genlist_bg"}},step_light={{"Arrange background","col_arrangebg"},{"Track-list background","col_tracklistbg"},{"Main surface","col_main_bg"}},preview_grid={{"Arrange grid","arrange_vgrid"},{"Grid lines","col_gridlines"}}}
  for row,entries in pairs(candidates)do for _,entry in ipairs(entries)do add(state,row,entry[1],native(host,entry[2],nil,true))end end
  for _,choice in ipairs(state.suggestions.accent or{})do add(state,"folder_text",choice.label,choice.color);add(state,"midi_note",choice.label,choice.color)end
  M.save(host,state)
end
function M.apply(state,C)
  local c=state.colors;C.window=c.window_bg;C.panel=c.panel_bg;C.panel2=c.preview_bg;C.text=c.text;C.selected_text=c.selected_text;C.selected=c.accent;C.accent=c.header_icon;C.value_marker=c.value_marker;C.playhead=c.folder_text;C.border=c.border;C.waveform=c.midi_note;C.preview_grid=c.preview_grid
  local light=luminance(c.panel_bg)>=145
  C.button=adjust(c.panel_bg,light and -.075 or .10);C.hover=adjust(c.panel_bg,light and -.14 or .18);C.step=c.step_dark;C.beat=c.step_light;C.muted=blend(c.text,c.panel_bg,.48)
end
M.luminance=luminance
return M
