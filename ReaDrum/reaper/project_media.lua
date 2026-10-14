-- @noindex
local M={FOLDER="ReaDrum Samples"}
local function normalize(path)return (path:gsub("\\","/"):gsub("/+$",""))end
function M.relative(path)
  if type(path)~="string" or path=="" or path:find("%z") then return nil end
  path=normalize(path)
  if path:sub(1,1)=="/" or path:find(":",1,true) then return nil end
  for part in path:gmatch("[^/]+")do if part==".." or part=="." then return nil end end
  return path
end
function M.directory(host,project)
  if not host.EnumProjects then return nil end
  if project==0 then
    local _,filename=host.EnumProjects(-1,"")
    return filename and filename~="" and normalize(filename):match("^(.*)/[^/]+$") or nil
  end
  local index=0
  while true do
    local found,filename=host.EnumProjects(index,"")
    if not found then return nil end
    if found==project then return filename and filename~="" and normalize(filename):match("^(.*)/[^/]+$") or nil end
    index=index+1
  end
end
function M.resolve_rack(rack,directory)
  if not directory then return end
  directory=normalize(directory)
  for _,pad in ipairs(rack.pads or {})do
    local sample=pad.sample
    if type(sample)=="table" and sample.project_relative_path then
      local relative=assert(M.relative(sample.project_relative_path),"Invalid collected sample path")
      sample.path=directory.."/"..relative
      sample._project_directory=directory
    end
  end
end
function M.detach_foreign(sample,directory)
  if type(sample)=="table" and sample.project_relative_path and sample._project_directory~=directory then
    -- Clipboard transfers retain the working source path until collected in
    -- their new project. Do not reinterpret it inside an unrelated folder.
    sample.project_relative_path=nil;sample._project_directory=nil
  end
end
function M.filesystem(host)
  return {
    open=io.open,rename=os.rename,remove=os.remove,
    exists=function(path)local f=io.open(path,"rb");if f then f:close();return true end;return false end,
    mkdir=function(path)host.RecursiveCreateDirectory(path,0)end,
  }
end
local function sample_path(sample)return type(sample)=="table" and sample.path or sample end
function M.begin_collect(rack,directory,token,fs)
  directory=normalize(assert(directory,"Save the project before collecting samples"))
  assert(type(token)=="string" and token:match("^[%w%-]+$"),"Invalid collection token")
  local task={rack=rack,directory=directory,fs=fs,inputs={},files={},handles={},created={},copied=0,bytes=0}
  local by_source,names={},{}
  local folder=M.FOLDER.."/"..token
  for _,pad in ipairs(rack.pads or {})do
    local path=sample_path(pad.sample)
    if type(path)=="string" and path~="" then
      assert(fs.exists(path),"Sample is missing: "..path)
      local entry=by_source[path]
      if not entry then
        local already=type(pad.sample)=="table" and M.relative(pad.sample.project_relative_path)
        if already and normalize(path)==directory.."/"..already then
          entry={source=path,relative=already,destination=path,existing=true}
        else
          local filename=(path:match("([^/\\]+)$") or "sample.wav"):gsub('[<>:"/\\|?*%c]',"_")
          local stem,extension=filename:match("^(.*)(%.[^%.]+)$")
          stem,extension=(stem or filename):sub(1,96),extension or ""
          filename=stem..extension
          local suffix=1
          while names[filename:lower()]do suffix=suffix+1;filename=stem.."_"..suffix..extension end
          names[filename:lower()]=true
          local relative=folder.."/"..filename
          entry={source=path,relative=relative,destination=directory.."/"..relative}
          assert(not fs.exists(entry.destination),"Collection destination already exists")
        end
        by_source[path]=entry;task.files[#task.files+1]=entry
      end
      task.inputs[#task.inputs+1]={pad=pad,sample=pad.sample,path=path,file=entry}
    end
  end
  task.coroutine=coroutine.create(function()
    if #task.inputs==0 then return end
    fs.mkdir(directory.."/"..folder)
    local function open(path,mode)
      local handle,failure=fs.open(path,mode);assert(handle,failure or ("Cannot open "..path))
      task.handles[handle]=true;return handle
    end
    local function close(handle)
      local ok,failure=handle:close();task.handles[handle]=nil;assert(ok,failure or "Could not close sample file")
    end
    for _,entry in ipairs(task.files)do
      if not entry.existing then
        local temporary=entry.destination..".part"
        assert(not fs.exists(temporary),"Collection temporary file already exists")
        local input=open(entry.source,"rb")
        local output=open(temporary,"wb");task.created[#task.created+1]=temporary
        while true do
          local bytes,failure=input:read(262144);assert(not failure,failure);if not bytes then break end
          assert(output:write(bytes),"Could not write copied sample")
          task.bytes=task.bytes+#bytes;coroutine.yield()
        end
        close(input);close(output)
        input=open(entry.source,"rb");output=open(temporary,"rb")
        while true do
          local original,original_failure=input:read(262144);local copied,copy_failure=output:read(262144)
          assert(not original_failure,original_failure);assert(not copy_failure,copy_failure)
          assert(original==copied,"Sample copy verification failed: "..entry.source)
          if not original then break end
          coroutine.yield()
        end
        close(input);close(output)
        assert(not fs.exists(entry.destination),"Collection destination already exists")
        assert(fs.rename(temporary,entry.destination),"Could not finalize copied sample")
        task.created[#task.created]=entry.destination
        task.copied=task.copied+1;coroutine.yield()
      end
    end
  end)
  return task
end
function M.cancel(task)
  for handle in pairs(task.handles)do pcall(function()handle:close()end)end
  task.handles={}
  for _,path in ipairs(task.created)do pcall(task.fs.remove,path)end
  task.cancelled=true
end
function M.step(task,budget)
  if task.cancelled then return false,"Collection cancelled" end
  if coroutine.status(task.coroutine)=="dead" then return true end
  for _=1,budget or 8 do
    local ok,failure=coroutine.resume(task.coroutine)
    if not ok then M.cancel(task);return false,tostring(failure)end
    if coroutine.status(task.coroutine)=="dead" then return true end
  end
  return nil
end
function M.commit(task,rack,directory)
  assert(rack==task.rack and normalize(directory or "")==task.directory,"Project changed during collection; samples were not relinked")
  assert(coroutine.status(task.coroutine)=="dead" and not task.cancelled,"Collection has not completed")
  for _,input in ipairs(task.inputs)do
    assert(input.pad.sample==input.sample and sample_path(input.pad.sample)==input.path,"A sample changed during collection; samples were not relinked")
  end
  for _,input in ipairs(task.inputs)do
    local sample={}
    if type(input.sample)=="table"then for key,value in pairs(input.sample)do sample[key]=value end end
    sample.path=input.file.destination
    sample.project_relative_path=input.file.relative
    sample._project_directory=task.directory
    input.pad.sample=sample
  end
  task.committed=true
end
return M
