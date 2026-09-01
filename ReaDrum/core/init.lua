-- @noindex
local Model = require("ReaDrum.core.model")

return {
  MODEL_SCHEMA_VERSION = Model.SCHEMA_VERSION,
  model = Model,
  round_robin = require("ReaDrum.core.round_robin"),
  engine_allocator = require("ReaDrum.core.engine_allocator"),
  commands = require("ReaDrum.core.commands"),
  clipboard = require("ReaDrum.core.clipboard"),
}
