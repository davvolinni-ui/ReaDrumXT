-- @noindex
-- Standard MIDI File groove extraction and recursive user-library discovery.
-- Parsed templates use ReaDrum's 960-ticks-per-quarter timing convention.
local M={MAX_STEPS=256}

local function u16(data,pos)
  local a,b=data:byte(pos,pos+1);if not b then return nil end
  return a*256+b
end

local function u32(data,pos)
  local a,b,c,d=data:byte(pos,pos+3);if not d then return nil end
  return ((a*256+b)*256+c)*256+d
end

local function varlen(data,pos,limit)
  local value=0
  for _=1,4 do
    if pos>limit then return nil,nil,"truncated variable-length value" end
    local byte=data:byte(pos);pos=pos+1;value=value*128+(byte&0x7F)
    if byte<0x80 then return value,pos end
  end
  return nil,nil,"invalid variable-length value"
end

local function parse_track(data,first,last,notes)
  local pos,tick,running=first,0,nil
  while pos<=last do
    local delta;delta,pos=varlen(data,pos,last);if not delta then return nil,"invalid MIDI delta" end
    tick=tick+delta
    if pos>last then return nil,"truncated MIDI event" end
    local byte=data:byte(pos);local status,first_data
    if byte<0x80 then
      if not running then return nil,"MIDI running status without a channel status" end
      status=running;first_data=byte;pos=pos+1
    else
      status=byte;pos=pos+1
      if status<0xF0 then running=status else running=nil end
    end
    if status==0xFF then
      if pos>last then return nil,"truncated MIDI meta event" end
      local kind=data:byte(pos);pos=pos+1
      local length;length,pos=varlen(data,pos,last);if not length or pos+length-1>last then return nil,"truncated MIDI meta payload" end
      pos=pos+length
      if kind==0x2F then return tick end
    elseif status==0xF0 or status==0xF7 then
      local length;length,pos=varlen(data,pos,last);if not length or pos+length-1>last then return nil,"truncated MIDI system payload" end
      pos=pos+length
    elseif status>=0x80 and status<0xF0 then
      local kind=status&0xF0;local one_byte=kind==0xC0 or kind==0xD0
      local a=first_data
      if a==nil then if pos>last then return nil,"truncated MIDI channel event" end;a=data:byte(pos);pos=pos+1 end
      local b
      if not one_byte then if pos>last then return nil,"truncated MIDI channel event" end;b=data:byte(pos);pos=pos+1 end
      if kind==0x90 and b and b>0 then notes[#notes+1]={tick=tick,velocity=b,note=a} end
    else return nil,"unsupported MIDI status byte" end
  end
  return tick
end

function M.parse(data,name,source)
  if type(data)~="string" or #data<14 or data:sub(1,4)~="MThd" then return nil,"not a Standard MIDI File" end
  local header_length=u32(data,5);if not header_length or header_length<6 or 8+header_length>#data then return nil,"invalid MIDI header" end
  local tracks=u16(data,11);local division=u16(data,13)
  if not tracks or tracks<1 or not division or division==0 or division>=0x8000 then return nil,"SMPTE or invalid MIDI timing is not supported" end
  local notes={};local pos=9+header_length;local end_tick=0
  for _=1,tracks do
    if pos+7>#data or data:sub(pos,pos+3)~="MTrk" then return nil,"missing MIDI track chunk" end
    local length=u32(data,pos+4);local first=pos+8;local last=first+length-1
    if last>#data then return nil,"truncated MIDI track" end
    local track_end,failure=parse_track(data,first,last,notes);if not track_end then return nil,failure end
    end_tick=math.max(end_tick,track_end);pos=last+1
  end
  if #notes<4 then return nil,"groove MIDI needs at least four note-on positions" end
  table.sort(notes,function(a,b)return a.tick==b.tick and a.note<b.note or a.tick<b.tick end)
  local onsets={}
  for _,event in ipairs(notes)do
    local last=onsets[#onsets]
    if last and last.tick==event.tick then last.velocity=math.max(last.velocity,event.velocity)
    else onsets[#onsets+1]={tick=event.tick,velocity=event.velocity} end
  end
  local candidates={{1,8},{1,12},{1,16},{1,24},{1,32}};local best
  for _,grid in ipairs(candidates)do
    local step_ticks=division*4*grid[1]/grid[2];local used={};local residuals={};local score=0;local valid=true;local max_index=0
    for _,event in ipairs(onsets)do
      local index=math.floor(event.tick/step_ticks+.5);local residual=event.tick-index*step_ticks
      if used[index] or math.abs(residual)>step_ticks*.49 then valid=false;break end
      used[index]=true;residuals[index]=residual;score=score+(residual/step_ticks)^2;max_index=math.max(max_index,index)
    end
    if valid and #onsets/(max_index+1)>=.5 then
      score=math.sqrt(score/#onsets)
      -- Prefer the coarsest grid that can represent every onset without
      -- collisions. A heavily swung 1/16 pattern can lie closer to 1/24
      -- lines, but reclassifying it as triplets makes a 1/16 lane intersect
      -- only part of the template and effectively removes its swing.
      if not best then best={num=grid[1],den=grid[2],step_ticks=step_ticks,residuals=residuals,max_index=max_index,score=score} end
    end
  end
  if not best then return nil,"note positions do not form a supported 1/8–1/32 groove grid" end
  local bar_steps=math.max(1,math.floor(best.den/best.num+.5));local cycle_steps=math.ceil((best.max_index+1)/bar_steps)*bar_steps
  if end_tick>0 then cycle_steps=math.max(cycle_steps,math.floor(end_tick/best.step_ticks+.5)) end
  if cycle_steps<1 or cycle_steps>M.MAX_STEPS then return nil,"groove cycle exceeds "..M.MAX_STEPS.." grid positions" end
  local origin=best.residuals[0]or 0;local offsets={}
  for index=0,cycle_steps-1 do offsets[index+1]=math.floor(((best.residuals[index]or 0)-origin)/division*960+.5) end
  return{name=name or"MIDI Groove",source=source or"",grid_num=best.num,grid_den=best.den,cycle_steps=cycle_steps,timing_offsets=offsets}
end

function M.load(path,name,source)
  local file,failure=io.open(path,"rb");if not file then return nil,tostring(failure) end
  local data=file:read("*a");file:close()
  return M.parse(data,name,source)
end

local function display_name(filename)return(filename:gsub("%.[Mm][Ii][Dd][Ii]?$",""))end

function M.scan(host,root)
  if host.RecursiveCreateDirectory then host.RecursiveCreateDirectory(root,0) end
  if not host.EnumerateFiles or not host.EnumerateSubdirectories then return{},"REAPER file enumeration is unavailable" end
  local entries={};local separator=package.config:sub(1,1)
  local function visit(directory,parts)
    local files={};local index=0
    while true do local filename=host.EnumerateFiles(directory,index);if not filename then break end;index=index+1;if filename:lower():match("%.midi?$")then files[#files+1]=filename end end
    table.sort(files,function(a,b)return a:lower()<b:lower()end)
    for _,filename in ipairs(files)do
      local relative=(#parts>0 and table.concat(parts,"/").."/"or"")..filename
      entries[#entries+1]={path=directory..separator..filename,relative=relative,name=display_name(filename),category=table.concat(parts," / ")}
    end
    local folders={};index=0
    while true do local folder=host.EnumerateSubdirectories(directory,index);if not folder then break end;index=index+1;folders[#folders+1]=folder end
    table.sort(folders,function(a,b)return a:lower()<b:lower()end)
    for _,folder in ipairs(folders)do local child={table.unpack(parts)};child[#child+1]=folder;visit(directory..separator..folder,child) end
  end
  visit(root,{})
  return entries
end

function M.model_copy(value)
  return{name=value.name,source=value.source,grid_num=value.grid_num,grid_den=value.grid_den,cycle_steps=value.cycle_steps,timing_offsets={table.unpack(value.timing_offsets or{})}}
end

return M
