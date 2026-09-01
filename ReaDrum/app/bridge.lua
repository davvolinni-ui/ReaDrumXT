-- @noindex
local M={SECTION="ReaDrumBridge"}
local function get(host,project,key)local _,value=host.GetProjExtState(project,M.SECTION,key);return value end
function M.poll(host,project,last_id)
  local id=get(host,project,"command_id");if id==""or id==last_id then return nil,last_id end
  return{ id=id,command=get(host,project,"command"),path=get(host,project,"path"),pad=tonumber(get(host,project,"pad"))},id
end
function M.ack(host,project,id,status)host.SetProjExtState(project,M.SECTION,"ack_id",id or"");host.SetProjExtState(project,M.SECTION,"ack_status",status or"ok")end
return M
