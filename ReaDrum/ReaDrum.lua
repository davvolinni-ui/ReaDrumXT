-- @description ReaDrumXT - Drum Sampler and Polymetric Step Sequencer
-- @version 0.1.0
-- @author davvolinni-ui
-- @changelog
--   Initial public release.
-- @link
--   Support https://forum.cockos.com/showthread.php?t=310870
--   Repository https://github.com/davvolinni-ui/ReaDrumXT
-- @provides
--   [nomain] EULA.md
--   [nomain] THIRD_PARTY_NOTICES.md
--   [nomain] app/*.lua
--   [nomain] core/*.lua
--   [nomain] reaper/*.lua
--   [effect] Effects/*.jsfx > ReaDrum/

local source = debug.getinfo(1, "S").source:sub(2)
local scripts = assert(source:match("^(.*)[/\\]ReaDrum[/\\]ReaDrum%.lua$"), "ReaDrum must remain inside Scripts/ReaDrum")
package.path = scripts .. "/?.lua;" .. scripts .. "/?/init.lua;" .. package.path

local Controller = require("ReaDrum.app.controller")
local UI = require("ReaDrum.app.ui")
local EULA = require("ReaDrum.app.eula")

local launch_started=reaper.time_precise()
-- ReaScripts are deferred processes: running the action again does not stop
-- the previous controller. Without ownership, several invisible instances
-- publish different revisions into one dispatcher. The newest launch owns the
-- runtime; older loops observe the generation change, save, and exit.
local runtime_section="ReaDrumXT_Runtime"
local runtime_key="owner_generation"
local owner_generation=(tonumber(reaper.GetExtState(runtime_section,runtime_key))or 0)%16777214+1
reaper.SetExtState(runtime_section,runtime_key,tostring(owner_generation),false)
local function owns_runtime()
  return tonumber(reaper.GetExtState(runtime_section,runtime_key))==owner_generation
end

local function report_error(title,failure)
  local message=tostring(failure)
  pcall(function()
    local file=assert(io.open(scripts.."/ReaDrum/ReaDrum-error.log","ab"))
    file:write(os.date("!%Y-%m-%dT%H:%M:%SZ"),"  ",title,"\n",message,"\n\n");file:close()
  end)
  reaper.MB(message.."\n\nA diagnostic log was written beside ReaDrum.lua.",title,0)
end

local function launch()
  if not owns_runtime() then return end
  -- Give a superseded deferred instance one UI cycle to save and close before
  -- this controller reads project state and publishes its first revision.
  if reaper.time_precise()-launch_started<0.15 then reaper.defer(launch);return end
  -- Startup actions can run before a saved project's extension state finishes
  -- loading.  Initializing in that gap creates a second rack.  Unsaved/new
  -- projects start immediately; saved projects get a short state-load grace.
  local project,project_path=reaper.EnumProjects(-1,"")
  local _,chunks=reaper.GetProjExtState(project,"ReaDrum","chunks")
  if project_path and project_path~="" and not tonumber(chunks) and reaper.time_precise()-launch_started<5 then
    reaper.defer(launch);return
  end

  local ok, app_or_error = xpcall(function() return Controller.new(reaper, project) end, debug.traceback)
  if not ok then report_error("ReaDrumXT could not start",app_or_error);return end
  local app = app_or_error
  local ok_ui, ui_or_error = xpcall(function() return UI.new(reaper, app) end, debug.traceback)
  if not ok_ui then pcall(function()app:close()end);report_error("ReaDrumXT could not open its interface",ui_or_error);return end
  local ui = ui_or_error

  local function project_guid(bound_project)
    return reaper.GetProjectGUID and reaper.GetProjectGUID(bound_project) or tostring(bound_project)
  end
  local function project_change_count(bound_project)
    return reaper.GetProjectStateChangeCount and reaper.GetProjectStateChangeCount(bound_project) or 0
  end
  local function project_has_readrum_state(bound_project)
    local _,chunks=reaper.GetProjExtState(bound_project,"ReaDrum","chunks")
    return tonumber(chunks)~=nil
  end
  local function project_state_signature(bound_project)
    local _,chunks=reaper.GetProjExtState(bound_project,"ReaDrum","chunks")
    local count=tonumber(chunks)
    if not count then return nil end
    local _,first=reaper.GetProjExtState(bound_project,"ReaDrum","state_001")
    local _,last=reaper.GetProjExtState(bound_project,"ReaDrum",string.format("state_%03d",count))
    return tostring(count)..":"..tostring(#first)..":"..first..":"..tostring(#last)..":"..last
  end
  local controllers={[project]={app=app,guid=project_guid(project),change_count=project_change_count(project),state_signature=project_state_signature(project)}}
  local current_project,current_app,current_guid=project,app,project_guid(project)
  local current_change_count=project_change_count(project)
  local pending_state_project,pending_state_guid,pending_state_started=nil,nil,nil
  local pending_rebind_signature=nil
  local closed=false
  local function project_is_open(target)
    local index=0
    while true do
      local candidate=reaper.EnumProjects(index,"")
      if not candidate then return false end
      if candidate==target then return true end
      index=index+1
    end
  end
  local function close()
    if closed then return end
    closed=true
    local active=reaper.EnumProjects(-1,"")
    for bound_project,binding in pairs(controllers) do
      if project_is_open(bound_project) and project_guid(bound_project)==binding.guid then
        if bound_project==active then pcall(function()binding.app:close()end)
        else pcall(function()binding.app:save_state_only()end) end
      end
    end
  end
  reaper.atexit(close)

  local function loop()
    if not owns_runtime() then close();return end
    local active_project,active_path=reaper.EnumProjects(-1,"")
    local active_guid=project_guid(active_project)
    local active_change_count=project_change_count(active_project)
    local has_readrum_state=project_has_readrum_state(active_project)
    local active_state_signature=has_readrum_state and project_state_signature(active_project) or nil
    local current_binding=controllers[current_project]
    local loaded_state_changed=active_project==current_project and current_binding and
      active_state_signature and current_binding.state_signature and
      active_state_signature~=current_binding.state_signature
    local project_replaced=active_project==current_project and
      (active_change_count<current_change_count or not has_readrum_state or loaded_state_changed)
    local project_changed=active_project~=current_project or active_guid~=current_guid or project_replaced
    local pending_state_ready=pending_state_project==active_project and
      pending_state_guid==active_guid and has_readrum_state

    -- Keep the transition latched while waiting. Once extension state appears,
    -- force a rebind even if REAPER reused the same handle/GUID and its change
    -- count has already caught up with the previous project.
    if pending_state_ready then
      project_replaced=true
      project_changed=true
    end

    -- Commit one lightweight ImGui frame before constructing/reconciling the
    -- restored controller. Otherwise the previous project's full UI remains
    -- visible throughout that potentially multi-second operation.
    if project_changed and has_readrum_state and pending_rebind_signature~=active_state_signature then
      pending_rebind_signature=active_state_signature
      local framed,keep_open=xpcall(function()return ui:loading_frame()end,debug.traceback)
      if not framed then close();report_error("ReaDrum loading interface error",keep_open);return end
      if not keep_open then close();return end
      reaper.defer(loop);return
    end

    -- REAPER can reuse a project handle while reopening a saved project, and
    -- its path becomes visible before extension state is restored.  Do not
    -- construct (and immediately save) a blank controller during that gap.
    if project_changed and not has_readrum_state then
      if pending_state_project~=active_project or pending_state_guid~=active_guid then
        pending_state_project,pending_state_guid,pending_state_started=active_project,active_guid,reaper.time_precise()
      end
      if reaper.time_precise()-pending_state_started<5 then
        local framed,keep_open=xpcall(function()return ui:loading_frame()end,debug.traceback)
        if not framed then close();report_error("ReaDrum loading interface error",keep_open);return end
        if not keep_open then close();return end
        reaper.defer(loop);return
      end
    elseif not pending_state_ready then
      pending_state_project,pending_state_guid,pending_state_started=nil,nil,nil
    end
    if project_changed then
      if not project_replaced and project_is_open(current_project) and project_guid(current_project)==current_guid then
        ui:flush_audition(true)
        pcall(function()current_app:save_state_only()end)
      else controllers[current_project]=nil end
      local binding=controllers[active_project]
      if binding and (binding.guid~=active_guid or active_change_count<binding.change_count) then binding=nil;controllers[active_project]=nil end
      if not binding then
        local made,next_or_error=xpcall(function()return Controller.new(reaper,active_project)end,debug.traceback)
        if not made then close();report_error("ReaDrum could not initialize the active project",next_or_error);return end
        binding={app=next_or_error,guid=active_guid,change_count=project_change_count(active_project),state_signature=project_state_signature(active_project)};controllers[active_project]=binding
      end
      current_project,current_app,current_guid=active_project,binding.app,active_guid
      current_change_count=binding.change_count
      pending_state_project,pending_state_guid,pending_state_started=nil,nil,nil
      pending_rebind_signature=nil
      ui:bind_app(binding.app)
    end
    local success, keep_open = xpcall(function() return ui:frame() end, debug.traceback)
    if not success then close();report_error("ReaDrum error",keep_open);return end
    current_change_count=project_change_count(current_project)
    current_binding=controllers[current_project]
    if current_binding then current_binding.change_count=current_change_count end
    if current_binding then current_binding.state_signature=project_state_signature(current_project) end
    if keep_open then reaper.defer(loop) else close() end
  end

  reaper.defer(loop)
end

EULA.begin(reaper,scripts.."/ReaDrum",launch,owns_runtime,function(failure)
  report_error("ReaDrumXT license agreement error",failure)
end)
