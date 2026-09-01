-- Narrow REAPER host boundary for the ReaDrum lifecycle layer.
-- Tests may inject an object implementing this interface; the pure core never
-- imports this module.

local Adapter = {}
Adapter.__index = Adapter

function Adapter.new(host, project)
  assert(type(host) == "table", "REAPER host table is required")
  return setmetatable({ host = host, project = project or 0 }, Adapter)
end

function Adapter:track_count()
  return self.host.CountTracks(self.project)
end

function Adapter:track_at(index)
  return self.host.GetTrack(self.project, index)
end

function Adapter:track_index(track)
  return math.floor(self.host.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER") - 1)
end

function Adapter:insert_track(index)
  self.host.InsertTrackAtIndex(index, false)
  return assert(self:track_at(index), "REAPER did not create the requested track")
end

function Adapter:delete_track(track)
  return self.host.DeleteTrack(track)
end

function Adapter:get_track_value(track, key)
  return self.host.GetMediaTrackInfo_Value(track, key)
end

function Adapter:set_track_value(track, key, value)
  return self.host.SetMediaTrackInfo_Value(track, key, value)
end

function Adapter:get_track_string(track, key)
  local ok, value = self.host.GetSetMediaTrackInfo_String(track, key, "", false)
  return ok and value or ""
end

function Adapter:set_track_string(track, key, value)
  return self.host.GetSetMediaTrackInfo_String(track, key, tostring(value or ""), true)
end

function Adapter:send_count(track)
  return self.host.GetTrackNumSends(track, 0)
end

function Adapter:send_destination(track, index)
  return self.host.GetTrackSendInfo_Value(track, 0, index, "P_DESTTRACK")
end

function Adapter:create_send(source, destination)
  return self.host.CreateTrackSend(source, destination)
end

function Adapter:remove_send(source, index)
  return self.host.RemoveTrackSend(source, 0, index)
end

function Adapter:get_send_value(track, index, key)
  return self.host.GetTrackSendInfo_Value(track, 0, index, key)
end

function Adapter:set_send_value(track, index, key, value)
  return self.host.SetTrackSendInfo_Value(track, 0, index, key, value)
end

function Adapter:get_send_string(track, index, key)
  local ok, value = self.host.GetSetTrackSendInfo_String(track, 0, index, key, "", false)
  return ok and value or ""
end

function Adapter:set_send_string(track, index, key, value)
  return self.host.GetSetTrackSendInfo_String(track, 0, index, key, tostring(value or ""), true)
end

function Adapter:fx_count(track)
  return self.host.TrackFX_GetCount(track)
end

function Adapter:add_fx(track, name)
  return self.host.TrackFX_AddByName(track, name, false, -1)
end

function Adapter:set_batch_fx_seed(track,index)
  if not self._batch_fx_seed then self._batch_fx_seed={track=track,index=index} end
end

function Adapter:copy_batch_fx_to(track)
  local seed=self._batch_fx_seed
  if not seed or not self.host.TrackFX_CopyToTrack then return nil end
  local destination=self:fx_count(track)
  self.host.TrackFX_CopyToTrack(seed.track,seed.index,track,destination,false)
  return self:fx_count(track)>destination and destination or nil
end

function Adapter:hide_fx(track,index)
  if self.host.TrackFX_Show then self.host.TrackFX_Show(track,index,2) end
end

function Adapter:fx_guid(track, index)
  return self.host.TrackFX_GetFXGUID(track, index)
end

function Adapter:fx_name(track, index)
  local ok, value = self.host.TrackFX_GetFXName(track, index, "")
  return ok and value or ""
end

function Adapter:get_fx_named(track, index, key)
  local ok, value = self.host.TrackFX_GetNamedConfigParm(track, index, key)
  return ok and value or nil
end

function Adapter:set_fx_named(track, index, key, value)
  return self.host.TrackFX_SetNamedConfigParm(track, index, key, tostring(value or ""))
end

function Adapter:fx_param_count(track, index)
  return self.host.TrackFX_GetNumParams(track, index)
end

function Adapter:fx_param_name(track, index, parameter)
  local ok, value = self.host.TrackFX_GetParamName(track, index, parameter, "")
  return ok and value or ""
end

function Adapter:fx_param_ident(track, index, parameter)
  local ok, value = self.host.TrackFX_GetParamIdent(track, index, parameter)
  return ok and value or ""
end

function Adapter:get_fx_param_normalized(track, index, parameter)
  return self.host.TrackFX_GetParamNormalized(track, index, parameter)
end

function Adapter:set_fx_param_normalized(track, index, parameter, value)
  return self.host.TrackFX_SetParamNormalized(track, index, parameter, value)
end

function Adapter:format_fx_param(track, index, parameter, value)
  if self.host.TrackFX_FormatParamValueNormalized then
    local ok, formatted = self.host.TrackFX_FormatParamValueNormalized(track, index, parameter, value, "")
    if ok then return formatted end
  end
  return nil
end

function Adapter:file_exists(path)
  if self.host.file_exists then
    local result = self.host.file_exists(path)
    return result == true or result == 1
  end
  local handle = io.open(path, "rb")
  if handle then handle:close(); return true end
  return false
end

function Adapter:begin_undo(label)
  self._undo_label = label
  self._batch_fx_seed = nil
  self.host.PreventUIRefresh(1)
  self.host.Undo_BeginBlock2(self.project)
end

function Adapter:end_undo(changed)
  self.host.Undo_EndBlock2(self.project, self._undo_label or "ReaDrum lifecycle", changed and -1 or 0)
  self.host.PreventUIRefresh(-1)
  self.host.TrackList_AdjustWindows(false)
  self.host.UpdateArrange()
  self._undo_label = nil
  self._batch_fx_seed = nil
end

return Adapter
