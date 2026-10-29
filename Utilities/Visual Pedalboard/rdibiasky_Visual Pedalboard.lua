-- @description Visual Pedalboard - live FX control surface
-- @version 1.1.0
-- @author rdibiasky (https://github.com/rdibiasky)
-- @about
--   A configurable REAPER FX pedalboard. Configuration is stored in the
--   project and FX indices in the editor are one-based.

-- ---------------------------------------------------------------------------
-- ReaImGui bootstrap (identical to the demo's verified pattern).
-- ---------------------------------------------------------------------------

package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua'
local ImGui = require 'imgui' '0.10'

local SCRIPT_NAME = "Visual Pedalboard"

if not ImGui.CreateContext then
  reaper.ShowMessageBox(
    "ReaImGui is required. Install it from ReaPack, then run this script again.",
    SCRIPT_NAME,
    0
  )
  return
end

-- ---------------------------------------------------------------------------
-- Module path setup — resolve relative to the script's own directory.
-- ---------------------------------------------------------------------------

local script_path = ({reaper.get_action_context()})[2]:match("^(.*[/\\])")
if not script_path then
  local info = debug.getinfo(1, 'S')
  script_path = info and info.source:match([[^@?(.*[\/])]]) or ""
end
package.path = script_path .. "modules/?.lua;" .. package.path

-- ---------------------------------------------------------------------------
-- Load modules.
-- ---------------------------------------------------------------------------

local cfg     = require("config")
local project = require("project")
local presets = require("presets")
local diag    = require("diagnostics")
local ui      = require("ui")

-- Wire inter-module dependencies.
presets.init(cfg, project)
cfg.set_project_helpers(project.resolve_track, project.find_fx_index, project.inspect_cell)

-- ---------------------------------------------------------------------------
-- Timing constants.
-- ---------------------------------------------------------------------------

local PROJECT_LIST_REFRESH_SECONDS = 1

-- ---------------------------------------------------------------------------
-- Active project state.
-- ---------------------------------------------------------------------------

local active_project, active_project_file = reaper.EnumProjects(-1)
active_project = active_project or 0
active_project_file = active_project_file or ""
local active_project_change_count = reaper.GetProjectStateChangeCount
    and reaper.GetProjectStateChangeCount(active_project) or nil

local project_serialized = select(2, reaper.GetProjExtState(
  active_project,
  cfg.EXT_SECTION,
  cfg.EXT_KEY
))

local config = cfg.load_config(project_serialized)

-- ---------------------------------------------------------------------------
-- ImGui context & fonts.
-- ---------------------------------------------------------------------------

local ctx = ImGui.CreateContext(SCRIPT_NAME)
local bold_font = ImGui.CreateFont("sans-serif", ImGui.FontFlags_Bold)
local italic_font = ImGui.CreateFont("sans-serif", ImGui.FontFlags_Italic)
ImGui.Attach(ctx, bold_font)
ImGui.Attach(ctx, italic_font)

ui.init(ImGui, ctx, bold_font, italic_font, cfg, project, presets, diag)

-- ---------------------------------------------------------------------------
-- Runtime state.
-- ---------------------------------------------------------------------------

local last_refresh = 0
local states = {}
local debug_mode = false
local debug_metrics
local debug_pause_state_reads = false
local debug_pause_grid = false

-- ---------------------------------------------------------------------------
-- Core: refresh FX states.
-- ---------------------------------------------------------------------------

local function refresh_states()
  local debug_started = debug_mode and reaper.time_precise()
  local tracks_by_guid = {}
  local requested_fx_by_track = {}
  local assigned_cells = debug_mode and 0 or nil
  for index = 1, config.rows * config.columns do
    local cell = config.cells[index]
    if debug_mode and cell.track_guid ~= "" and cell.fx_guid ~= "" then
      assigned_cells = assigned_cells + 1
    end
    if cell.track_guid ~= "" then
      if tracks_by_guid[cell.track_guid] == nil then
        tracks_by_guid[cell.track_guid] = project.get_cached_track(
          cell.track_guid,
          active_project,
          PROJECT_LIST_REFRESH_SECONDS,
          debug_mode and debug_metrics or nil
        ) or false
      end
      if cell.fx_guid ~= "" then
        local requested_fx = requested_fx_by_track[cell.track_guid]
        if not requested_fx then
          requested_fx = {}
          requested_fx_by_track[cell.track_guid] = requested_fx
        end
        requested_fx[cell.fx_guid] = true
      end
    end
  end

  local fx_indices_by_track = {}
  for track_guid, requested_fx in pairs(requested_fx_by_track) do
    local track = tracks_by_guid[track_guid]
    if track then
      local fx_indices = {}
      for fx_guid in pairs(requested_fx) do
        fx_indices[fx_guid] = project.get_cached_fx_index(
          track,
          track_guid,
          fx_guid,
          PROJECT_LIST_REFRESH_SECONDS,
          debug_mode and debug_metrics or nil
        ) or false
      end
      fx_indices_by_track[track_guid] = fx_indices
    end
  end

  for index = 1, config.rows * config.columns do
    local cell = config.cells[index]
    local track = tracks_by_guid[cell.track_guid]
    local fx_indices = fx_indices_by_track[cell.track_guid]
    local fx_index = fx_indices and fx_indices[cell.fx_guid]
    if fx_index == false then
      fx_index = nil
    end
    states[index] = project.inspect_cell(cell, track, fx_index)
  end
  last_refresh = reaper.time_precise()
  if debug_mode then
    local elapsed = last_refresh - debug_started
    debug_metrics.states.total = debug_metrics.states.total + elapsed
    debug_metrics.states.max = math.max(debug_metrics.states.max, elapsed)
    debug_metrics.states.count = debug_metrics.states.count + 1
    debug_metrics.refreshes = debug_metrics.refreshes + 1
    debug_metrics.cells_checked = debug_metrics.cells_checked
        + config.rows * config.columns
    debug_metrics.assigned_cells = debug_metrics.assigned_cells + assigned_cells
  end
end

local last_midi_event_sequence = 0
if reaper.MIDI_GetRecentInputEvent then
  last_midi_event_sequence = select(1, reaper.MIDI_GetRecentInputEvent(0)) or 0
else
  cfg.report_error(
    "This REAPER version does not support MIDI input event polling; "
      .. "preset Program Change control is unavailable."
  )
end

local function poll_preset_program_change()
  if not reaper.MIDI_GetRecentInputEvent then
    return
  end

  local latest_sequence, latest_message = reaper.MIDI_GetRecentInputEvent(0)
  if not latest_sequence or latest_sequence == 0 then
    return
  end
  if not config.listen_midi_program_change then
    last_midi_event_sequence = latest_sequence
    return
  end
  if latest_sequence < last_midi_event_sequence then
    last_midi_event_sequence = latest_sequence
    return
  end
  if latest_sequence == last_midi_event_sequence then
    return
  end

  local preset_index
  local event_index = 0
  while true do
    local sequence, message
    if event_index == 0 then
      sequence, message = latest_sequence, latest_message
    else
      sequence, message = reaper.MIDI_GetRecentInputEvent(event_index)
    end
    if not sequence or sequence == 0
        or sequence <= last_midi_event_sequence then
      break
    end

    if not preset_index and type(message) == "string" then
      local status, program = message:byte(1, 2)
      if status == 0xC0 and program and program <= 7 then
        preset_index = program + 1
      end
    end
    event_index = event_index + 1
  end
  last_midi_event_sequence = latest_sequence

  if preset_index and config.presets[preset_index] then
    local loaded = presets.load_preset(config, preset_index, active_project, function()
      for index in pairs(states) do states[index] = nil end
      refresh_states()
    end)
    if loaded then
      ui.active_preset_index = preset_index
    end
  end
end

-- ---------------------------------------------------------------------------
-- Project switch detection.
-- ---------------------------------------------------------------------------

local function switch_project_if_needed()
  local current_project, current_project_file = reaper.EnumProjects(-1)
  current_project = current_project or 0
  current_project_file = current_project_file or ""
  local current_change_count = reaper.GetProjectStateChangeCount
      and reaper.GetProjectStateChangeCount(current_project) or nil
  local project_reloaded = current_change_count
      and active_project_change_count
      and current_change_count < active_project_change_count
  local project_changed = current_project ~= active_project
      or current_project_file ~= active_project_file
      or project_reloaded
  active_project_change_count = current_change_count
  if not project_changed then
    return
  end

  active_project = current_project
  active_project_file = current_project_file
  local _, current_serialized = reaper.GetProjExtState(
    active_project,
    cfg.EXT_SECTION,
    cfg.EXT_KEY
  )
  config = cfg.load_config(current_serialized)
  last_refresh = 0
  project.clear_assignment_caches()
  states = {}
  ui.active_preset_index = nil
  ui.on_project_switched()
end

local function replace_config(new_config)
  if not cfg.save_config(active_project, new_config) then
    return nil
  end
  config = new_config
  ui.settings_open = false
  ui.settings_draft = nil
  ui.cell_text_layouts = {}
  ui.selected_index = 1
  ui.draft = nil
  ui.draft_index = nil
  ui.open_cell_configuration = false
  ui.request_cell_configuration = false
  ui.preset_dialog_open = false
  ui.request_preset_dialog = false
  ui.preset_dialog_index = nil
  ui.preset_dialog_name = ""
  ui.preset_dialog_save_plugins_state = false
  ui.preset_dialog_fx_selections = {}
  ui.preset_dialog_fx_entries = {}
  ui.preset_dialog_locked = false
  ui.preset_dialog_confirming = false
  ui.preset_dialog_unlock_confirming = false
  ui.active_preset_index = nil
  states = {}
  last_refresh = 0
  project.clear_assignment_caches()
  ui.apply_configured_dock = true
  return config
end

-- ---------------------------------------------------------------------------
-- Main loop.
-- ---------------------------------------------------------------------------

local function loop()
  local debug_active_for_frame = debug_mode
  local loop_started = debug_active_for_frame and reaper.time_precise()
  local stage_started = debug_active_for_frame and reaper.time_precise()
  switch_project_if_needed()
  if debug_active_for_frame then
    local metric = debug_metrics.switch
    local elapsed = reaper.time_precise() - stage_started
    metric.total = metric.total + elapsed
    metric.max = math.max(metric.max, elapsed)
    metric.count = metric.count + 1
  end
  poll_preset_program_change()
  local now = reaper.time_precise()
  if ui.project_lists_dirty
      or (ui.open_cell_configuration
        and now - ui.last_project_list_refresh >= PROJECT_LIST_REFRESH_SECONDS) then
    ui.refresh_project_lists(config, debug_mode, debug_metrics)
  end
  if not debug_mode or not debug_pause_state_reads then
    if now - last_refresh >= config.refresh_ms / 1000 then
      local previous_refresh = last_refresh
      if debug_active_for_frame then
        stage_started = reaper.time_precise()
      end
      refresh_states()
      if debug_active_for_frame then
        local lateness = math.max(
          0,
          now - previous_refresh - config.refresh_ms / 1000
        )
        if lateness > 0.005 then
          debug_metrics.late_refreshes = debug_metrics.late_refreshes + 1
        end
        debug_metrics.max_refresh_lateness = math.max(
          debug_metrics.max_refresh_lateness,
          lateness
        )
      end
    end
  end
  if debug_active_for_frame then
    stage_started = reaper.time_precise()
  end
  local needs_refresh = ui.draw_window(
    config,
    active_project,
    states,
    debug_mode,
    debug_pause_state_reads,
    debug_pause_grid,
    debug_metrics,
    refresh_states,
    -- on_toggle_debug
    function()
      debug_mode = not debug_mode
      if debug_mode then
        debug_metrics = diag.reset_metrics()
        debug_pause_state_reads = false
        debug_pause_grid = false
      else
        debug_pause_state_reads = false
        debug_pause_grid = false
      end
    end,
    -- on_toggle_pause_reads
    function()
      debug_pause_state_reads = not debug_pause_state_reads
      last_refresh = reaper.time_precise()
    end,
    -- on_toggle_pause_grid
    function()
      debug_pause_grid = not debug_pause_grid
    end,
    -- on_import
    function()
      local imported = cfg.import_configuration()
      if not imported then
        return nil
      end
      return replace_config(imported)
    end,
    -- on_export
    function()
      cfg.export_configuration(config)
    end,
    -- on_reset
    function()
      return replace_config(cfg.default_config())
    end
  )
  if needs_refresh then
    last_refresh = 0
    refresh_states()
  end
  if debug_active_for_frame then
    local draw_elapsed = reaper.time_precise() - stage_started
    local draw_metric = debug_metrics.draw
    draw_metric.total = draw_metric.total + draw_elapsed
    draw_metric.max = math.max(draw_metric.max, draw_elapsed)
    draw_metric.count = draw_metric.count + 1
  end
  if ui.window_open then
    if debug_active_for_frame then
      local now_finished = reaper.time_precise()
      local loop_elapsed = now_finished - loop_started
      local loop_metric = debug_metrics.loop
      loop_metric.total = loop_metric.total + loop_elapsed
      loop_metric.max = math.max(loop_metric.max, loop_elapsed)
      loop_metric.count = loop_metric.count + 1
      debug_metrics.frames = debug_metrics.frames + 1
      if loop_elapsed > 0.005 then
        debug_metrics.loop_over_5ms = debug_metrics.loop_over_5ms + 1
      end
      if loop_elapsed > 0.010 then
        debug_metrics.loop_over_10ms = debug_metrics.loop_over_10ms + 1
      end
      diag.report_metrics(
        debug_metrics,
        config,
        active_project,
        debug_pause_state_reads,
        debug_pause_grid,
        now_finished
      )
    end
    reaper.defer(loop)
  else
    cfg.save_config(active_project, config)
  end
end

-- ---------------------------------------------------------------------------
-- Startup.
-- ---------------------------------------------------------------------------

refresh_states()
reaper.defer(loop)
