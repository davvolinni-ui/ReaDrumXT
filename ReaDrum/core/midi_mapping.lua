-- @noindex
-- Controller layouts are permutations of the 128 MIDI notes, indexed by pad
-- position. They deliberately live outside pad/sample objects.
local json=require("ReaDrum.core.json")
local M={FACTORY="ReaDrum default",SECTION="ReaDrum5k",KEY="midi_mapping_presets_v1"}
function M.default_note(index)return (36+index-1)%128 end
function M.factory()
  local notes={};for index=1,128 do notes[index]=M.default_note(index) end
  return {name=M.FACTORY,notes=notes}
end
function M.validate(mapping)
  if type(mapping)~="table" or type(mapping.name)~="string" or mapping.name=="" or #mapping.name>64 then return nil,"Invalid MIDI mapping name" end
  if type(mapping.notes)~="table" or #mapping.notes~=128 then return nil,"MIDI mapping requires 128 notes" end
  local seen={}
  for index=1,128 do
    local note=mapping.notes[index]
    if type(note)~="number" or note%1~=0 or note<0 or note>127 or seen[note] then return nil,"MIDI mapping notes must be unique integers from 0 to 127" end
    seen[note]=true
  end
  for key in pairs(mapping.notes) do if type(key)~="number" or key%1~=0 or key<1 or key>128 then return nil,"Invalid MIDI mapping position" end end
  return true
end
function M.copy(mapping)
  local ok,why=M.validate(mapping);assert(ok,why)
  local notes={};for i=1,128 do notes[i]=mapping.notes[i] end
  return {name=mapping.name,notes=notes}
end
function M.note(rack,index)
  return rack.midi_mapping and rack.midi_mapping.notes[index] or M.default_note(index)
end
function M.pad(rack,note)
  if type(note)~="number" or note%1~=0 or note<0 or note>127 then return nil end
  if not rack.midi_mapping then return ((note-36+128)%128)+1 end
  for index,value in ipairs(rack.midi_mapping.notes) do if value==note then return index end end
end
function M.assign(mapping,index,note)
  if type(index)~="number" or index%1~=0 or index<1 or index>128 or type(note)~="number" or note%1~=0 or note<0 or note>127 then return false end
  local previous=mapping.notes[index];if previous==note then return false end
  local other
  for i,value in ipairs(mapping.notes) do if value==note then other=i;break end end
  if other then mapping.notes[other]=previous end
  mapping.notes[index]=note
  return true,other
end
function M.load_library(host)
  local library={version=1,default=M.FACTORY,presets={}}
  local text=host.GetExtState and host.GetExtState(M.SECTION,M.KEY) or ""
  if text=="" then return library end
  local ok,saved=pcall(json.decode,text)
  if not ok or type(saved)~="table" or saved.version~=1 or type(saved.presets)~="table" then return library,"Could not read saved MIDI mapping presets" end
  local names={[M.FACTORY]=true}
  for _,preset in ipairs(saved.presets) do
    if not M.validate(preset) or names[preset.name] then return library,"Invalid saved MIDI mapping preset" end
    names[preset.name]=true
  end
  if type(saved.default)~="string" or not names[saved.default] then return library,"Invalid default MIDI mapping preset" end
  return saved
end
function M.find(library,name)
  if name==M.FACTORY then return M.factory() end
  for _,preset in ipairs(library.presets) do if preset.name==name then return M.copy(preset) end end
end
function M.matches(a,b)
  if not a or not b then return false end
  for i=1,128 do if a.notes[i]~=b.notes[i] then return false end end
  return true
end
function M.save_library(host,library)
  assert(host.SetExtState,"REAPER preference storage is unavailable")
  host.SetExtState(M.SECTION,M.KEY,json.encode(library),true)
end
function M.new_project(host)
  local library,warning=M.load_library(host)
  return M.find(library,library.default) or M.factory(),warning
end
return M
