-- @noindex
-- Explicit, transient gmem requests only. No FX setters, transport or project edits.
local M={BASE=8000000,STRIDE=2304,DURATION=10}
local function attach(r,target)r.gmem_attach(target.memory)end
function M.start(r,app)
  local targets={}
  local function add(track,needle,param,memory,bank)
    if not track then return end
    for fx=0,r.TrackFX_GetCount(track)-1 do
      local ok,name=r.TrackFX_GetFXName(track,fx,"")
      if ok and name:find(needle,1,true) then
        local named,label=r.TrackFX_GetParamName(track,fx,param,"")
        local id=named and label:find("capture instance v1",1,true) and r.TrackFX_GetParam(track,fx,param)
        assert(id and id>0,"Capture requires the updated, running dispatcher and sampler FX; no FX were reloaded.")
        targets[#targets+1]={track=track,fx=fx,id=id,param=param,memory=memory,bank=bank,base=M.BASE+(bank or 0)*M.STRIDE}
      end
    end
  end
  add(app:find_track("sequencer"),"ReaDrum Round Robin Dispatcher",104,"ReaDrumSnapshot")
  assert(#targets==1,"Capture requires exactly one dispatcher on the sequencer track")
  for bank=0,7 do add(app:find_track("bank",tostring(bank)),"ReaDrum Sampler Bank",9,"ReaDrumSampler",bank) end
  local now=r.time_precise()
  local used={}
  for _,target in ipairs(targets) do
    local key=target.memory..":"..target.base
    assert(not used[key],"Duplicate sampler bank FX; capture cannot safely select one")
    used[key]=true;attach(r,target)
    assert(r.gmem_read(target.base+1)<=now,"Another playback capture is running")
  end
  -- Publish the target last so the audio thread cannot see a partial request.
  for _,target in ipairs(targets) do
    attach(r,target);r.gmem_write(target.base,0)
    for i=1,M.STRIDE-1 do r.gmem_write(target.base+i,0) end
    r.gmem_write(target.base+1,now+M.DURATION)
    r.gmem_write(target.base,target.id)
  end
  return{targets=targets,started=now,deadline=now+M.DURATION}
end
function M.finish(r,job)
  assert(r.time_precise()>=job.deadline+.1,"Capture has not finished")
  local report={schema="readrumxt-playback-capture",version=1,duration_seconds=M.DURATION,
    meaning="Note-ons received by pitch/channel (input buses combined); dispatcher emissions by destination bank/channel, expressed as pad index 1-128 (including raw MIDI passthrough); sampler voice starts by slot (legato retargets are not new voices). Voice starts do not prove audible output. Pad audition is included. Counts saturate at 16777215.",engines={}}
  for _,target in ipairs(job.targets) do
    attach(r,target)
    local owned=r.gmem_read(target.base)==target.id
    local valid,current=pcall(r.TrackFX_GetParam,target.track,target.fx,target.param)
    local entry={kind=target.bank==nil and "dispatcher" or "sampler",bank=target.bank,available=owned,
      instance_unchanged=valid and current==target.id,input={},outputs={}}
    if entry.instance_unchanged then
      if target.bank==nil then
        entry.map_live_midi=r.TrackFX_GetParam(target.track,target.fx,65)
        entry.playback_mode=r.TrackFX_GetParam(target.track,target.fx,66)
        entry.active_revision=r.TrackFX_GetParam(target.track,target.fx,34)
      else entry.actual_bank=r.TrackFX_GetParam(target.track,target.fx,0) end
    end
    if owned then
      -- Deadline has expired before this function is called; no active writer.
      entry.blocks=r.gmem_read(target.base+2);entry.sample_rate=r.gmem_read(target.base+3)
      entry.acknowledged=entry.blocks>0
      for i=0,2047 do local count=r.gmem_read(target.base+16+i)
        if count>0 then entry.input[#entry.input+1]={channel=math.floor(i/128)+1,pitch=i%128,count=count} end
      end
      for i=0,(target.bank==nil and 127 or 15) do local count=r.gmem_read(target.base+16+2048+i)
        if count>0 then entry.outputs[#entry.outputs+1]={index=i+1,count=count} end
      end
      r.gmem_write(target.base,0)
    end
    report.engines[#report.engines+1]=entry
  end
  return report
end
return M
