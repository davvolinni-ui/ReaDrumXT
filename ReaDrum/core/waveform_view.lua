-- @noindex
-- Editor-only coordinates; never persisted in pad or playback state.
local M={}
function M.zoom(first,last,anchor,wheel)
  local span=last-first
  local next_span=math.max(1/64,math.min(1,span*2^(-wheel/4)))
  local next_first=math.max(0,math.min(1-next_span,first+anchor*(span-next_span)))
  return next_first,next_first+next_span
end
function M.pan(first,last,delta)
  local span=last-first
  local next_first=math.max(0,math.min(1-span,first+delta))
  return next_first,next_first+span
end
function M.screen(position,first,last,width)
  return (position-first)/(last-first)*width
end
function M.position(pixel,first,last,width)
  return first+pixel/width*(last-first)
end
return M
