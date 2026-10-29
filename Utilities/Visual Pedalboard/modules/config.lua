-- Visual Pedalboard: configuration, defaults, JSON serialization and file I/O.

local SCRIPT_NAME = "Visual Pedalboard"
local EXT_SECTION = "VisualPedalboard"
local EXT_KEY = "configuration"
local CONFIG_VERSION = 1
local MAX_ROWS = 8
local MAX_COLUMNS = 8
local MAX_CELLS = MAX_ROWS * MAX_COLUMNS
local PRESET_COUNT = 8
local MIN_REFRESH_MS = 30

local M = {}

M.SCRIPT_NAME = SCRIPT_NAME
M.EXT_SECTION = EXT_SECTION
M.EXT_KEY = EXT_KEY
M.CONFIG_VERSION = CONFIG_VERSION
M.MAX_ROWS = MAX_ROWS
M.MAX_COLUMNS = MAX_COLUMNS
M.MAX_CELLS = MAX_CELLS
M.PRESET_COUNT = PRESET_COUNT
M.MIN_REFRESH_MS = MIN_REFRESH_MS

-- ---------------------------------------------------------------------------
-- Cell / config constructors
-- ---------------------------------------------------------------------------

function M.new_cell(index)
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

function M.default_config()
  local config = {
    rows = 2,
    columns = 4,
    spacing = 8,
    font_size = 16,
    minimal_gui = false,
    show_presets = true,
    listen_midi_program_change = true,
    refresh_ms = 100,
    dock_id = 0,
    restore_dock = false,
    cells = {},
    presets = {},
  }
  for index = 1, config.rows * config.columns do
    config.cells[index] = M.new_cell(index)
  end
  for index = 1, PRESET_COUNT do
    config.presets[index] = false
  end
  return config
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

function M.clamp(value, minimum, maximum)
  return math.max(minimum, math.min(maximum, value))
end

local function report_error(message)
  reaper.ShowConsoleMsg(SCRIPT_NAME .. ": " .. message .. "\n")
end

M.report_error = report_error

function M.color_from_hex(value)
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

M.COLORS = {
  active = 0x4B9441FF,
  preset_inactive = 0x3087BFFF,
  bypassed = 0xC83C3CFF,
  unsupported = 0x666666FF,
  invalid = 0x666666FF,
  unassigned = 0x555555FF,
  pressed = 0x777777FF,
}

-- ---------------------------------------------------------------------------
-- JSON encoder
-- ---------------------------------------------------------------------------

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

function M.serialize_json_config(source)
  local default = M.default_config()
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
  add_setting("show_presets", source.show_presets, default.show_presets)
  add_setting(
    "listen_midi_program_change",
    source.listen_midi_program_change,
    default.listen_midi_program_change
  )
  add_setting("refresh_ms", source.refresh_ms, default.refresh_ms)
  add_setting("dock_id", source.dock_id, default.dock_id)
  add_setting("restore_dock", source.restore_dock, default.restore_dock)

  local function serialize_cell(cell, index)
    local cell_default = M.new_cell(index)
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
    return "{" .. table.concat(cell_fields, ",") .. "}"
  end

  local last_cell = 0
  for index, cell in ipairs(source.cells) do
    local cell_default = M.new_cell(index)
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
      cells[index] = serialize_cell(source.cells[index], index)
    end
    fields[#fields + 1] = '"cells":[' .. table.concat(cells, ",") .. ']'
  end

  local has_presets = false
  for index = 1, PRESET_COUNT do
    if source.presets[index] then
      has_presets = true
      break
    end
  end
  if has_presets then
    local presets = {}
    for index = 1, PRESET_COUNT do
      local preset = source.presets[index]
      if not preset then
        presets[index] = "null"
      else
        local preset_fields = {
          '"name":' .. json_quote(preset.name),
        }
        if preset.locked then
          preset_fields[#preset_fields + 1] = '"locked":true'
        end
        local preset_cells = {}
        for _, cell in ipairs(preset.cells) do
          local cell_fields = {}
          cell_fields[#cell_fields + 1] = '"position":' .. cell.position
          cell_fields[#cell_fields + 1] =
            '"state":' .. json_quote(cell.state)
          if cell.fx_state then
            cell_fields[#cell_fields + 1] = '"fx_state":{'
              .. '"chunk":' .. json_quote(cell.fx_state.chunk)
              .. "}"
          end
          preset_cells[#preset_cells + 1] =
            "{" .. table.concat(cell_fields, ",") .. "}"
        end
        preset_fields[#preset_fields + 1] =
          '"cells":[' .. table.concat(preset_cells, ",") .. ']'
        presets[index] = "{" .. table.concat(preset_fields, ",") .. "}"
      end
    end
    fields[#fields + 1] = '"presets":[' .. table.concat(presets, ",") .. ']'
  end
  return "{" .. table.concat(fields, ",") .. "}"
end

-- ---------------------------------------------------------------------------
-- JSON decoder
-- ---------------------------------------------------------------------------

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

-- ---------------------------------------------------------------------------
-- FX chunk helpers (needed by config_from_json for preset validation)
-- ---------------------------------------------------------------------------

local function fx_chunk_range(track_chunk, fx_guid)
  local wanted_guid = fx_guid:upper():gsub("[{}]", "")
  local stack = {}
  local current_fx
  local position = 1
  while position <= #track_chunk do
    local newline = track_chunk:find("\n", position, true)
    local line_end = newline or #track_chunk
    local line = track_chunk:sub(position, line_end):gsub("\r$", "")
    local trimmed = line:match("^%s*(.-)%s*$")
    if trimmed == ">" then
      local frame = stack[#stack]
      if frame then
        if frame.is_fx_chain and current_fx and current_fx.matches_guid then
          return current_fx.start, position - 1
        end
        stack[#stack] = nil
      end
    elseif trimmed:sub(1, 1) == "<" then
      local parent = stack[#stack]
      if parent and parent.is_fx_chain then
        if current_fx and current_fx.matches_guid then
          return current_fx.start, position - 1
        end
        current_fx = { start = position, matches_guid = false }
      end
      stack[#stack + 1] = {
        is_fx_chain = trimmed:match("^<FXCHAIN") ~= nil,
      }
    else
      local chunk_guid = trimmed:match("^FXID%s+(%S+)")
      if chunk_guid and chunk_guid:upper():gsub("[{}]", "") == wanted_guid then
        if current_fx then
          current_fx.matches_guid = true
        end
      end
    end
    if not newline then
      break
    end
    position = newline + 1
  end
  return nil
end

M.fx_chunk_range = fx_chunk_range

function M.replace_fx_chunk(track_chunk, fx_guid, replacement)
  local start_position, end_position = fx_chunk_range(track_chunk, fx_guid)
  if not start_position then
    return nil
  end
  return track_chunk:sub(1, start_position - 1)
    .. replacement
    .. track_chunk:sub(end_position + 1)
end

function M.valid_fx_state_chunk(state_chunk, fx_guid)
  local prefix = "<FXCHAIN\n"
  local wrapped_chunk = prefix .. state_chunk .. ">\n"
  local start_position, end_position = fx_chunk_range(wrapped_chunk, fx_guid)
  return start_position == #prefix + 1
    and end_position == #prefix + #state_chunk
end

-- ---------------------------------------------------------------------------
-- JSON → config
-- ---------------------------------------------------------------------------

local function cell_from_json(cell, index, json_null, array_metatable)
  if type(cell) ~= "table"
      or cell == json_null
      or getmetatable(cell) == array_metatable then
    return nil, "Configuration cell " .. index .. " is invalid."
  end
  local imported_cell = M.new_cell(index)
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
    if type(cell.param_index) ~= "number"
        or cell.param_index ~= cell.param_index
        or cell.param_index == math.huge
        or cell.param_index == -math.huge
        or cell.param_index % 1 ~= 0
        or cell.param_index < -1 then
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
  return imported_cell
end

function M.config_from_json(text)
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
  local presets = decoded.presets
  if presets ~= nil
      and (type(presets) ~= "table"
        or presets == json_null
        or getmetatable(presets) ~= array_metatable
        or #presets > PRESET_COUNT) then
    report_error(
      "Saved project presets are invalid; keeping the rest of the configuration. "
        .. "The presets will be ignored."
    )
    presets = nil
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
  local imported = M.default_config()
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
  local show_presets = settings and settings.show_presets
  if show_presets ~= nil then
    if type(show_presets) ~= "boolean" then
      return nil, "Configuration setting 'show_presets' must be a boolean."
    end
    imported.show_presets = show_presets
  end
  local listen_midi_program_change = settings and settings.listen_midi_program_change
  if listen_midi_program_change ~= nil then
    if type(listen_midi_program_change) ~= "boolean" then
      return nil, "Configuration setting 'listen_midi_program_change' must be a boolean."
    end
    imported.listen_midi_program_change = listen_midi_program_change
  end

  for index, cell in ipairs(cells or {}) do
    local imported_cell, cell_error = cell_from_json(
      cell,
      index,
      json_null,
      array_metatable
    )
    if not imported_cell then
      return nil, cell_error
    end
    imported.cells[index] = imported_cell
  end
  for index = 1, MAX_CELLS do
    if not imported.cells[index] then
      imported.cells[index] = M.new_cell(index)
    end
  end

  local function parse_preset(index, preset)
    if preset == json_null then
      return false
    end
    if type(preset) ~= "table"
        or getmetatable(preset) == array_metatable
        or type(preset.name) ~= "string"
        or (preset.locked ~= nil and type(preset.locked) ~= "boolean")
        or type(preset.cells) ~= "table"
        or getmetatable(preset.cells) ~= array_metatable
        or #preset.cells > MAX_CELLS then
      return nil, "has invalid preset data."
    end

    local saved_cells, positions = {}, {}
    local is_legacy = preset.save_plugins_state ~= nil
        or preset.plugin_states ~= nil
    if is_legacy then
      if type(preset.save_plugins_state) ~= "boolean"
          or #preset.cells ~= MAX_CELLS then
        return nil, "has invalid legacy preset data."
      end
      local legacy_fx_states = {}
      if preset.plugin_states ~= nil then
        if type(preset.plugin_states) ~= "table"
            or getmetatable(preset.plugin_states) ~= array_metatable then
          report_error(
            "Preset " .. index
              .. " has an invalid plugin-state list; pedal states will still load."
          )
        else
          for state_index, state in ipairs(preset.plugin_states) do
            if type(state) ~= "table"
                or getmetatable(state) == array_metatable
                or type(state.track_guid) ~= "string"
                or state.track_guid == ""
                or type(state.fx_guid) ~= "string"
                or state.fx_guid == ""
                or type(state.chunk) ~= "string"
                or state.chunk == ""
                or not M.valid_fx_state_chunk(state.chunk, state.fx_guid) then
              report_error(
                "Preset " .. index .. " plugin-state entry " .. state_index
                  .. " is invalid; that plugin state will be skipped."
              )
            else
              legacy_fx_states[state.track_guid .. "\31" .. state.fx_guid] = {
                chunk = state.chunk,
              }
            end
          end
        end
      end
      for position = 1, MAX_CELLS do
        local current_cell = imported.cells[position]
        if current_cell.track_guid ~= "" and current_cell.fx_guid ~= "" then
          local track = M._resolve_track(current_cell.track_guid)
          local fx_index = track
              and M._find_fx_index(track, current_cell.fx_guid)
          local current_state = M._inspect_cell(
            current_cell,
            track,
            fx_index
          ).state
          local entry = {
            position = position,
            state = current_state == "bypassed"
                and "bypassed" or "active",
          }
          if preset.save_plugins_state then
            entry.fx_state = legacy_fx_states[
              current_cell.track_guid .. "\31" .. current_cell.fx_guid
            ]
          end
          saved_cells[#saved_cells + 1] = entry
        end
      end
    else
      for cell_index, cell in ipairs(preset.cells) do
        if type(cell) ~= "table"
            or getmetatable(cell) == array_metatable
            or not is_integer(cell.position)
            or cell.position < 1
            or cell.position > MAX_CELLS
            or positions[cell.position]
            or (cell.state ~= "active" and cell.state ~= "bypassed") then
          report_error(
            "Preset " .. index .. ", cell entry " .. cell_index
              .. " is invalid; that cell will be skipped."
          )
        else
          local configured_cell = imported.cells[cell.position]
          if configured_cell.track_guid == "" or configured_cell.fx_guid == "" then
            report_error(
              "Preset " .. index .. ", cell entry " .. cell_index
                .. " points to unassigned pedal " .. cell.position
                .. "; that cell will be skipped."
            )
          else
            local saved_cell = {
              position = cell.position,
              state = cell.state,
            }
            if cell.fx_state ~= nil then
              local fx_state = cell.fx_state
              if type(fx_state) ~= "table"
                  or getmetatable(fx_state) == array_metatable
                  or type(fx_state.chunk) ~= "string"
                  or fx_state.chunk == ""
                  or not M.valid_fx_state_chunk(
                    fx_state.chunk,
                    configured_cell.fx_guid
                  ) then
                report_error(
                  "Preset " .. index .. ", pedal " .. cell.position
                    .. " has invalid plugin state; that plugin state will be skipped."
                )
              else
                saved_cell.fx_state = { chunk = fx_state.chunk }
              end
            end
            positions[cell.position] = true
            saved_cells[#saved_cells + 1] = saved_cell
          end
        end
      end
    end
    return {
      name = preset.name,
      cells = saved_cells,
      locked = preset.locked == true,
    }
  end

  for index, preset in ipairs(presets or {}) do
    local imported_preset, preset_error = parse_preset(index, preset)
    if imported_preset == false then
      imported.presets[index] = false
    elseif imported_preset then
      imported.presets[index] = imported_preset
    else
      report_error(
        "Preset " .. index .. " " .. preset_error
          .. " It will be skipped; the remaining configuration and presets will load."
      )
      imported.presets[index] = false
    end
  end
  return imported
end

-- ---------------------------------------------------------------------------
-- Load / save to REAPER project
-- ---------------------------------------------------------------------------

function M.load_config(serialized)
  if not serialized or serialized == "" then
    return M.default_config()
  end
  local loaded, load_error = M.config_from_json(serialized)
  if not loaded then
    reaper.ShowConsoleMsg(
      SCRIPT_NAME .. ": saved project configuration is invalid or unsupported; using defaults. "
        .. tostring(load_error) .. "\n"
    )
    return M.default_config()
  end
  return loaded
end

--- Save the current config to the active REAPER project.
--- @param active_project userdata the REAPER project to save to
--- @param config table the config table
--- @return boolean success
function M.save_config(active_project, config)
  local bytes = reaper.SetProjExtState(
    active_project,
    EXT_SECTION,
    EXT_KEY,
    M.serialize_json_config(config)
  )
  if not bytes or bytes <= 0 then
    reaper.ShowConsoleMsg(SCRIPT_NAME .. ": could not save configuration to the current project.\n")
    return false
  end
  reaper.MarkProjectDirty(active_project)
  return true
end

-- ---------------------------------------------------------------------------
-- Import / export files
-- ---------------------------------------------------------------------------

local function append_json_extension(path)
  if not path:lower():match("%.json$") then
    return path .. ".json"
  end
  return path
end

function M.export_configuration(config)
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
  local written, write_error = file:write(M.serialize_json_config(config), "\n")
  local closed, close_error = file:close()
  if not written then
    report_error("Could not write JSON file: " .. tostring(write_error))
  elseif not closed then
    report_error("Could not close JSON file: " .. tostring(close_error))
  end
end

--- Import configuration from a JSON file.
--- @return table|nil imported the imported config, or nil on cancel/error
function M.import_configuration()
  local selected, path = reaper.GetUserFileNameForRead(
    "",
    "Import Visual Pedalboard configuration",
    "json"
  )
  if not selected then
    return nil
  end
  local file, open_error = io.open(path, "rb")
  if not file then
    report_error("Could not open configuration file: " .. tostring(open_error))
    return nil
  end
  local contents, read_error = file:read("*a")
  local closed, close_error = file:close()
  if not contents then
    report_error("Could not read configuration file: " .. tostring(read_error))
    return nil
  elseif not closed then
    report_error("Could not close configuration file: " .. tostring(close_error))
    return nil
  end
  local imported, import_error = M.config_from_json(contents)
  if not imported then
    report_error(import_error)
    return nil
  end
  return imported
end

-- ---------------------------------------------------------------------------
-- Dependency injection for legacy preset loading (resolve_track, find_fx_index,
-- inspect_cell). The main script sets these after loading modules/project.lua.
-- ---------------------------------------------------------------------------

M._resolve_track = function() return nil end
M._find_fx_index = function() return nil end
M._inspect_cell = function() return { state = "unassigned" } end

function M.set_project_helpers(resolve_track, find_fx_index, inspect_cell)
  M._resolve_track = resolve_track
  M._find_fx_index = find_fx_index
  M._inspect_cell = inspect_cell
end

return M
