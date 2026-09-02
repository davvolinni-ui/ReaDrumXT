-- @noindex
-- Pure, serializable ReaDrum domain model. This module intentionally has no
-- dependency on REAPER or on third-party Lua libraries.

local M = {}

M.SCHEMA_VERSION = 1

local function deep_copy(value, seen)
  if type(value) ~= "table" then
    return value
  end

  seen = seen or {}
  if seen[value] then
    return seen[value]
  end

  local result = {}
  seen[value] = result
  for key, child in pairs(value) do
    result[deep_copy(key, seen)] = deep_copy(child, seen)
  end
  return result
end

M.deep_copy = deep_copy

local function option(opts, key, default)
  local value = opts[key]
  if value == nil then
    return deep_copy(default)
  end
  return deep_copy(value)
end

local function is_integer(value)
  return type(value) == "number" and value == math.floor(value)
end

local function is_non_empty_string(value)
  return type(value) == "string" and value ~= ""
end

local function fail(path, message)
  return nil, path .. ": " .. message
end

local function validate_array(value, path)
  if type(value) ~= "table" then
    return fail(path, "expected an array table")
  end

  local count, highest = 0, 0
  for key in pairs(value) do
    if not is_integer(key) or key < 1 then
      return fail(path, "expected only positive integer array keys")
    end
    count = count + 1
    if key > highest then
      highest = key
    end
  end

  if count ~= highest then
    return fail(path, "array contains a missing index")
  end
  return true
end

local function validate_unique_strings(value, path, maximum)
  local ok, err = validate_array(value, path)
  if not ok then
    return nil, err
  end
  if maximum and #value > maximum then
    return fail(path, "expected at most " .. maximum .. " entries")
  end

  local seen = {}
  for index, item in ipairs(value) do
    local item_path = path .. "[" .. index .. "]"
    if not is_non_empty_string(item) then
      return fail(item_path, "expected a non-empty string ID")
    end
    if seen[item] then
      return fail(item_path, "duplicate ID '" .. item .. "'")
    end
    seen[item] = true
  end
  return true
end

local function validate_id(value, path)
  if not is_non_empty_string(value) then
    return fail(path, "expected a stable, non-empty string ID")
  end
  return true
end

local function validate_number(value, path, minimum, maximum, integer)
  if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
    return fail(path, "expected a finite number")
  end
  if integer and not is_integer(value) then
    return fail(path, "expected an integer")
  end
  if minimum and value < minimum then
    return fail(path, "expected a value >= " .. minimum .. ", got " .. value)
  end
  if maximum and value > maximum then
    return fail(path, "expected a value <= " .. maximum .. ", got " .. value)
  end
  return true
end

local function validate_boolean(value, path)
  if type(value) ~= "boolean" then
    return fail(path, "expected a boolean")
  end
  return true
end

local function validate_rational(value, path, allow_number)
  if allow_number and type(value) == "number" then
    local ok, err = validate_number(value, path, 0, nil, false)
    if not ok then return nil, err end
    if value == 0 then return fail(path, "expected positive timing") end
    return true
  end
  if type(value) ~= "table" then
    return fail(path, "expected { numerator, denominator } rational timing")
  end
  local ok, err = validate_number(value.numerator, path .. ".numerator", 1, nil, true)
  if not ok then
    return nil, err
  end
  return validate_number(value.denominator, path .. ".denominator", 1, nil, true)
end

local function validate_serializable(value, path, seen)
  local value_type = type(value)
  if value_type == "nil" or value_type == "boolean" or value_type == "string" then
    return true
  end
  if value_type == "number" then
    return validate_number(value, path)
  end
  if value_type ~= "table" then
    return fail(path, "expected serializable data, got " .. value_type)
  end

  seen = seen or {}
  if seen[value] then
    return fail(path, "cyclic tables are not serializable")
  end
  seen[value] = true
  for key, child in pairs(value) do
    if type(key) ~= "string" and not is_integer(key) then
      seen[value] = nil
      return fail(path, "table keys must be strings or integers")
    end
    local child_path = path .. "[" .. tostring(key) .. "]"
    local ok, err = validate_serializable(child, child_path, seen)
    if not ok then
      seen[value] = nil
      return nil, err
    end
  end
  seen[value] = nil
  return true
end

-- The factory is deterministic by construction and owns all mutable ID state.
-- Constructors never fall back to process-global counters.
function M.new_id_factory(prefix, first)
  prefix = prefix or "readrum"
  first = first or 1
  if not is_non_empty_string(prefix) then
    error("id factory prefix must be a non-empty string", 2)
  end
  if not is_integer(first) or first < 1 then
    error("id factory first value must be a positive integer", 2)
  end

  local next_value = first
  return function(kind)
    kind = tostring(kind or "object"):lower():gsub("[^%w]+", "_")
    local id = string.format("%s_%s_%04d", prefix, kind, next_value)
    next_value = next_value + 1
    return id
  end
end

local function resolve_id(kind, opts, id_factory)
  if opts.id ~= nil then
    if not is_non_empty_string(opts.id) then
      error(kind .. ".id must be a non-empty string", 3)
    end
    return opts.id
  end

  local factory = id_factory or opts.id_factory
  if type(factory) ~= "function" then
    error(kind .. " requires opts.id or an injected id factory", 3)
  end
  local id = factory(kind)
  if not is_non_empty_string(id) then
    error("id factory returned an invalid ID for " .. kind, 3)
  end
  return id
end

local STEP_PROPERTY_ORDER = {}
local STEP_PROPERTY_REGISTRY = {}

function M.register_step_property(definition)
  if type(definition) ~= "table" then
    error("step property definition must be a table", 2)
  end
  if not is_non_empty_string(definition.id) then
    error("step property definition.id must be a non-empty string", 2)
  end
  if STEP_PROPERTY_REGISTRY[definition.id] then
    error("step property '" .. definition.id .. "' is already registered", 2)
  end
  if definition.default == nil then
    error("step property '" .. definition.id .. "'.default must be explicit", 2)
  end
  for _, required in ipairs({ "label", "value_type", "unit", "inheritance", "serialization" }) do
    if not is_non_empty_string(definition[required]) then
      error("step property '" .. definition.id .. "'." .. required .. " must be a non-empty string", 2)
    end
  end

  local stored = deep_copy(definition)
  STEP_PROPERTY_REGISTRY[stored.id] = stored
  STEP_PROPERTY_ORDER[#STEP_PROPERTY_ORDER + 1] = stored.id
  return deep_copy(stored)
end

function M.get_step_property_definition(id)
  return deep_copy(STEP_PROPERTY_REGISTRY[id])
end

function M.get_step_property_definitions()
  local result = {}
  for index, id in ipairs(STEP_PROPERTY_ORDER) do
    result[index] = deep_copy(STEP_PROPERTY_REGISTRY[id])
  end
  return result
end

local builtin_step_properties = {
  { id = "enabled", label = "Enabled", value_type = "boolean", unit = "boolean", default = false,
    inheritance = "none", serialization = "boolean" },
  { id = "velocity", label = "Velocity", value_type = "integer", unit = "midi_velocity", minimum = 1,
    maximum = 127, default = 100, inheritance = "lane default", serialization = "integer" },
  { id = "pitch_semitones", label = "Pitch", value_type = "integer", unit = "semitones", minimum = -96,
    maximum = 96, default = 0, inheritance = "additive lane default", serialization = "integer" },
  { id = "pitch_cents", label = "Pitch Cents", value_type = "integer", unit = "cents", minimum = -100,
    maximum = 100, default = 0, inheritance = "additive lane default", serialization = "integer" },
  { id = "pan_lock", label = "Pan Lock", value_type = "integer_or_false", unit = "percent", minimum = -100,
    maximum = 100, default = false, inheritance = "false inherits pad pan; integer is explicit", serialization = "boolean_or_integer" },
  { id = "repeat_count", label = "Repeats", value_type = "integer", unit = "hits", minimum = 1,
    maximum = 64, default = 1, inheritance = "lane default", serialization = "integer" },
  { id = "repeat_spacing", label = "Repeat Spacing", value_type = "rational", unit = "whole_note_fraction",
    default = { numerator = 1, denominator = 16 }, inheritance = "lane default", serialization = "rational" },
  { id = "probability", label = "Probability", value_type = "number", unit = "percent", minimum = 0,
    maximum = 1600, default = 100, inheritance = "lane default", serialization = "number" },
  { id = "timing_offset", label = "Timing Offset", value_type = "integer", unit = "ticks_960_per_quarter",
    minimum = -960, maximum = 960, default = 0, inheritance = "additive lane default", serialization = "integer" },
  { id = "gate", label = "Gate", value_type = "number", unit = "percent", minimum = 0,
    maximum = 100, default = 100, inheritance = "lane default", serialization = "number" },
  { id = "condition", label = "Condition", value_type = "condition", unit = "condition", default = { type = "always" },
    inheritance = "lane default", serialization = "tagged_table" },
  { id = "parameter_locks", label = "Parameter Locks", value_type = "parameter_lock_array", unit = "mixed",
    default = {}, inheritance = "merge by parameter_id", serialization = "array" },
}

for _, definition in ipairs(builtin_step_properties) do
  M.register_step_property(definition)
end

local function default_step_value(id)
  return deep_copy(STEP_PROPERTY_REGISTRY[id].default)
end

function M.new_parameter_lock(opts)
  opts = opts or {}
  return {
    type = "ParameterLock",
    parameter_id = option(opts, "parameter_id", ""),
    value = option(opts, "value", false),
    interpolation = option(opts, "interpolation", "step"),
  }
end

function M.new_step(opts)
  opts = opts or {}
  local parameter_locks = {}
  for index, lock in ipairs(opts.parameter_locks or {}) do
    parameter_locks[index] = lock.type == "ParameterLock" and deep_copy(lock) or M.new_parameter_lock(lock)
  end

  local step = {
    type = "Step",
    enabled = option(opts, "enabled", default_step_value("enabled")),
    accent = option(opts, "accent", false),
    cut = option(opts, "cut", false),
    slide = option(opts, "slide", false),
    velocity = option(opts, "velocity", default_step_value("velocity")),
    pitch_semitones = option(opts, "pitch_semitones", default_step_value("pitch_semitones")),
    pitch_cents = option(opts, "pitch_cents", default_step_value("pitch_cents")),
    pan_lock = option(opts, "pan_lock", default_step_value("pan_lock")),
    repeat_count = option(opts, "repeat_count", default_step_value("repeat_count")),
    repeat_spacing = option(opts, "repeat_spacing", default_step_value("repeat_spacing")),
    probability = option(opts, "probability", default_step_value("probability")),
    timing_offset = option(opts, "timing_offset", default_step_value("timing_offset")),
    gate = option(opts, "gate", default_step_value("gate")),
    condition = option(opts, "condition", default_step_value("condition")),
    parameter_locks = parameter_locks,
  }
  for _, property_id in ipairs(STEP_PROPERTY_ORDER) do
    if step[property_id] == nil then
      step[property_id] = option(opts, property_id, default_step_value(property_id))
    end
  end
  return step
end

local function construct_steps(source)
  local result = {}
  for index, step in ipairs(source) do
    result[index] = step.type == "Step" and deep_copy(step) or M.new_step(step)
  end
  return result
end

function M.new_lane(opts, id_factory)
  opts = opts or {}
  local step_count = opts.step_count == nil and 16 or opts.step_count
  local steps
  if opts.steps == nil then
    steps = {}
    if is_integer(step_count) and step_count >= 0 then
      for index = 1, step_count do
        steps[index] = M.new_step()
      end
    end
  else
    steps = construct_steps(opts.steps)
  end

  return {
    type = "Lane",
    id = resolve_id("Lane", opts, id_factory),
    pad_id = option(opts, "pad_id", ""),
    step_count = step_count,
    division_num = option(opts, "division_num", 1),
    division_den = option(opts, "division_den", 16),
    phase = option(opts, "phase", 0),
    swing = option(opts, "swing", 0),
    timing_offset = option(opts, "timing_offset", 0),
    velocity_scale = option(opts, "velocity_scale", 100),
    velocity_sensitivity = option(opts, "velocity_sensitivity", 100),
    gate_scale = option(opts, "gate_scale", 100),
    accentuator_enabled = option(opts, "accentuator_enabled", true),
    global_swing_enabled = option(opts, "global_swing_enabled", true),
    global_gate_enabled = option(opts, "global_gate_enabled", true),
    global_velocity_sensitivity_enabled = option(opts, "global_velocity_sensitivity_enabled", true),
    global_velocity_humanize_enabled = option(opts, "global_velocity_humanize_enabled", true),
    velocity_humanize = option(opts, "velocity_humanize", 0),
    timing_humanize = option(opts, "timing_humanize", 0),
    pitch_humanize = option(opts, "pitch_humanize", 0),
    pan_humanize = option(opts, "pan_humanize", 0),
    defaults = option(opts, "defaults", {
      velocity = 100,
      pitch_semitones = 0,
      pitch_cents = 0,
      pan_lock = false,
      repeat_count = 1,
      repeat_spacing = { numerator = 1, denominator = 16 },
      probability = 100,
      timing_offset = 0,
      gate = 100,
      condition = { type = "always" },
    }),
    steps = steps,
  }
end

function M.new_variation(opts, id_factory)
  opts = opts or {}
  local factory = id_factory or opts.id_factory
  local lanes = {}
  for index, lane in ipairs(opts.lanes or {}) do
    lanes[index] = lane.type == "Lane" and deep_copy(lane) or M.new_lane(lane, factory)
  end
  return {
    type = "Variation",
    id = resolve_id("Variation", opts, factory),
    name = option(opts, "name", "Variation"),
    switch_quantization = option(opts, "switch_quantization", "bar"),
    swing = option(opts, "swing", 0),
    groove = option(opts, "groove", nil),
    velocity_humanize = option(opts, "velocity_humanize", 0),
    timing_humanize = option(opts, "timing_humanize", 0),
    pitch_humanize = option(opts, "pitch_humanize", 0),
    pan_humanize = option(opts, "pan_humanize", 0),
    lanes = lanes,
  }
end

function M.new_pattern(opts, id_factory)
  opts = opts or {}
  local factory = id_factory or opts.id_factory
  local variations = {}
  for index, variation in ipairs(opts.variations or {}) do
    variations[index] = variation.type == "Variation" and deep_copy(variation) or M.new_variation(variation, factory)
  end
  return {
    type = "Pattern",
    id = resolve_id("Pattern", opts, factory),
    name = option(opts, "name", "Pattern"),
    seed = option(opts, "seed", 0),
    variations = variations,
  }
end

function M.new_pad(opts, id_factory)
  opts = opts or {}
  local default_controls = deep_copy(option(opts, "default_controls", {}))
  if default_controls.playback_mode == nil then default_controls.playback_mode = "one_shot" end
  if default_controls.gate_release_ms == nil then default_controls.gate_release_ms = 10 end
  if default_controls.envelope_enabled == nil then default_controls.envelope_enabled = false end
  if default_controls.legato_enabled == nil then default_controls.legato_enabled = true end
  if default_controls.slide_retrigger == nil then default_controls.slide_retrigger = true end
  if default_controls.slide_crossfade_ms == nil then default_controls.slide_crossfade_ms = 20 end
  if default_controls.fade_in == nil then default_controls.fade_in = 0 end
  if default_controls.fade_out == nil then default_controls.fade_out = 0 end
  return {
    type = "Pad",
    id = resolve_id("Pad", opts, id_factory),
    logical_index = option(opts, "logical_index", 1),
    name = option(opts, "name", "Pad"),
    sample = option(opts, "sample", false),
    color = option(opts, "color", "#808080"),
    choke_group = option(opts, "choke_group", false),
    simultaneous_play_targets = option(opts, "simultaneous_play_targets", {}),
    mute_targets = option(opts, "mute_targets", {}),
    polyphony = option(opts, "polyphony", 16),
    self_choke = option(opts, "self_choke", true),
    muted = option(opts, "muted", false),
    soloed = option(opts, "soloed", false),
    output_id = option(opts, "output_id", "main"),
    default_controls = default_controls,
    reaper_object_refs = option(opts, "reaper_object_refs", {}),
  }
end

function M.new_output(opts, id_factory)
  opts = opts or {}
  return {
    type = "LogicalOutput",
    id = resolve_id("Output", opts, id_factory),
    name = option(opts, "name", "Output"),
    aux_a_send = option(opts, "aux_a_send", 0),
    aux_b_send = option(opts, "aux_b_send", 0),
    -- This reference is deliberately optional. The REAPER destination is
    -- created lazily when the logical output is first assigned/used.
    reaper_destination = option(opts, "reaper_destination", false),
  }
end

function M.new_round_robin_group(opts, id_factory)
  opts = opts or {}
  return {
    type = "RoundRobinGroup",
    id = resolve_id("RoundRobinGroup", opts, id_factory),
    master_pad_id = option(opts, "master_pad_id", ""),
    member_pad_ids = option(opts, "member_pad_ids", {}),
    mode = option(opts, "mode", "sequential"),
    probability = option(opts, "probability", 100),
    reset_policy = option(opts, "reset_policy", "pattern"),
    advance_on_skip = option(opts, "advance_on_skip", false),
    advance_each_repeat = option(opts, "advance_each_repeat", false),
    seed = option(opts, "seed", 0),
  }
end

function M.new_rack(opts, id_factory)
  opts = opts or {}
  local factory = id_factory or opts.id_factory
  local pads, groups, patterns, outputs = {}, {}, {}, {}

  for index, pad in ipairs(opts.pads or {}) do
    pads[index] = pad.type == "Pad" and deep_copy(pad) or M.new_pad(pad, factory)
  end
  for index, group in ipairs(opts.round_robin_groups or {}) do
    groups[index] = group.type == "RoundRobinGroup" and deep_copy(group) or M.new_round_robin_group(group, factory)
  end
  for index, pattern in ipairs(opts.patterns or {}) do
    patterns[index] = pattern.type == "Pattern" and deep_copy(pattern) or M.new_pattern(pattern, factory)
  end
  if opts.outputs == nil then
    outputs[1] = M.new_output({ id = "main", name = "Main" })
  else
    for index, output in ipairs(opts.outputs) do
      outputs[index] = output.type == "LogicalOutput" and deep_copy(output) or M.new_output(output, factory)
    end
  end

  local pad_order = opts.pad_order and deep_copy(opts.pad_order) or {}
  if opts.pad_order == nil then
    for index, pad in ipairs(pads) do
      pad_order[index] = pad.id
    end
  end

  return {
    type = "Rack",
    id = resolve_id("Rack", opts, factory),
    schema_version = option(opts, "schema_version", M.SCHEMA_VERSION),
    name = option(opts, "name", "ReaDrum Rack"),
    accent_multiplier = option(opts, "accent_multiplier", 130),
    global_gate_scale = option(opts, "global_gate_scale", 100),
    global_velocity_sensitivity = option(opts, "global_velocity_sensitivity", 100),
    accentuator = option(opts, "accentuator", { enabled = true, amount = 100, bands = { 0, 0, 0, 0 } }),
    selected_bank = option(opts, "selected_bank", 1),
    pad_order = pad_order,
    pads = pads,
    outputs = outputs,
    round_robin_groups = groups,
    patterns = patterns,
  }
end

local interpolation_modes = { step = true, linear = true, smooth = true }

function M.validate_parameter_lock(lock, path)
  path = path or "ParameterLock"
  if type(lock) ~= "table" then
    return fail(path, "expected a ParameterLock table")
  end
  if lock.type ~= nil and lock.type ~= "ParameterLock" then
    return fail(path .. ".type", "expected 'ParameterLock'")
  end
  if not is_non_empty_string(lock.parameter_id) then
    return fail(path .. ".parameter_id", "expected a non-empty registered parameter ID")
  end
  if lock.value == nil then
    return fail(path .. ".value", "must be explicit; nil cannot represent a lock")
  end
  local ok, err = validate_serializable(lock.value, path .. ".value")
  if not ok then
    return nil, err
  end
  if not interpolation_modes[lock.interpolation] then
    return fail(path .. ".interpolation", "expected 'step', 'linear', or 'smooth'")
  end
  return true
end

local no_argument_conditions = {
  always = true,
  first = true,
  not_first = true,
  fill = true,
  not_fill = true,
}

local function validate_condition(condition, path)
  if type(condition) ~= "table" then
    return fail(path, "expected a tagged condition table")
  end
  if not is_non_empty_string(condition.type) then
    return fail(path .. ".type", "expected a non-empty condition type")
  end
  local ok, err = validate_serializable(condition, path)
  if not ok then
    return nil, err
  end

  if condition.type == "every_n" then
    ok, err = validate_number(condition.n, path .. ".n", 1, nil, true)
    if not ok then
      return nil, err
    end
    if condition.offset ~= nil then
      ok, err = validate_number(condition.offset, path .. ".offset", 0, condition.n - 1, true)
      if not ok then
        return nil, err
      end
    end
  elseif condition.type == "previous" then
    if condition.state ~= "hit" and condition.state ~= "miss" then
      return fail(path .. ".state", "expected 'hit' or 'miss'")
    end
    if condition.lane_id ~= nil and not is_non_empty_string(condition.lane_id) then
      return fail(path .. ".lane_id", "expected a non-empty lane ID")
    end
  elseif not no_argument_conditions[condition.type] then
    -- Unknown tagged conditions are intentionally retained for forward-compatible
    -- evaluators; serializability and the stable type tag are still enforced.
  end
  return true
end

local function validate_registered_property(value, path, definition)
  if definition.value_type == "boolean" then
    return validate_boolean(value, path)
  elseif definition.value_type == "integer" then
    return validate_number(value, path, definition.minimum, definition.maximum, true)
  elseif definition.value_type == "number" then
    return validate_number(value, path, definition.minimum, definition.maximum, false)
  elseif definition.value_type == "string" then
    if type(value) ~= "string" then return fail(path, "expected a string") end
    return true
  elseif definition.value_type == "rational" then
    return validate_rational(value, path, true)
  elseif definition.value_type == "condition" then
    return validate_condition(value, path)
  elseif definition.value_type == "integer_or_false" then
    if value == false then return true end
    return validate_number(value, path, definition.minimum, definition.maximum, true)
  end
  return validate_serializable(value, path)
end

function M.validate_step(step, path)
  path = path or "Step"
  if type(step) ~= "table" then
    return fail(path, "expected a Step table")
  end
  if step.type ~= nil and step.type ~= "Step" then
    return fail(path .. ".type", "expected 'Step'")
  end

  local validators = {
    enabled = function(value, child) return validate_boolean(value, child) end,
    velocity = function(value, child) return validate_number(value, child, 1, 127, true) end,
    pitch_semitones = function(value, child) return validate_number(value, child, -96, 96, true) end,
    pitch_cents = function(value, child) return validate_number(value, child, -100, 100, true) end,
    pan_lock = function(value, child)
      if value == false then return true end
      return validate_number(value, child, -100, 100, true)
    end,
    repeat_count = function(value, child) return validate_number(value, child, 1, 64, true) end,
    repeat_spacing = function(value, child) return validate_rational(value, child, true) end,
    probability = function(value, child) return validate_number(value, child, 0, 100, false) end,
    timing_offset = function(value, child) return validate_number(value, child, -960, 960, true) end,
    gate = function(value, child) return validate_number(value, child, 0, 1600, false) end,
    condition = validate_condition,
  }

  if step.accent == nil then step.accent = false end
  local accent_ok, accent_err = validate_boolean(step.accent, path .. ".accent")
  if not accent_ok then return nil, accent_err end
  if step.cut == nil then step.cut = false end
  local cut_ok, cut_err = validate_boolean(step.cut, path .. ".cut")
  if not cut_ok then return nil, cut_err end
  if step.slide == nil then step.slide = false end
  local slide_ok, slide_err = validate_boolean(step.slide, path .. ".slide")
  if not slide_ok then return nil, slide_err end

  for _, property_id in ipairs(STEP_PROPERTY_ORDER) do
    if step[property_id] == nil then
      return fail(path .. "." .. property_id, "missing complete Step property")
    end
    if property_id ~= "parameter_locks" then
      local validator = validators[property_id]
      local ok, err
      if validator then
        ok, err = validator(step[property_id], path .. "." .. property_id)
      else
        ok, err = validate_registered_property(
          step[property_id],
          path .. "." .. property_id,
          STEP_PROPERTY_REGISTRY[property_id]
        )
      end
      if not ok then
        return nil, err
      end
    end
  end

  local ok, err = validate_array(step.parameter_locks, path .. ".parameter_locks")
  if not ok then
    return nil, err
  end
  local seen_locks = {}
  for index, lock in ipairs(step.parameter_locks) do
    ok, err = M.validate_parameter_lock(lock, path .. ".parameter_locks[" .. index .. "]")
    if not ok then
      return nil, err
    end
    if seen_locks[lock.parameter_id] then
      return fail(path .. ".parameter_locks[" .. index .. "].parameter_id", "duplicate lock for '" .. lock.parameter_id .. "'")
    end
    seen_locks[lock.parameter_id] = true
  end
  return true
end

function M.validate_lane(lane, path)
  path = path or "Lane"
  if type(lane) ~= "table" then return fail(path, "expected a Lane table") end
  if lane.type ~= nil and lane.type ~= "Lane" then return fail(path .. ".type", "expected 'Lane'") end
  local ok, err = validate_id(lane.id, path .. ".id")
  if not ok then return nil, err end
  ok, err = validate_id(lane.pad_id, path .. ".pad_id")
  if not ok then return nil, err end
  ok, err = validate_number(lane.step_count, path .. ".step_count", 1, 4096, true)
  if not ok then return nil, err end
  ok, err = validate_number(lane.division_num, path .. ".division_num", 1, nil, true)
  if not ok then return nil, err end
  ok, err = validate_number(lane.division_den, path .. ".division_den", 1, nil, true)
  if not ok then return nil, err end
  ok, err = validate_number(lane.phase, path .. ".phase", 0, lane.step_count - 1, true)
  if not ok then return nil, err end
  ok, err = validate_number(lane.swing, path .. ".swing", -100, 100, false)
  if not ok then return nil, err end
  lane.gate_scale=tonumber(lane.gate_scale) or 100
  lane.velocity_humanize=tonumber(lane.velocity_humanize) or 0
  lane.timing_humanize=tonumber(lane.timing_humanize) or 0
  lane.pitch_humanize=tonumber(lane.pitch_humanize) or 0
  lane.pan_humanize=tonumber(lane.pan_humanize) or 0
  ok, err = validate_number(lane.timing_offset == nil and 0 or lane.timing_offset, path .. ".timing_offset", -120, 120, true)
  if not ok then return nil, err end
  ok, err = validate_number(lane.velocity_scale == nil and 100 or lane.velocity_scale, path .. ".velocity_scale", 25, 200, true)
  if not ok then return nil, err end
  ok, err = validate_number(lane.velocity_sensitivity == nil and 100 or lane.velocity_sensitivity, path .. ".velocity_sensitivity", 0, 200, false)
  if not ok then return nil, err end
  ok, err = validate_boolean(lane.accentuator_enabled == nil and false or lane.accentuator_enabled, path .. ".accentuator_enabled")
  if not ok then return nil, err end
  for _,key in ipairs({"global_swing_enabled","global_gate_enabled","global_velocity_sensitivity_enabled","global_velocity_humanize_enabled"}) do
    if lane[key]==nil then lane[key]=true end
    ok,err=validate_boolean(lane[key],path.."."..key)
    if not ok then return nil,err end
  end
  ok, err = validate_number(lane.gate_scale, path .. ".gate_scale", 0, 200, false)
  if not ok then return nil, err end
  ok, err = validate_number(lane.velocity_humanize, path .. ".velocity_humanize", 0, 100, false)
  if not ok then return nil, err end
  ok, err = validate_number(lane.timing_humanize, path .. ".timing_humanize", 0, 100, false)
  if not ok then return nil, err end
  ok, err = validate_number(lane.pitch_humanize, path .. ".pitch_humanize", 0, 100, false)
  if not ok then return nil, err end
  ok, err = validate_number(lane.pan_humanize, path .. ".pan_humanize", 0, 100, false)
  if not ok then return nil, err end
  if type(lane.defaults) ~= "table" then return fail(path .. ".defaults", "expected a defaults table") end
  ok, err = validate_serializable(lane.defaults, path .. ".defaults")
  if not ok then return nil, err end
  ok, err = validate_array(lane.steps, path .. ".steps")
  if not ok then return nil, err end
  if #lane.steps ~= lane.step_count then
    return fail(path .. ".steps", "expected exactly step_count (" .. lane.step_count .. ") complete steps, got " .. #lane.steps)
  end
  for index, step in ipairs(lane.steps) do
    ok, err = M.validate_step(step, path .. ".steps[" .. index .. "]")
    if not ok then return nil, err end
  end
  return true
end

function M.validate_variation(variation, path)
  path = path or "Variation"
  if type(variation) ~= "table" then return fail(path, "expected a Variation table") end
  if variation.type ~= nil and variation.type ~= "Variation" then return fail(path .. ".type", "expected 'Variation'") end
  local ok, err = validate_id(variation.id, path .. ".id")
  if not ok then return nil, err end
  if not is_non_empty_string(variation.name) then return fail(path .. ".name", "expected a non-empty name") end
  if type(variation.switch_quantization) == "table" then
    ok, err = validate_rational(variation.switch_quantization, path .. ".switch_quantization")
    if not ok then return nil, err end
  elseif not is_non_empty_string(variation.switch_quantization) then
    return fail(path .. ".switch_quantization", "expected a named or rational quantization")
  end
  variation.velocity_humanize=tonumber(variation.velocity_humanize) or 0
  variation.timing_humanize=tonumber(variation.timing_humanize) or 0
  variation.pitch_humanize=tonumber(variation.pitch_humanize) or 0
  variation.pan_humanize=tonumber(variation.pan_humanize) or 0
  -- Legacy projects could store reverse global swing. The current global
  -- control is an amount, so migrate those values safely to the straight grid.
  variation.swing=math.max(0,tonumber(variation.swing) or 0)
  ok, err = validate_number(variation.swing, path .. ".swing", 0, 100, false)
  if not ok then return nil, err end
  if variation.groove~=nil then
    local groove=variation.groove
    if type(groove)~="table" then return fail(path..".groove","expected a groove table") end
    if not is_non_empty_string(groove.name) then return fail(path..".groove.name","expected a non-empty name") end
    if groove.source~=nil and type(groove.source)~="string" then return fail(path..".groove.source","expected a string") end
    for _,key in ipairs({"grid_num","grid_den","cycle_steps"})do
      ok,err=validate_number(groove[key],path..".groove."..key,1,key=="cycle_steps"and 256 or 2147483647,true)
      if not ok then return nil,err end
    end
    if type(groove.timing_offsets)~="table" or #groove.timing_offsets~=groove.cycle_steps then return fail(path..".groove.timing_offsets","expected one offset per cycle step") end
    for index,value in ipairs(groove.timing_offsets)do
      ok,err=validate_number(value,path..".groove.timing_offsets["..index.."]",-960,960,true)
      if not ok then return nil,err end
    end
  end
  ok, err = validate_number(variation.velocity_humanize, path .. ".velocity_humanize", 0, 100, false)
  if not ok then return nil, err end
  ok, err = validate_number(variation.timing_humanize, path .. ".timing_humanize", 0, 100, false)
  if not ok then return nil, err end
  ok, err = validate_number(variation.pitch_humanize, path .. ".pitch_humanize", 0, 100, false)
  if not ok then return nil, err end
  ok, err = validate_number(variation.pan_humanize, path .. ".pan_humanize", 0, 100, false)
  if not ok then return nil, err end
  ok, err = validate_array(variation.lanes, path .. ".lanes")
  if not ok then return nil, err end
  local ids, pad_ids = {}, {}
  for index, lane in ipairs(variation.lanes) do
    ok, err = M.validate_lane(lane, path .. ".lanes[" .. index .. "]")
    if not ok then return nil, err end
    if ids[lane.id] then return fail(path .. ".lanes[" .. index .. "].id", "duplicate lane ID '" .. lane.id .. "'") end
    if pad_ids[lane.pad_id] then return fail(path .. ".lanes[" .. index .. "].pad_id", "duplicate lane binding for pad '" .. lane.pad_id .. "'") end
    ids[lane.id], pad_ids[lane.pad_id] = true, true
  end
  return true
end

function M.validate_pattern(pattern, path)
  path = path or "Pattern"
  if type(pattern) ~= "table" then return fail(path, "expected a Pattern table") end
  if pattern.type ~= nil and pattern.type ~= "Pattern" then return fail(path .. ".type", "expected 'Pattern'") end
  local ok, err = validate_id(pattern.id, path .. ".id")
  if not ok then return nil, err end
  if not is_non_empty_string(pattern.name) then return fail(path .. ".name", "expected a non-empty name") end
  ok, err = validate_number(pattern.seed, path .. ".seed", 0, 2147483647, true)
  if not ok then return nil, err end
  ok, err = validate_array(pattern.variations, path .. ".variations")
  if not ok then return nil, err end
  local ids = {}
  for index, variation in ipairs(pattern.variations) do
    ok, err = M.validate_variation(variation, path .. ".variations[" .. index .. "]")
    if not ok then return nil, err end
    if ids[variation.id] then return fail(path .. ".variations[" .. index .. "].id", "duplicate variation ID '" .. variation.id .. "'") end
    ids[variation.id] = true
  end
  return true
end

function M.validate_pad(pad, path)
  path = path or "Pad"
  if type(pad) ~= "table" then return fail(path, "expected a Pad table") end
  if pad.type ~= nil and pad.type ~= "Pad" then return fail(path .. ".type", "expected 'Pad'") end
  local ok, err = validate_id(pad.id, path .. ".id")
  if not ok then return nil, err end
  ok, err = validate_number(pad.logical_index, path .. ".logical_index", 1, 128, true)
  if not ok then return nil, err end
  if not is_non_empty_string(pad.name) then return fail(path .. ".name", "expected a non-empty name") end
  if pad.sample ~= false and type(pad.sample) ~= "string" and type(pad.sample) ~= "table" then
    return fail(path .. ".sample", "expected false, a path string, or sample descriptor table")
  end
  ok, err = validate_serializable(pad.sample, path .. ".sample")
  if not ok then return nil, err end
  if type(pad.color) ~= "string" and type(pad.color) ~= "table" then
    return fail(path .. ".color", "expected a color string or descriptor table")
  end
  ok, err = validate_serializable(pad.color, path .. ".color")
  if not ok then return nil, err end
  if pad.choke_group ~= false then
    ok, err = validate_number(pad.choke_group, path .. ".choke_group", 1, 32, true)
    if not ok then return nil, err end
  end
  ok, err = validate_unique_strings(pad.simultaneous_play_targets, path .. ".simultaneous_play_targets", 4)
  if not ok then return nil, err end
  ok, err = validate_unique_strings(pad.mute_targets, path .. ".mute_targets", 4)
  if not ok then return nil, err end
  ok, err = validate_number(pad.polyphony, path .. ".polyphony", 1, 128, true)
  if not ok then return nil, err end
  ok, err = validate_boolean(pad.self_choke, path .. ".self_choke")
  if not ok then return nil, err end
  ok, err = validate_boolean(pad.muted == nil and false or pad.muted, path .. ".muted")
  if not ok then return nil, err end
  ok, err = validate_boolean(pad.soloed == nil and false or pad.soloed, path .. ".soloed")
  if not ok then return nil, err end
  if not is_non_empty_string(pad.output_id) then return fail(path .. ".output_id", "expected a non-empty logical output ID") end
  for _, field in ipairs({ "default_controls", "reaper_object_refs" }) do
    if type(pad[field]) ~= "table" then return fail(path .. "." .. field, "expected a table") end
    ok, err = validate_serializable(pad[field], path .. "." .. field)
    if not ok then return nil, err end
  end
  return true
end

function M.validate_output(output, path)
  path = path or "LogicalOutput"
  if type(output) ~= "table" then return fail(path, "expected a LogicalOutput table") end
  if output.type ~= nil and output.type ~= "LogicalOutput" then return fail(path .. ".type", "expected 'LogicalOutput'") end
  local ok, err = validate_id(output.id, path .. ".id")
  if not ok then return nil, err end
  if not is_non_empty_string(output.name) then return fail(path .. ".name", "expected a non-empty name") end
  output.aux_a_send=tonumber(output.aux_a_send) or 0
  output.aux_b_send=tonumber(output.aux_b_send) or 0
  ok, err = validate_number(output.aux_a_send, path .. ".aux_a_send", 0, 1, false)
  if not ok then return nil, err end
  ok, err = validate_number(output.aux_b_send, path .. ".aux_b_send", 0, 1, false)
  if not ok then return nil, err end
  if output.reaper_destination ~= false and type(output.reaper_destination) ~= "table" then
    return fail(path .. ".reaper_destination", "expected false or a serializable destination descriptor")
  end
  return validate_serializable(output.reaper_destination, path .. ".reaper_destination")
end

local round_robin_modes = { sequential = true, ping_pong = true, random = true, random_no_repeat = true }
local reset_policies = { never = true, pattern = true, transport = true, trigger = true }

function M.validate_round_robin_group(group, path)
  path = path or "RoundRobinGroup"
  if type(group) ~= "table" then return fail(path, "expected a RoundRobinGroup table") end
  if group.type ~= nil and group.type ~= "RoundRobinGroup" then return fail(path .. ".type", "expected 'RoundRobinGroup'") end
  local ok, err = validate_id(group.id, path .. ".id")
  if not ok then return nil, err end
  ok, err = validate_id(group.master_pad_id, path .. ".master_pad_id")
  if not ok then return nil, err end
  ok, err = validate_unique_strings(group.member_pad_ids, path .. ".member_pad_ids")
  if not ok then return nil, err end
  if #group.member_pad_ids < 1 then return fail(path .. ".member_pad_ids", "expected at least one member pad") end
  local master_is_member = false
  for _, member_pad_id in ipairs(group.member_pad_ids) do
    if member_pad_id == group.master_pad_id then
      master_is_member = true
      break
    end
  end
  if not master_is_member then
    return fail(path .. ".master_pad_id", "must also appear in member_pad_ids")
  end
  if not round_robin_modes[group.mode] then
    return fail(path .. ".mode", "expected sequential, ping_pong, random, or random_no_repeat")
  end
  ok, err = validate_number(group.probability, path .. ".probability", 0, 100, false)
  if not ok then return nil, err end
  if not reset_policies[group.reset_policy] then
    return fail(path .. ".reset_policy", "expected never, pattern, transport, or trigger")
  end
  ok, err = validate_boolean(group.advance_on_skip, path .. ".advance_on_skip")
  if not ok then return nil, err end
  ok, err = validate_boolean(group.advance_each_repeat, path .. ".advance_each_repeat")
  if not ok then return nil, err end
  return validate_number(group.seed, path .. ".seed", 0, 2147483647, true)
end

function M.validate_rack(rack, path)
  path = path or "Rack"
  if type(rack) ~= "table" then return fail(path, "expected a Rack table") end
  if rack.type ~= nil and rack.type ~= "Rack" then return fail(path .. ".type", "expected 'Rack'") end
  local ok, err = validate_id(rack.id, path .. ".id")
  if not ok then return nil, err end
  if rack.schema_version ~= M.SCHEMA_VERSION then
    return fail(path .. ".schema_version", "unsupported schema version " .. tostring(rack.schema_version) .. "; expected " .. M.SCHEMA_VERSION)
  end
  if not is_non_empty_string(rack.name) then return fail(path .. ".name", "expected a non-empty name") end
  if rack.accent_multiplier == nil then rack.accent_multiplier = 130 end
  ok, err = validate_number(rack.accent_multiplier, path .. ".accent_multiplier", 100, 200, false)
  if not ok then return nil, err end
  if rack.global_gate_scale == nil then rack.global_gate_scale = 100 end
  ok, err = validate_number(rack.global_gate_scale, path .. ".global_gate_scale", 0, 200, false)
  if not ok then return nil, err end
  if rack.global_velocity_sensitivity == nil then rack.global_velocity_sensitivity = 100 end
  ok, err = validate_number(rack.global_velocity_sensitivity, path .. ".global_velocity_sensitivity", 0, 200, false)
  if not ok then return nil, err end
  if type(rack.accentuator) ~= "table" then rack.accentuator = { enabled = true, amount = 100, bands = { 0, 0, 0, 0 } } end
  if rack.accentuator.enabled == nil then rack.accentuator.enabled = true end
  ok, err = validate_boolean(rack.accentuator.enabled, path .. ".accentuator.enabled")
  if not ok then return nil, err end
  rack.accentuator.amount = tonumber(rack.accentuator.amount) or 100
  ok, err = validate_number(rack.accentuator.amount, path .. ".accentuator.amount", 0, 200, false)
  if not ok then return nil, err end
  if type(rack.accentuator.bands) ~= "table" then rack.accentuator.bands = { 0, 0, 0, 0 } end
  for i=1,4 do
    rack.accentuator.bands[i] = tonumber(rack.accentuator.bands[i]) or 0
    ok, err = validate_number(rack.accentuator.bands[i], path .. ".accentuator.bands[" .. i .. "]", -100, 100, false)
    if not ok then return nil, err end
  end
  ok, err = validate_number(rack.selected_bank, path .. ".selected_bank", 1, 8, true)
  if not ok then return nil, err end
  ok, err = validate_array(rack.pads, path .. ".pads")
  if not ok then return nil, err end
  if #rack.pads > 128 then return fail(path .. ".pads", "expected at most 128 populated pads") end

  local pad_ids, logical_indices = {}, {}
  for index, pad in ipairs(rack.pads) do
    ok, err = M.validate_pad(pad, path .. ".pads[" .. index .. "]")
    if not ok then return nil, err end
    if pad_ids[pad.id] then return fail(path .. ".pads[" .. index .. "].id", "duplicate pad ID '" .. pad.id .. "'") end
    if logical_indices[pad.logical_index] then
      return fail(path .. ".pads[" .. index .. "].logical_index", "logical pad index is already occupied")
    end
    pad_ids[pad.id], logical_indices[pad.logical_index] = true, true
  end


  ok, err = validate_array(rack.outputs, path .. ".outputs")
  if not ok then return nil, err end
  if #rack.outputs < 1 or #rack.outputs > 16 then return fail(path .. ".outputs", "expected 1 to 16 logical outputs") end
  local output_ids = {}
  for index, output in ipairs(rack.outputs) do
    ok, err = M.validate_output(output, path .. ".outputs[" .. index .. "]")
    if not ok then return nil, err end
    if output_ids[output.id] then return fail(path .. ".outputs[" .. index .. "].id", "duplicate logical output ID '" .. output.id .. "'") end
    output_ids[output.id] = true
  end
  for index, pad in ipairs(rack.pads) do
    if not output_ids[pad.output_id] then
      return fail(path .. ".pads[" .. index .. "].output_id", "references unknown logical output ID '" .. pad.output_id .. "'")
    end
  end

  ok, err = validate_unique_strings(rack.pad_order, path .. ".pad_order", 128)
  if not ok then return nil, err end
  if #rack.pad_order ~= #rack.pads then
    return fail(path .. ".pad_order", "must contain every populated pad exactly once")
  end
  for index, pad_id in ipairs(rack.pad_order) do
    if not pad_ids[pad_id] then return fail(path .. ".pad_order[" .. index .. "]", "references unknown pad ID '" .. pad_id .. "'") end
  end

  for index, pad in ipairs(rack.pads) do
    for _, relationship in ipairs({ "simultaneous_play_targets", "mute_targets" }) do
      for target_index, target_id in ipairs(pad[relationship]) do
        local target_path = path .. ".pads[" .. index .. "]." .. relationship .. "[" .. target_index .. "]"
        if target_id == pad.id then return fail(target_path, "a pad cannot target itself") end
        if not pad_ids[target_id] then return fail(target_path, "references unknown pad ID '" .. target_id .. "'") end
      end
    end
  end

  ok, err = validate_array(rack.round_robin_groups, path .. ".round_robin_groups")
  if not ok then return nil, err end
  local group_ids = {}
  for index, group in ipairs(rack.round_robin_groups) do
    local group_path = path .. ".round_robin_groups[" .. index .. "]"
    ok, err = M.validate_round_robin_group(group, group_path)
    if not ok then return nil, err end
    if group_ids[group.id] then return fail(group_path .. ".id", "duplicate round-robin group ID '" .. group.id .. "'") end
    group_ids[group.id] = true
    if not pad_ids[group.master_pad_id] then return fail(group_path .. ".master_pad_id", "references unknown pad ID '" .. group.master_pad_id .. "'") end
    for member_index, member_id in ipairs(group.member_pad_ids) do
      if not pad_ids[member_id] then
        return fail(group_path .. ".member_pad_ids[" .. member_index .. "]", "references unknown pad ID '" .. member_id .. "'")
      end
    end
  end

  ok, err = validate_array(rack.patterns, path .. ".patterns")
  if not ok then return nil, err end
  local pattern_ids = {}
  for pattern_index, pattern in ipairs(rack.patterns) do
    local pattern_path = path .. ".patterns[" .. pattern_index .. "]"
    ok, err = M.validate_pattern(pattern, pattern_path)
    if not ok then return nil, err end
    if pattern_ids[pattern.id] then return fail(pattern_path .. ".id", "duplicate pattern ID '" .. pattern.id .. "'") end
    pattern_ids[pattern.id] = true
    for variation_index, variation in ipairs(pattern.variations) do
      for lane_index, lane in ipairs(variation.lanes) do
        if not pad_ids[lane.pad_id] then
          return fail(pattern_path .. ".variations[" .. variation_index .. "].lanes[" .. lane_index .. "].pad_id",
            "references unknown pad ID '" .. lane.pad_id .. "'")
        end
      end
    end
  end
  return true
end

function M.validate(entity, path)
  if type(entity) ~= "table" then return fail(path or "Model", "expected a model table") end
  local validators = {
    Rack = M.validate_rack,
    Pad = M.validate_pad,
    RoundRobinGroup = M.validate_round_robin_group,
    Pattern = M.validate_pattern,
    Variation = M.validate_variation,
    Lane = M.validate_lane,
    Step = M.validate_step,
    ParameterLock = M.validate_parameter_lock,
  }
  local validator = validators[entity.type]
  if not validator then return fail(path or "Model", "unknown model type '" .. tostring(entity.type) .. "'") end
  return validator(entity, path or entity.type)
end

function M.assert_valid(entity, path)
  local ok, err = M.validate(entity, path)
  if not ok then error(err, 2) end
  return entity
end

-- Constructor aliases make call sites read naturally while retaining explicit
-- new_* names for code that prefers conventional Lua module APIs.
M.Rack = M.new_rack
M.LogicalOutput = M.new_output
M.Pad = M.new_pad
M.RoundRobinGroup = M.new_round_robin_group
M.Pattern = M.new_pattern
M.Variation = M.new_variation
M.Lane = M.new_lane
M.Step = M.new_step
M.ParameterLock = M.new_parameter_lock

return M
