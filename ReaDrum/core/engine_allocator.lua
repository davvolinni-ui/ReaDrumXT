-- Pure mapping between ReaDrum's stable logical pad IDs and transient sampler
-- engine locations. Bank/slot addresses must never be persisted as pad identity.

local M = {}

M.BANK_COUNT = 8
M.SLOTS_PER_BANK = 16
M.CAPACITY = M.BANK_COUNT * M.SLOTS_PER_BANK

local function fail(message)
  return nil, message
end

function M.allocate(pads)
  if type(pads) ~= "table" then return fail("pads must be a table") end

  local allocation = { by_pad_id = {}, banks = {} }
  for bank = 1, M.BANK_COUNT do allocation.banks[bank] = {} end

  local occupied = {}
  for index, pad in ipairs(pads) do
    if type(pad) ~= "table" or type(pad.id) ~= "string" or pad.id == "" then
      return fail("pads[" .. index .. "] has no stable logical ID")
    end
    if allocation.by_pad_id[pad.id] then
      return fail("duplicate logical pad ID '" .. pad.id .. "'")
    end
    local logical_index = tonumber(pad.logical_index)
    if not logical_index or logical_index % 1 ~= 0 or logical_index < 1 or logical_index > M.CAPACITY then
      return fail("pads[" .. index .. "].logical_index must be an integer from 1 to " .. M.CAPACITY)
    end
    if occupied[logical_index] then
      return fail("logical pad index " .. logical_index .. " is already occupied")
    end

    local bank = math.floor((logical_index - 1) / M.SLOTS_PER_BANK) + 1
    local slot = ((logical_index - 1) % M.SLOTS_PER_BANK) + 1
    local location = { bank = bank, slot = slot }
    allocation.by_pad_id[pad.id] = location
    allocation.banks[bank][slot] = pad.id
    occupied[logical_index] = pad.id
  end

  return allocation
end

function M.location(allocation, pad_id)
  return allocation and allocation.by_pad_id and allocation.by_pad_id[pad_id] or nil
end

-- Physical stereo pairs are assigned to logical outputs, not pads or banks.
-- Every sampler-bank instance uses the same pair number for the same output,
-- allowing pads in different banks to share one downstream REAPER route.
function M.allocate_outputs(outputs)
  if type(outputs) ~= "table" then return fail("outputs must be a table") end
  if #outputs > M.SLOTS_PER_BANK then return fail("at most 16 logical outputs can be mapped to stereo pairs") end
  local result = { by_output_id = {}, by_pair = {} }
  for index, output in ipairs(outputs) do
    if type(output) ~= "table" or type(output.id) ~= "string" or output.id == "" then
      return fail("outputs[" .. index .. "] has no logical output ID")
    end
    if result.by_output_id[output.id] then return fail("duplicate logical output ID '" .. output.id .. "'") end
    local pair = index - 1 -- JSFX control uses zero-based stereo-pair indexes.
    result.by_output_id[output.id] = pair
    result.by_pair[pair] = output.id
  end
  return result
end

return M
