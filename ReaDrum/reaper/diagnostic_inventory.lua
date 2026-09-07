-- @noindex
-- On-demand, bounded metadata inspection. Never reads sample audio or edits MIDI.
local M={}
local function call(fn,...)
  if type(fn)~="function" then return nil end
  local values=table.pack(pcall(fn,...))
  if values[1] then return table.unpack(values,2,values.n) end
end
function M.midi(r,track,budget)
  local result={items={},available=type(r.CountTrackMediaItems)=="function"}
  local count=call(r.CountTrackMediaItems,track)or 0
  result.total_items=count
  local inspect=math.min(count,budget.items)
  for i=0,inspect-1 do
    budget.items=budget.items-1
    local item=call(r.GetTrackMediaItem,track,i)
    local take=call(r.GetActiveTake,item)
    if take and call(r.TakeIsMIDI,take) then
      local ok,notes=call(r.MIDI_CountEvts,take)
      local entry={index=i,position=call(r.GetMediaItemInfo_Value,item,"D_POSITION"),length=call(r.GetMediaItemInfo_Value,item,"D_LENGTH"),
        mute=call(r.GetMediaItemInfo_Value,item,"B_MUTE"),take_mute=call(r.GetMediaItemTakeInfo_Value,take,"B_MUTE"),
        loop_source=call(r.GetMediaItemInfo_Value,item,"B_LOOPSRC"),active_take_only=true,available=not not ok,notes=notes,histogram={},scanned=0}
      local counts={}
      for n=0,math.min(notes or 0,budget.notes)-1 do
        budget.notes=budget.notes-1
        local valid,_,muted,_,_,channel,pitch=call(r.MIDI_GetNote,take,n)
        if valid then
          local key=channel*128+pitch
          counts[key]=counts[key]or{channel=channel+1,pitch=pitch,count=0,muted=0}
          counts[key].count=counts[key].count+1
          counts[key].muted=counts[key].muted+(muted and 1 or 0)
          entry.scanned=entry.scanned+1
        else entry.read_error=true end
      end
      for key=0,2047 do if counts[key] then entry.histogram[#entry.histogram+1]=counts[key] end end
      entry.truncated=entry.scanned<(notes or 0)
      result.items[#result.items+1]=entry
    end
  end
  result.truncated=count>inspect
  return result
end
return M
