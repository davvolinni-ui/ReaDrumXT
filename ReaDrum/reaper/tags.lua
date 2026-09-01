-- @noindex
local M = {}

M.SCHEMA_VERSION = "1"
M.OWNER = "ReaDrum"
M.prefix = "P_EXT:ReaDrum."

local fields = { "owner", "schema", "kind", "rack_id", "object_id", "logical_index" }

function M.read_track(adapter, track)
  local tag = {}
  for _, field in ipairs(fields) do tag[field] = adapter:get_track_string(track, M.prefix .. field) end
  if tag.owner ~= M.OWNER or tag.schema ~= M.SCHEMA_VERSION then return nil end
  return tag
end

function M.write_track(adapter, track, values)
  local tag = {
    owner = M.OWNER,
    schema = M.SCHEMA_VERSION,
    kind = assert(values.kind),
    rack_id = assert(values.rack_id),
    object_id = assert(values.object_id),
    logical_index = values.logical_index and tostring(values.logical_index) or "",
  }
  for _, field in ipairs(fields) do adapter:set_track_string(track, M.prefix .. field, tag[field]) end
end

function M.clear_track(adapter, track)
  for _, field in ipairs(fields) do adapter:set_track_string(track, M.prefix .. field, "") end
end

function M.send_key(rack_id, pad_id)
  return rack_id .. "/pad-send/" .. pad_id
end

function M.read_send(adapter, source, index)
  local owner = adapter:get_send_string(source, index, M.prefix .. "owner")
  local schema = adapter:get_send_string(source, index, M.prefix .. "schema")
  if owner ~= M.OWNER or schema ~= M.SCHEMA_VERSION then return nil end
  return {
    owner = owner,
    schema = schema,
    rack_id = adapter:get_send_string(source, index, M.prefix .. "rack_id"),
    object_id = adapter:get_send_string(source, index, M.prefix .. "object_id"),
  }
end

function M.write_send(adapter, source, index, rack_id, pad_id)
  adapter:set_send_string(source, index, M.prefix .. "owner", M.OWNER)
  adapter:set_send_string(source, index, M.prefix .. "schema", M.SCHEMA_VERSION)
  adapter:set_send_string(source, index, M.prefix .. "rack_id", rack_id)
  adapter:set_send_string(source, index, M.prefix .. "object_id", M.send_key(rack_id, pad_id))
end

return M
