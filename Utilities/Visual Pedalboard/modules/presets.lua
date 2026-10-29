-- Visual Pedalboard: preset save/load, plugin state capture/restore.

local M = {}

-- Dependencies set by init().
local cfg      -- modules/config
local project  -- modules/project

function M.init(config_module, project_module)
  cfg = config_module
  project = project_module
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

function M.copy_cells(source)
  local copied = {}
  for index = 1, cfg.MAX_CELLS do
    local cell = source[index] or cfg.new_cell(index)
    local copied_cell = {}
    for key, value in pairs(cell) do
      copied_cell[key] = value
    end
    copied[index] = copied_cell
  end
  return copied
end

function M.preset_has_plugin_state(preset)
  for _, cell in ipairs(preset.cells) do
    if cell.fx_state then
      return true
    end
  end
  return false
end

-- ---------------------------------------------------------------------------
-- Capture / restore plugin state chunks
-- ---------------------------------------------------------------------------

function M.capture_plugin_states(cells)
  if not reaper.GetTrackStateChunk then
    return nil, "This REAPER version cannot capture plugin state chunks."
  end
  local captured, seen = {}, {}
  for _, cell in ipairs(cells) do
    if cell.track_guid ~= "" and cell.fx_guid ~= "" then
      local key = cell.track_guid .. "\31" .. cell.fx_guid
      if not seen[key] then
        seen[key] = true
        local track = project.resolve_track(cell.track_guid)
        if not track then
          return nil, "Cannot save plugin state: a pedal's track is unavailable."
        end
        local fx_index = project.find_fx_index(track, cell.fx_guid)
        if not fx_index then
          return nil, "Cannot save plugin state: a pedal's FX is unavailable."
        end
        local ok, track_chunk = reaper.GetTrackStateChunk(track, "", false)
        if not ok or type(track_chunk) ~= "string" then
          return nil, "REAPER could not read a track state chunk."
        end
        local start_position, end_position = cfg.fx_chunk_range(
          track_chunk,
          cell.fx_guid
        )
        if not start_position then
          return nil, "Could not locate a configured FX in its track state chunk."
        end
        captured[key] = {
          track_guid = cell.track_guid,
          fx_guid = cell.fx_guid,
          chunk = track_chunk:sub(start_position, end_position),
        }
      end
    end
  end
  return captured
end

local function rollback_plugin_chunks(original_chunks, active_project)
  local restored = true
  if #original_chunks > 0 then
    reaper.Undo_BeginBlock2(active_project)
  end
  for _, entry in ipairs(original_chunks) do
    if not reaper.SetTrackStateChunk(
        entry.track,
        entry.chunk,
        true
      ) then
      restored = false
    end
  end
  if #original_chunks > 0 then
    reaper.Undo_EndBlock2(active_project, "Roll back Visual Pedalboard preset", -1)
  end
  if not restored then
    cfg.report_error("Could not roll back every plugin state change.")
  end
  return restored
end

M.rollback_plugin_chunks = rollback_plugin_chunks

function M.restore_plugin_states(plugin_states, active_project, preset_index)
  if not reaper.GetTrackStateChunk or not reaper.SetTrackStateChunk then
    return nil, "This REAPER version cannot restore plugin state chunks."
  end
  local chunks_by_track, original_chunks, seen_fx = {}, {}, {}
  local has_plugin_state = false
  for _, cell in ipairs(plugin_states) do
    if cell.fx_state then
      has_plugin_state = true
      break
    end
  end
  if not has_plugin_state then
    return original_chunks
  end

  reaper.Undo_BeginBlock2(active_project)
  for _, cell in ipairs(plugin_states) do
    local state = cell.fx_state
    if state then
      local key = state.track_guid .. "\31" .. state.fx_guid
      local location = (preset_index and "Preset " .. preset_index .. ", " or "")
        .. "pedal " .. tostring(cell.position) .. " (FX " .. state.fx_guid .. ")"
      if not seen_fx[key] then
        seen_fx[key] = true
        local track = project.resolve_track(state.track_guid)
        if not track or not project.find_fx_index(track, state.fx_guid) then
          cfg.report_error(
            location .. " plugin state was skipped: its track or FX is unavailable."
          )
        else
          local track_entry = chunks_by_track[state.track_guid]
          if not track_entry then
            local ok, track_chunk = reaper.GetTrackStateChunk(track, "", false)
            if ok and type(track_chunk) == "string" then
              track_entry = {
                track = track,
                current = track_chunk,
                original = track_chunk,
              }
              chunks_by_track[state.track_guid] = track_entry
            else
              cfg.report_error(
                location
                  .. " plugin state was skipped: REAPER could not read the track state."
              )
            end
          end
          if track_entry then
            local updated = cfg.replace_fx_chunk(
              track_entry.current,
              state.fx_guid,
              state.chunk
            )
            if not updated then
              cfg.report_error(
                location
                  .. " plugin state was skipped: the FX was not found in the track state."
              )
            elseif reaper.SetTrackStateChunk(track, updated, true) then
              track_entry.current = updated
            else
              cfg.report_error(
                location
                  .. " plugin state was skipped: REAPER could not apply the saved FX state."
              )
              if not reaper.SetTrackStateChunk(track, track_entry.current, true) then
                cfg.report_error(
                  location
                    .. " failed-state rollback also failed; the track may have been partially changed."
                )
              end
            end
          end
        end
      end
    end
  end

  for _, entry in pairs(chunks_by_track) do
    if entry.current ~= entry.original then
      original_chunks[#original_chunks + 1] = {
        track = entry.track,
        chunk = entry.original,
      }
    end
  end
  reaper.Undo_EndBlock2(active_project, "Load Visual Pedalboard preset", -1)
  return original_chunks
end

-- ---------------------------------------------------------------------------
-- Restore / rollback pedal parameter states
-- ---------------------------------------------------------------------------

local function restore_pedal_states(saved_cells, active_project)
  if not reaper.TrackFX_GetParamNormalized
      or not reaper.TrackFX_SetParamNormalized
      or not reaper.TrackFX_GetNumParams then
    return {}, { "This REAPER version cannot restore pedal parameter states." }
  end
  local operations, errors = {}, {}
  for _, saved_cell in ipairs(saved_cells) do
    if saved_cell.state then
      local track = project.resolve_track(saved_cell.track_guid)
      local fx_index = track and project.find_fx_index(track, saved_cell.fx_guid)
      if not track or not fx_index then
        errors[#errors + 1] = "pedal " .. tostring(saved_cell.position)
          .. " was skipped because its track or FX is unavailable."
      else
        local param_index = saved_cell.param_index
        if saved_cell.param_ident ~= "" then
          if not reaper.TrackFX_GetParamFromIdent then
            errors[#errors + 1] = "pedal " .. tostring(saved_cell.position)
              .. " was skipped because this REAPER version cannot resolve its parameter identifier."
            param_index = nil
          else
            param_index = reaper.TrackFX_GetParamFromIdent(
              track,
              fx_index,
              saved_cell.param_ident
            )
          end
        end
        if param_index and (param_index < 0
            or param_index >= reaper.TrackFX_GetNumParams(track, fx_index)) then
          errors[#errors + 1] = "pedal " .. tostring(saved_cell.position)
            .. " was skipped because its saved parameter is unavailable."
        elseif param_index then
          local current = reaper.TrackFX_GetParamNormalized(
            track,
            fx_index,
            param_index
          )
          local bypassed = saved_cell.state == "bypassed"
          local value = bypassed ~= saved_cell.invert_state and 1 or 0
          if (current >= 0.5 and value == 0)
              or (current < 0.5 and value == 1) then
            operations[#operations + 1] = {
              track = track,
              fx_index = fx_index,
              param_index = param_index,
              value = value,
              previous_value = current,
              position = saved_cell.position,
            }
          end
        end
      end
    end
  end

  local changed_parameters = {}
  if #operations > 0 then
    reaper.Undo_BeginBlock2(active_project)
  end
  for _, operation in ipairs(operations) do
    if not reaper.TrackFX_SetParamNormalized(
        operation.track,
        operation.fx_index,
        operation.param_index,
        operation.value
        ) then
          errors[#errors + 1] = "pedal " .. tostring(operation.position)
            .. " could not restore its saved parameter."
    else
      changed_parameters[#changed_parameters + 1] = {
        track = operation.track,
        fx_index = operation.fx_index,
        param_index = operation.param_index,
        value = operation.previous_value,
      }
    end
  end
  if #operations > 0 then
    reaper.Undo_EndBlock2(active_project, "Restore Visual Pedalboard preset", -1)
  end
  return changed_parameters, errors
end

M.restore_pedal_states = restore_pedal_states

-- ---------------------------------------------------------------------------
-- Save / load preset (high-level)
-- ---------------------------------------------------------------------------

--- Save a preset into the config.
--- @param config table the active config
--- @param index integer preset slot number
--- @param name string preset name
--- @param save_plugins_state boolean whether to save FX state chunks
--- @param active_project userdata REAPER project
--- @param locked boolean|nil whether the preset is locked from edits
--- @param selected_fx table|nil map of track/FX GUID keys to selection booleans
--- @return boolean success
function M.save_preset(
    config,
    index,
    name,
    save_plugins_state,
    active_project,
    locked,
    selected_fx
  )
  local previous_preset = config.presets[index]
  if previous_preset and previous_preset.locked and locked == nil then
    return false
  end
  local cells = {}
  local configured_cells = {}
  for position = 1, cfg.MAX_CELLS do
    local cell = config.cells[position]
    if cell and cell.track_guid ~= "" and cell.fx_guid ~= "" then
      local track = project.resolve_track(cell.track_guid)
      local fx_index = track and project.find_fx_index(track, cell.fx_guid)
      local state = project.inspect_cell(cell, track, fx_index).state
      if state ~= "active" and state ~= "bypassed" then
        cfg.report_error(
          "Cannot save preset: pedal " .. position
            .. " does not have a valid, readable FX parameter."
        )
        return false
      end
      cells[#cells + 1] = {
        position = position,
        state = state,
      }
      configured_cells[#configured_cells + 1] = {
        position = position,
        cell = cell,
      }
    end
  end
  if save_plugins_state then
    local cells_to_capture = {}
    for _, entry in ipairs(configured_cells) do
      local key = entry.cell.track_guid .. "\31" .. entry.cell.fx_guid
      if selected_fx == nil or selected_fx[key] == true then
        cells_to_capture[#cells_to_capture + 1] = entry.cell
      end
    end
    local captured, capture_error = M.capture_plugin_states(cells_to_capture)
    if not captured then
      cfg.report_error(capture_error)
      return false
    end
    for ci, entry in ipairs(configured_cells) do
      local state = captured[
        entry.cell.track_guid .. "\31" .. entry.cell.fx_guid
      ]
      if state then
        cells[ci].fx_state = { chunk = state.chunk }
      end
    end
  end
  config.presets[index] = {
    name = name,
    cells = cells,
    locked = locked and true or false,
  }
  if not cfg.save_config(active_project, config) then
    config.presets[index] = previous_preset
    return false
  end
  return true
end

--- Reset (clear) a preset slot in the config.
--- @param config table the active config
--- @param index integer preset slot number
--- @param active_project userdata REAPER project
--- @return boolean success
function M.reset_preset(config, index, active_project)
  local previous_preset = config.presets[index]
  if previous_preset and previous_preset.locked then
    return false
  end
  config.presets[index] = false
  if not cfg.save_config(active_project, config) then
    config.presets[index] = previous_preset
    return false
  end
  return true
end

--- Load (apply) a preset.
--- @param config table the active config
--- @param index integer preset slot number
--- @param active_project userdata REAPER project
--- @param on_success function callback(states, last_refresh) after applying
function M.load_preset(config, index, active_project, on_success)
  local preset = config.presets[index]
  if not preset then
    return
  end
  local cells = {}
  for _, saved_cell in ipairs(preset.cells) do
    local configured_cell = config.cells[saved_cell.position]
    if not configured_cell
        or configured_cell.track_guid == ""
        or configured_cell.fx_guid == "" then
      cfg.report_error(
        "Preset " .. index .. ", pedal " .. tostring(saved_cell.position)
          .. " was skipped because the pedal is not assigned."
      )
    else
      local cell = {}
      for key, value in pairs(configured_cell) do
        cell[key] = value
      end
      cell.position = saved_cell.position
      cell.state = saved_cell.state
      if saved_cell.fx_state then
        cell.fx_state = {
          track_guid = configured_cell.track_guid,
          fx_guid = configured_cell.fx_guid,
          chunk = saved_cell.fx_state.chunk,
        }
      end
      cells[#cells + 1] = cell
    end
  end

  local original_chunks
  if M.preset_has_plugin_state({ cells = cells }) then
    local restore_error
    original_chunks, restore_error = M.restore_plugin_states(
      cells,
      active_project,
      index
    )
    if not original_chunks then
      cfg.report_error(
        "Preset " .. index .. " plugin states were skipped: "
          .. tostring(restore_error)
      )
      original_chunks = {}
    end
  end
  local _, state_errors = restore_pedal_states(cells, active_project)
  for _, state_error in ipairs(state_errors) do
    cfg.report_error("Preset " .. index .. ": " .. state_error)
  end
  project.clear_assignment_caches()
  if on_success then
    on_success()
  end
  return #cells > 0
end

return M
