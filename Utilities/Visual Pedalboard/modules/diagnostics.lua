-- Visual Pedalboard: debug metrics and reporting.

local M = {}

local DEBUG_REPORT_SECONDS = 5
M.DEBUG_REPORT_SECONDS = DEBUG_REPORT_SECONDS

function M.reset_metrics()
  return {
    started_at = reaper.time_precise(),
    frames = 0,
    loop = { total = 0, max = 0, count = 0 },
    draw = { total = 0, max = 0, count = 0 },
    switch = { total = 0, max = 0, count = 0 },
    project_lists = { total = 0, max = 0, count = 0 },
    states = { total = 0, max = 0, count = 0 },
    refreshes = 0,
    late_refreshes = 0,
    max_refresh_lateness = 0,
    loop_over_5ms = 0,
    loop_over_10ms = 0,
    tracks_listed = 0,
    fx_listed = 0,
    tracks_resolved = 0,
    track_cache_hits = 0,
    track_cache_misses = 0,
    track_scan_steps = 0,
    fx_cache_hits = 0,
    fx_cache_misses = 0,
    fx_scan_steps = 0,
    cells_checked = 0,
    assigned_cells = 0,
    window_width = 0,
    window_height = 0,
    content_width = 0,
    content_height = 0,
    armed_tracks = 0,
    monitored_tracks = 0,
  }
end

local function metric_summary(metric)
  local average = metric.count > 0 and metric.total / metric.count or 0
  return string.format(
    "avg_ms=%.3f max_ms=%.3f calls=%d",
    average * 1000,
    metric.max * 1000,
    metric.count
  )
end

M.metric_summary = metric_summary

function M.report_metrics(metrics, config, active_project,
                          debug_pause_state_reads, debug_pause_grid, now)
  local elapsed = now - metrics.started_at
  if elapsed < DEBUG_REPORT_SECONDS then
    return
  end

  local play_state = reaper.GetPlayState()
  local armed_tracks = 0
  local monitored_tracks = 0
  local master = reaper.GetMasterTrack(active_project)
  if reaper.GetMediaTrackInfo_Value(master, "I_RECARM") > 0 then
    armed_tracks = armed_tracks + 1
    if reaper.GetMediaTrackInfo_Value(master, "I_RECMON") > 0 then
      monitored_tracks = monitored_tracks + 1
    end
  end
  for track_index = 0, reaper.CountTracks(active_project) - 1 do
    local track = reaper.GetTrack(active_project, track_index)
    if reaper.GetMediaTrackInfo_Value(track, "I_RECARM") > 0 then
      armed_tracks = armed_tracks + 1
      if reaper.GetMediaTrackInfo_Value(track, "I_RECMON") > 0 then
        monitored_tracks = monitored_tracks + 1
      end
    end
  end
  metrics.armed_tracks = armed_tracks
  metrics.monitored_tracks = monitored_tracks
  reaper.ShowConsoleMsg(string.format(
    "[Visual Pedalboard debug] seconds=%.1f fps=%.1f refresh_ms=%d "
      .. "playing=%s paused=%s recording=%s play_state=%d "
      .. "armed_tracks=%d monitored_tracks=%d state_reads_paused=%s grid_paused=%s "
      .. "window=%.0fx%.0f content=%.0fx%.0f grid=%dx%d cells=%d assigned=%d "
      .. "loop{%s,over5ms=%d,over10ms=%d} draw{%s} switch{%s} "
      .. "states{%s,calls=%d,cells_checked=%d,late=%d,max_late_ms=%.3f} "
      .. "project_lists{%s,tracks=%d,fx=%d} "
      .. "track_cache{hits=%d,misses=%d,resolved=%d,scan_steps=%d} "
      .. "fx_cache{hits=%d,misses=%d,scan_steps=%d}\n",
    elapsed,
    metrics.frames / elapsed,
    config.refresh_ms,
    (play_state & 1) ~= 0 and "yes" or "no",
    (play_state & 2) ~= 0 and "yes" or "no",
    (play_state & 4) ~= 0 and "yes" or "no",
    play_state,
    metrics.armed_tracks,
    metrics.monitored_tracks,
    debug_pause_state_reads and "yes" or "no",
    debug_pause_grid and "yes" or "no",
    metrics.window_width,
    metrics.window_height,
    metrics.content_width,
    metrics.content_height,
    config.rows,
    config.columns,
    config.rows * config.columns,
    metrics.assigned_cells,
    metric_summary(metrics.loop),
    metrics.loop_over_5ms,
    metrics.loop_over_10ms,
    metric_summary(metrics.draw),
    metric_summary(metrics.switch),
    metric_summary(metrics.states),
    metrics.refreshes,
    metrics.cells_checked,
    metrics.late_refreshes,
    metrics.max_refresh_lateness * 1000,
    metric_summary(metrics.project_lists),
    metrics.tracks_listed,
    metrics.fx_listed,
    metrics.track_cache_hits,
    metrics.track_cache_misses,
    metrics.tracks_resolved,
    metrics.track_scan_steps,
    metrics.fx_cache_hits,
    metrics.fx_cache_misses,
    metrics.fx_scan_steps
  ))

  metrics.started_at = now
  metrics.frames = 0
  for _, name in ipairs({ "loop", "draw", "switch", "project_lists", "states" }) do
    metrics[name] = { total = 0, max = 0, count = 0 }
  end
  metrics.refreshes = 0
  metrics.late_refreshes = 0
  metrics.max_refresh_lateness = 0
  metrics.loop_over_5ms = 0
  metrics.loop_over_10ms = 0
  metrics.tracks_listed = 0
  metrics.fx_listed = 0
  metrics.tracks_resolved = 0
  metrics.track_cache_hits = 0
  metrics.track_cache_misses = 0
  metrics.track_scan_steps = 0
  metrics.fx_cache_hits = 0
  metrics.fx_cache_misses = 0
  metrics.fx_scan_steps = 0
  metrics.cells_checked = 0
  metrics.assigned_cells = 0
end

return M

