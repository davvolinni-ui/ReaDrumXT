local Commands = {}

local function copy_table(value, seen)
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
        result[copy_table(key, seen)] = copy_table(child, seen)
    end
    return result
end

local function assert_command(command, argument_name)
    if type(command) ~= "table"
        or type(command.apply) ~= "function"
        or type(command.undo) ~= "function" then
        error((argument_name or "command") .. " must provide apply and undo functions", 3)
    end
end

local function normalize_metadata(metadata, defaults)
    local result = copy_table(metadata or {})
    for key, value in pairs(defaults or {}) do
        if result[key] == nil then
            result[key] = copy_table(value)
        end
    end
    return result
end

local function invoke(command, method_name, context)
    return command[method_name](command, context)
end

---Create a reversible command.
---
---The supplied callbacks receive `(context, command)`. The returned command is
---stateful: it cannot be applied twice without an undo, or undone before it has
---been applied. A command may be applied again after undo.
---@param spec table
---@return table
function Commands.new(spec)
    if type(spec) ~= "table" then
        error("command specification must be a table", 2)
    end
    if type(spec.apply) ~= "function" then
        error("command specification requires apply", 2)
    end
    if type(spec.undo) ~= "function" then
        error("command specification requires undo", 2)
    end

    local apply_callback = spec.apply
    local undo_callback = spec.undo
    local command = {
        metadata = normalize_metadata(spec.metadata, {
            kind = spec.kind or "command",
            label = spec.label,
            affected_ids = spec.affected_ids or {},
            coalesce_key = spec.coalesce_key,
        }),
        state = "ready",
    }

    function command:apply(context)
        if self.state == "applied" then
            error("command is already applied", 2)
        end
        if self.state == "applying" or self.state == "undoing" then
            error("command is already being mutated", 2)
        end

        local previous_state = self.state
        self.state = "applying"
        local packed = table.pack(pcall(apply_callback, context, self))
        if not packed[1] then
            self.state = previous_state
            error(packed[2], 2)
        end

        self.state = "applied"
        return table.unpack(packed, 2, packed.n)
    end

    function command:undo(context)
        if self.state ~= "applied" then
            error("command is not applied", 2)
        end

        self.state = "undoing"
        local packed = table.pack(pcall(undo_callback, context, self))
        if not packed[1] then
            self.state = "applied"
            error(packed[2], 2)
        end

        self.state = "undone"
        return table.unpack(packed, 2, packed.n)
    end

    function command:can_coalesce_with(other)
        if type(other) ~= "table" or type(other.metadata) ~= "table" then
            return false
        end

        local own_key = self.metadata.coalesce_key
        local other_key = other.metadata.coalesce_key
        if own_key == nil or other_key == nil or own_key ~= other_key then
            return false
        end

        local own_group = self.metadata.coalesce_group or self.metadata.kind
        local other_group = other.metadata.coalesce_group or other.metadata.kind
        return own_group == other_group
    end

    return command
end

---Apply a command using a consistent call convention.
---@param command table
---@param context any
---@return any
function Commands.apply(command, context)
    assert_command(command)
    return invoke(command, "apply", context)
end

---Undo a command using a consistent call convention.
---@param command table
---@param context any
---@return any
function Commands.undo(command, context)
    assert_command(command)
    return invoke(command, "undo", context)
end

local function append_unique(list, included, value)
    if value ~= nil and not included[value] then
        included[value] = true
        list[#list + 1] = value
    end
end

local function transaction_affected_ids(children)
    local result = {}
    local included = {}
    for _, child in ipairs(children) do
        local ids = child.metadata and child.metadata.affected_ids or nil
        if type(ids) == "table" then
            for _, id in ipairs(ids) do
                append_unique(result, included, id)
            end
        end
    end
    return result
end

---Create one command from a list of child commands.
---
---Children apply in order and undo in reverse order. If a child apply fails,
---already-applied children are rolled back before the original error is raised.
---Accepted forms are `transaction(children, metadata)` and
---`transaction({ commands = children, metadata = metadata })`.
---@param children_or_spec table
---@param metadata table|nil
---@return table
function Commands.transaction(children_or_spec, metadata)
    if type(children_or_spec) ~= "table" then
        error("transaction requires a command list", 2)
    end

    local children = children_or_spec
    local transaction_metadata = metadata
    if children_or_spec.commands ~= nil then
        children = children_or_spec.commands
        transaction_metadata = children_or_spec.metadata or metadata
    end
    if type(children) ~= "table" then
        error("transaction commands must be a table", 2)
    end

    local child_copy = {}
    for index, child in ipairs(children) do
        assert_command(child, "transaction command " .. index)
        child_copy[index] = child
    end

    transaction_metadata = normalize_metadata(transaction_metadata, {
        kind = "transaction",
        affected_ids = transaction_affected_ids(child_copy),
    })

    return Commands.new({
        metadata = transaction_metadata,
        apply = function(context)
            local applied_count = 0
            for index, child in ipairs(child_copy) do
                local ok, failure = pcall(invoke, child, "apply", context)
                if not ok then
                    local rollback_errors = {}
                    for rollback_index = applied_count, 1, -1 do
                        local rollback_ok, rollback_failure =
                            pcall(invoke, child_copy[rollback_index], "undo", context)
                        if not rollback_ok then
                            rollback_errors[#rollback_errors + 1] = tostring(rollback_failure)
                        end
                    end

                    local message = "transaction child " .. index .. " failed: " .. tostring(failure)
                    if #rollback_errors > 0 then
                        message = message .. "; rollback failed: "
                            .. table.concat(rollback_errors, "; ")
                    end
                    error(message, 0)
                end
                applied_count = index
            end
        end,
        undo = function(context)
            local undone = {}
            for index = #child_copy, 1, -1 do
                local child = child_copy[index]
                local ok, failure = pcall(invoke, child, "undo", context)
                if not ok then
                    -- Restore the transaction's applied state when possible.
                    for restore_index = #undone, 1, -1 do
                        pcall(invoke, undone[restore_index], "apply", context)
                    end
                    error("transaction undo child " .. index .. " failed: "
                        .. tostring(failure), 0)
                end
                undone[#undone + 1] = child
            end
        end,
    })
end

Commands.create = Commands.new

return Commands
