-- @noindex
local M = {}

local escapes = { ['"']='\\"', ['\\']='\\\\', ['\b']='\\b', ['\f']='\\f', ['\n']='\\n', ['\r']='\\r', ['\t']='\\t' }
local key_prefix_cache = {}
local object_key_cache = {}

local function encode_string(value)
  return '"' .. value:gsub('[%z\1-\31\\"]', function(char)
    return escapes[char] or string.format('\\u%04x', char:byte())
  end) .. '"'
end

local function is_array(value)
  local maximum, count = 0, 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return false end
    maximum, count = math.max(maximum, key), count + 1
  end
  return maximum == count, maximum
end

local function encode(value, seen)
  local kind = type(value)
  if kind == "nil" then return "null" end
  if kind == "boolean" then return value and "true" or "false" end
  if kind == "number" then
    assert(value == value and value ~= math.huge and value ~= -math.huge, "JSON cannot encode non-finite numbers")
    if value == math.floor(value) then return tostring(value) end
    return string.format("%.17g", value)
  end
  if kind == "string" then return encode_string(value) end
  assert(kind == "table", "JSON cannot encode " .. kind)
  assert(not seen[value], "JSON cannot encode cyclic tables")
  seen[value] = true
  local array, count = is_array(value)
  local output = {}
  if array then
    for index = 1, count do output[index] = encode(value[index], seen) end
    seen[value] = nil
    return "[" .. table.concat(output, ",") .. "]"
  end
  local cache_tag=type(value.type)=="string" and value.type or nil
  local keys=cache_tag and object_key_cache[cache_tag] or nil
  if keys then
    local count=0;for key in pairs(value) do assert(type(key)=="string","JSON object keys must be strings");count=count+1 end
    if count~=#keys then keys=nil else for _,key in ipairs(keys) do if value[key]==nil then keys=nil;break end end end
  end
  if not keys then
    keys={};for key in pairs(value) do assert(type(key)=="string","JSON object keys must be strings");keys[#keys+1]=key end
    table.sort(keys);if cache_tag then object_key_cache[cache_tag]=keys end
  end
  for index, key in ipairs(keys) do
    local prefix=key_prefix_cache[key]
    if not prefix then prefix=encode_string(key)..":";key_prefix_cache[key]=prefix end
    output[index] = prefix .. encode(value[key], seen)
  end
  seen[value] = nil
  return "{" .. table.concat(output, ",") .. "}"
end

function M.encode(value) return encode(value, {}) end

function M.begin_encode(value,budget)
  budget=math.max(16,math.floor(budget or 256))
  local task={}
  task.coroutine=coroutine.create(function()
    local output,seen,count={},{},0
    local function emit(text)output[#output+1]=text end
    local write
    write=function(item)
      count=count+1;if count>=budget then count=0;coroutine.yield()end
      local kind=type(item)
      if kind=="nil"then emit("null");return end
      if kind=="boolean"then emit(item and "true"or"false");return end
      if kind=="number"then
        assert(item==item and item~=math.huge and item~=-math.huge,"JSON cannot encode non-finite numbers")
        emit(item==math.floor(item)and tostring(item)or string.format("%.17g",item));return
      end
      if kind=="string"then emit(encode_string(item));return end
      assert(kind=="table","JSON cannot encode "..kind);assert(not seen[item],"JSON cannot encode cyclic tables");seen[item]=true
      local array,array_count=is_array(item)
      if array then
        emit("[");for index=1,array_count do if index>1 then emit(",")end;write(item[index])end;emit("]")
      else
        local cache_tag=type(item.type)=="string"and item.type or nil
        local keys=cache_tag and object_key_cache[cache_tag]or nil
        if keys then
          local key_count=0;for key in pairs(item)do assert(type(key)=="string","JSON object keys must be strings");key_count=key_count+1 end
          if key_count~=#keys then keys=nil else for _,key in ipairs(keys)do if item[key]==nil then keys=nil;break end end end
        end
        if not keys then
          keys={};for key in pairs(item)do assert(type(key)=="string","JSON object keys must be strings");keys[#keys+1]=key end
          table.sort(keys);if cache_tag then object_key_cache[cache_tag]=keys end
        end
        emit("{");for index,key in ipairs(keys)do
          if index>1 then emit(",")end
          local prefix=key_prefix_cache[key];if not prefix then prefix=encode_string(key)..":";key_prefix_cache[key]=prefix end
          emit(prefix);write(item[key])
        end;emit("}")
      end
      seen[item]=nil
    end
    write(value);return table.concat(output)
  end)
  return task
end

function M.step_encode(task)
  local ok,result=coroutine.resume(task.coroutine)
  if not ok then error(result,2)end
  if coroutine.status(task.coroutine)=="dead"then task.result=result;return true,result end
  return false
end

local function decoder(source)
  local position, length = 1, #source
  local function skip() while position <= length and source:sub(position, position):match("%s") do position = position + 1 end end
  local parse
  local function string_value()
    position = position + 1
    local output = {}
    while position <= length do
      local char = source:sub(position, position)
      if char == '"' then position = position + 1; return table.concat(output) end
      if char == "\\" then
        local code = source:sub(position + 1, position + 1)
        local simple = { ['"']='"', ['\\']='\\', ['/']='/', b='\b', f='\f', n='\n', r='\r', t='\t' }
        if simple[code] then output[#output + 1] = simple[code]; position = position + 2
        elseif code == "u" then
          local hex = source:sub(position + 2, position + 5)
          assert(hex:match("^%x%x%x%x$"), "invalid JSON unicode escape")
          local number = tonumber(hex, 16)
          if number < 128 then output[#output + 1] = string.char(number)
          elseif number < 2048 then output[#output + 1] = string.char(192 + math.floor(number / 64), 128 + number % 64)
          else output[#output + 1] = string.char(224 + math.floor(number / 4096), 128 + math.floor(number / 64) % 64, 128 + number % 64) end
          position = position + 6
        else error("invalid JSON escape", 0) end
      else output[#output + 1] = char; position = position + 1 end
    end
    error("unterminated JSON string", 0)
  end
  local function array_value()
    position = position + 1; skip(); local result = {}
    if source:sub(position, position) == "]" then position = position + 1; return result end
    while true do
      result[#result + 1] = parse(); skip()
      local char = source:sub(position, position)
      if char == "]" then position = position + 1; return result end
      assert(char == ",", "expected ',' in JSON array"); position = position + 1
    end
  end
  local function object_value()
    position = position + 1; skip(); local result = {}
    if source:sub(position, position) == "}" then position = position + 1; return result end
    while true do
      skip(); assert(source:sub(position, position) == '"', "expected JSON object key")
      local key = string_value(); skip(); assert(source:sub(position, position) == ":", "expected ':' after JSON key")
      position = position + 1; result[key] = parse(); skip()
      local char = source:sub(position, position)
      if char == "}" then position = position + 1; return result end
      assert(char == ",", "expected ',' in JSON object"); position = position + 1
    end
  end
  parse = function()
    skip(); local char = source:sub(position, position)
    if char == '"' then return string_value() end
    if char == "[" then return array_value() end
    if char == "{" then return object_value() end
    local tail = source:sub(position)
    if tail:sub(1, 4) == "true" then position = position + 4; return true end
    if tail:sub(1, 5) == "false" then position = position + 5; return false end
    if tail:sub(1, 4) == "null" then position = position + 4; return nil end
    local token = tail:match("^-?%d+%.?%d*[eE]?[+-]?%d*")
    assert(token and token ~= "", "invalid JSON value at byte " .. position)
    local number = tonumber(token); assert(number, "invalid JSON number")
    position = position + #token; return number
  end
  local result = parse(); skip(); assert(position > length, "trailing JSON data")
  return result
end

function M.decode(source)
  assert(type(source) == "string", "JSON source must be a string")
  return decoder(source)
end

return M
