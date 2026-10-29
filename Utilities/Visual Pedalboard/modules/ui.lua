-- Visual Pedalboard: all ImGui rendering — grid, selectors, modals, settings.

local M = {}

-- Dependencies set by init().
local cfg       -- modules/config
local project   -- modules/project
local presets   -- modules/presets
local diag      -- modules/diagnostics

local ImGui     -- ReaImGui module table
local ctx       -- ImGui context
local bold_font
local italic_font
local FLT_MIN

-- Shared UI state exposed through M for the main loop to read/write.
M.selected_index = 1
M.draft_index = nil
---@type CellDraft|nil
M.draft = nil
M.track_filter = ""
M.cell_text_layouts = {}
M.project_lists_dirty = false
M.last_project_list_refresh = 0
M.window_open = true
M.first_frame = true
M.open_cell_configuration = false
M.request_cell_configuration = false
M.settings_open = true
M.request_settings = false
M.settings_draft = nil
M.help_open = true
M.request_help = false
M.about_open = true
M.request_about = false
M.preset_dialog_open = false
M.request_preset_dialog = false
M.preset_dialog_index = nil
M.preset_dialog_name = ""
M.preset_dialog_save_plugins_state = false
M.preset_dialog_fx_selections = {}
M.preset_dialog_fx_entries = {}
M.preset_dialog_locked = false
M.preset_dialog_confirming = false
M.preset_dialog_unlock_confirming = false
M.apply_configured_dock = false
M.active_preset_index = nil

-- Project list caches.
M.track_entries = {}
M.fx_entries_by_track = {}
M.param_entries_by_fx = {}

function M.on_project_switched()
  M.project_lists_dirty = true
  M.last_project_list_refresh = 0
  M.selected_index = 1
  M.draft = nil
  M.draft_index = nil
  M.open_cell_configuration = false
  M.request_cell_configuration = false
  M.settings_draft = nil
  M.active_preset_index = nil
  M.preset_dialog_open = false
  M.request_preset_dialog = false
  M.preset_dialog_index = nil
  M.preset_dialog_fx_selections = {}
  M.preset_dialog_fx_entries = {}
  M.preset_dialog_confirming = false
  M.apply_configured_dock = true
end

--- Initialise the UI module.
--- @param imgui_table table the imported ImGui module
--- @param imgui_ctx userdata the created ImGui context
--- @param bold userdata bold font
--- @param italic userdata italic font
--- @param config_module table modules/config
--- @param project_module table modules/project
--- @param presets_module table modules/presets
--- @param diagnostics_module table modules/diagnostics
function M.init(imgui_table, imgui_ctx, bold, italic,
                config_module, project_module, presets_module, diagnostics_module)
  ImGui = imgui_table
  ctx = imgui_ctx
  FLT_MIN = select(1, ImGui.NumericLimits_Float())
  bold_font = bold
  italic_font = italic
  cfg = config_module
  project = project_module
  presets = presets_module
  diag = diagnostics_module
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function color_for_editor(value, default_color)
  return (cfg.color_from_hex(value) or default_color) >> 8
end

local function push_configured_font(config)
  ImGui.PushFont(ctx, nil, config.font_size)
  return true
end

local function push_cell_colors(cell, state)
  local color = cfg.COLORS[state]
  if state == "active" then
    color = cfg.color_from_hex(cell.active_color) or color
  elseif state == "bypassed" then
    color = cfg.color_from_hex(cell.bypass_color) or color
  end
  ImGui.PushStyleColor(ctx, ImGui.Col_Button, color)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, color)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive, color)
end

local function toggle_cell(cell, state)
  if state.state ~= "active" and state.state ~= "bypassed" then
    return
  end
  local bypassed = state.state == "active"
  local value = bypassed ~= cell.invert_state and 1 or 0
  reaper.Undo_BeginBlock2(0)
  local changed = reaper.TrackFX_SetParamNormalized(
    state.track,
    state.fx_index,
    state.param_index,
    value
  )
  reaper.Undo_EndBlock2(
    0,
    (bypassed and "Bypass FX: " or "Enable FX: ") .. cell.label,
    -1
  )
  if not changed then
    cfg.report_error("Could not change the selected FX parameter.")
    return
  end
  reaper.UpdateArrange()
end

local function normalize_cells(config)
  for index = 1, config.rows * config.columns do
    if not config.cells[index] then
      config.cells[index] = cfg.new_cell(index)
    end
  end
end

local function preset_cell_height(config)
  return math.max(52, config.font_size * 2 + 12)
end

local function configured_preset_fx(config)
  local entries, seen = {}, {}
  for position = 1, cfg.MAX_CELLS do
    local cell = config.cells[position]
    if cell and cell.track_guid ~= "" and cell.fx_guid ~= "" then
      local key = cell.track_guid .. "\31" .. cell.fx_guid
      if not seen[key] then
        seen[key] = true
        local track = project.resolve_track(cell.track_guid)
        local fx_index = track and project.find_fx_index(track, cell.fx_guid)
        local track_name, fx_name = "Unavailable track", "Unavailable FX"
        if track then
          local _, name = reaper.GetTrackName(track)
          track_name = type(name) == "string" and name ~= "" and name or "Track"
        end
        if track and fx_index then
          local _, name = reaper.TrackFX_GetFXName(track, fx_index)
          fx_name = project.clean_fx_name(type(name) == "string" and name or "")
          fx_name = fx_name ~= "" and fx_name or ("FX " .. (fx_index + 1))
        end
        entries[#entries + 1] = {
          key = key,
          label = track_name .. " / " .. fx_name,
        }
      end
    end
  end
  return entries
end

local function initialize_preset_fx_selections(config, preset)
  M.preset_dialog_fx_selections = {}
  M.preset_dialog_fx_entries = configured_preset_fx(config)
  local saved_fx = {}
  if preset then
    for _, cell in ipairs(preset.cells) do
      if cell.fx_state then
        local configured_cell = config.cells[cell.position]
        if configured_cell then
          saved_fx[configured_cell.track_guid .. "\31" .. configured_cell.fx_guid] = true
        end
      end
    end
  end
  local has_saved_state = preset and presets.preset_has_plugin_state(preset)
  for _, entry in ipairs(M.preset_dialog_fx_entries) do
    M.preset_dialog_fx_selections[entry.key] = has_saved_state
        and saved_fx[entry.key] == true or not has_saved_state
  end
end

-- ---------------------------------------------------------------------------
-- Draft management
-- ---------------------------------------------------------------------------

local function load_draft(index, config)
  M.selected_index = index
  local source = config.cells[index] or cfg.new_cell(index)
  M.draft = {
    label = source.label,
    track_guid = source.track_guid,
    fx_guid = source.fx_guid,
    param_index = source.param_index,
    param_ident = source.param_ident,
    invert_state = source.invert_state,
    active_color = source.active_color,
    bypass_color = source.bypass_color,
    tooltip = source.tooltip,
  }
  M.draft_index = index
end

local function find_selected_fx()
  if not M.draft then
    return nil
  end
  for _, entry in ipairs(M.fx_entries_by_track[M.draft.track_guid] or {}) do
    if entry.guid == M.draft.fx_guid then
      return entry
    end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Project list refresh
-- ---------------------------------------------------------------------------

function M.refresh_project_lists(config, debug_mode, debug_metrics)
  local debug_started = debug_mode and reaper.time_precise()
  M.track_entries = project.all_tracks()
  M.fx_entries_by_track = {}
  local listed_fx = debug_mode and 0 or nil
  for _, track_entry in ipairs(M.track_entries) do
    local entries = {}
    for fx_index = 0, reaper.TrackFX_GetCount(track_entry.track) - 1 do
      local _, name = reaper.TrackFX_GetFXName(track_entry.track, fx_index)
      local guid = reaper.TrackFX_GetFXGUID(track_entry.track, fx_index)
      entries[#entries + 1] = {
        guid = guid,
        name = name ~= "" and name or ("FX " .. (fx_index + 1)),
        index = fx_index,
        track = track_entry.track,
      }
      if debug_mode then
        listed_fx = listed_fx + 1
      end
    end
    M.fx_entries_by_track[track_entry.guid] = entries
  end
  M.param_entries_by_fx = {}
  M.last_project_list_refresh = reaper.time_precise()
  M.project_lists_dirty = false
  if debug_mode and debug_metrics then
    local elapsed = reaper.time_precise() - debug_started
    debug_metrics.project_lists.total = debug_metrics.project_lists.total + elapsed
    debug_metrics.project_lists.max = math.max(debug_metrics.project_lists.max, elapsed)
    debug_metrics.project_lists.count = debug_metrics.project_lists.count + 1
    debug_metrics.tracks_listed = debug_metrics.tracks_listed + #M.track_entries
    debug_metrics.fx_listed = debug_metrics.fx_listed + listed_fx
  end
end

-- ---------------------------------------------------------------------------
-- Selectors
-- ---------------------------------------------------------------------------

local function draw_track_selector()
  if not M.draft then
    return
  end
  local preview = "— Unassigned —"
  for _, entry in ipairs(M.track_entries) do
    if entry.guid == M.draft.track_guid then
      preview = entry.name
      break
    end
  end
  if M.draft.track_guid ~= "" and preview == "— Unassigned —" then
    preview = "Missing track"
  end

  if ImGui.BeginCombo(ctx, "Track", preview) then
    if ImGui.Selectable(ctx, "— Unassigned —", M.draft.track_guid == "") then
      M.draft.track_guid = ""
      M.draft.fx_guid = ""
      M.draft.param_index = -1
      M.draft.param_ident = ""
    end
    for _, entry in ipairs(M.track_entries) do
      if M.track_filter == "" or entry.name:lower():find(M.track_filter:lower(), 1, true) then
        local label = entry.name .. "##" .. entry.guid
        if ImGui.Selectable(ctx, label, entry.guid == M.draft.track_guid) then
          if M.draft.track_guid ~= entry.guid then
            M.draft.fx_guid = ""
            M.draft.param_index = -1
            M.draft.param_ident = ""
          end
          M.draft.track_guid = entry.guid
        end
      end
    end
    ImGui.EndCombo(ctx)
  end
end

local function draw_fx_selector()
  if not M.draft then
    return
  end
  local entries = M.fx_entries_by_track[M.draft.track_guid] or {}
  local preview = "— Select FX —"
  for _, entry in ipairs(entries) do
    if entry.guid == M.draft.fx_guid then
      preview = entry.name
      break
    end
  end
  if M.draft.fx_guid ~= "" and preview == "— Select FX —" then
    preview = "Missing FX"
  end

  if ImGui.BeginCombo(ctx, "FX", preview) then
    if ImGui.Selectable(ctx, "— Select FX —", M.draft.fx_guid == "") then
      M.draft.fx_guid = ""
      M.draft.param_index = -1
      M.draft.param_ident = ""
    end
    for _, entry in ipairs(entries) do
      local label = entry.name .. "##" .. entry.guid
      if ImGui.Selectable(ctx, label, entry.guid == M.draft.fx_guid) then
        if M.draft.fx_guid ~= entry.guid then
          M.draft.param_index = -1
          M.draft.param_ident = ""
        end
        M.draft.fx_guid = entry.guid
      end
    end
    ImGui.EndCombo(ctx)
  end
end

local function draw_param_selector()
  if not M.draft then
    return
  end
  local fx_entry = find_selected_fx()
  if not fx_entry then
    ImGui.Text(ctx, "Select an FX to list its parameters.")
    return
  end
  local params = M.param_entries_by_fx[fx_entry.guid]
  if not params then
    params = {}
    for param_index = 0, reaper.TrackFX_GetNumParams(fx_entry.track, fx_entry.index) - 1 do
      local _, param_name = reaper.TrackFX_GetParamName(
        fx_entry.track,
        fx_entry.index,
        param_index
      )
      local param_ident = ""
      if reaper.TrackFX_GetParamIdent then
        local _, ident = reaper.TrackFX_GetParamIdent(
          fx_entry.track,
          fx_entry.index,
          param_index
        )
        param_ident = ident or ""
      end
      params[#params + 1] = {
        index = param_index,
        ident = param_ident,
        label = string.format("%d: %s", param_index + 1,
          param_name ~= "" and param_name or ("Parameter " .. (param_index + 1))),
      }
    end
    M.param_entries_by_fx[fx_entry.guid] = params
  end
  local preview = "— Select parameter —"
  for _, entry in ipairs(params) do
    local selected = M.draft.param_ident ~= "" and entry.ident == M.draft.param_ident
      or M.draft.param_ident == "" and entry.index == M.draft.param_index
    if selected then
      preview = entry.label
      break
    end
  end
  if M.draft.param_index >= 0 and preview == "— Select parameter —" then
    preview = "Missing parameter"
  end

  if ImGui.BeginCombo(ctx, "Parameter", preview) then
    if ImGui.Selectable(ctx, "— Select parameter —", M.draft.param_index < 0) then
      M.draft.param_index = -1
      M.draft.param_ident = ""
    end
    for _, entry in ipairs(params) do
      local selected = M.draft.param_ident ~= "" and entry.ident == M.draft.param_ident
        or M.draft.param_ident == "" and entry.index == M.draft.param_index
      if ImGui.Selectable(ctx, entry.label .. "##" .. entry.index, selected) then
        M.draft.param_index = entry.index
        M.draft.param_ident = entry.ident
      end
    end
    ImGui.EndCombo(ctx)
  end
end

-- ---------------------------------------------------------------------------
-- Cell config save / reset
-- ---------------------------------------------------------------------------

local function save_cell_draft(config, active_project)
  if not M.draft or not M.draft_index then
    return
  end
  local active_color = M.draft.active_color:gsub("^#", ""):upper()
  local bypass_color = M.draft.bypass_color:gsub("^#", ""):upper()
  if active_color ~= "" and not cfg.color_from_hex(active_color) then
    cfg.report_error("Active color must be blank or a six-digit RGB value.")
    return
  end
  if bypass_color ~= "" and not cfg.color_from_hex(bypass_color) then
    cfg.report_error("Bypass color must be blank or a six-digit RGB value.")
    return
  end
  if M.draft.track_guid ~= "" then
    local track = project.resolve_track(M.draft.track_guid)
    local fx_index = track and project.find_fx_index(track, M.draft.fx_guid)
    if not track or not fx_index then
      cfg.report_error("Select a loaded FX on the selected track.")
      return
    end
    local param_index = M.draft.param_index
    if M.draft.param_ident ~= "" then
      if not reaper.TrackFX_GetParamFromIdent then
        cfg.report_error("This REAPER version cannot resolve the selected parameter.")
        return
      end
      param_index = reaper.TrackFX_GetParamFromIdent(track, fx_index, M.draft.param_ident)
    end
    if param_index < 0 or param_index >= reaper.TrackFX_GetNumParams(track, fx_index) then
      cfg.report_error("Select a valid parameter from the selected FX.")
      return
    end
  else
    M.draft.fx_guid = ""
    M.draft.param_index = -1
    M.draft.param_ident = ""
  end
  local cell = config.cells[M.draft_index]
  cell.label = M.draft.label ~= "" and M.draft.label or ("Cell " .. M.draft_index)
  cell.track_guid = M.draft.track_guid
  cell.fx_guid = M.draft.fx_guid
  cell.param_index = M.draft.param_index
  cell.param_ident = M.draft.param_ident
  cell.invert_state = M.draft.invert_state
  cell.active_color = active_color
  cell.bypass_color = bypass_color
  cell.tooltip = M.draft.tooltip
  cfg.save_config(active_project, config)
  project.clear_assignment_caches()
  return true -- signal that a refresh is needed
end

local function reset_selected_cell()
  M.draft = cfg.new_cell(M.selected_index)
  M.draft_index = M.selected_index
end

-- ---------------------------------------------------------------------------
-- Drawing: presets
-- ---------------------------------------------------------------------------

local function draw_presets(
  layout_config,
  config,
  active_project,
  states,
  refresh_states_fn
)
  ImGui.Separator(ctx)
  ImGui.Text(ctx, "Presets")
  local available_width = select(1, ImGui.GetContentRegionAvail(ctx))
  local spacing = layout_config.spacing
  local cell_width = math.max(
    1,
    (available_width - spacing * (cfg.PRESET_COUNT - 1)) / cfg.PRESET_COUNT
  )
  local cell_height = preset_cell_height(layout_config)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_ItemSpacing, spacing, spacing)
  for index = 1, cfg.PRESET_COUNT do
    if index > 1 then
      ImGui.SameLine(ctx)
    end
    local preset = config.presets[index]
    ImGui.PushID(ctx, "preset-" .. index)
    local color = preset and (
      M.active_preset_index == index and cfg.COLORS.active
        or cfg.COLORS.preset_inactive
    ) or cfg.COLORS.unassigned
    ImGui.PushStyleColor(ctx, ImGui.Col_Button, color)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, color)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive, color)
    local clicked = ImGui.Button(ctx, "##preset", cell_width, cell_height)
    local min_x, min_y = ImGui.GetItemRectMin(ctx)
    local max_x, max_y = ImGui.GetItemRectMax(ctx)
    local name = preset and preset.name ~= "" and preset.name
      or (preset and ("Preset " .. index) or "")
    local draw_list = ImGui.GetWindowDrawList(ctx)
    local text_color = ImGui.GetStyleColor(ctx, ImGui.Col_Text)
    ImGui.PushClipRect(ctx, min_x, min_y, max_x, max_y, true)
    local number = tostring(index)
    local number_width, number_height = ImGui.CalcTextSize(ctx, number)
    local number_x = min_x + (max_x - min_x - number_width) * 0.5
    local name_width, name_height = 0, 0
    if name ~= "" then
      name_width, name_height = ImGui.CalcTextSize(ctx, name)
    end
    local text_height = number_height
      + (name ~= "" and name_height + 2 or 0)
    local number_y = min_y + (max_y - min_y - text_height) * 0.5
    ImGui.DrawList_AddTextEx(
      draw_list,
      ImGui.GetFont(ctx),
      ImGui.GetFontSize(ctx),
      number_x,
      number_y,
      text_color,
      number
    )
    if name ~= "" then
      local name_x = min_x + (max_x - min_x - name_width) * 0.5
      ImGui.DrawList_AddTextEx(
        draw_list,
        ImGui.GetFont(ctx),
        ImGui.GetFontSize(ctx),
        name_x,
        number_y + number_height + 2,
        text_color,
        name
      )
    end
    if preset and presets.preset_has_plugin_state(preset) then
      local icon = "🎛"
      local icon_font_size = 11
      ImGui.PushFont(ctx, nil, icon_font_size)
      local icon_width = ImGui.CalcTextSize(ctx, icon)
      ImGui.PopFont(ctx)
      local icon_x = max_x - icon_width
      ImGui.DrawList_AddTextEx(
        draw_list,
        ImGui.GetFont(ctx),
        icon_font_size,
        icon_x,
        min_y,
        text_color,
        icon
      )
    end
    if preset and preset.locked then
      local lock_padding = 0
      local lock_x = min_x + lock_padding
      local lock_y = min_y + lock_padding
      ImGui.DrawList_AddTextEx(
        draw_list,
        ImGui.GetFont(ctx),
        -- ImGui.GetFontSize(ctx),
        11,
        lock_x,
        lock_y,
        text_color,
        "🔒"
      )
    end
    ImGui.PopClipRect(ctx)
    ImGui.PopStyleColor(ctx, 3)
    if ImGui.IsItemClicked(ctx, 1) then
      M.preset_dialog_index = index
      M.preset_dialog_name = preset and preset.name or ""
      M.preset_dialog_save_plugins_state = preset
          and presets.preset_has_plugin_state(preset) or false
      initialize_preset_fx_selections(config, preset)
      M.preset_dialog_locked = preset and preset.locked or false
      M.preset_dialog_confirming = false
      M.preset_dialog_unlock_confirming = false
      M.preset_dialog_open = true
      M.request_preset_dialog = true
    elseif clicked and preset then
      local loaded = presets.load_preset(config, index, active_project, function()
        for k in pairs(states) do states[k] = nil end
        refresh_states_fn()
      end)
      if loaded then
        M.active_preset_index = index
      end
    end
    ImGui.PopID(ctx)
  end
  ImGui.PopStyleVar(ctx)
end

-- ---------------------------------------------------------------------------
-- Drawing: preset modal
-- ---------------------------------------------------------------------------

local function draw_preset_modal(config, active_project)
  if M.request_preset_dialog then
    ImGui.OpenPopup(ctx, "Preset configuration")
    M.request_preset_dialog = false
  end
  if not M.preset_dialog_index then
    return
  end
  local window_x, window_y = ImGui.GetWindowPos(ctx)
  local window_width, window_height = ImGui.GetWindowSize(ctx)
  ImGui.SetNextWindowPos(
    ctx,
    window_x + window_width * 0.5,
    window_y + window_height * 0.5,
    ImGui.Cond_Appearing,
    0.5,
    0.5
  )
  ImGui.SetNextWindowSize(ctx, 420, 0, ImGui.Cond_Appearing)
  local visible, open = ImGui.BeginPopupModal(
    ctx,
    "Preset configuration",
    M.preset_dialog_open,
    ImGui.WindowFlags_AlwaysAutoResize
  )
  M.preset_dialog_open = open
  if visible then
    local font_pushed = push_configured_font(config)
    local in_confirm = M.preset_dialog_confirming or M.preset_dialog_unlock_confirming
    local is_locked = M.preset_dialog_locked

    local disable_fields = in_confirm or is_locked
    if disable_fields then
      ImGui.BeginDisabled(ctx)
    end
    local changed
    changed, M.preset_dialog_name = ImGui.InputText(
      ctx,
      "Name",
      M.preset_dialog_name
    )
    changed, M.preset_dialog_save_plugins_state = ImGui.Checkbox(
      ctx,
      "Save plugins state",
      M.preset_dialog_save_plugins_state
    )
    if M.preset_dialog_save_plugins_state then
      ImGui.Indent(ctx)
      ImGui.Text(ctx, "Effects to include:")
      if disable_fields then
        ImGui.BeginDisabled(ctx)
      end
      if ImGui.BeginChild(
          ctx,
          "##preset_fx_list",
          -FLT_MIN,
          140,
          ImGui.ChildFlags_FrameStyle
        ) then
        local entries = M.preset_dialog_fx_entries
        if #entries == 0 then
          ImGui.TextDisabled(ctx, "No configured effects.")
        else
          for _, entry in ipairs(entries) do
            ImGui.PushID(ctx, entry.key)
            local selected = M.preset_dialog_fx_selections[entry.key] == true
            local selection_changed
            selection_changed, selected = ImGui.Checkbox(
              ctx,
              entry.label,
              selected
            )
            if selection_changed then
              M.preset_dialog_fx_selections[entry.key] = selected
            end
            ImGui.PopID(ctx)
          end
        end
        ImGui.EndChild(ctx)
      end
      if disable_fields then
        ImGui.EndDisabled(ctx)
      end
      ImGui.Unindent(ctx)
    end
    if disable_fields then
      ImGui.EndDisabled(ctx)
    end

    if in_confirm then
      ImGui.BeginDisabled(ctx)
    end
    local lock_changed, new_locked = ImGui.Checkbox(
      ctx,
      "Locked",
      M.preset_dialog_locked
    )
    if lock_changed then
      if M.preset_dialog_locked and not new_locked then
        -- User clicked to uncheck locked: prompt for confirmation before actually unlocking
        M.preset_dialog_unlock_confirming = true
      else
        M.preset_dialog_locked = new_locked
        if config.presets[M.preset_dialog_index] then
          config.presets[M.preset_dialog_index].locked = new_locked
          cfg.save_config(active_project, config)
        end
      end
    end
    if in_confirm then
      ImGui.EndDisabled(ctx)
    end
    ImGui.Separator(ctx)
    if M.preset_dialog_unlock_confirming then
      ImGui.Text(ctx, "Unlock preset in cell " .. M.preset_dialog_index .. "?")
      if ImGui.Button(ctx, "Unlock") then
        M.preset_dialog_locked = false
        if config.presets[M.preset_dialog_index] then
          config.presets[M.preset_dialog_index].locked = false
          cfg.save_config(active_project, config)
        end
        M.preset_dialog_unlock_confirming = false
      end
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, "Cancel") then
        M.preset_dialog_unlock_confirming = false
      end
    elseif M.preset_dialog_confirming then
      ImGui.Text(ctx, "Overwrite existing preset in cell "
        .. M.preset_dialog_index .. "?")
      if ImGui.Button(ctx, "Overwrite") then
        local trimmed_name = M.preset_dialog_name:gsub("^%s*(.-)%s*$", "%1")
        if presets.save_preset(
            config,
            M.preset_dialog_index,
            trimmed_name,
            M.preset_dialog_save_plugins_state,
            active_project,
            M.preset_dialog_locked,
            M.preset_dialog_fx_selections
          ) then
          M.preset_dialog_open = false
          M.preset_dialog_index = nil
          M.preset_dialog_fx_selections = {}
          M.preset_dialog_fx_entries = {}
          M.preset_dialog_locked = false
          M.preset_dialog_confirming = false
          M.preset_dialog_unlock_confirming = false
          ImGui.CloseCurrentPopup(ctx)
        end
      end
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, "Cancel") then
        M.preset_dialog_confirming = false
      end
    else
      if is_locked then
        ImGui.BeginDisabled(ctx)
      end
      if ImGui.Button(ctx, "Save preset") then
        local preset = config.presets[M.preset_dialog_index]
        if preset then
          M.preset_dialog_confirming = true
        else
          local trimmed_name = M.preset_dialog_name:gsub("^%s*(.-)%s*$", "%1")
          if presets.save_preset(
              config,
              M.preset_dialog_index,
              trimmed_name,
              M.preset_dialog_save_plugins_state,
              active_project,
              M.preset_dialog_locked,
              M.preset_dialog_fx_selections
            ) then
            M.preset_dialog_open = false
            M.preset_dialog_index = nil
            M.preset_dialog_fx_selections = {}
            M.preset_dialog_fx_entries = {}
            M.preset_dialog_locked = false
            M.preset_dialog_confirming = false
            M.preset_dialog_unlock_confirming = false
            ImGui.CloseCurrentPopup(ctx)
          end
        end
      end
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, "Reset preset") then
        local ok = true
        if config.presets[M.preset_dialog_index] then
          ok = presets.reset_preset(config, M.preset_dialog_index, active_project)
        end
        if ok then
          if M.active_preset_index == M.preset_dialog_index then
            M.active_preset_index = nil
          end
          M.preset_dialog_name = ""
          M.preset_dialog_save_plugins_state = false
          M.preset_dialog_fx_selections = {}
          M.preset_dialog_fx_entries = {}
          M.preset_dialog_locked = false
          M.preset_dialog_open = false
          M.preset_dialog_index = nil
          M.preset_dialog_confirming = false
          M.preset_dialog_unlock_confirming = false
          ImGui.CloseCurrentPopup(ctx)
        end
      end
      if is_locked then
        ImGui.EndDisabled(ctx)
      end
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, "Close") then
        M.preset_dialog_open = false
        M.preset_dialog_index = nil
        M.preset_dialog_fx_selections = {}
        M.preset_dialog_fx_entries = {}
        M.preset_dialog_locked = false
        M.preset_dialog_confirming = false
        M.preset_dialog_unlock_confirming = false
        ImGui.CloseCurrentPopup(ctx)
      end
    end
    if font_pushed then
      ImGui.PopFont(ctx)
    end
    ImGui.EndPopup(ctx)
  elseif not M.preset_dialog_open then
    M.preset_dialog_index = nil
    M.preset_dialog_fx_selections = {}
    M.preset_dialog_fx_entries = {}
    M.preset_dialog_locked = false
    M.preset_dialog_confirming = false
    M.preset_dialog_unlock_confirming = false
  end
end

-- ---------------------------------------------------------------------------
-- Drawing: grid
-- ---------------------------------------------------------------------------

local function draw_grid(config, states, debug_mode, debug_pause_state_reads,
                          refresh_states_fn)
  local spacing = config.spacing
  local available_width, available_height = ImGui.GetContentRegionAvail(ctx)
  local cell_width = math.max(
    1,
    (available_width - spacing * (config.columns - 1)) / config.columns
  )
  local presets_height = config.show_presets
      and (preset_cell_height(config) + config.font_size + 24) or 0
  local cell_height = math.max(
    1,
    (
      available_height
      - presets_height
      - spacing * (config.rows - 1)
    ) / config.rows
  )
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_ItemSpacing, spacing, spacing)
  for row = 1, config.rows do
    for column = 1, config.columns do
      local index = (row - 1) * config.columns + column
      local cell = config.cells[index]
      local state = states[index] or { state = "unassigned", message = "UNASSIGNED" }
      if column > 1 then
        ImGui.SameLine(ctx)
      end
      ImGui.PushID(ctx, tostring(index))
      push_cell_colors(cell, state.state)
      local label = cell.label ~= "" and cell.label or ("Cell " .. index)
      local clicked = ImGui.Button(
        ctx,
        config.minimal_gui and label or "##cell",
        cell_width,
        cell_height
      )
      if clicked then
        if not debug_mode or not debug_pause_state_reads then
          refresh_states_fn()
          local current_state = states[index]
          toggle_cell(cell, current_state)
          refresh_states_fn()
        end
      end
      if not config.minimal_gui then
        local fx_name = state.fx_name or ""
        local layout = M.cell_text_layouts[index]
        if not layout
            or layout.label ~= label
            or layout.fx_name ~= fx_name
            or layout.message ~= state.message
            or layout.font_size ~= config.font_size then
          local button_lines = { { text = label, font = bold_font } }
          if fx_name ~= "" then
            button_lines[#button_lines + 1] = {
              text = fx_name,
              font = italic_font,
            }
          end
          button_lines[#button_lines + 1] = { text = state.message }
          local total_text_height = 0
          for _, line in ipairs(button_lines) do
            ImGui.PushFont(ctx, line.font or ImGui.GetFont(ctx), config.font_size)
            line.width, line.height = ImGui.CalcTextSize(ctx, line.text)
            line.font_size = ImGui.GetFontSize(ctx)
            total_text_height = total_text_height + line.height
            ImGui.PopFont(ctx)
          end
          layout = {
            label = label,
            fx_name = fx_name,
            message = state.message,
            font_size = config.font_size,
            lines = button_lines,
            total_text_height = total_text_height,
          }
          M.cell_text_layouts[index] = layout
        end
        local min_x, min_y = ImGui.GetItemRectMin(ctx)
        local max_x, max_y = ImGui.GetItemRectMax(ctx)
        local text_y = min_y + (max_y - min_y - layout.total_text_height) * 0.5
        local draw_list = ImGui.GetWindowDrawList(ctx)
        local text_color = ImGui.GetStyleColor(ctx, ImGui.Col_Text)
        ImGui.PushClipRect(ctx, min_x, min_y, max_x, max_y, true)
        for line_index, line in ipairs(layout.lines) do
          local text_x = min_x + (max_x - min_x - line.width) * 0.5
          if line_index == 1 then
            ImGui.DrawList_AddRectFilled(
              draw_list,
              text_x - 4,
              text_y - 2,
              text_x + line.width + 4,
              text_y + line.height + 2,
              0x101010FF
            )
          end
          ImGui.DrawList_AddTextEx(
            draw_list,
            line.font or ImGui.GetFont(ctx),
            line.font_size,
            text_x,
            text_y,
            text_color,
            line.text
          )
          text_y = text_y + line.height
        end
        ImGui.PopClipRect(ctx)
      end
      ImGui.PopStyleColor(ctx, 3)
      if ImGui.IsItemClicked(ctx, 1) then
        load_draft(index, config)
        M.open_cell_configuration = true
        M.request_cell_configuration = true
        M.project_lists_dirty = true
      end
      if cell.tooltip ~= "" and ImGui.IsItemHovered(ctx) then
        if ImGui.BeginTooltip(ctx) then
          ImGui.Text(ctx, cell.tooltip)
          ImGui.EndTooltip(ctx)
        end
      end
      ImGui.PopID(ctx)
    end
  end
  ImGui.PopStyleVar(ctx)
end

-- ---------------------------------------------------------------------------
-- Drawing: cell configuration
-- ---------------------------------------------------------------------------

local function draw_cell_configuration(config, active_project)
  local selected_changed, next_index = ImGui.InputInt(ctx, "Selected cell", M.selected_index)
  if selected_changed then
    M.selected_index = cfg.clamp(next_index, 1, config.rows * config.columns)
    load_draft(M.selected_index, config)
  end
  M.selected_index = cfg.clamp(M.selected_index, 1, config.rows * config.columns)
  if M.draft_index ~= M.selected_index or not M.draft then
    load_draft(M.selected_index, config)
  end

  if not M.draft then
    return
  end

  local label_changed, label = ImGui.InputText(ctx, "Label", M.draft.label)
  if label_changed then M.draft.label = label end
  local filter_changed, filter = ImGui.InputText(ctx, "Search tracks", M.track_filter)
  if filter_changed then M.track_filter = filter end
  draw_track_selector()
  draw_fx_selector()
  draw_param_selector()
  local invert_changed, invert_state = ImGui.Checkbox(
    ctx,
    "Invert parameter state",
    M.draft.invert_state
  )
  if invert_changed then M.draft.invert_state = invert_state end
  local active_changed, active_color = ImGui.ColorEdit3(
    ctx,
    "Active RGB",
    color_for_editor(M.draft.active_color, cfg.COLORS.active)
  )
  if active_changed then
    M.draft.active_color = string.format("%06X", active_color & 0xFFFFFF)
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Default##active-color") then
    M.draft.active_color = ""
  end
  local bypass_changed, bypass_color = ImGui.ColorEdit3(
    ctx,
    "Bypassed RGB",
    color_for_editor(M.draft.bypass_color, cfg.COLORS.bypassed)
  )
  if bypass_changed then
    M.draft.bypass_color = string.format("%06X", bypass_color & 0xFFFFFF)
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Default##bypassed-color") then
    M.draft.bypass_color = ""
  end
  local tooltip_changed, tooltip = ImGui.InputText(ctx, "Tooltip", M.draft.tooltip)
  if tooltip_changed then M.draft.tooltip = tooltip end

  if ImGui.Button(ctx, "Save cell changes") then
    if save_cell_draft(config, active_project) then
      return true -- signal refresh
    end
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Reset selected cell") then
    reset_selected_cell()
  end
end

local function draw_cell_configuration_modal(config, active_project)
  if M.request_cell_configuration then
    ImGui.OpenPopup(ctx, "Cell Configuration")
    M.request_cell_configuration = false
  end

  local window_x, window_y = ImGui.GetWindowPos(ctx)
  local window_width, window_height = ImGui.GetWindowSize(ctx)
  local center_x = window_x + window_width * 0.5
  local center_y = window_y + window_height * 0.5
  ImGui.SetNextWindowPos(ctx, center_x, center_y, ImGui.Cond_Appearing, 0.5, 0.5)
  ImGui.SetNextWindowSize(ctx, 480, 0, ImGui.Cond_Appearing)

  local visible, open = ImGui.BeginPopupModal(
    ctx,
    "Cell Configuration",
    M.open_cell_configuration,
    ImGui.WindowFlags_AlwaysAutoResize
  )
  M.open_cell_configuration = open
  if visible then
    local font_pushed = push_configured_font(config)
    local needs_refresh = draw_cell_configuration(config, active_project)
    ImGui.Separator(ctx)
    if ImGui.Button(ctx, "Close") then
      M.open_cell_configuration = false
      ImGui.CloseCurrentPopup(ctx)
    end
    if font_pushed then
      ImGui.PopFont(ctx)
    end
    ImGui.EndPopup(ctx)
    return needs_refresh
  end
end

-- ---------------------------------------------------------------------------
-- Drawing: settings
-- ---------------------------------------------------------------------------

local function copy_table(value)
  if type(value) ~= "table" then
    return value
  end
  local copy = {}
  for key, nested_value in pairs(value) do
    copy[key] = copy_table(nested_value)
  end
  return copy
end

local function draw_settings(config)
  local changed, value = ImGui.InputInt(ctx, "Rows", config.rows)
  if changed then config.rows = cfg.clamp(value, 1, cfg.MAX_ROWS); normalize_cells(config) end
  changed, value = ImGui.InputInt(ctx, "Columns", config.columns)
  if changed then config.columns = cfg.clamp(value, 1, cfg.MAX_COLUMNS); normalize_cells(config) end
  changed, value = ImGui.InputInt(ctx, "Spacing", config.spacing)
  if changed then config.spacing = cfg.clamp(value, 0, 32) end
  changed, value = ImGui.InputInt(ctx, "Font size", config.font_size)
  if changed then config.font_size = cfg.clamp(value, 10, 36) end
  changed, value = ImGui.Checkbox(ctx, "Minimal GUI", config.minimal_gui)
  if changed then
    config.minimal_gui = value
  end
  changed, value = ImGui.Checkbox(ctx, "Show presets", config.show_presets)
  if changed then config.show_presets = value end
  changed, value = ImGui.Checkbox(
    ctx,
    "Listen for MIDI Program Change",
    config.listen_midi_program_change
  )
  if changed then config.listen_midi_program_change = value end
  changed, value = ImGui.InputInt(ctx, "Refresh (ms)", config.refresh_ms)
  if changed then config.refresh_ms = cfg.clamp(value, cfg.MIN_REFRESH_MS, 2000) end
end

local function draw_settings_modal(config, active_project)
  local window_x, window_y = ImGui.GetWindowPos(ctx)
  local window_width, window_height = ImGui.GetWindowSize(ctx)
  local center_x = window_x + window_width * 0.5
  local center_y = window_y + window_height * 0.5
  ImGui.SetNextWindowPos(ctx, center_x, center_y, ImGui.Cond_Appearing, 0.5, 0.5)
  ImGui.SetNextWindowSize(ctx, 420, 0, ImGui.Cond_Appearing)
  local visible, open = ImGui.BeginPopupModal(
    ctx,
    "Settings",
    M.settings_open,
    ImGui.WindowFlags_AlwaysAutoResize
  )
  M.settings_open = open
  if visible then
    if not open then
      M.settings_draft = nil
      ImGui.CloseCurrentPopup(ctx)
    else
      if not M.settings_draft then
        M.settings_draft = copy_table(config)
      end
      local draft = M.settings_draft
      local font_pushed = push_configured_font(draft)
      draw_settings(draft)
      ImGui.Separator(ctx)
      if ImGui.Button(ctx, "OK") then
        if cfg.save_config(active_project, draft) then
          for key in pairs(config) do
            config[key] = nil
          end
          for key, value in pairs(draft) do
            config[key] = value
          end
          M.cell_text_layouts = {}
          M.settings_draft = nil
          M.settings_open = false
          ImGui.CloseCurrentPopup(ctx)
        end
      end
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, "Cancel") then
        M.settings_draft = nil
        M.settings_open = false
        ImGui.CloseCurrentPopup(ctx)
      end
      if font_pushed then
        ImGui.PopFont(ctx)
      end
    end
    ImGui.EndPopup(ctx)
  end
end

-- ---------------------------------------------------------------------------
-- Drawing: documentation modal
-- ---------------------------------------------------------------------------

local function draw_help_modal(is_open, parent_center_x, parent_center_y, config)
  ImGui.SetNextWindowPos(
    ctx,
    parent_center_x,
    parent_center_y,
    ImGui.Cond_Appearing,
    0.5,
    0.5
  )
  ImGui.SetNextWindowSize(ctx, 620, 560, ImGui.Cond_Appearing)
  local visible, open = ImGui.BeginPopupModal(
    ctx,
    "Documentation",
    is_open,
    ImGui.WindowFlags_None
  )
  if visible then
    local font_pushed = push_configured_font(config)
    ImGui.PushFont(ctx, bold_font, config.font_size)
    ImGui.TextColored(ctx, 0x70C878FF, "VISUAL PEDALBOARD")
    ImGui.PopFont(ctx)
    ImGui.PushFont(ctx, italic_font, config.font_size)
    ImGui.TextWrapped(
      ctx,
      "A quick guide to controlling your FX parameters from a grid."
    )
    ImGui.PopFont(ctx)
    ImGui.Separator(ctx)

    if ImGui.CollapsingHeader(
        ctx,
        "1. Quick start",
        nil,
        ImGui.TreeNodeFlags_DefaultOpen
      ) then
      ImGui.BulletText(ctx, "Click a cell to toggle its assigned parameter.")
      ImGui.BulletText(ctx, "Each click switches the parameter between its two endpoints: minimum and maximum.")
      ImGui.BulletText(ctx, "The FX name and current state are shown inside the cell.")
      ImGui.TextColored(ctx, cfg.COLORS.active, "ACTIVE")
      ImGui.SameLine(ctx)
      ImGui.TextWrapped(ctx, "The value is below its midpoint, unless you invert the state.")
      ImGui.TextColored(ctx, cfg.COLORS.bypassed, "BYPASSED")
      ImGui.SameLine(ctx)
      ImGui.TextWrapped(ctx, "The value is at or above its midpoint, unless you invert the state.")
      ImGui.TextWrapped(
        ctx,
        "These labels describe the assigned parameter's value. To toggle an FX's actual bypass, assign its bypass control."
      )
    end

    if ImGui.CollapsingHeader(ctx, "2. Assign a cell") then
      ImGui.BulletText(ctx, "Right-click the cell you want to configure.")
      ImGui.BulletText(ctx, "Choose a track (including Master), an FX, and a parameter.")
      ImGui.BulletText(ctx, "Give the cell a short name that makes its purpose easy to recognize while mixing or performing.")
      ImGui.BulletText(ctx, "Click Save cell changes to save the assignment.")
      ImGui.TextWrapped(
        ctx,
        "For switch-like behavior, choose a parameter with two clear states, such as an on/off control. Clicking the cell sets it to minimum or maximum; a continuous control may jump between those endpoints."
      )
    end

    if ImGui.CollapsingHeader(ctx, "3. Customize and edit") then
      ImGui.BulletText(ctx, "Label changes the text shown on the cell.")
      ImGui.BulletText(ctx, "Active RGB and Bypassed RGB set the colors for each state; Default restores the original color.")
      ImGui.BulletText(ctx, "Invert parameter state reverses which endpoint is shown as active or bypassed.")
      ImGui.BulletText(ctx, "Tooltip adds a note shown when you hover over the cell.")
      ImGui.BulletText(ctx, "Reset selected cell clears its settings. Click Save cell changes to save the reset.")
    end

    if ImGui.CollapsingHeader(ctx, "4. Use presets") then
      ImGui.BulletText(ctx, "The Presets row contains eight slots below the pedalboard.")
      ImGui.BulletText(ctx, "Right-click a slot to configure it with an optional name; replacing an existing preset requires confirmation. Use Reset preset to clear a saved preset.")
      ImGui.BulletText(ctx, "Locked presets cannot be edited or cleared. Unchecking Locked asks you to confirm before unlocking.")
      ImGui.BulletText(ctx, "Left-click a saved slot to restore those states using the current pedal assignments. Empty slots do nothing.")
      ImGui.BulletText(ctx, "Enable Listen for MIDI Program Change in Settings to use MIDI on channel 1 to select presets: values 0-7 load slots 1-8. MIDI input must also be enabled in REAPER.")
      ImGui.BulletText(ctx, "Save plugins state lets you choose which unique referenced FX states to store without replacing other FX on their tracks.")
    end

    if ImGui.CollapsingHeader(ctx, "5. Adjust the pedalboard") then
      ImGui.BulletText(ctx, "Open Settings from the menu bar.")
      ImGui.BulletText(ctx, "Rows and Columns set the grid size (from 1 to 8).")
      ImGui.BulletText(ctx, "Spacing adjusts the gap between cells; Font size changes the text size.")
      ImGui.BulletText(ctx, "Minimal GUI uses native button labels instead of custom multi-line text drawing.")
      ImGui.BulletText(ctx, "Show presets controls whether the Presets row is displayed.")
      ImGui.BulletText(ctx, "Listen for MIDI Program Change enables or disables MIDI preset selection.")
      ImGui.BulletText(ctx, "Refresh (ms) sets how often assigned FX states are read.")
      ImGui.BulletText(ctx, "Settings changes are a draft: OK saves them to this project, while Cancel discards them. Save the project to store them in its RPP file.")
      ImGui.BulletText(ctx, "Use File > Import configuration or Export configuration to exchange settings as JSON.")
      ImGui.BulletText(ctx, "Use File > Reset to restore the default configuration for this project.")
    end

    if ImGui.CollapsingHeader(ctx, "6. Status and troubleshooting") then
      ImGui.TextColored(ctx, cfg.COLORS.unassigned, "UNASSIGNED")
      ImGui.SameLine(ctx)
      ImGui.TextWrapped(ctx, "No track has been assigned to this cell yet.")
      ImGui.TextColored(ctx, cfg.COLORS.invalid, "INVALID TRACK / INVALID FX")
      ImGui.SameLine(ctx)
      ImGui.TextWrapped(ctx, "The track or FX is no longer available; select it again in the cell configuration.")
      ImGui.TextColored(ctx, cfg.COLORS.unsupported, "SELECT PARAMETER / INVALID PARAMETER")
      ImGui.SameLine(ctx)
      ImGui.TextWrapped(ctx, "Select a valid parameter for this FX.")
      ImGui.TextColored(ctx, cfg.COLORS.unsupported, "PARAMETER API UNAVAILABLE")
      ImGui.SameLine(ctx)
      ImGui.TextWrapped(ctx, "This FX or REAPER version does not allow the pedalboard to read or change the parameter.")
    end
    ImGui.Separator(ctx)
    if ImGui.Button(ctx, "Close") then
      ImGui.CloseCurrentPopup(ctx)
      open = false
    end
    if font_pushed then
      ImGui.PopFont(ctx)
    end
    ImGui.EndPopup(ctx)
  end
  return open
end

-- ---------------------------------------------------------------------------
-- Drawing: generic info modal
-- ---------------------------------------------------------------------------

local function draw_info_modal(
  title,
  message,
  is_open,
  width,
  height,
  flags,
  parent_center_x,
  parent_center_y,
  config
)
  ImGui.SetNextWindowPos(
    ctx,
    parent_center_x,
    parent_center_y,
    ImGui.Cond_Appearing,
    0.5,
    0.5
  )
  ImGui.SetNextWindowSize(ctx, width, height, ImGui.Cond_Appearing)
  local visible, open = ImGui.BeginPopupModal(
    ctx,
    title,
    is_open,
    flags
  )
  if visible then
    local font_pushed = push_configured_font(config)
    ImGui.TextWrapped(ctx, message)
    ImGui.Separator(ctx)
    if ImGui.Button(ctx, "Close") then
      ImGui.CloseCurrentPopup(ctx)
      open = false
    end
    if font_pushed then
      ImGui.PopFont(ctx)
    end
    ImGui.EndPopup(ctx)
  end
  return open
end

-- ---------------------------------------------------------------------------
-- Main window
-- ---------------------------------------------------------------------------

function M.draw_window(config, active_project, states,
                       debug_mode, debug_pause_state_reads, debug_pause_grid,
                       debug_metrics,
                       refresh_states_fn,
                       on_toggle_debug, on_toggle_pause_reads, on_toggle_pause_grid,
                       on_import, on_export, on_reset)
  if M.first_frame then
    ImGui.SetNextWindowSize(ctx, 640, 460, ImGui.Cond_FirstUseEver)
    if config.restore_dock and config.dock_id > 0 and ImGui.SetNextWindowDockID then
      ImGui.SetNextWindowDockID(ctx, config.dock_id, ImGui.Cond_FirstUseEver)
    end
    M.first_frame = false
  end
  if M.apply_configured_dock then
    if config.restore_dock and config.dock_id > 0 and ImGui.SetNextWindowDockID then
      ImGui.SetNextWindowDockID(ctx, config.dock_id, ImGui.Cond_Always)
    end
    M.apply_configured_dock = false
  end

  local visible, open = ImGui.Begin(
    ctx,
    cfg.SCRIPT_NAME,
    true,
    ImGui.WindowFlags_MenuBar
  )
  M.window_open = open
  if not visible then
    return
  end

  local window_x, window_y = ImGui.GetWindowPos(ctx)
  local window_width, window_height = ImGui.GetWindowSize(ctx)
  if debug_mode and debug_metrics then
    debug_metrics.window_width = window_width
    debug_metrics.window_height = window_height
    debug_metrics.content_width, debug_metrics.content_height =
        ImGui.GetContentRegionAvail(ctx)
  end
  local parent_center_x = window_x + window_width * 0.5
  local parent_center_y = window_y + window_height * 0.5
  if ImGui.BeginMenuBar(ctx) then
    if ImGui.BeginMenu(ctx, "File") then
      if ImGui.MenuItem(ctx, "Import configuration") then
        local new_config = on_import()
        if new_config then
          config = new_config
        end
      end
      if ImGui.MenuItem(ctx, "Export configuration") then
        on_export()
      end
      ImGui.Separator(ctx)
      if ImGui.MenuItem(ctx, "Reset") then
        local new_config = on_reset()
        if new_config then
          config = new_config
        end
      end
      ImGui.EndMenu(ctx)
    end
    if ImGui.MenuItem(ctx, "Settings") then
      M.settings_open = true
      M.settings_draft = copy_table(config)
      M.request_settings = true
    end
    if ImGui.BeginMenu(ctx, "Help") then
      if ImGui.MenuItem(ctx, "Documentation") then
        M.help_open = true
        M.request_help = true
      end
      if ImGui.MenuItem(ctx, "Debug mode", nil, debug_mode) then
        on_toggle_debug()
      end
      if ImGui.BeginMenu(ctx, "Isolation tests", debug_mode) then
        if ImGui.MenuItem(
            ctx,
            "Pause state reads",
            nil,
            debug_pause_state_reads,
            debug_mode
          ) then
          on_toggle_pause_reads()
        end
        if ImGui.MenuItem(
            ctx,
            "Pause pedalboard grid",
            nil,
            debug_pause_grid,
            debug_mode
          ) then
          on_toggle_pause_grid()
        end
        ImGui.EndMenu(ctx)
      end
      ImGui.EndMenu(ctx)
    end
    if ImGui.MenuItem(ctx, "About...") then
      M.about_open = true
      M.request_about = true
    end
    ImGui.EndMenuBar(ctx)
  end
  if M.request_settings then
    ImGui.OpenPopup(ctx, "Settings")
    M.request_settings = false
  end
  if M.request_help then
    ImGui.OpenPopup(ctx, "Documentation")
    M.request_help = false
  end
  if M.request_about then
    ImGui.OpenPopup(ctx, "About")
    M.request_about = false
  end

  local display_config = M.settings_draft or config
  local font_pushed = push_configured_font(display_config)
  local needs_refresh = false
  if not debug_mode or not debug_pause_grid then
    draw_grid(display_config, states, debug_mode, debug_pause_state_reads, refresh_states_fn)
    if display_config.show_presets then
      draw_presets(
        display_config,
        config,
        active_project,
        states,
        refresh_states_fn
      )
    end
  end
  if draw_cell_configuration_modal(config, active_project) then
    needs_refresh = true
  end
  draw_preset_modal(config, active_project)
  if font_pushed then
    ImGui.PopFont(ctx)
  end
  M.help_open = draw_help_modal(
    M.help_open,
    parent_center_x,
    parent_center_y,
    config
  )
  M.about_open = draw_info_modal(
    "About",
    "Made by rdibiasky",
    M.about_open,
    400,
    150,
    ImGui.WindowFlags_NoResize,
    parent_center_x,
    parent_center_y,
    config
  )
  draw_settings_modal(config, active_project)
  ImGui.End(ctx)
  return needs_refresh
end

return M
