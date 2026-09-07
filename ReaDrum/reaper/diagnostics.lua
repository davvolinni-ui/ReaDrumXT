-- @noindex
-- Production diagnostics. Active-project inspection is deliberately read-only:
-- this module contains no REAPER project mutation calls.
local json=require("ReaDrum.core.json")
local sampler_bank=require("ReaDrum.reaper.sampler_bank")
local inventory=require("ReaDrum.reaper.diagnostic_inventory")
local M={VERSION=2}
local sep=package.config:sub(1,1)

local function call(fn,...)
  if type(fn)~="function" then return nil end
  local ok,a,b,c,d=pcall(fn,...);if not ok then return nil end;return a,b,c,d
end
local function write(path,text)local f,e=io.open(path,"wb");if not f then return nil,e end;f:write(text);f:close();return true end
local function read(path)local f=io.open(path,"rb");if not f then return nil end;local s=f:read("*a");f:close();return s end
local function basename(path)return type(path)=="string"and(path:match("([^/\\]+)$")or path)or""end
local function sanitize(text)
  text=tostring(text or"");local home=os.getenv("USERPROFILE")or os.getenv("HOME")
  if home and home~=""then text=text:gsub(home:gsub("([^%w])","%%%1"),"<HOME>")end
  return text
end
local function fingerprint(path)
  local data=read(path);if not data then return{present=false}end
  local h=2166136261;for i=1,#data do h=((h~data:byte(i))*16777619)&0xffffffff end
  return{present=true,bytes=#data,fnv1a32=string.format("%08x",h)}
end
local function track_report(r,track,index)
  local _,name=call(r.GetTrackName,track,"");local item={index=index,name=name or"",channels=call(r.GetMediaTrackInfo_Value,track,"I_NCHAN"),mute=call(r.GetMediaTrackInfo_Value,track,"B_MUTE"),solo=call(r.GetMediaTrackInfo_Value,track,"I_SOLO"),main_send=call(r.GetMediaTrackInfo_Value,track,"B_MAINSEND"),fx={},sends={}}
  for fx=0,(call(r.TrackFX_GetCount,track)or 0)-1 do
    local _,fxname=call(r.TrackFX_GetFXName,track,fx,"")
    item.fx[#item.fx+1]={index=fx,name=fxname or"",enabled=call(r.TrackFX_GetEnabled,track,fx),offline=call(r.TrackFX_GetOffline,track,fx)}
    local effect=item.fx[#item.fx]
    local ok,identity=call(r.TrackFX_GetNamedConfigParm,track,fx,"fx_ident")
    effect.identity_available=ok==true
    if ok then effect.identity=sanitize(identity) end
    local renamed,value=call(r.TrackFX_GetNamedConfigParm,track,fx,"renamed_name")
    if renamed then effect.renamed_name=value end
  end
  for send=0,(call(r.GetTrackNumSends,track,0)or 0)-1 do
    local dst=call(r.GetTrackSendInfo_Value,track,0,send,"P_DESTTRACK");local dstname=""
    if dst then local _,name=call(r.GetTrackName,dst,"");dstname=name or""end
    item.sends[#item.sends+1]={index=send,destination=dstname or"",source_channels=call(r.GetTrackSendInfo_Value,track,0,send,"I_SRCCHAN"),destination_channels=call(r.GetTrackSendInfo_Value,track,0,send,"I_DSTCHAN"),midi_flags=call(r.GetTrackSendInfo_Value,track,0,send,"I_MIDIFLAGS"),volume=call(r.GetTrackSendInfo_Value,track,0,send,"D_VOL")}
    item.sends[#item.sends].mute=call(r.GetTrackSendInfo_Value,track,0,send,"B_MUTE")
    item.sends[#item.sends].mode=call(r.GetTrackSendInfo_Value,track,0,send,"I_SENDMODE")
    item.sends[#item.sends].destination_index=dst and call(r.GetMediaTrackInfo_Value,dst,"IP_TRACKNUMBER")
  end
  return item
end
local function runtime_report(r,app)
  local result={};local track=app and call(app.find_track,app,"sequencer");if not track then return{available=false}end
  -- Controller:dispatcher can ADD a missing FX. Diagnostics must only inspect.
  local fx
  for index=0,(call(r.TrackFX_GetCount,track)or 0)-1 do
    local _,name=call(r.TrackFX_GetFXName,track,index,"")
    if name and name:find("ReaDrum Round Robin Dispatcher",1,true) then fx=index;break end
  end
  if fx==nil then return{available=false,reason="dispatcher not found"}end
  local fields={sample_rate=67,runtime_magic=28,runtime_version=29,runtime_words=31,runtime_checksum=32,runtime_commit=33,active_revision=34,pending_revision=35,runtime_promote=36,map_magic=37,map_version=38,map_words=40,map_checksum=41,map_commit=42,map_promote=43,budget_status=44,budget_rejection=52,runtime_guard=53,future_queue=54,future_queue_peak=55,off_queue=56,off_queue_peak=57,fault_latch=58,stage_blocks=59,stage_ons=60,stage_future=61,stage_owned=62,stage_result=63,fill=64,map_live_midi=65,dispatcher_playback_mode=66,active_variation=71,pending_variation=72,variation_count=74,transport_playing=79,map_active_words=80}
  result.available=true;for key,param in pairs(fields)do result[key]=call(r.TrackFX_GetParam,track,fx,param)end
  result.controller_playback_mode=app.rack and app.rack.playback_mode or nil
  result.expected_revision=app.revision
  result.last_published_rate=app.last_published_rate
  result.follow_variation_events=app.follow_variation_events
  result.banks={};local project=select(1,call(r.EnumProjects,-1,""))or 0
  for ti=0,(call(r.CountTracks,project)or 0)-1 do local candidate=call(r.GetTrack,project,ti);local _,track_name=call(r.GetTrackName,candidate,"")
    for index=0,(call(r.TrackFX_GetCount,candidate)or 0)-1 do local _,name=call(r.TrackFX_GetFXName,candidate,index,"");if name and name:find("ReaDrum Sampler Bank",1,true)then result.banks[#result.banks+1]={track=track_name or"",name=name,bank=call(r.TrackFX_GetParam,candidate,index,0),heartbeat=call(r.TrackFX_GetParam,candidate,index,1),idle_heartbeat=call(r.TrackFX_GetParam,candidate,index,2),observed=call(r.TrackFX_GetParam,candidate,index,3),namespace=call(r.TrackFX_GetParam,candidate,index,4),note_ons=call(r.TrackFX_GetParam,candidate,index,5),voices=call(r.TrackFX_GetParam,candidate,index,6),active=call(r.TrackFX_GetParam,candidate,index,7),peak=call(r.TrackFX_GetParam,candidate,index,8)}end end
  end
  return result
end
function M.collect(r,app,product_directory)
  local report={schema="readrumxt-diagnostic",version=M.VERSION,generated_utc=os.date("!%Y-%m-%dT%H:%M:%SZ"),platform={os=call(r.GetOS),reaper=call(r.GetAppVersion),lua=_VERSION},project={transport=call(r.GetPlayState),position=call(r.GetPlayPosition),tracks={}},runtime=runtime_report(r,app),installation={},samples={}}
  local project=select(1,call(r.EnumProjects,-1,""))or 0
  local budget={items=256,notes=4096}
  report.midi_scan_limits={items=256,notes=4096,active_takes_only=true}
  for index=0,(call(r.CountTracks,project)or 0)-1 do
    local track=call(r.GetTrack,project,index)
    local entry=track_report(r,track,index)
    entry.midi=inventory.midi(r,track,budget)
    report.project.tracks[#report.project.tracks+1]=entry
  end
  local files={"ReaDrum.lua","app/controller.lua","app/ui.lua","reaper/snapshot_v2.lua","reaper/diagnostics.lua"}
  for _,relative in ipairs(files)do local path=product_directory..sep..relative:gsub("/",sep);report.installation[relative]=fingerprint(path)end
  for index,pad in ipairs(app and app.rack and app.rack.pads or{})do local sample=type(pad.sample)=="table"and pad.sample.path or pad.sample;if sample then
    local logical=math.max(1,math.floor(tonumber(pad.logical_index)or index))-1;local bank,slot=math.floor(logical/16),logical%16;local namespace=app.rack.engine_namespace or 0
    local entry={pad=index,file=basename(sample),accessible=call(app.adapter.file_exists,app.adapter,sample)==true,bank=bank,slot=slot,namespace=namespace}
    entry.output_id=pad.output_id;entry.muted=pad.muted;entry.soloed=pad.soloed
    entry.choke_group=pad.choke_group;entry.self_choke=pad.self_choke
    entry.round_robin_groups={}
    for _,group in ipairs(app.rack.round_robin_groups or{}) do
      local member=group.master_pad_id==pad.id
      for _,id in ipairs(group.member_pad_ids or{}) do if id==pad.id then member=true;break end end
      if member then entry.round_robin_groups[#entry.round_robin_groups+1]={id=group.id,mode=group.mode,master_pad_id=group.master_pad_id,member_pad_ids=group.member_pad_ids} end
    end
    local ok,status=pcall(sampler_bank.status,r,bank,slot,namespace);if ok then entry.sampler_status=status end
    entry.sampler_live=call(sampler_bank.live,r,bank,slot,namespace);entry.control_revision=call(sampler_bank.control_revision,r,bank,slot,namespace)
    report.samples[#report.samples+1]=entry
  end end
  report.error_log=sanitize(read(product_directory..sep.."ReaDrum-error.log")or"")
  return report
end
local function quote(value)return'"'..tostring(value):gsub('"','\\"')..'"'end
function M.resolve_executable(r)
  local directory=assert(call(r.GetExePath),"REAPER did not provide its executable directory")
  local osname=call(r.GetOS)or"Other";local names
  if osname:find("Win",1,true)then names={"reaper.exe","REAPER.exe"}
  elseif osname:find("OSX",1,true)or osname:find("macOS",1,true)then names={"REAPER","reaper"}
  else names={"reaper","REAPER"}end
  local path_separator=osname:find("Win",1,true)and"\\"or"/"
  for _,name in ipairs(names)do
    local path=directory..path_separator..name
    if type(r.file_exists)~="function"or call(r.file_exists,path)==true then return path,osname end
  end
  error("Could not locate the REAPER executable in "..directory.." for "..osname)
end
function M.report_directory(r,environment)
  return assert(call(r.GetResourcePath),"REAPER did not provide a writable report location")..sep.."Data"..sep.."ReaDrumXT"..sep.."Diagnostics"
end
function M.create(r,app,product_directory)
  local report_directory=M.report_directory(r);assert(call(r.RecursiveCreateDirectory,report_directory,0)~=nil,"Could not access the diagnostic report location")
  local id=os.date("%Y%m%d-%H%M%S").."-"..tostring(math.floor((call(r.time_precise)or os.time())*1000)%1000000);local directory=report_directory..sep.."ReaDrumXT-Diagnostic-"..id
  assert(call(r.RecursiveCreateDirectory,directory,0)~=nil,"Could not create diagnostic folder")
  local executable,osname=M.resolve_executable(r)
  local report=M.collect(r,app,product_directory);report.diagnostic_launch={method="REAPER ExecProcess",executable=basename(executable),platform=osname};assert(write(directory..sep.."project-report.json",json.encode(report)))
  local disposable=directory..sep.."isolated-diagnostic.rpp";assert(write(disposable,'<REAPER_PROJECT 0.1 "ReaDrumXT Diagnostic" 0\n>\n'))
  local report_path=report_directory..sep.."ReaDrumXT-Diagnostic-"..id..".json"
  local request=r.GetResourcePath()..sep.."Data"..sep.."ReaDrum"..sep.."diagnostic-request.txt";call(r.RecursiveCreateDirectory,r.GetResourcePath()..sep.."Data"..sep.."ReaDrum",0)
  local runner=product_directory..sep.."reaper"..sep.."diagnostic_runner.lua";local command
  command=quote(executable).." -newinst -nosplash "..quote(disposable).." "..quote(runner)
  -- Keep the timestamp last: the normal startup action uses it to suppress its
  -- UI only while this exact short-lived diagnostic request is active.
  write(request,table.concat({id,directory,product_directory,disposable,report_path,tostring(os.time())},"\n"))
  -- Never wait for the secondary process in the production UI. A long
  -- ExecProcess wait stalls ReaImGui between frames and invalidates its window
  -- stack on some systems. The disposable runner packages the report itself.
  local launched,output=pcall(r.ExecProcess,command,-1)
  assert(launched and output~=nil,"REAPER could not launch the isolated diagnostic instance")
  write(directory..sep.."runner-launch.txt",sanitize(output or"secondary diagnostic process launched"))
  return{directory=directory,report=report_path,started=call(r.time_precise)or os.time()}
end
function M.is_ready(job)
  if type(job)~="table"then return false end
  local report=io.open(job.report or"","rb");if report then local size=report:seek("end")or 0;report:close();return size>0 end
  return false
end
function M.save_capture(r,report)
  local directory=M.report_directory(r)
  assert(call(r.RecursiveCreateDirectory,directory,0)~=nil,"Could not create capture folder")
  local path=directory..sep.."ReaDrumXT-Playback-"..os.date("%Y%m%d-%H%M%S").."-"..tostring(math.floor(r.time_precise()*1000)%1000000)..".json"
  assert(write(path,json.encode(report)))
  return path
end
return M
