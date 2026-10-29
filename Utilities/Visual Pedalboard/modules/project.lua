-- Visual Pedalboard: track/FX resolution, caching and state inspection.

local M = {}

-- ---------------------------------------------------------------------------
-- Track / FX lookup
-- ---------------------------------------------------------------------------

function M.all_tracks()
  local master = reaper.GetMasterTrack(0)
  local tracks = {
    {
      track = master,
      guid = reaper.GetTrackGUID(master),
      name = "Master",
    },
  }
  for index = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, index)
    local _, name = reaper.GetTrackName(track)
    tracks[#tracks + 1] = {
      track = track,
      guid = reaper.GetTrackGUID(track),
      name = name and name ~= "" and name or ("Track " .. (index + 1)),
    }
  end
  return tracks
end

function M.resolve_track(guid)
  if not guid or guid == "" then
    return nil
  end
  local master = reaper.GetMasterTrack(0)
  if reaper.GetTrackGUID(master) == guid then
    return master
  end
  for index = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, index)
    if reaper.GetTrackGUID(track) == guid then
      return track
    end
  end
  return nil
end

function M.find_fx_index(track, fx_guid)
  if not track or not fx_guid or fx_guid == "" then
    return nil
  end
  for fx_index = 0, reaper.TrackFX_GetCount(track) - 1 do
    if reaper.TrackFX_GetFXGUID(track, fx_index) == fx_guid then
      return fx_index
    end
  end
  return nil
end

function M.clean_fx_name(name)
  name = name:gsub("^[^:]+:%s*", "")
  name = name:gsub("%s*%([^()]*%)%s*$", "")
  return name
end

-- ---------------------------------------------------------------------------
-- Cell state inspection
-- ---------------------------------------------------------------------------

function M.inspect_cell(cell, track, fx_index)
  if not cell.track_guid or cell.track_guid == "" then
    return { state = "unassigned", message = "UNASSIGNED" }
  end
  if not track then
    return { state = "invalid", message = "INVALID TRACK" }
  end
  if not fx_index then
    return { state = "invalid", message = "INVALID FX" }
  end
  local _, fx_name = reaper.TrackFX_GetFXName(track, fx_index)
  fx_name = M.clean_fx_name(fx_name)
  fx_name = fx_name ~= "" and fx_name or ("FX " .. (fx_index + 1))
  if cell.param_index < 0 and cell.param_ident == "" then
    return { state = "unsupported", fx_name = fx_name, message = "SELECT PARAMETER" }
  end
  if not reaper.TrackFX_GetNumParams
      or not reaper.TrackFX_GetParamNormalized
      or not reaper.TrackFX_SetParamNormalized then
    return { state = "unsupported", fx_name = fx_name, message = "PARAMETER API UNAVAILABLE" }
  end
  local param_index = cell.param_index
  if cell.param_ident ~= "" then
    if not reaper.TrackFX_GetParamFromIdent then
      return { state = "unsupported", fx_name = fx_name, message = "PARAMETER API UNAVAILABLE" }
    end
    param_index = reaper.TrackFX_GetParamFromIdent(track, fx_index, cell.param_ident)
  end
  if param_index < 0 or param_index >= reaper.TrackFX_GetNumParams(track, fx_index) then
    return { state = "unsupported", fx_name = fx_name, message = "INVALID PARAMETER" }
  end
  local bypassed = reaper.TrackFX_GetParamNormalized(track, fx_index, param_index) >= 0.5
  if cell.invert_state then
    bypassed = not bypassed
  end
  return {
    state = bypassed and "bypassed" or "active",
    track = track,
    fx_index = fx_index,
    param_index = param_index,
    fx_name = fx_name,
    message = bypassed and "BYPASSED" or "ACTIVE",
  }
end

-- ---------------------------------------------------------------------------
-- Caching layer
-- ---------------------------------------------------------------------------

local cached_tracks = {}
local cached_fx_indices = {}
local cached_track_retry_times = {}
local cached_fx_retry_times = {}

function M.clear_assignment_caches()
  cached_tracks = {}
  cached_fx_indices = {}
  cached_track_retry_times = {}
  cached_fx_retry_times = {}
end

--- @param track_guid string
--- @param active_project userdata
--- @param project_list_refresh_seconds number
--- @param debug_metrics table|nil
--- @return userdata|nil track
function M.get_cached_track(track_guid, active_project, project_list_refresh_seconds, debug_metrics)
  if track_guid == "" then
    return nil
  end
  local track = cached_tracks[track_guid]
  if track and reaper.ValidatePtr2
      and reaper.ValidatePtr2(active_project, track, "MediaTrack*")
      and reaper.GetTrackGUID(track) == track_guid then
    if debug_metrics then
      debug_metrics.track_cache_hits = debug_metrics.track_cache_hits + 1
    end
    return track
  end
  local now = reaper.time_precise()
  if track == false and now < (cached_track_retry_times[track_guid] or 0) then
    return nil
  end

  if debug_metrics then
    debug_metrics.track_cache_misses = debug_metrics.track_cache_misses + 1
  end
  track = M.resolve_track(track_guid)
  if debug_metrics then
    debug_metrics.tracks_resolved = debug_metrics.tracks_resolved + (track and 1 or 0)
    debug_metrics.track_scan_steps = debug_metrics.track_scan_steps
        + reaper.CountTracks(active_project) + 1
  end
  cached_tracks[track_guid] = track or false
  if track then
    cached_track_retry_times[track_guid] = nil
  else
    cached_track_retry_times[track_guid] = now + project_list_refresh_seconds
  end
  return track
end

--- @param track userdata
--- @param track_guid string
--- @param fx_guid string
--- @param project_list_refresh_seconds number
--- @param debug_metrics table|nil
--- @return integer|nil fx_index
function M.get_cached_fx_index(track, track_guid, fx_guid, project_list_refresh_seconds, debug_metrics)
  if not track or fx_guid == "" then
    return nil
  end
  local fx_indices = cached_fx_indices[track_guid]
  if not fx_indices then
    fx_indices = {}
    cached_fx_indices[track_guid] = fx_indices
  end

  local fx_index = fx_indices[fx_guid]
  local now = reaper.time_precise()
  if fx_index == false
      and now < ((cached_fx_retry_times[track_guid] or {})[fx_guid] or 0) then
    return nil
  end
  if fx_index and fx_index < reaper.TrackFX_GetCount(track)
      and reaper.TrackFX_GetFXGUID(track, fx_index) == fx_guid then
    if debug_metrics then
      debug_metrics.fx_cache_hits = debug_metrics.fx_cache_hits + 1
    end
    return fx_index
  end

  if debug_metrics then
    debug_metrics.fx_cache_misses = debug_metrics.fx_cache_misses + 1
  end
  fx_index = M.find_fx_index(track, fx_guid)
  if debug_metrics then
    debug_metrics.fx_scan_steps = debug_metrics.fx_scan_steps
        + reaper.TrackFX_GetCount(track)
  end
  fx_indices[fx_guid] = fx_index or false
  local retry_times = cached_fx_retry_times[track_guid]
  if not retry_times then
    retry_times = {}
    cached_fx_retry_times[track_guid] = retry_times
  end
  if fx_index then
    retry_times[fx_guid] = nil
  else
    retry_times[fx_guid] = now + project_list_refresh_seconds
  end
  return fx_index
end

return M

