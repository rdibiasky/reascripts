-- @description Visual Pedalboard - live FX control surface
-- @version 1.0.0
-- @author rdibiasky
-- @about
--   A configurable REAPER FX pedalboard. Configuration is stored in the
--   project and FX indices in the editor are one-based.

local SCRIPT_NAME = "Visual Pedalboard"
local EXT_SECTION = "VisualPedalboard"
local EXT_KEY = "configuration"
local CONFIG_VERSION = 1
local MAX_ROWS = 8
local MAX_COLUMNS = 8
local MAX_CELLS = MAX_ROWS * MAX_COLUMNS
local MIN_REFRESH_MS = 30
local PROJECT_LIST_REFRESH_SECONDS = 1
local DEBUG_REPORT_SECONDS = 5

package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua'
local ImGui = require 'imgui' '0.10'

if not ImGui.CreateContext then
  reaper.ShowMessageBox(
    "ReaImGui is required. Install it from ReaPack, then run this script again.",
    SCRIPT_NAME,
    0
  )
  return
end

local function new_cell(index)
  return {
    label = "Cell " .. index,
    track_guid = "",
    fx_guid = "",
    param_index = -1,
    param_ident = "",
    invert_state = false,
    active_color = "",
    bypass_color = "",
    tooltip = "",
  }
end

local function default_config()
  local config = {
    rows = 2,
    columns = 4,
    spacing = 8,
    font_size = 16,
    minimal_gui = false,
    refresh_ms = 100,
    dock_id = 0,
    restore_dock = false,
    cells = {},
  }
  for index = 1, config.rows * config.columns do
    config.cells[index] = new_cell(index)
  end
  return config
end

local config = default_config()
local active_project, active_project_file
local active_project_change_count
local last_refresh, states
local cached_tracks, cached_fx_indices = {}, {}
local cached_track_retry_times, cached_fx_retry_times = {}, {}
local project_serialized
local save_config
local load_config

local function clear_assignment_caches()
  cached_tracks = {}
  cached_fx_indices = {}
  cached_track_retry_times = {}
  cached_fx_retry_times = {}
end

local function clamp(value, minimum, maximum)
  return math.max(minimum, math.min(maximum, value))
end

active_project, active_project_file = reaper.EnumProjects(-1)
active_project = active_project or 0
active_project_file = active_project_file or ""
active_project_change_count = reaper.GetProjectStateChangeCount
    and reaper.GetProjectStateChangeCount(active_project) or nil
project_serialized = select(2, reaper.GetProjExtState(
  active_project,
  EXT_SECTION,
  EXT_KEY
))
local apply_configured_dock = false

local function all_tracks()
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

local function resolve_track(guid)
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

local function find_fx_index(track, fx_guid)
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

local function clean_fx_name(name)
  name = name:gsub("^[^:]+:%s*", "")
  name = name:gsub("%s*%([^()]*%)%s*$", "")
  return name
end

local function inspect_cell(cell, track, fx_index)
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
  fx_name = clean_fx_name(fx_name)
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

local function color_from_hex(value)
  if not value or value == "" then
    return nil
  end
  local hex = value:gsub("^#", ""):upper()
  if not hex:match("^%x%x%x%x%x%x$") then
    return nil
  end
  local red = tonumber(hex:sub(1, 2), 16)
  local green = tonumber(hex:sub(3, 4), 16)
  local blue = tonumber(hex:sub(5, 6), 16)
  return tonumber(string.format("%02X%02X%02XFF", red, green, blue), 16)
end

local COLORS = {
  active = 0x4B9441FF,
  bypassed = 0xC83C3CFF,
  unsupported = 0x666666FF,
  invalid = 0x666666FF,
  unassigned = 0x555555FF,
  pressed = 0x777777FF,
}

local function color_for_editor(value, default_color)
  return (color_from_hex(value) or default_color) >> 8
end

local ctx
local track_entries = {}
local fx_entries_by_track = {}
local param_entries_by_fx = {}

local function report_error(message)
  reaper.ShowConsoleMsg(SCRIPT_NAME .. ": " .. message .. "\n")
end

local function json_quote(value)
  return '"' .. value:gsub('[%z\1-\31\\"]', function(character)
    local escapes = {
      ['"'] = '\\"',
      ["\\"] = "\\\\",
      ["\b"] = "\\b",
      ["\f"] = "\\f",
      ["\n"] = "\\n",
      ["\r"] = "\\r",
      ["\t"] = "\\t",
    }
    return escapes[character] or string.format("\\u%04X", string.byte(character))
  end) .. '"'
end

local function serialize_json_config(source)
  local default = default_config()
  local settings = {}
  local function add_setting(key, value, default_value)
    if value ~= default_value then
      settings[#settings + 1] = json_quote(key) .. ":" .. tostring(value)
    end
  end
  add_setting("rows", source.rows, default.rows)
  add_setting("columns", source.columns, default.columns)
  add_setting("spacing", source.spacing, default.spacing)
  add_setting("font_size", source.font_size, default.font_size)
  add_setting("minimal_gui", source.minimal_gui, default.minimal_gui)
  add_setting("refresh_ms", source.refresh_ms, default.refresh_ms)
  add_setting("dock_id", source.dock_id, default.dock_id)
  add_setting("restore_dock", source.restore_dock, default.restore_dock)

  local last_cell = 0
  for index, cell in ipairs(source.cells) do
    local cell_default = new_cell(index)
    if (cell.label ~= "" and cell.label ~= cell_default.label)
        or (cell.track_guid ~= "" and cell.track_guid ~= cell_default.track_guid)
        or (cell.fx_guid ~= "" and cell.fx_guid ~= cell_default.fx_guid)
        or cell.param_index ~= cell_default.param_index
        or (cell.param_ident ~= "" and cell.param_ident ~= cell_default.param_ident)
        or cell.invert_state ~= cell_default.invert_state
        or (cell.active_color ~= "" and cell.active_color ~= cell_default.active_color)
        or (cell.bypass_color ~= "" and cell.bypass_color ~= cell_default.bypass_color)
        or (cell.tooltip ~= "" and cell.tooltip ~= cell_default.tooltip) then
      last_cell = index
    end
  end

  local fields = {
    '"format":"Visual Pedalboard"',
    '"version":' .. CONFIG_VERSION,
  }
  if #settings > 0 then
    fields[#fields + 1] = '"settings":{' .. table.concat(settings, ",") .. '}'
  end
  if last_cell > 0 then
    local cells = {}
    for index = 1, last_cell do
      local cell = source.cells[index]
      local cell_default = new_cell(index)
      local cell_fields = {}
      local function add_cell_field(key, value, default_value, is_string)
        if value ~= default_value and (not is_string or value ~= "") then
          cell_fields[#cell_fields + 1] = json_quote(key) .. ":"
            .. (is_string and json_quote(value) or tostring(value))
        end
      end
      add_cell_field("label", cell.label, cell_default.label, true)
      add_cell_field("track_guid", cell.track_guid, cell_default.track_guid, true)
      add_cell_field("fx_guid", cell.fx_guid, cell_default.fx_guid, true)
      add_cell_field("param_index", cell.param_index, cell_default.param_index)
      add_cell_field("param_ident", cell.param_ident, cell_default.param_ident, true)
      add_cell_field("invert_state", cell.invert_state, cell_default.invert_state)
      add_cell_field("active_color", cell.active_color, cell_default.active_color, true)
      add_cell_field("bypass_color", cell.bypass_color, cell_default.bypass_color, true)
      add_cell_field("tooltip", cell.tooltip, cell_default.tooltip, true)
      cells[index] = "{" .. table.concat(cell_fields, ",") .. "}"
    end
    fields[#fields + 1] = '"cells":[' .. table.concat(cells, ",") .. ']'
  end
  return "{" .. table.concat(fields, ",") .. "}"
end

local function decode_json(text)
  local position = 1
  local array_metatable = { __json_array = true }
  local json_null = {}

  local function skip_whitespace()
    while text:sub(position, position):match("%s") do
      position = position + 1
    end
  end

  local function parse_string()
    if text:sub(position, position) ~= '"' then
      error("expected a JSON string")
    end
    position = position + 1
    local result = {}
    local start = position
    while position <= #text do
      local byte = text:byte(position)
      if byte == 34 then
        result[#result + 1] = text:sub(start, position - 1)
        position = position + 1
        return table.concat(result)
      elseif byte == 92 then
        result[#result + 1] = text:sub(start, position - 1)
        local escape = text:sub(position + 1, position + 1)
        local replacements = {
          ['"'] = '"',
          ["\\"] = "\\",
          ["/"] = "/",
          b = "\b",
          f = "\f",
          n = "\n",
          r = "\r",
          t = "\t",
        }
        if replacements[escape] then
          result[#result + 1] = replacements[escape]
          position = position + 2
        elseif escape == "u" then
          local hex = text:sub(position + 2, position + 5)
          local codepoint = tonumber(hex, 16)
          if #hex ~= 4 or not codepoint then
            error("invalid Unicode escape")
          end
          position = position + 6
          if codepoint >= 0xD800 and codepoint <= 0xDBFF then
            if text:sub(position, position + 1) ~= "\\u" then
              error("invalid Unicode surrogate pair")
            end
            local low_hex = text:sub(position + 2, position + 5)
            local low = tonumber(low_hex, 16)
            if #low_hex ~= 4 or not low or low < 0xDC00 or low > 0xDFFF then
              error("invalid Unicode surrogate pair")
            end
            codepoint = 0x10000 + (codepoint - 0xD800) * 0x400 + low - 0xDC00
            position = position + 6
          elseif codepoint >= 0xDC00 and codepoint <= 0xDFFF then
            error("invalid Unicode surrogate pair")
          end
          if codepoint < 0x80 then
            result[#result + 1] = string.char(codepoint)
          elseif codepoint < 0x800 then
            result[#result + 1] = string.char(
              0xC0 + (codepoint >> 6),
              0x80 + (codepoint & 0x3F)
            )
          elseif codepoint < 0x10000 then
            result[#result + 1] = string.char(
              0xE0 + (codepoint >> 12),
              0x80 + ((codepoint >> 6) & 0x3F),
              0x80 + (codepoint & 0x3F)
            )
          else
            result[#result + 1] = string.char(
              0xF0 + (codepoint >> 18),
              0x80 + ((codepoint >> 12) & 0x3F),
              0x80 + ((codepoint >> 6) & 0x3F),
              0x80 + (codepoint & 0x3F)
            )
          end
          start = position
        else
          error("invalid JSON string escape")
        end
        start = position
      elseif byte < 32 then
        error("unescaped control character in JSON string")
      else
        position = position + 1
      end
    end
    error("unterminated JSON string")
  end

  local function parse_number()
    local start = position
    if text:sub(position, position) == "-" then
      position = position + 1
    end
    if text:sub(position, position) == "0" then
      position = position + 1
      if text:sub(position, position):match("%d") then
        error("invalid JSON number")
      end
    elseif text:sub(position, position):match("[1-9]") then
      repeat
        position = position + 1
      until not text:sub(position, position):match("%d")
    else
      error("invalid JSON number")
    end

    if text:sub(position, position) == "." then
      position = position + 1
      if not text:sub(position, position):match("%d") then
        error("invalid JSON number")
      end
      repeat
        position = position + 1
      until not text:sub(position, position):match("%d")
    end
    if text:sub(position, position):match("[eE]") then
      position = position + 1
      if text:sub(position, position):match("[+-]") then
        position = position + 1
      end
      if not text:sub(position, position):match("%d") then
        error("invalid JSON number")
      end
      repeat
        position = position + 1
      until not text:sub(position, position):match("%d")
    end
    local number = tonumber(text:sub(start, position - 1))
    if not number then
      error("invalid JSON number")
    end
    return number
  end

  local parse_value
  parse_value = function()
    skip_whitespace()
    local character = text:sub(position, position)
    if character == '"' then
      return parse_string()
    elseif character == "{" then
      position = position + 1
      skip_whitespace()
      local object = {}
      if text:sub(position, position) == "}" then
        position = position + 1
        return object
      end
      while true do
        skip_whitespace()
        local key = parse_string()
        skip_whitespace()
        if text:sub(position, position) ~= ":" then
          error("expected ':' after a JSON object key")
        end
        position = position + 1
        if object[key] ~= nil then
          error("duplicate JSON object key")
        end
        object[key] = parse_value()
        skip_whitespace()
        local delimiter = text:sub(position, position)
        if delimiter == "}" then
          position = position + 1
          return object
        elseif delimiter ~= "," then
          error("expected ',' or '}' in JSON object")
        end
        position = position + 1
      end
    elseif character == "[" then
      position = position + 1
      skip_whitespace()
      local array = setmetatable({}, array_metatable)
      if text:sub(position, position) == "]" then
        position = position + 1
        return array
      end
      while true do
        array[#array + 1] = parse_value()
        skip_whitespace()
        local delimiter = text:sub(position, position)
        if delimiter == "]" then
          position = position + 1
          return array
        elseif delimiter ~= "," then
          error("expected ',' or ']' in JSON array")
        end
        position = position + 1
      end
    elseif text:sub(position, position + 3) == "true" then
      position = position + 4
      return true
    elseif text:sub(position, position + 4) == "false" then
      position = position + 5
      return false
    elseif text:sub(position, position + 3) == "null" then
      position = position + 4
      return json_null
    elseif character == "-" or character:match("%d") then
      return parse_number()
    end
    error("unexpected value in JSON")
  end

  local value = parse_value()
  skip_whitespace()
  if position <= #text then
    error("unexpected content after JSON value")
  end
  return value, array_metatable, json_null
end

local function config_from_json(text)
  local ok, decoded, array_metatable, json_null = pcall(decode_json, text)
  if not ok then
    return nil, "Invalid JSON: " .. tostring(decoded)
  end
  if type(decoded) ~= "table"
      or decoded == json_null
      or decoded.format ~= "Visual Pedalboard"
      or decoded.version ~= CONFIG_VERSION then
    return nil, "Unsupported configuration JSON format or version."
  end

  local settings = decoded.settings
  if settings ~= nil
      and (type(settings) ~= "table"
        or settings == json_null
        or getmetatable(settings) == array_metatable) then
    return nil, "Configuration JSON has invalid settings data."
  end
  local cells = decoded.cells
  if cells ~= nil
      and (type(cells) ~= "table"
        or cells == json_null
        or getmetatable(cells) ~= array_metatable
        or #cells > MAX_CELLS) then
    return nil, "Configuration JSON has invalid cell data."
  end

  local function is_integer(value)
    return type(value) == "number"
      and value == value
      and value ~= math.huge
      and value ~= -math.huge
      and value % 1 == 0
  end
  local integer_fields = {
    "rows", "columns", "spacing", "font_size", "refresh_ms", "dock_id",
  }
  local setting_ranges = {
    rows = { 1, MAX_ROWS },
    columns = { 1, MAX_COLUMNS },
    spacing = { 0, 32 },
    font_size = { 10, 36 },
    refresh_ms = { MIN_REFRESH_MS, 2000 },
    dock_id = { 0, 2147483647 },
  }
  local imported = default_config()
  for _, field in ipairs(integer_fields) do
    local value = settings and settings[field]
    if value ~= nil then
      if not is_integer(value) then
        return nil, "Configuration setting '" .. field .. "' must be an integer."
      end
      local range = setting_ranges[field]
      if value < range[1] or value > range[2] then
        return nil, "Configuration setting '" .. field .. "' is outside the supported range."
      end
      imported[field] = value
    end
  end
  local restore_dock = settings and settings.restore_dock
  if restore_dock ~= nil then
    if type(restore_dock) ~= "boolean" then
      return nil, "Configuration setting 'restore_dock' must be a boolean."
    end
    imported.restore_dock = restore_dock
  end
  local minimal_gui = settings and settings.minimal_gui
  if minimal_gui ~= nil then
    if type(minimal_gui) ~= "boolean" then
      return nil, "Configuration setting 'minimal_gui' must be a boolean."
    end
    imported.minimal_gui = minimal_gui
  end

  for index, cell in ipairs(cells or {}) do
    if type(cell) ~= "table"
        or cell == json_null
        or getmetatable(cell) == array_metatable then
      return nil, "Configuration cell " .. index .. " is invalid."
    end
    local imported_cell = imported.cells[index] or new_cell(index)
    local string_fields = {
      "label", "track_guid", "fx_guid", "param_ident",
      "active_color", "bypass_color", "tooltip",
    }
    for _, field in ipairs(string_fields) do
      local value = cell[field]
      if value ~= nil then
        if type(value) ~= "string" then
          return nil, "Configuration cell " .. index .. " has an invalid '" .. field .. "' value."
        end
        imported_cell[field] = value
      end
    end
    if cell.param_index ~= nil then
      if not is_integer(cell.param_index) or cell.param_index < -1 then
        return nil, "Configuration cell " .. index .. " has invalid parameter settings."
      end
      imported_cell.param_index = cell.param_index
    end
    if cell.invert_state ~= nil then
      if type(cell.invert_state) ~= "boolean" then
        return nil, "Configuration cell " .. index .. " has invalid parameter settings."
      end
      imported_cell.invert_state = cell.invert_state
    end
    local active_color = imported_cell.active_color:gsub("^#", ""):upper()
    local bypass_color = imported_cell.bypass_color:gsub("^#", ""):upper()
    if (active_color ~= "" and not active_color:match("^%x%x%x%x%x%x$"))
        or (bypass_color ~= "" and not bypass_color:match("^%x%x%x%x%x%x$")) then
      return nil, "Configuration cell " .. index .. " has an invalid RGB color."
    end
    imported_cell.active_color = active_color
    imported_cell.bypass_color = bypass_color
    imported.cells[index] = imported_cell
  end
  for index = 1, imported.rows * imported.columns do
    if not imported.cells[index] then
      imported.cells[index] = new_cell(index)
    end
  end
  return imported
end

load_config = function(serialized)
  if not serialized or serialized == "" then
    return default_config()
  end
  local loaded, load_error = config_from_json(serialized)
  if not loaded then
    reaper.ShowConsoleMsg(
      SCRIPT_NAME .. ": saved project configuration is invalid or unsupported; using defaults. "
        .. tostring(load_error) .. "\n"
    )
    return default_config()
  end
  return loaded
end

config = load_config(project_serialized)

save_config = function()
  local bytes = reaper.SetProjExtState(
    active_project,
    EXT_SECTION,
    EXT_KEY,
    serialize_json_config(config)
  )
  if not bytes or bytes <= 0 then
    reaper.ShowConsoleMsg(SCRIPT_NAME .. ": could not save configuration to the current project.\n")
    return false
  end
  reaper.MarkProjectDirty(active_project)
  return true
end

local function append_json_extension(path)
  if not path:lower():match("%.json$") then
    return path .. ".json"
  end
  return path
end

local function export_configuration()
  local path
  if reaper.JS_Dialog_BrowseForSaveFile then
    local result
    result, path = reaper.JS_Dialog_BrowseForSaveFile(
      "Export Visual Pedalboard configuration",
      "",
      "Visual Pedalboard.json",
      "JSON files (*.json)\0*.json\0All files\0*.*\0"
    )
    if result < 0 then
      report_error("Could not open the configuration export dialog.")
      return
    elseif result == 0 then
      return
    end
  else
    local confirmed
    confirmed, path = reaper.GetUserInputs(
      "Export Visual Pedalboard configuration",
      1,
      "JSON file path",
      "Visual Pedalboard.json"
    )
    if not confirmed then
      return
    end
  end
  path = append_json_extension(path)
  local file, open_error = io.open(path, "wb")
  if not file then
    report_error("Could not create JSON file: " .. tostring(open_error))
    return
  end
  local written, write_error = file:write(serialize_json_config(config), "\n")
  local closed, close_error = file:close()
  if not written then
    report_error("Could not write JSON file: " .. tostring(write_error))
  elseif not closed then
    report_error("Could not close JSON file: " .. tostring(close_error))
  else
    reaper.ShowConsoleMsg(SCRIPT_NAME .. ": configuration exported to " .. path .. "\n")
  end
end

local function import_configuration()
  local selected, path = reaper.GetUserFileNameForRead(
    "",
    "Import Visual Pedalboard configuration",
    "json"
  )
  if not selected then
    return
  end
  local file, open_error = io.open(path, "rb")
  if not file then
    report_error("Could not open configuration file: " .. tostring(open_error))
    return
  end
  local contents, read_error = file:read("*a")
  local closed, close_error = file:close()
  if not contents then
    report_error("Could not read configuration file: " .. tostring(read_error))
    return
  elseif not closed then
    report_error("Could not close configuration file: " .. tostring(close_error))
    return
  end
  local imported, import_error = config_from_json(contents)
  if not imported then
    report_error(import_error)
    return
  end
  local previous_config = config
  config = imported
  if not save_config() then
    config = previous_config
    return
  end
  states = {}
  last_refresh = 0
  clear_assignment_caches()
  apply_configured_dock = true
  reaper.ShowConsoleMsg(SCRIPT_NAME .. ": configuration imported from " .. path .. "\n")
end

---@class CellDraft
---@field label string
---@field track_guid string
---@field fx_guid string
---@field param_index integer
---@field param_ident string
---@field invert_state boolean
---@field active_color string
---@field bypass_color string
---@field tooltip string

local function push_cell_colors(cell, state)
  local color = COLORS[state]
  if state == "active" then
    color = color_from_hex(cell.active_color) or color
  elseif state == "bypassed" then
    color = color_from_hex(cell.bypass_color) or color
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
    report_error("Could not change the selected FX parameter.")
    return
  end
  reaper.UpdateArrange()
end

local function normalize_cells()
  for index = 1, config.rows * config.columns do
    if not config.cells[index] then
      config.cells[index] = new_cell(index)
    end
  end
end

ctx = ImGui.CreateContext(SCRIPT_NAME)
local bold_font = ImGui.CreateFont("sans-serif", ImGui.FontFlags_Bold)
local italic_font = ImGui.CreateFont("sans-serif", ImGui.FontFlags_Italic)
ImGui.Attach(ctx, bold_font)
ImGui.Attach(ctx, italic_font)
local selected_index = 1
local draft_index = nil
---@type CellDraft|nil
local draft = nil
local track_filter = ""
last_refresh = 0
states = {}
local cell_text_layouts = {}
local project_lists_dirty = false
local last_project_list_refresh = 0
local refresh_states
local debug_mode = false
local debug_metrics
local debug_pause_state_reads = false
local debug_pause_grid = false
local window_open = true
local first_frame = true
local open_cell_configuration = false
local request_cell_configuration = false
local settings_open = true
local request_settings = false
local help_open = true
local request_help = false
local about_open = true
local request_about = false
local main_window_dock_id = 0

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
    EXT_SECTION,
    EXT_KEY
  )
  config = load_config(current_serialized)
  last_refresh = 0
  clear_assignment_caches()
  states = {}
  project_lists_dirty = true
  last_project_list_refresh = 0
  selected_index = 1
  draft = nil
  draft_index = nil
  open_cell_configuration = false
  request_cell_configuration = false
  apply_configured_dock = true
end

local function reset_debug_metrics()
  debug_metrics = {
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

local function load_draft(index)
  selected_index = index
  local source = config.cells[index] or new_cell(index)
  draft = {
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
  draft_index = index
end

local function find_selected_fx()
  if not draft then
    return nil
  end
  for _, entry in ipairs(fx_entries_by_track[draft.track_guid] or {}) do
    if entry.guid == draft.fx_guid then
      return entry
    end
  end
  return nil
end

local function draw_fx_selector()
  if not draft then
    return
  end
  local entries = fx_entries_by_track[draft.track_guid] or {}
  local preview = "— Select FX —"
  for _, entry in ipairs(entries) do
    if entry.guid == draft.fx_guid then
      preview = entry.name
      break
    end
  end
  if draft.fx_guid ~= "" and preview == "— Select FX —" then
    preview = "Missing FX"
  end

  if ImGui.BeginCombo(ctx, "FX", preview) then
    if ImGui.Selectable(ctx, "— Select FX —", draft.fx_guid == "") then
      draft.fx_guid = ""
      draft.param_index = -1
      draft.param_ident = ""
    end
    for _, entry in ipairs(entries) do
      local label = entry.name .. "##" .. entry.guid
      if ImGui.Selectable(ctx, label, entry.guid == draft.fx_guid) then
        if draft.fx_guid ~= entry.guid then
          draft.param_index = -1
          draft.param_ident = ""
        end
        draft.fx_guid = entry.guid
      end
    end
    ImGui.EndCombo(ctx)
  end
end

local function draw_param_selector()
  if not draft then
    return
  end
  local fx_entry = find_selected_fx()
  if not fx_entry then
    ImGui.Text(ctx, "Select an FX to list its parameters.")
    return
  end
  local params = param_entries_by_fx[fx_entry.guid]
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
    param_entries_by_fx[fx_entry.guid] = params
  end
  local preview = "— Select parameter —"
  for _, entry in ipairs(params) do
    local selected = draft.param_ident ~= "" and entry.ident == draft.param_ident
      or draft.param_ident == "" and entry.index == draft.param_index
    if selected then
      preview = entry.label
      break
    end
  end
  if draft.param_index >= 0 and preview == "— Select parameter —" then
    preview = "Missing parameter"
  end

  if ImGui.BeginCombo(ctx, "Parameter", preview) then
    if ImGui.Selectable(ctx, "— Select parameter —", draft.param_index < 0) then
      draft.param_index = -1
      draft.param_ident = ""
    end
    for _, entry in ipairs(params) do
      local selected = draft.param_ident ~= "" and entry.ident == draft.param_ident
        or draft.param_ident == "" and entry.index == draft.param_index
      if ImGui.Selectable(ctx, entry.label .. "##" .. entry.index, selected) then
        draft.param_index = entry.index
        draft.param_ident = entry.ident
      end
    end
    ImGui.EndCombo(ctx)
  end
end

local function draw_track_selector()
  if not draft then
    return
  end
  local preview = "— Unassigned —"
  for _, entry in ipairs(track_entries) do
    if entry.guid == draft.track_guid then
      preview = entry.name
      break
    end
  end
  if draft.track_guid ~= "" and preview == "— Unassigned —" then
    preview = "Missing track"
  end

  if ImGui.BeginCombo(ctx, "Track", preview) then
    if ImGui.Selectable(ctx, "— Unassigned —", draft.track_guid == "") then
      draft.track_guid = ""
      draft.fx_guid = ""
      draft.param_index = -1
      draft.param_ident = ""
    end
    for _, entry in ipairs(track_entries) do
      if track_filter == "" or entry.name:lower():find(track_filter:lower(), 1, true) then
        local label = entry.name .. "##" .. entry.guid
        if ImGui.Selectable(ctx, label, entry.guid == draft.track_guid) then
          if draft.track_guid ~= entry.guid then
            draft.fx_guid = ""
            draft.param_index = -1
            draft.param_ident = ""
          end
          draft.track_guid = entry.guid
        end
      end
    end
    ImGui.EndCombo(ctx)
  end
end

local function save_cell_draft()
  if not draft or not draft_index then
    return
  end
  local active_color = draft.active_color:gsub("^#", ""):upper()
  local bypass_color = draft.bypass_color:gsub("^#", ""):upper()
  if active_color ~= "" and not color_from_hex(active_color) then
    report_error("Active color must be blank or a six-digit RGB value.")
    return
  end
  if bypass_color ~= "" and not color_from_hex(bypass_color) then
    report_error("Bypass color must be blank or a six-digit RGB value.")
    return
  end
  if draft.track_guid ~= "" then
    local track = resolve_track(draft.track_guid)
    local fx_index = track and find_fx_index(track, draft.fx_guid)
    if not track or not fx_index then
      report_error("Select a loaded FX on the selected track.")
      return
    end
    local param_index = draft.param_index
    if draft.param_ident ~= "" then
      if not reaper.TrackFX_GetParamFromIdent then
        report_error("This REAPER version cannot resolve the selected parameter.")
        return
      end
      param_index = reaper.TrackFX_GetParamFromIdent(track, fx_index, draft.param_ident)
    end
    if param_index < 0 or param_index >= reaper.TrackFX_GetNumParams(track, fx_index) then
      report_error("Select a valid parameter from the selected FX.")
      return
    end
  else
    draft.fx_guid = ""
    draft.param_index = -1
    draft.param_ident = ""
  end
  local cell = config.cells[draft_index]
  cell.label = draft.label ~= "" and draft.label or ("Cell " .. draft_index)
  cell.track_guid = draft.track_guid
  cell.fx_guid = draft.fx_guid
  cell.param_index = draft.param_index
  cell.param_ident = draft.param_ident
  cell.invert_state = draft.invert_state
  cell.active_color = active_color
  cell.bypass_color = bypass_color
  cell.tooltip = draft.tooltip
  save_config()
  clear_assignment_caches()
  last_refresh = 0
end

local function reset_selected_cell()
  draft = new_cell(selected_index)
  draft_index = selected_index
end

local function draw_grid()
  local spacing = config.spacing
  local available_width, available_height = ImGui.GetContentRegionAvail(ctx)
  local cell_width = math.max(
    1,
    (available_width - spacing * (config.columns - 1)) / config.columns
  )
  local cell_height = math.max(
    1,
    (available_height - spacing * (config.rows - 1)) / config.rows
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
          refresh_states()
          local current_state = states[index]
          toggle_cell(cell, current_state)
          refresh_states()
        end
      end
      if not config.minimal_gui then
        local fx_name = state.fx_name or ""
        local layout = cell_text_layouts[index]
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
          cell_text_layouts[index] = layout
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
        load_draft(index)
        open_cell_configuration = true
        request_cell_configuration = true
        project_lists_dirty = true
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

local function draw_cell_configuration()
  local selected_changed, next_index = ImGui.InputInt(ctx, "Selected cell", selected_index)
  if selected_changed then
    selected_index = clamp(next_index, 1, config.rows * config.columns)
    load_draft(selected_index)
  end
  selected_index = clamp(selected_index, 1, config.rows * config.columns)
  if draft_index ~= selected_index or not draft then
    load_draft(selected_index)
  end

  if not draft then
    return
  end

  local label_changed, label = ImGui.InputText(ctx, "Label", draft.label)
  if label_changed then draft.label = label end
  local filter_changed, filter = ImGui.InputText(ctx, "Search tracks", track_filter)
  if filter_changed then track_filter = filter end
  draw_track_selector()
  draw_fx_selector()
  draw_param_selector()
  local invert_changed, invert_state = ImGui.Checkbox(
    ctx,
    "Invert parameter state",
    draft.invert_state
  )
  if invert_changed then draft.invert_state = invert_state end
  local active_changed, active_color = ImGui.ColorEdit3(
    ctx,
    "Active RGB",
    color_for_editor(draft.active_color, COLORS.active)
  )
  if active_changed then
    draft.active_color = string.format("%06X", active_color & 0xFFFFFF)
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Default##active-color") then
    draft.active_color = ""
  end
  local bypass_changed, bypass_color = ImGui.ColorEdit3(
    ctx,
    "Bypassed RGB",
    color_for_editor(draft.bypass_color, COLORS.bypassed)
  )
  if bypass_changed then
    draft.bypass_color = string.format("%06X", bypass_color & 0xFFFFFF)
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Default##bypassed-color") then
    draft.bypass_color = ""
  end
  local tooltip_changed, tooltip = ImGui.InputText(ctx, "Tooltip", draft.tooltip)
  if tooltip_changed then draft.tooltip = tooltip end

  if ImGui.Button(ctx, "Save cell changes") then
    save_cell_draft()
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Reset selected cell") then
    reset_selected_cell()
  end
end

local function push_configured_font()
  ImGui.PushFont(ctx, nil, config.font_size)
  return true
end

local function draw_cell_configuration_modal()
  if request_cell_configuration then
    ImGui.OpenPopup(ctx, "Cell Configuration")
    request_cell_configuration = false
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
    open_cell_configuration,
    ImGui.WindowFlags_AlwaysAutoResize
  )
  open_cell_configuration = open
  if visible then
    local font_pushed = push_configured_font()
    draw_cell_configuration()
    ImGui.Separator(ctx)
    if ImGui.Button(ctx, "Close") then
      open_cell_configuration = false
      ImGui.CloseCurrentPopup(ctx)
    end
    if font_pushed then
      ImGui.PopFont(ctx)
    end
    ImGui.EndPopup(ctx)
  end
end

local function draw_settings()
  local changed, value = ImGui.InputInt(ctx, "Rows", config.rows)
  if changed then config.rows = clamp(value, 1, MAX_ROWS); normalize_cells() end
  changed, value = ImGui.InputInt(ctx, "Columns", config.columns)
  if changed then config.columns = clamp(value, 1, MAX_COLUMNS); normalize_cells() end
  changed, value = ImGui.InputInt(ctx, "Spacing", config.spacing)
  if changed then config.spacing = clamp(value, 0, 32) end
  changed, value = ImGui.InputInt(ctx, "Font size", config.font_size)
  if changed then config.font_size = clamp(value, 10, 36) end
  changed, value = ImGui.Checkbox(ctx, "Minimal GUI", config.minimal_gui)
  if changed then
    config.minimal_gui = value
    cell_text_layouts = {}
  end
  changed, value = ImGui.InputInt(ctx, "Refresh (ms)", config.refresh_ms)
  if changed then config.refresh_ms = clamp(value, MIN_REFRESH_MS, 2000) end

  if ImGui.Button(ctx, config.restore_dock and "Forget saved dock" or "Save current dock") then
    if config.restore_dock then
      config.dock_id = 0
      config.restore_dock = false
    else
      local get_dock_id = ImGui.GetWindowDockID
      if get_dock_id then
        config.dock_id = main_window_dock_id
        config.restore_dock = config.dock_id > 0
      else
        report_error("This ReaImGui version does not expose dock-location control.")
      end
    end
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Save configuration") then
    save_config()
  end
end

local function draw_settings_modal()
  local window_x, window_y = ImGui.GetWindowPos(ctx)
  local window_width, window_height = ImGui.GetWindowSize(ctx)
  local center_x = window_x + window_width * 0.5
  local center_y = window_y + window_height * 0.5
  ImGui.SetNextWindowPos(ctx, center_x, center_y, ImGui.Cond_Appearing, 0.5, 0.5)
  ImGui.SetNextWindowSize(ctx, 420, 0, ImGui.Cond_Appearing)
  local visible, open = ImGui.BeginPopupModal(
    ctx,
    "Settings",
    settings_open,
    ImGui.WindowFlags_AlwaysAutoResize
  )
  settings_open = open
  if visible then
    local font_pushed = push_configured_font()
    draw_settings()
    ImGui.Separator(ctx)
    if ImGui.Button(ctx, "Close") then
      ImGui.CloseCurrentPopup(ctx)
    end
    if font_pushed then
      ImGui.PopFont(ctx)
    end
    ImGui.EndPopup(ctx)
  end
end

local function draw_info_modal(
  title,
  message,
  is_open,
  width,
  height,
  flags,
  parent_center_x,
  parent_center_y
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
    local font_pushed = push_configured_font()
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

local function draw_help_modal(is_open, parent_center_x, parent_center_y)
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
    "Help",
    is_open,
    ImGui.WindowFlags_None
  )
  if visible then
    local font_pushed = push_configured_font()
    ImGui.PushFont(ctx, bold_font, config.font_size)
    ImGui.TextColored(ctx, 0x70C878FF, "VISUAL PEDALBOARD")
    ImGui.PopFont(ctx)
    ImGui.PushFont(ctx, italic_font, config.font_size)
    ImGui.TextWrapped(
      ctx,
      "A quick guide to controlling your FX parameters from a grid."
    )
    ImGui.PopFont(ctx)
    if ImGui.Button(ctx, "Close help") then
      ImGui.CloseCurrentPopup(ctx)
      open = false
    end
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
      ImGui.TextColored(ctx, COLORS.active, "ACTIVE")
      ImGui.SameLine(ctx)
      ImGui.TextWrapped(ctx, "The value is below its midpoint, unless you invert the state.")
      ImGui.TextColored(ctx, COLORS.bypassed, "BYPASSED")
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

    if ImGui.CollapsingHeader(ctx, "4. Adjust the pedalboard") then
      ImGui.BulletText(ctx, "Open Settings from the menu bar.")
      ImGui.BulletText(ctx, "Rows and Columns set the grid size (from 1 to 8).")
      ImGui.BulletText(ctx, "Spacing adjusts the gap between cells; Font size changes the text size.")
      ImGui.BulletText(ctx, "Minimal GUI uses native button labels instead of custom multi-line text drawing.")
      ImGui.BulletText(ctx, "Refresh (ms) sets how often assigned FX states are read.")
      ImGui.BulletText(ctx, "Save configuration stores your settings in this project. The script also saves when closed or when you switch projects; save the project to store them in its RPP file.")
      ImGui.BulletText(ctx, "Use File > Import configuration or Export configuration to exchange settings as JSON.")
      ImGui.BulletText(ctx, "Save current dock remembers the window's dock location, when available.")
    end

    if ImGui.CollapsingHeader(ctx, "5. Status and troubleshooting") then
      ImGui.TextColored(ctx, COLORS.unassigned, "UNASSIGNED")
      ImGui.SameLine(ctx)
      ImGui.TextWrapped(ctx, "No track has been assigned to this cell yet.")
      ImGui.TextColored(ctx, COLORS.invalid, "INVALID TRACK / INVALID FX")
      ImGui.SameLine(ctx)
      ImGui.TextWrapped(ctx, "The track or FX is no longer available; select it again in the cell configuration.")
      ImGui.TextColored(ctx, COLORS.unsupported, "SELECT PARAMETER / INVALID PARAMETER")
      ImGui.SameLine(ctx)
      ImGui.TextWrapped(ctx, "Select a valid parameter for this FX.")
      ImGui.TextColored(ctx, COLORS.unsupported, "PARAMETER API UNAVAILABLE")
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

local function refresh_project_lists()
  local debug_started = debug_mode and reaper.time_precise()
  track_entries = all_tracks()
  fx_entries_by_track = {}
  local listed_fx = debug_mode and 0 or nil
  for _, track_entry in ipairs(track_entries) do
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
    fx_entries_by_track[track_entry.guid] = entries
  end
  param_entries_by_fx = {}
  last_project_list_refresh = reaper.time_precise()
  project_lists_dirty = false
  if debug_mode then
    local elapsed = reaper.time_precise() - debug_started
    debug_metrics.project_lists.total = debug_metrics.project_lists.total + elapsed
    debug_metrics.project_lists.max = math.max(debug_metrics.project_lists.max, elapsed)
    debug_metrics.project_lists.count = debug_metrics.project_lists.count + 1
    debug_metrics.tracks_listed = debug_metrics.tracks_listed + #track_entries
    debug_metrics.fx_listed = debug_metrics.fx_listed + listed_fx
  end
end

local function get_cached_track(track_guid)
  if track_guid == "" then
    return nil
  end
  local track = cached_tracks[track_guid]
  if track and reaper.ValidatePtr2
      and reaper.ValidatePtr2(active_project, track, "MediaTrack*")
      and reaper.GetTrackGUID(track) == track_guid then
    if debug_mode then
      debug_metrics.track_cache_hits = debug_metrics.track_cache_hits + 1
    end
    return track
  end
  local now = reaper.time_precise()
  if track == false and now < (cached_track_retry_times[track_guid] or 0) then
    return nil
  end

  if debug_mode then
    debug_metrics.track_cache_misses = debug_metrics.track_cache_misses + 1
  end
  track = resolve_track(track_guid)
  if debug_mode then
    debug_metrics.tracks_resolved = debug_metrics.tracks_resolved + (track and 1 or 0)
    debug_metrics.track_scan_steps = debug_metrics.track_scan_steps
        + reaper.CountTracks(active_project) + 1
  end
  cached_tracks[track_guid] = track or false
  if track then
    cached_track_retry_times[track_guid] = nil
  else
    cached_track_retry_times[track_guid] = now + PROJECT_LIST_REFRESH_SECONDS
  end
  return track
end

local function get_cached_fx_index(track, track_guid, fx_guid)
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
    if debug_mode then
      debug_metrics.fx_cache_hits = debug_metrics.fx_cache_hits + 1
    end
    return fx_index
  end

  if debug_mode then
    debug_metrics.fx_cache_misses = debug_metrics.fx_cache_misses + 1
  end
  fx_index = find_fx_index(track, fx_guid)
  if debug_mode then
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
    retry_times[fx_guid] = now + PROJECT_LIST_REFRESH_SECONDS
  end
  return fx_index
end

refresh_states = function()
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
        tracks_by_guid[cell.track_guid] = get_cached_track(cell.track_guid) or false
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
        fx_indices[fx_guid] = get_cached_fx_index(track, track_guid, fx_guid) or false
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
    states[index] = inspect_cell(cell, track, fx_index)
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

local function draw_window()
  if first_frame then
    ImGui.SetNextWindowSize(ctx, 640, 460, ImGui.Cond_FirstUseEver)
    if config.restore_dock and config.dock_id > 0 and ImGui.SetNextWindowDockID then
      ImGui.SetNextWindowDockID(ctx, config.dock_id, ImGui.Cond_FirstUseEver)
    end
    first_frame = false
  end
  if apply_configured_dock then
    if config.restore_dock and config.dock_id > 0 and ImGui.SetNextWindowDockID then
      ImGui.SetNextWindowDockID(ctx, config.dock_id, ImGui.Cond_Always)
    end
    apply_configured_dock = false
  end

  local visible, open = ImGui.Begin(
    ctx,
    SCRIPT_NAME,
    true,
    ImGui.WindowFlags_MenuBar
  )
  window_open = open
  if not visible then
    return
  end

  local window_x, window_y = ImGui.GetWindowPos(ctx)
  local window_width, window_height = ImGui.GetWindowSize(ctx)
  if debug_mode then
    debug_metrics.window_width = window_width
    debug_metrics.window_height = window_height
    debug_metrics.content_width, debug_metrics.content_height =
        ImGui.GetContentRegionAvail(ctx)
  end
  local parent_center_x = window_x + window_width * 0.5
  local parent_center_y = window_y + window_height * 0.5
  if ImGui.GetWindowDockID then
    main_window_dock_id = ImGui.GetWindowDockID(ctx) or 0
  end
  if ImGui.BeginMenuBar(ctx) then
    if ImGui.BeginMenu(ctx, "File") then
      if ImGui.MenuItem(ctx, "Import configuration") then
        import_configuration()
      end
      if ImGui.MenuItem(ctx, "Export configuration") then
        export_configuration()
      end
      ImGui.EndMenu(ctx)
    end
    if ImGui.MenuItem(ctx, "Settings") then
      settings_open = true
      request_settings = true
    end
    if ImGui.BeginMenu(ctx, "Help") then
      if ImGui.MenuItem(ctx, "Documentation") then
        help_open = true
        request_help = true
      end
      if ImGui.MenuItem(ctx, "Debug mode", nil, debug_mode) then
        debug_mode = not debug_mode
        if debug_mode then
          reset_debug_metrics()
          debug_pause_state_reads = false
          debug_pause_grid = false
        else
          debug_pause_state_reads = false
          debug_pause_grid = false
        end
      end
      if ImGui.BeginMenu(ctx, "Isolation tests", debug_mode) then
        if ImGui.MenuItem(
            ctx,
            "Pause state reads",
            nil,
            debug_pause_state_reads,
            debug_mode
          ) then
          debug_pause_state_reads = not debug_pause_state_reads
          last_refresh = reaper.time_precise()
        end
        if ImGui.MenuItem(
            ctx,
            "Pause pedalboard grid",
            nil,
            debug_pause_grid,
            debug_mode
          ) then
          debug_pause_grid = not debug_pause_grid
        end
        ImGui.EndMenu(ctx)
      end
      ImGui.EndMenu(ctx)
    end
    if ImGui.MenuItem(ctx, "About...") then
      about_open = true
      request_about = true
    end
    ImGui.EndMenuBar(ctx)
  end
  if request_settings then
    ImGui.OpenPopup(ctx, "Settings")
    request_settings = false
  end
  if request_help then
    ImGui.OpenPopup(ctx, "Help")
    request_help = false
  end
  if request_about then
    ImGui.OpenPopup(ctx, "About")
    request_about = false
  end

  local font_pushed = push_configured_font()
  if not debug_mode or not debug_pause_grid then
    draw_grid()
  end
  draw_cell_configuration_modal()
  if font_pushed then
    ImGui.PopFont(ctx)
  end
  help_open = draw_help_modal(
    help_open,
    parent_center_x,
    parent_center_y
  )
  about_open = draw_info_modal(
    "About",
    "Made with ❤️by rdibiasky",
    about_open,
    400,
    150,
    ImGui.WindowFlags_NoResize,
    parent_center_x,
    parent_center_y
  )
  draw_settings_modal()
  ImGui.End(ctx)
end

local function debug_metric_summary(metric)
  local average = metric.count > 0 and metric.total / metric.count or 0
  return string.format(
    "avg_ms=%.3f max_ms=%.3f calls=%d",
    average * 1000,
    metric.max * 1000,
    metric.count
  )
end

local function report_debug_metrics(now)
  local elapsed = now - debug_metrics.started_at
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
  debug_metrics.armed_tracks = armed_tracks
  debug_metrics.monitored_tracks = monitored_tracks
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
    debug_metrics.frames / elapsed,
    config.refresh_ms,
    (play_state & 1) ~= 0 and "yes" or "no",
    (play_state & 2) ~= 0 and "yes" or "no",
    (play_state & 4) ~= 0 and "yes" or "no",
    play_state,
    debug_metrics.armed_tracks,
    debug_metrics.monitored_tracks,
    debug_pause_state_reads and "yes" or "no",
    debug_pause_grid and "yes" or "no",
    debug_metrics.window_width,
    debug_metrics.window_height,
    debug_metrics.content_width,
    debug_metrics.content_height,
    config.rows,
    config.columns,
    config.rows * config.columns,
    debug_metrics.assigned_cells,
    debug_metric_summary(debug_metrics.loop),
    debug_metrics.loop_over_5ms,
    debug_metrics.loop_over_10ms,
    debug_metric_summary(debug_metrics.draw),
    debug_metric_summary(debug_metrics.switch),
    debug_metric_summary(debug_metrics.states),
    debug_metrics.refreshes,
    debug_metrics.cells_checked,
    debug_metrics.late_refreshes,
    debug_metrics.max_refresh_lateness * 1000,
    debug_metric_summary(debug_metrics.project_lists),
    debug_metrics.tracks_listed,
    debug_metrics.fx_listed,
    debug_metrics.track_cache_hits,
    debug_metrics.track_cache_misses,
    debug_metrics.tracks_resolved,
    debug_metrics.track_scan_steps,
    debug_metrics.fx_cache_hits,
    debug_metrics.fx_cache_misses,
    debug_metrics.fx_scan_steps
  ))

  debug_metrics.started_at = now
  debug_metrics.frames = 0
  for _, name in ipairs({ "loop", "draw", "switch", "project_lists", "states" }) do
    debug_metrics[name] = { total = 0, max = 0, count = 0 }
  end
  debug_metrics.refreshes = 0
  debug_metrics.late_refreshes = 0
  debug_metrics.max_refresh_lateness = 0
  debug_metrics.loop_over_5ms = 0
  debug_metrics.loop_over_10ms = 0
  debug_metrics.tracks_listed = 0
  debug_metrics.fx_listed = 0
  debug_metrics.tracks_resolved = 0
  debug_metrics.track_cache_hits = 0
  debug_metrics.track_cache_misses = 0
  debug_metrics.track_scan_steps = 0
  debug_metrics.fx_cache_hits = 0
  debug_metrics.fx_cache_misses = 0
  debug_metrics.fx_scan_steps = 0
  debug_metrics.cells_checked = 0
  debug_metrics.assigned_cells = 0
end

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
  local now = reaper.time_precise()
  if project_lists_dirty
      or (open_cell_configuration
        and now - last_project_list_refresh >= PROJECT_LIST_REFRESH_SECONDS) then
    refresh_project_lists()
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
  draw_window()
  if debug_active_for_frame then
    local draw_elapsed = reaper.time_precise() - stage_started
    local draw_metric = debug_metrics.draw
    draw_metric.total = draw_metric.total + draw_elapsed
    draw_metric.max = math.max(draw_metric.max, draw_elapsed)
    draw_metric.count = draw_metric.count + 1
  end
  if window_open then
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
      report_debug_metrics(now_finished)
    end
    reaper.defer(loop)
  else
    save_config()
  end
end

refresh_states()
reaper.defer(loop)
