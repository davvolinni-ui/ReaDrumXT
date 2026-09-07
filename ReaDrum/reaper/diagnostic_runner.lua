-- @noindex
-- Runs only in a secondary disposable REAPER instance.
local source=debug.getinfo(1,"S").source:sub(2);local product=assert(source:match("^(.*)[/\\]reaper[/\\]diagnostic_runner%.lua$"));local sep=package.config:sub(1,1)
package.path=product:match("^(.*)[/\\]ReaDrum$")..sep.."?.lua;"..package.path
local json=require("ReaDrum.core.json");local request=reaper.GetResourcePath()..sep.."Data"..sep.."ReaDrum"..sep.."diagnostic-request.txt"
local function read(path)local f=io.open(path,"rb");if not f then return nil end;local s=f:read("*a");f:close();return s end
local function write(path,value)local f=assert(io.open(path,"wb"));f:write(type(value)=="string"and value or json.encode(value));f:close()end
local raw=read(request)or"";local id,directory,expected,disposable,report_path=raw:match("([^\r\n]+)[\r\n]+([^\r\n]+)[\r\n]+([^\r\n]+)[\r\n]+([^\r\n]+)[\r\n]+([^\r\n]+)")
local result={schema="readrumxt-isolated-test",version=2,generated_utc=os.date("!%Y-%m-%dT%H:%M:%SZ"),id=id,status="pass",tests={}};local app
local function test(name,fn)local ok,value=xpcall(fn,debug.traceback);result.tests[#result.tests+1]={name=name,status=ok and"pass"or"fail",detail=ok and value or tostring(value)};if not ok then result.status="fail"end;return ok end
local function normalized(path)return tostring(path or""):gsub("\\","/"):lower()end
local function make_wav(path)local rate,frames=44100,11025;local chunks={}for i=0,frames-1 do local sample=math.floor(math.sin(2*math.pi*220*i/rate)*math.exp(-i/(rate*.08))*28000);chunks[#chunks+1]=string.pack("<i2",sample)end;local pcm=table.concat(chunks);write(path,"RIFF"..string.pack("<I4",36+#pcm).."WAVEfmt "..string.pack("<I4I2I2I4I4I2I2",16,1,1,rate,rate*2,2,16).."data"..string.pack("<I4",#pcm)..pcm)end
local function finish()
  if app then pcall(app.close,app);app=nil end
  if directory then
    test("save disposable evidence",function()reaper.Main_SaveProject(0,false);assert(not reaper.IsProjectDirty or reaper.IsProjectDirty(0)==0,"disposable project could not be saved cleanly")return"saved"end)
    write(directory..sep.."isolated-test.json",result);local ok,active=pcall(json.decode,read(directory..sep.."project-report.json")or"{}");if not ok then active={decode_error=tostring(active)}end
    if report_path then write(report_path,{schema="readrumxt-diagnostic-bundle",version=2,active_project=active,isolated_test=result})end
  end
  os.remove(request);if not reaper.IsProjectDirty or reaper.IsProjectDirty(0)==0 then reaper.Main_OnCommand(40004,0)end
end
test("request isolation",function()assert(directory and expected==product,"diagnostic request mismatch")return"unique request accepted"end)
test("module load",function()local c=require("ReaDrum.app.controller");local s=require("ReaDrum.reaper.snapshot_v2");assert(c and s.VERSION==2)return"production modules loaded"end)
local _,project_path=reaper.EnumProjects(-1,"");local project_count=0;while reaper.EnumProjects(project_count,"")do project_count=project_count+1 end
local isolated=disposable and normalized(project_path)==normalized(disposable)and project_count==1 and reaper.CountTracks(0)==0 and reaper.CountMediaItems(0)==0
test("dedicated secondary project",function()assert(isolated,"runner was not given its sole disposable project; active test skipped")return"sole disposable project verified before mutation"end)
if not isolated then finish();return end
local wav=directory..sep.."diagnostic-source.wav";make_wav(wav)
if not test("fresh disposable engine",function()
  local Controller=require("ReaDrum.app.controller");app=Controller.new(reaper,0);app:set_playback_mode("continuous",false);assert(app:load_sample_path(1,wav),"diagnostic sample 1 was not accepted");assert(app:load_sample_path(2,wav),"diagnostic sample 2 was not accepted")
  local lane1=assert(app:lane(1),"lane 1 missing");local lane2=assert(app:lane(2),"lane 2 missing");for _,step in ipairs(lane1.steps)do step.enabled=false end;for _,step in ipairs(lane2.steps)do step.enabled=false end;lane1.steps[2].enabled=true;lane1.steps[2].velocity=127;lane2.steps[4].enabled=true;lane2.steps[4].velocity=110;app:mark_dirty(false);app:flush(true)
  local track=assert(app:find_track("sequencer"),"sequencer missing");reaper.SetMediaTrackInfo_Value(track,"B_MAINSEND",1);local dispatcher=assert(app:dispatcher(track),"dispatcher missing");assert(reaper.TrackFX_GetParam(track,dispatcher,28)==52444,"runtime snapshot absent")
  return"engine, two samples, two-note pattern, and runtime created"
end)then finish();return end
local deadline=reaper.time_precise()+12
local function poll()
  local safe,err=xpcall(function()
    app:poll_sampler_loads(8);local pad1,pad2=app:pad(1),app:pad(2);local cache1=pad1 and app.sampler_cache[pad1.id];local cache2=pad2 and app.sampler_cache[pad2.id]
    if not(cache1 and cache1.ready and cache2 and cache2.ready)then assert(reaper.time_precise()<deadline,"both sampler slots did not become ready within 12 seconds");reaper.defer(poll);return end
    local function bank_stats()local count,peak=0,0;for ti=0,reaper.CountTracks(0)-1 do local t=reaper.GetTrack(0,ti);for fx=0,reaper.TrackFX_GetCount(t)-1 do local _,name=reaper.TrackFX_GetFXName(t,fx,"");if name:find("ReaDrum Sampler Bank",1,true)then local notes=reaper.TrackFX_GetParam(t,fx,5);local voices=reaper.TrackFX_GetParam(t,fx,8);count=math.max(count,notes);peak=math.max(peak,voices)end end end;return count,peak end
    local sequencer=assert(app:find_track("sequencer"));local baseline_ons=bank_stats();local item=assert(reaper.CreateNewMIDIItemInProj(sequencer,0,1.5,false));local take=assert(reaper.GetActiveTake(item));assert(reaper.MIDI_InsertCC(take,false,false,0,0xB0,15,1,0,true));reaper.MIDI_Sort(take)
    local audio_item=assert(reaper.AddMediaItemToTrack(sequencer));local audio_take=assert(reaper.AddTakeToMediaItem(audio_item));reaper.SetMediaItemTake_Source(audio_take,assert(reaper.PCM_Source_CreateFromFile(wav)));reaper.SetMediaItemTakeInfo_Value(audio_take,"D_VOL",0);reaper.SetMediaItemInfo_Value(audio_item,"D_POSITION",0);reaper.SetMediaItemInfo_Value(audio_item,"D_LENGTH",1.5)
    reaper.SetEditCurPos(0,false,false);reaper.OnPlayButton();local measure_at=reaper.time_precise()+1
    local function measure()
      if reaper.time_precise()<measure_at then reaper.defer(measure);return end
      local track=assert(app:find_track("sequencer"));local dispatcher=assert(app:dispatcher(track));local ons=reaper.TrackFX_GetParam(track,dispatcher,60);local stage=reaper.TrackFX_GetParam(track,dispatcher,63);local realtime_bank_ons,realtime_peak=bank_stats();reaper.OnStopButton();test("full sequencer to audio path",function()
      assert(realtime_bank_ons-baseline_ons>=2,"multi-step sequencer produced fewer than two notes");assert(realtime_bank_ons-baseline_ons<1000,"multi-step sequencer note count ran away")
      app:set_playback_mode("rendered",false);app:flush(true);assert(reaper.MIDI_InsertNote(take,false,false,0,240,0,36,127,true));assert(reaper.MIDI_InsertNote(take,false,false,480,720,0,37,110,true));reaper.MIDI_Sort(take)
      reaper.SetMediaTrackInfo_Value(reaper.GetMasterTrack(0),"I_NCHAN",32);reaper.GetSetProjectInfo(0,"PROJECT_SRATE_USE",1,true);reaper.GetSetProjectInfo(0,"PROJECT_SRATE",44100,true);reaper.GetSetProjectInfo(0,"RENDER_SETTINGS",0,true);reaper.GetSetProjectInfo(0,"RENDER_BOUNDSFLAG",0,true);reaper.GetSetProjectInfo(0,"RENDER_STARTPOS",0,true);reaper.GetSetProjectInfo(0,"RENDER_ENDPOS",1.5,true);reaper.GetSetProjectInfo(0,"RENDER_TAILFLAG",0,true);reaper.GetSetProjectInfo(0,"RENDER_CHANNELS",32,true);reaper.GetSetProjectInfo(0,"RENDER_SRATE",44100,true)
      reaper.GetSetProjectInfo_String(0,"RENDER_FILE",directory,true);reaper.GetSetProjectInfo_String(0,"RENDER_PATTERN","diagnostic-audio",true);reaper.GetSetProjectInfo_String(0,"RENDER_FORMAT","evaw",true);reaper.Main_OnCommand(42230,0)
      local fault=reaper.TrackFX_GetParam(track,dispatcher,58);local bank_ons,bank_peak=bank_stats()
      local rendered=directory..sep.."diagnostic-audio.wav";local f=assert(io.open(rendered,"rb"),"rendered audio file missing");local bytes=f:seek("end")or 0;f:close()
      assert(fault==0,"dispatcher fault latch="..fault);assert(stage==1,"dispatcher stage result="..stage);assert(bank_ons-realtime_bank_ons>=2,"rendered MIDI produced fewer than two note-ons");assert(bank_peak>0 and realtime_peak>0,"sampler produced no audio");assert(bytes>44,"rendered output is empty")
      return{configured_pads={1,2},configured_steps={2,4},configured_midi_notes={36,37},loaded_sampler_slots={0,1},sequencer_note_ons=realtime_bank_ons-baseline_ons,rendered_midi_note_ons=bank_ons-realtime_bank_ons,dispatcher_last_block_note_ons=ons,sampler_peak=math.max(bank_peak,realtime_peak),rendered_bytes=bytes}
      end);finish()
    end
    reaper.defer(measure)
  end,debug.traceback)
  if not safe then result.tests[#result.tests+1]={name="diagnostic runner",status="fail",detail=tostring(err)};result.status="fail";finish()end
end
reaper.defer(poll)
