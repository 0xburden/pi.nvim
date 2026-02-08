--- Model Management RPC Commands
-- Manage model selection and thinking levels

local M = {}

local state = require("pi.state")
local events = require("pi.events")

--- Set a specific model
-- @param client RPC client
-- @param provider string Provider name (anthropic, openai, google, etc.)
-- @param modelId string Model ID
-- @param callback function|nil Called with result containing full Model object
function M.set(client, provider, modelId, callback)
  client:request("set_model", {
    type = "set_model",
    provider = provider,
    modelId = modelId,
  }, function(result)
    vim.schedule(function()
      if result and result.success then
        state.update("model.current", result.data)
        state.update("agent.model", result.data)
        events.emit("model_changed", result.data)
      end
      if callback then callback(result) end
    end)
  end)
end

--- Cycle to the next available model
-- @param client RPC client
-- @param callback function|nil Called with result { model, thinkingLevel, isScoped }
function M.cycle(client, callback)
  client:request("cycle_model", { type = "cycle_model" }, function(result)
    vim.schedule(function()
      if result and result.success and result.data then
        state.update("model.current", result.data.model)
        state.update("agent.model", result.data.model)
        state.update("agent.thinking_level", result.data.thinkingLevel)
        events.emit("model_changed", result.data.model)
      end
      if callback then callback(result) end
    end)
  end)
end

--- Get all available/configured models
-- @param client RPC client
-- @param callback function Called with result { models = [...] }
function M.get_available(client, callback)
  client:request("get_available_models", { type = "get_available_models" }, function(result)
    vim.schedule(function()
      if result and result.success then
        state.update("model.available", result.data and result.data.models)
      end
      if callback then callback(result) end
    end)
  end)
end

--- Set thinking/reasoning level
-- @param client RPC client
-- @param level string One of: "off", "minimal", "low", "medium", "high", "xhigh"
-- @param callback function|nil Called with result
function M.set_thinking_level(client, level, callback)
  client:request("set_thinking_level", {
    type = "set_thinking_level",
    level = level,
  }, function(result)
    vim.schedule(function()
      if result and result.success then
        state.update("agent.thinking_level", level)
        events.emit("thinking_level_changed", { level = level })
      end
      if callback then callback(result) end
    end)
  end)
end

--- Cycle through available thinking levels
-- Returns null data if model doesn't support thinking
-- @param client RPC client
-- @param callback function|nil Called with result { level = "..." }
function M.cycle_thinking_level(client, callback)
  client:request("cycle_thinking_level", { type = "cycle_thinking_level" }, function(result)
    vim.schedule(function()
      if result and result.success and result.data then
        state.update("agent.thinking_level", result.data.level)
        events.emit("thinking_level_changed", { level = result.data.level })
      end
      if callback then callback(result) end
    end)
  end)
end

--- Get the current model
-- @return table|nil The current model object
function M.get_current()
  return state.get("model.current") or state.get("agent.model")
end

--- Get the current thinking level
-- @return string|nil The current thinking level
function M.get_thinking_level()
  return state.get("agent.thinking_level")
end

--- Check if current model supports thinking/reasoning
-- @return boolean
function M.supports_thinking()
  local model = M.get_current()
  return model and model.reasoning == true
end

--- Format model for display
-- @param model table Model object
-- @return string Formatted display string
function M.format(model)
  if not model then return "No model" end
  local name = model.name or model.id or "Unknown"
  local provider = model.provider or "?"
  return string.format("%s (%s)", name, provider)
end

return M
