-- @noindex
local M={VERSION=1,SECTION="ReaDrumXT"}

local function clean(value)
  return tostring(value or ""):gsub("%*%*",""):gsub("`([^`]*)`","%1"):gsub("^%s+",""):gsub("%s+$","")
end

local function load_document(path)
  local file,open_error=io.open(path,"rb")
  if not file then return nil,"EULA.md is missing from the ReaDrumXT installation: "..tostring(open_error or path) end
  local text=file:read("*a") or "";file:close()
  if text=="" then return nil,"EULA.md is empty. Reinstall ReaDrumXT before continuing." end
  return text
end

function M.load(product_directory)
  local path=product_directory:gsub("[/\\]+$","").."/EULA.md"
  return load_document(path)
end

local function render_document(host,ctx,markdown,accent)
  local blocks,current={},nil
  local function flush()
    if current and current.text~="" then current.text=clean(current.text);blocks[#blocks+1]=current end
    current=nil
  end
  local normalized=tostring(markdown or ""):gsub("\r","")
  for line in (normalized.."\n"):gmatch("(.-)\n") do
    local heading=line:match("^##%s+(.+)$");local title=line:match("^#%s+(.+)$");local bullet=line:match("^%-%s+(.+)$")
    if line:match("^%s*$") then flush()
    elseif heading then flush();blocks[#blocks+1]={kind="heading",text=clean(heading)}
    elseif title then flush();blocks[#blocks+1]={kind="title",text=clean(title)}
    elseif bullet then flush();current={kind="bullet",text=bullet}
    else
      local trimmed=clean(line)
      if not current then current={kind=trimmed:match("^TO THE MAXIMUM EXTENT") and "disclaimer" or "paragraph",text=trimmed}
      elseif trimmed~="" then current.text=current.text.." "..trimmed end
    end
  end
  flush()
  for _,block in ipairs(blocks) do
    if block.kind=="heading" then
      host.ImGui_Spacing(ctx);host.ImGui_PushStyleColor(ctx,host.ImGui_Col_Text(),accent);host.ImGui_TextWrapped(ctx,block.text);host.ImGui_PopStyleColor(ctx);host.ImGui_Separator(ctx)
    elseif block.kind=="bullet" then
      host.ImGui_Indent(ctx,10);host.ImGui_TextWrapped(ctx,"•  "..block.text);host.ImGui_Unindent(ctx,10)
    elseif block.kind=="disclaimer" then
      host.ImGui_PushStyleColor(ctx,host.ImGui_Col_Text(),accent);host.ImGui_TextWrapped(ctx,block.text);host.ImGui_PopStyleColor(ctx);host.ImGui_Spacing(ctx)
    elseif block.kind~="title" then host.ImGui_TextWrapped(ctx,block.text);host.ImGui_Spacing(ctx) end
  end
end

function M.render(host,ctx,markdown,accent)
  render_document(host,ctx,markdown,accent)
end

function M.is_accepted(host)
  return (tonumber(host.GetExtState(M.SECTION,"eula_accepted_version")) or 0)>=M.VERSION
end

function M.begin(host,product_directory,on_accept,owns_runtime,on_error)
  if M.is_accepted(host) then host.defer(on_accept);return end
  if not host.ImGui_CreateContext then
    on_error("ReaImGui is required to review and accept the ReaDrumXT EULA.")
    return
  end
  local text,error_text=M.load(product_directory)
  local ctx=host.ImGui_CreateContext("ReaDrumXT License Agreement")
  local checked,declined,complete=false,false,false
  local accent=0x1687D5FF
  local function accept()
    host.SetExtState(M.SECTION,"eula_accepted_version",tostring(M.VERSION),true)
    host.SetExtState(M.SECTION,"eula_accepted_at",tostring(os.time()),true)
    if not M.is_accepted(host) then error_text="REAPER could not save your acceptance. Check that REAPER's settings are writable.";return end
    complete=true
  end
  local safe_frame
  local function frame()
    if owns_runtime and not owns_runtime() then return end
    if host.ImGui_SetNextWindowSize then host.ImGui_SetNextWindowSize(ctx,760,700,host.ImGui_Cond_Appearing and host.ImGui_Cond_Appearing() or 0) end
    local flags=host.ImGui_WindowFlags_NoCollapse and host.ImGui_WindowFlags_NoCollapse() or 0
    local visible,open=host.ImGui_Begin(ctx,"ReaDrumXT",true,flags)
    if visible then
      host.ImGui_PushStyleColor(ctx,host.ImGui_Col_Text(),accent);host.ImGui_Text(ctx,"READRUMXT");host.ImGui_PopStyleColor(ctx)
      host.ImGui_Text(ctx,"End User License Agreement");host.ImGui_SameLine(ctx);host.ImGui_TextDisabled(ctx,"Version "..M.VERSION)
      host.ImGui_TextWrapped(ctx,"Please review these terms. ReaDrumXT will initialize only after you explicitly agree.")
      host.ImGui_Separator(ctx)
      local _,available_height=host.ImGui_GetContentRegionAvail(ctx);local agreement_height=math.max(220,available_height-145)
      local child_flags=host.ImGui_ChildFlags_Borders and host.ImGui_ChildFlags_Borders() or 0
      local child_visible=host.ImGui_BeginChild(ctx,"##readrum_eula_text",0,agreement_height,child_flags)
      if child_visible then
        if text then render_document(host,ctx,text,accent) else host.ImGui_TextWrapped(ctx,error_text or "The agreement could not be loaded.") end
      end
      host.ImGui_EndChild(ctx)
      host.ImGui_Spacing(ctx)
      local changed,next_checked=host.ImGui_Checkbox(ctx,"##readrum_eula_accept",checked);if changed then checked=next_checked end
      host.ImGui_SameLine(ctx);host.ImGui_TextWrapped(ctx,"I have read and agree to the ReaDrumXT EULA.")
      if error_text then host.ImGui_TextWrapped(ctx,error_text) end
      host.ImGui_TextDisabled(ctx,"Acceptance is stored on this REAPER installation.")
      local available_width=host.ImGui_GetContentRegionAvail(ctx);local button_width=math.max(120,(available_width-8)*.5)
      local blocked=not checked or not text or error_text~=nil
      if blocked and host.ImGui_BeginDisabled then host.ImGui_BeginDisabled(ctx,true) end
      local agreed=host.ImGui_Button(ctx,"Agree and Continue",button_width,0)
      if blocked and host.ImGui_EndDisabled then host.ImGui_EndDisabled(ctx) end
      if agreed and not blocked then accept() end
      host.ImGui_SameLine(ctx,0,8);if host.ImGui_Button(ctx,"Decline and Close",button_width,0) then declined=true end
    end
    host.ImGui_End(ctx)
    if complete then host.defer(on_accept)
    elseif declined or not open then return
    else host.defer(safe_frame) end
  end
  safe_frame=function()
    local ok,failure=xpcall(frame,debug.traceback)
    if not ok then on_error(failure) end
  end
  safe_frame()
end

return M
