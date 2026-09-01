-- @noindex
local RoundRobin = {}

local Group = {}
Group.__index = Group

local Prng = {}
Prng.__index = Prng

local MODULUS = 2147483647
local MULTIPLIER = 48271
local PROBABILITY_STEPS = 1000000

local VALID_MODES = {
  sequential = true,
  ping_pong = true,
  random = true,
  random_no_repeat = true,
}

local VALID_RESET_POLICIES = {
  never = true,
  pattern = true,
  transport = true,
  trigger = true,
}

local function is_integer(value)
  return type(value) == "number" and value == math.floor(value)
end

local function validate_seed(seed)
  if not is_integer(seed) then
    error("round-robin seed must be an integer", 3)
  end
  return ((seed - 1) % (MODULUS - 1)) + 1
end

function Prng.new(seed)
  local normalized = validate_seed(seed or 1)
  return setmetatable({ initial_seed = normalized, state = normalized }, Prng)
end

function Prng:next_int()
  self.state = (self.state * MULTIPLIER) % MODULUS
  return self.state
end

function Prng:uniform(count)
  if not is_integer(count) or count < 1 then
    error("PRNG uniform count must be a positive integer", 2)
  end
  return ((self:next_int() - 1) % count) + 1
end

function Prng:reset(seed)
  if seed ~= nil then
    self.initial_seed = validate_seed(seed)
  end
  self.state = self.initial_seed
end

function Prng:get_state()
  return self.state
end

local function normalize_probability(value)
  if value == nil then
    return 1
  end
  if type(value) ~= "number" or value ~= value then
    error("group probability must be a number", 3)
  end
  if value >= 0 and value <= 1 then
    return value
  end
  if value > 1 and value <= 100 then
    return value / 100
  end
  error("group probability must be between 0 and 1, or 0 and 100 percent", 3)
end

local function validate_boolean(value, name, default)
  if value == nil then
    return default
  end
  if type(value) ~= "boolean" then
    error(name .. " must be a boolean", 3)
  end
  return value
end

local function copy_and_validate_members(members)
  if type(members) ~= "table" then
    error("round-robin group members must be an array", 3)
  end

  local count = 0
  local highest = 0
  for key, member in pairs(members) do
    if not is_integer(key) or key < 1 then
      error("round-robin group members must be a dense array", 3)
    end
    if member == nil then
      error("round-robin group members cannot contain nil", 3)
    end
    count = count + 1
    if key > highest then
      highest = key
    end
  end

  if count == 0 then
    error("round-robin group cannot be empty", 3)
  end
  if count ~= highest then
    error("round-robin group members must be a dense array", 3)
  end

  local result = {}
  local seen = {}
  for index = 1, highest do
    local member = rawget(members, index)
    if member == nil then
      error("round-robin group members must be a dense array", 3)
    end
    if seen[member] then
      error("round-robin group cannot contain duplicate members", 3)
    end
    seen[member] = true
    result[index] = member
  end
  return result
end

local function normalize_reset_on(reset_on)
  if reset_on == nil then
    return {}
  end
  if type(reset_on) == "string" then
    return { [reset_on] = true }
  end
  if type(reset_on) ~= "table" then
    error("reset_on must be an event name, array, or set", 3)
  end

  local result = {}
  for key, value in pairs(reset_on) do
    if type(key) == "number" then
      if type(value) ~= "string" or value == "" then
        error("reset_on array values must be event names", 3)
      end
      result[value] = true
    elseif type(key) == "string" then
      if type(value) ~= "boolean" then
        error("reset_on set values must be booleans", 3)
      end
      if value then
        result[key] = true
      end
    else
      error("reset_on contains an invalid key", 3)
    end
  end
  return result
end

local function assignment_copy(assignment)
  if not assignment then
    return nil
  end
  local result = {}
  for key, value in pairs(assignment) do
    result[key] = value
  end
  return result
end

function RoundRobin.new(config)
  if type(config) ~= "table" then
    error("round-robin group config must be a table", 2)
  end

  local mode = config.mode or "sequential"
  if not VALID_MODES[mode] then
    error("invalid round-robin mode: " .. tostring(mode), 2)
  end

  if config.members ~= nil and config.member_pad_ids ~= nil then
    error("provide either members or member_pad_ids, not both", 2)
  end
  local members = config.members or config.member_pad_ids

  local reset_policy = config.reset_policy or "never"
  if not VALID_RESET_POLICIES[reset_policy] then
    error("invalid round-robin reset policy: " .. tostring(reset_policy), 2)
  end

  local validated_members = copy_and_validate_members(members)
  if config.master_pad_id ~= nil then
    local master_is_member = false
    for _, member in ipairs(validated_members) do
      if member == config.master_pad_id then
        master_is_member = true
        break
      end
    end
    if not master_is_member then
      error("master_pad_id must be present in round-robin group members", 2)
    end
  end

  local seed = validate_seed(config.seed or 1)
  local self = setmetatable({
    id = config.id,
    master_pad_id = config.master_pad_id,
    members = validated_members,
    mode = mode,
    probability = normalize_probability(config.probability),
    advance_on_skip = validate_boolean(config.advance_on_skip, "advance_on_skip", false),
    advance_each_repeat = validate_boolean(
      config.advance_each_repeat,
      "advance_each_repeat",
      false
    ),
    reset_policy = reset_policy,
    reset_on = normalize_reset_on(config.reset_on),
    initial_seed = seed,
    prng = Prng.new(seed),
    cursor = 1,
    direction = 1,
    last_random_index = nil,
    selection_count = 0,
    trigger_count = 0,
    skipped_count = 0,
    next_token = 1,
    active = {},
  }, Group)

  return self
end

function Group:_passes_probability()
  if self.probability <= 0 then
    return false
  end
  if self.probability >= 1 then
    return true
  end
  local threshold = math.floor(self.probability * PROBABILITY_STEPS + 0.5)
  local roll = (self.prng:next_int() - 1) % PROBABILITY_STEPS
  return roll < threshold
end

function Group:_select_index()
  local count = #self.members
  local index

  if self.mode == "sequential" then
    index = self.cursor
    self.cursor = (self.cursor % count) + 1
  elseif self.mode == "ping_pong" then
    index = self.cursor
    if count > 1 then
      if self.direction > 0 then
        if self.cursor >= count then
          self.direction = -1
          self.cursor = count - 1
        else
          self.cursor = self.cursor + 1
        end
      elseif self.cursor <= 1 then
        self.direction = 1
        self.cursor = 2
      else
        self.cursor = self.cursor - 1
      end
    end
  elseif self.mode == "random" then
    index = self.prng:uniform(count)
  else
    if count == 1 then
      index = 1
    elseif self.last_random_index == nil then
      index = self.prng:uniform(count)
    else
      local draw = self.prng:uniform(count - 1)
      index = draw >= self.last_random_index and draw + 1 or draw
    end
    self.last_random_index = index
  end

  self.selection_count = self.selection_count + 1
  return index
end

function Group:_new_token()
  while self.active[self.next_token] ~= nil do
    self.next_token = self.next_token + 1
  end
  local token = self.next_token
  self.next_token = self.next_token + 1
  return token
end

function Group:note_on(options)
  options = options or {}
  if type(options) ~= "table" then
    error("group trigger options must be a table", 2)
  end
  if options.kind ~= nil and options.kind ~= "group" then
    error("round-robin dispatch accepts group triggers only", 2)
  end
  if options.source_pad_id ~= nil
    and self.master_pad_id ~= nil
    and options.source_pad_id ~= self.master_pad_id
  then
    error("group trigger source does not match master_pad_id", 2)
  end
  if options.token ~= nil and self.active[options.token] ~= nil then
    error("group trigger token is already active", 2)
  end

  local advance_each_repeat = self.advance_each_repeat
  if options.advance_each_repeat ~= nil then
    advance_each_repeat = validate_boolean(
      options.advance_each_repeat,
      "advance_each_repeat",
      false
    )
  end

  self.trigger_count = self.trigger_count + 1
  if not self:_passes_probability() then
    self.skipped_count = self.skipped_count + 1
    if self.advance_on_skip then
      self:_select_index()
    end
    return {
      kind = "group",
      group_id = self.id,
      source_pad_id = options.source_pad_id or self.master_pad_id,
      skipped = true,
      advanced = self.advance_on_skip,
      advance_each_repeat = advance_each_repeat,
    }
  end

  local member_index = self:_select_index()
  local token = options.token ~= nil and options.token or self:_new_token()
  local assignment = {
    kind = "group",
    group_id = self.id,
    source_pad_id = options.source_pad_id or self.master_pad_id,
    skipped = false,
    token = token,
    member = self.members[member_index],
    member_index = member_index,
    repeat_index = 1,
    advance_each_repeat = advance_each_repeat,
  }
  self.active[token] = assignment_copy(assignment)
  return assignment
end

Group.trigger = Group.note_on
Group.dispatch_group = Group.note_on

function Group:repeat_note(token, options)
  options = options or {}
  if type(options) ~= "table" then
    error("repeat options must be a table", 2)
  end

  local requested_assignment = self.active[token]
  if requested_assignment == nil then
    return nil, "unknown group assignment token"
  end

  local parent_token = requested_assignment.parent_token or token
  local assignment = self.active[parent_token]
  if assignment == nil then
    return nil, "unknown parent group assignment token"
  end

  local should_advance = assignment.advance_each_repeat
  if options.advance_each_repeat ~= nil then
    should_advance = validate_boolean(
      options.advance_each_repeat,
      "advance_each_repeat",
      false
    )
  end

  assignment.repeat_index = assignment.repeat_index + 1
  local member_index = assignment.member_index
  if should_advance then
    member_index = self:_select_index()
  end
  if options.token ~= nil and self.active[options.token] ~= nil then
    error("group repeat token is already active", 2)
  end
  local child_token = options.token ~= nil and options.token or self:_new_token()
  local child_assignment = {
    kind = "group",
    group_id = self.id,
    skipped = false,
    token = child_token,
    parent_token = parent_token,
    member = self.members[member_index],
    member_index = member_index,
    repeat_index = assignment.repeat_index,
    advance_each_repeat = should_advance,
  }
  self.active[child_token] = assignment_copy(child_assignment)

  local result = assignment_copy(child_assignment)
  result.kind = "group_repeat"
  result.advanced = should_advance
  result.previous_member = requested_assignment.member
  result.previous_member_index = requested_assignment.member_index
  return result
end

Group.ratchet = Group.repeat_note

function Group:peek_assignment(token)
  return assignment_copy(self.active[token])
end

function Group:note_off(token)
  local assignment = self.active[token]
  if assignment == nil then
    return nil, "unknown group assignment token"
  end
  self.active[token] = nil
  local result = assignment_copy(assignment)
  result.kind = "group_note_off"
  return result
end

Group.resolve_note_off = Group.note_off

function Group:reset(options)
  options = options or {}
  if type(options) ~= "table" then
    error("reset options must be a table", 2)
  end

  local clear_active = validate_boolean(options.clear_active, "clear_active", false)
  local seed = options.seed ~= nil and validate_seed(options.seed) or self.initial_seed
  if options.seed ~= nil then
    self.initial_seed = seed
  end

  self.prng:reset(seed)
  self.cursor = 1
  self.direction = 1
  self.last_random_index = nil
  self.selection_count = 0
  self.trigger_count = 0
  self.skipped_count = 0
  if clear_active then
    self.active = {}
    self.next_token = 1
  end
  return true
end

function Group:handle_reset(reason, options)
  if type(reason) ~= "string" or reason == "" then
    error("reset reason must be a non-empty string", 2)
  end
  local policy_match = self.reset_on[reason] == true
  if not policy_match and self.reset_policy ~= "never" then
    policy_match = reason == self.reset_policy
      or reason:sub(1, #self.reset_policy + 1) == self.reset_policy .. "_"
  end
  if not policy_match then
    return false
  end
  self:reset(options)
  return true
end

function Group:get_state()
  local active_count = 0
  for _ in pairs(self.active) do
    active_count = active_count + 1
  end
  return {
    mode = self.mode,
    cursor = self.cursor,
    direction = self.direction,
    random_state = self.prng:get_state(),
    last_random_index = self.last_random_index,
    selection_count = self.selection_count,
    trigger_count = self.trigger_count,
    skipped_count = self.skipped_count,
    active_count = active_count,
    reset_policy = self.reset_policy,
    advance_on_skip = self.advance_on_skip,
    advance_each_repeat = self.advance_each_repeat,
  }
end

function RoundRobin.is_group_trigger(value)
  return type(value) == "table"
    and (value.kind == "group" or value.kind == "group_repeat" or value.kind == "group_note_off")
end

RoundRobin.new_prng = Prng.new
RoundRobin.VALID_MODES = VALID_MODES
RoundRobin.VALID_RESET_POLICIES = VALID_RESET_POLICIES

return RoundRobin
