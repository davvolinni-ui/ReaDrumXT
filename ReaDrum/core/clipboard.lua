local Commands = require("ReaDrum.core.commands")
local Model = require("ReaDrum.core.model")

local Clipboard = {
    FORMAT = "readrum-clipboard",
    SCHEMA_VERSION = 1,
}

Clipboard.SCOPES = {
    selected_steps = true,
    property_lane = true,
    lane = true,
    variation = true,
    pattern = true,
    pad = true,
}

Clipboard.PASTE_MODES = {
    Replace = true,
    Merge = true,
    replace = true,
    merge = true,
}

local property_registry = {}

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

local function replace_contents(destination, source)
    for key in pairs(destination) do
        destination[key] = nil
    end
    for key, value in pairs(source) do
        destination[deep_copy(key)] = deep_copy(value)
    end
end

local function deep_merge(destination, source)
    for key, value in pairs(source) do
        if type(value) == "table" and type(destination[key]) == "table" then
            deep_merge(destination[key], value)
        else
            destination[key] = deep_copy(value)
        end
    end
    return destination
end

local function is_integer(value)
    return type(value) == "number" and value == math.floor(value)
end

local function normalize_mode(mode)
    mode = mode or "Replace"
    if mode == "replace" then
        return "Replace"
    end
    if mode == "merge" then
        return "Merge"
    end
    if mode ~= "Replace" and mode ~= "Merge" then
        error("paste mode must be Replace or Merge", 3)
    end
    return mode
end

local function normalize_property_definition(property_id, definition)
    if type(definition) ~= "table" then
        error("property definition must be a table", 3)
    end
    if definition.default == nil then
        error("property definition requires an explicit default", 3)
    end

    local result = deep_copy(definition)
    local default = deep_copy(definition.default)
    result.get = definition.get or function(step)
        return step[property_id]
    end
    result.set = definition.set or function(step, value)
        step[property_id] = deep_copy(value)
    end
    result.clear = definition.clear or function(step)
        step[property_id] = deep_copy(default)
    end
    return result
end

---Register a property that may be copied and pasted by itself.
---Custom definitions may provide `get(step)`, `set(step, value)`, and
---`clear(step)` callbacks, which also supports property-lock projections.
---@param property_id string
---@param definition table
function Clipboard.register_property(property_id, definition)
    if type(property_id) ~= "string" or property_id == "" then
        error("property id must be a non-empty string", 2)
    end
    property_registry[property_id] =
        normalize_property_definition(property_id, definition)
end

function Clipboard.unregister_property(property_id)
    property_registry[property_id] = nil
end

function Clipboard.is_property_registered(property_id, options)
    local registry = options and
        (options.property_registry or options.registered_properties) or nil
    if registry and registry[property_id] ~= nil then
        return true
    end
    return property_registry[property_id] ~= nil
end

local function resolve_property(property_id, options)
    local registry = options and
        (options.property_registry or options.registered_properties) or nil
    local definition = registry and registry[property_id] or nil
    if definition ~= nil then
        return normalize_property_definition(property_id, definition)
    end
    return property_registry[property_id]
end

for _, definition in ipairs(Model.get_step_property_definitions()) do
    Clipboard.register_property(definition.id, definition)
end

local function validation_failure(message)
    return nil, message
end

local function validate_position_entries(entries, value_field)
    if type(entries) ~= "table" then
        return validation_failure("clipboard payload entries must be a table")
    end
    for index, entry in ipairs(entries) do
        if type(entry) ~= "table" then
            return validation_failure("clipboard entry " .. index .. " must be a table")
        end
        if not is_integer(entry.position) or entry.position < 0 then
            return validation_failure("clipboard entry " .. index
                .. " has an invalid relative position")
        end
        if value_field == "step" and type(entry.step) ~= "table" then
            return validation_failure("clipboard step entry " .. index
                .. " must contain a complete Step table")
        end
        if value_field == "step" then
            local valid, message = Model.validate_step(entry.step,
                "clipboard.payload.steps[" .. index .. "].step")
            if not valid then
                return validation_failure(message)
            end
        end
        if value_field == "value" and entry.value == nil then
            return validation_failure("clipboard property entry " .. index
                .. " must contain a value")
        end
    end
    return true
end

---Validate the table envelope used as the canonical clipboard representation.
---Unsupported schema versions are rejected explicitly. JSON transport can wrap
---this representation later without changing paste semantics.
---@param envelope table
---@param options table|nil
---@return boolean|nil, string|nil
function Clipboard.validate_envelope(envelope, options)
    if type(envelope) ~= "table" then
        return validation_failure("clipboard envelope must be a table")
    end
    if envelope.format ~= Clipboard.FORMAT then
        return validation_failure("unsupported clipboard format")
    end
    if envelope.schema_version ~= Clipboard.SCHEMA_VERSION then
        return validation_failure("unsupported clipboard schema version: "
            .. tostring(envelope.schema_version))
    end
    if not Clipboard.SCOPES[envelope.scope] then
        return validation_failure("unsupported clipboard scope: "
            .. tostring(envelope.scope))
    end
    if type(envelope.payload) ~= "table" then
        return validation_failure("clipboard payload must be a table")
    end

    if envelope.scope == "selected_steps" then
        if not is_integer(envelope.payload.span) or envelope.payload.span < 1 then
            return validation_failure("selected-step payload requires a positive span")
        end
        return validate_position_entries(envelope.payload.steps, "step")
    elseif envelope.scope == "property_lane" then
        if type(envelope.property_id) ~= "string"
            or not Clipboard.is_property_registered(envelope.property_id, options) then
            return validation_failure("property-only payload uses an unregistered property: "
                .. tostring(envelope.property_id))
        end
        if not is_integer(envelope.payload.span) or envelope.payload.span < 1 then
            return validation_failure("property-lane payload requires a positive span")
        end
        local entries_valid, entries_message =
            validate_position_entries(envelope.payload.values, "value")
        if not entries_valid then
            return nil, entries_message
        end
        local definition = resolve_property(envelope.property_id, options)
        for index, entry in ipairs(envelope.payload.values) do
            local step = Model.new_step()
            definition.set(step, deep_copy(entry.value))
            local valid, message = Model.validate_step(step,
                "clipboard.payload.values[" .. index .. "].value")
            if not valid then
                return validation_failure(message)
            end
        end
        return true
    elseif envelope.scope == "lane" then
        if type(envelope.payload.lane) ~= "table" then
            return validation_failure("lane payload requires a lane table")
        end
        local valid, message = Model.validate_lane(envelope.payload.lane,
            "clipboard.payload.lane")
        if not valid then
            return validation_failure(message)
        end
    elseif envelope.scope == "variation" then
        if type(envelope.payload.variation) ~= "table" then
            return validation_failure("variation payload requires a variation table")
        end
        local valid, message = Model.validate_variation(envelope.payload.variation,
            "clipboard.payload.variation")
        if not valid then
            return validation_failure(message)
        end
    elseif envelope.scope == "pattern" then
        if type(envelope.payload.pattern) ~= "table" then
            return validation_failure("pattern payload requires a pattern table")
        end
        local valid, message = Model.validate_pattern(envelope.payload.pattern,
            "clipboard.payload.pattern")
        if not valid then
            return validation_failure(message)
        end
    elseif envelope.scope == "pad" then
        if type(envelope.payload.pad) ~= "table" then
            return validation_failure("pad payload requires a pad table")
        end
        local valid, message = Model.validate_pad(envelope.payload.pad,
            "clipboard.payload.pad")
        if not valid then return validation_failure(message) end
    end

    return true
end

function Clipboard.assert_valid_envelope(envelope, options)
    local valid, message = Clipboard.validate_envelope(envelope, options)
    if not valid then
        error(message, 2)
    end
    return true
end

local function make_envelope(scope, payload, options)
    options = options or {}
    local envelope = {
        format = Clipboard.FORMAT,
        schema_version = Clipboard.SCHEMA_VERSION,
        scope = scope,
        source_context = deep_copy(options.source_context or {}),
        time_origin = options.time_origin,
        payload = deep_copy(payload),
    }
    if options.property_id ~= nil then
        envelope.property_id = options.property_id
    end
    Clipboard.assert_valid_envelope(envelope, options)
    return envelope
end

local function step_table(source)
    if type(source) ~= "table" then
        error("step source must be a table", 3)
    end
    if type(source.steps) == "table" then
        return source.steps
    end
    return source
end

local function requested_positions(source, options)
    if options and options.positions ~= nil then
        if type(options.positions) ~= "table" then
            error("positions must be a table", 3)
        end
        return options.positions
    end

    local positions = {}
    for key in pairs(step_table(source)) do
        local position = tonumber(key)
        if is_integer(position) then
            positions[#positions + 1] = position
        end
    end
    table.sort(positions)
    return positions
end

local function lookup_step(source, position)
    local steps = step_table(source)
    local direct = steps[position]
    if direct ~= nil then
        if type(direct) == "table" and direct.position ~= nil and direct.step ~= nil then
            return direct.step, direct.position
        end
        return direct, position
    end

    for _, entry in ipairs(steps) do
        if type(entry) == "table" and entry.position == position then
            return entry.step, entry.position
        end
    end
    return nil, position
end

local function collect_steps(source, options)
    local raw = step_table(source)
    local collected = {}

    if options and options.positions ~= nil then
        for _, requested_position in ipairs(requested_positions(source, options)) do
            local step, position = lookup_step(source, requested_position)
            if type(step) == "table" then
                collected[#collected + 1] = { position = position, step = step }
            end
        end
    else
        for key, value in pairs(raw) do
            if type(value) == "table" and value.position ~= nil and value.step ~= nil then
                collected[#collected + 1] = {
                    position = value.position,
                    step = value.step,
                }
            else
                local position = tonumber(key)
                if is_integer(position) and type(value) == "table" then
                    collected[#collected + 1] = {
                        position = position,
                        step = value,
                    }
                end
            end
        end
    end

    table.sort(collected, function(left, right)
        return left.position < right.position
    end)
    return collected
end

local function copy_origin_and_span(entries, source, options)
    options = options or {}
    local first = entries[1] and entries[1].position or nil
    local last = entries[#entries] and entries[#entries].position or nil
    local origin = options.time_origin
    if origin == nil then
        origin = first or 0
    end

    local span = options.span
    if span == nil and options.positions == nil and type(source.step_count) == "number" then
        span = source.step_count
    end
    if span == nil and first ~= nil then
        span = last - origin + 1
    end
    if not is_integer(span) or span < 1 then
        error("copy requires at least one position or an explicit positive span", 3)
    end
    return origin, span
end

---Copy sparse complete Step objects relative to an origin.
---@param source table lane, position->Step map, or entry list
---@param options table|nil positions, time_origin, span, source_context
---@return table
function Clipboard.copy_selected_steps(source, options)
    options = options or {}
    local collected = collect_steps(source, options)
    local origin, span = copy_origin_and_span(collected, source, options)
    local entries = {}
    for _, entry in ipairs(collected) do
        local relative_position = entry.position - origin
        if relative_position < 0 then
            error("selected step precedes the clipboard time origin", 2)
        end
        entries[#entries + 1] = {
            position = relative_position,
            step = deep_copy(entry.step),
        }
    end

    local envelope_options = deep_copy(options)
    envelope_options.time_origin = origin
    return make_envelope("selected_steps", {
        span = span,
        steps = entries,
    }, envelope_options)
end

---Copy one registered property without copying note state or other properties.
---@param source table lane or position->Step map
---@param property_id string
---@param options table|nil
---@return table
function Clipboard.copy_property_lane(source, property_id, options)
    options = options or {}
    local definition = resolve_property(property_id, options)
    if not definition then
        error("property is not registered: " .. tostring(property_id), 2)
    end

    local collected = collect_steps(source, options)
    local origin, span = copy_origin_and_span(collected, source, options)
    local values = {}
    for _, entry in ipairs(collected) do
        local value = definition.get(entry.step)
        if value ~= nil then
            values[#values + 1] = {
                position = entry.position - origin,
                value = deep_copy(value),
            }
        end
    end

    local envelope_options = deep_copy(options)
    envelope_options.time_origin = origin
    envelope_options.property_id = property_id
    return make_envelope("property_lane", {
        span = span,
        values = values,
        units = deep_copy(definition.unit),
        value_type = definition.value_type,
    }, envelope_options)
end

function Clipboard.copy_lane(lane, options)
    if type(lane) ~= "table" then
        error("lane copy requires a lane table", 2)
    end
    return make_envelope("lane", { lane = deep_copy(lane) }, options)
end

function Clipboard.copy_variation(variation, options)
    if type(variation) ~= "table" then
        error("variation copy requires a variation table", 2)
    end
    return make_envelope("variation", {
        variation = deep_copy(variation),
    }, options)
end

function Clipboard.copy_pattern(pattern, options)
    if type(pattern) ~= "table" then
        error("pattern copy requires a pattern table", 2)
    end
    return make_envelope("pattern", {
        pattern = deep_copy(pattern),
    }, options)
end

function Clipboard.copy_pad(pad, options)
    if type(pad) ~= "table" then error("pad copy requires a pad table", 2) end
    return make_envelope("pad", { pad = deep_copy(pad) }, options)
end

function Clipboard.copy(scope, source, options)
    if scope == "selected_steps" then
        return Clipboard.copy_selected_steps(source, options)
    elseif scope == "property_lane" then
        if not options or not options.property_id then
            error("property_lane copy requires options.property_id", 2)
        end
        return Clipboard.copy_property_lane(source, options.property_id, options)
    elseif scope == "lane" then
        return Clipboard.copy_lane(source, options)
    elseif scope == "variation" then
        return Clipboard.copy_variation(source, options)
    elseif scope == "pattern" then
        return Clipboard.copy_pattern(source, options)
    elseif scope == "pad" then
        return Clipboard.copy_pad(source, options)
    end
    error("unsupported clipboard scope: " .. tostring(scope), 2)
end

local function call_id_factory(factory, kind, previous_id)
    if type(factory) == "function" then
        local id = factory(kind, previous_id)
        if id == nil then
            error("id factory returned nil for " .. kind, 3)
        end
        return id
    end
    if type(factory) == "table" then
        local method = factory.next or factory.create or factory.new_id
        if type(method) == "function" then
            local id = method(factory, kind, previous_id)
            if id == nil then
                error("id factory returned nil for " .. kind, 3)
            end
            return id
        end
    end
    error("lane and variation paste require an injected id_factory", 3)
end

local function selected_steps_result(envelope, destination, options, mode)
    local result = deep_copy(destination)
    result.steps = result.steps or {}
    local origin = options.destination_origin or options.position or 1
    if not is_integer(origin) then
        error("destination origin must be an integer", 3)
    end
    if is_integer(result.step_count)
        and origin + envelope.payload.span - 1 > result.step_count then
        error("selected-step paste exceeds destination lane length", 3)
    end

    if mode == "Replace" then
        for offset = 0, envelope.payload.span - 1 do
            result.steps[origin + offset] = Model.new_step()
        end
    end
    for _, entry in ipairs(envelope.payload.steps) do
        result.steps[origin + entry.position] = deep_copy(entry.step)
    end
    return result
end

local function property_lane_result(envelope, destination, options, mode)
    local definition = resolve_property(envelope.property_id, options)
    if not definition then
        error("property is not registered: " .. tostring(envelope.property_id), 3)
    end

    local result = deep_copy(destination)
    result.steps = result.steps or {}
    local origin = options.destination_origin or options.position or 1
    if not is_integer(origin) then
        error("destination origin must be an integer", 3)
    end
    if is_integer(result.step_count)
        and origin + envelope.payload.span - 1 > result.step_count then
        error("property-lane paste exceeds destination lane length", 3)
    end

    if mode == "Replace" then
        for offset = 0, envelope.payload.span - 1 do
            local step = result.steps[origin + offset]
            if type(step) == "table" then
                definition.clear(step)
            end
        end
    end

    for _, entry in ipairs(envelope.payload.values) do
        local destination_position = origin + entry.position
        local step = result.steps[destination_position]
        if type(step) ~= "table" then
            step = Model.new_step()
            result.steps[destination_position] = step
        end
        definition.set(step, deep_copy(entry.value))
    end
    return result
end

local function normalize_lane_steps(lane)
    if type(lane) ~= "table" or not is_integer(lane.step_count)
        or lane.step_count < 1 then
        return lane
    end
    lane.steps = lane.steps or {}
    for index = 1, lane.step_count do
        if type(lane.steps[index]) ~= "table" then
            lane.steps[index] = Model.new_step()
        end
    end
    local stale = {}
    for key in pairs(lane.steps) do
        if is_integer(key) and (key < 1 or key > lane.step_count) then
            stale[#stale + 1] = key
        end
    end
    for _, key in ipairs(stale) do
        lane.steps[key] = nil
    end
    return lane
end

local function lane_result(envelope, destination, options, mode)
    local copied_lane = deep_copy(envelope.payload.lane)
    local result
    if mode == "Merge" then
        result = deep_merge(deep_copy(destination), copied_lane)
    else
        result = copied_lane
    end

    if not options.clone_binding and destination.pad_id ~= nil then
        result.pad_id = destination.pad_id
    end
    result.id = call_id_factory(options.id_factory, "lane", copied_lane.id)
    return normalize_lane_steps(result)
end

local function variation_result(envelope, destination, options, mode)
    local copied_variation = deep_copy(envelope.payload.variation)
    local result
    if mode == "Merge" then
        result = deep_merge(deep_copy(destination), copied_variation)
    else
        result = copied_variation
    end

    result.id = call_id_factory(options.id_factory, "variation", copied_variation.id)
    if type(copied_variation.lanes) == "table" then
        result.lanes = result.lanes or {}
        for key, copied_lane in pairs(copied_variation.lanes) do
            if type(copied_lane) == "table" and type(result.lanes[key]) == "table" then
                result.lanes[key].id =
                    call_id_factory(options.id_factory, "lane", copied_lane.id)
                normalize_lane_steps(result.lanes[key])
            end
        end
    end
    return result
end

local function pattern_result(envelope, destination, options, mode)
    local copied_pattern = deep_copy(envelope.payload.pattern)
    local result
    if mode == "Merge" then
        result = deep_merge(deep_copy(destination), copied_pattern)
    else
        result = copied_pattern
    end

    result.id = call_id_factory(options.id_factory, "pattern", copied_pattern.id)
    if type(copied_pattern.variations) == "table" then
        result.variations = result.variations or {}
        for variation_key, copied_variation in pairs(copied_pattern.variations) do
            local result_variation = result.variations[variation_key]
            if type(copied_variation) == "table"
                and type(result_variation) == "table" then
                result_variation.id = call_id_factory(options.id_factory,
                    "variation", copied_variation.id)
                if type(copied_variation.lanes) == "table" then
                    result_variation.lanes = result_variation.lanes or {}
                    for lane_key, copied_lane in pairs(copied_variation.lanes) do
                        local result_lane = result_variation.lanes[lane_key]
                        if type(copied_lane) == "table"
                            and type(result_lane) == "table" then
                            result_lane.id = call_id_factory(options.id_factory,
                                "lane", copied_lane.id)
                            normalize_lane_steps(result_lane)
                        end
                    end
                end
            end
        end
    end
    return result
end

local function build_paste_result(envelope, destination, options, mode)
    if envelope.scope == "selected_steps" then
        return selected_steps_result(envelope, destination, options, mode)
    elseif envelope.scope == "property_lane" then
        return property_lane_result(envelope, destination, options, mode)
    elseif envelope.scope == "lane" then
        return lane_result(envelope, destination, options, mode)
    elseif envelope.scope == "variation" then
        return variation_result(envelope, destination, options, mode)
    elseif envelope.scope == "pattern" then
        return pattern_result(envelope, destination, options, mode)
    end
    error("unsupported clipboard scope: " .. tostring(envelope.scope), 3)
end

local function validate_paste_result(envelope, destination, result)
    local valid, message
    if envelope.scope == "selected_steps" or envelope.scope == "property_lane" then
        if destination.type ~= "Lane" then
            return true
        end
        valid, message = Model.validate_lane(result, "paste.destination")
    elseif envelope.scope == "lane" then
        valid, message = Model.validate_lane(result, "paste.destination")
    elseif envelope.scope == "variation" then
        valid, message = Model.validate_variation(result, "paste.destination")
    elseif envelope.scope == "pattern" then
        valid, message = Model.validate_pattern(result, "paste.destination")
    else
        return true
    end
    if not valid then
        error(message, 3)
    end
    return true
end

---Build one reversible command for the entire paste operation.
---
---The destination table keeps its identity. Its complete pre-paste state is
---restored by one undo, regardless of payload size.
---@param envelope table
---@param destination table
---@param options table|nil mode, destination_origin, id_factory, clone_binding
---@return table command
function Clipboard.make_paste_command(envelope, destination, options)
    if type(destination) ~= "table" then
        error("paste destination must be a table", 2)
    end
    options = options or {}
    Clipboard.assert_valid_envelope(envelope, options)
    local mode = normalize_mode(options.mode)
    local before = deep_copy(destination)
    local after = build_paste_result(envelope, destination, options, mode)
    validate_paste_result(envelope, destination, after)

    local affected_ids = {}
    if destination.id ~= nil then
        affected_ids[#affected_ids + 1] = destination.id
    end
    if after.id ~= nil and after.id ~= destination.id then
        affected_ids[#affected_ids + 1] = after.id
    end

    return Commands.new({
        metadata = {
            kind = "clipboard.paste",
            label = "Paste " .. envelope.scope,
            scope = envelope.scope,
            paste_mode = mode,
            affected_ids = affected_ids,
            coalesce_key = options.coalesce_key,
            source_context = deep_copy(envelope.source_context),
        },
        apply = function()
            replace_contents(destination, after)
        end,
        undo = function()
            replace_contents(destination, before)
        end,
    })
end

---Create and immediately apply a paste command, returning it for undo/history.
function Clipboard.paste(envelope, destination, options)
    local command = Clipboard.make_paste_command(envelope, destination, options)
    command:apply()
    return command
end

Clipboard.deep_copy = deep_copy
Clipboard.validate = Clipboard.validate_envelope
Clipboard.paste_command = Clipboard.make_paste_command

return Clipboard
