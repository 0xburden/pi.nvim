local M = {}

local state = require("pi.state")
local events = require("pi.events")

--- Send a prompt to the agent
-- @param client RPC client
-- @param message string The prompt message
-- @param opts table|nil Options: { images = {...}, streamingBehavior = "steer"|"followUp" }
-- @param callback function|nil Called with result
function M.prompt(client, message, opts, callback)
  opts = opts or {}
  local params = {
    type = "prompt",
    message = message,
  }
  
  -- Add images if provided
  if opts.images then
    params.images = opts.images
  end
  
  -- Add streaming behavior if agent is already running
  if opts.streamingBehavior then
    params.streamingBehavior = opts.streamingBehavior
  end
  
  client:request("prompt", params, function(result)
    vim.schedule(function()
      if result and result.success then
        state.update("agent.running", true)
        state.update("agent.current_task", message)
        events.emit("agent_started", result)
      end
      if callback then callback(result) end
    end)
  end)
end

-- Alias for backward compatibility
function M.start(client, task, callback)
  M.prompt(client, task, nil, callback)
end

--- Steer the agent mid-run (interrupt with new instructions)
-- Message is delivered after current tool execution, remaining tools are skipped
-- @param client RPC client
-- @param message string The steering message
-- @param opts table|nil Options: { images = {...} }
-- @param callback function|nil Called with result
function M.steer(client, message, opts, callback)
  opts = opts or {}
  local params = {
    type = "steer",
    message = message,
  }
  
  if opts.images then
    params.images = opts.images
  end
  
  client:request("steer", params, function(result)
    vim.schedule(function()
      if result and result.success then
        events.emit("agent_steered", { message = message })
      end
      if callback then callback(result) end
    end)
  end)
end

--- Queue a follow-up message to be processed after agent finishes
-- Message is delivered only when agent has no more tool calls or steering messages
-- @param client RPC client
-- @param message string The follow-up message
-- @param opts table|nil Options: { images = {...} }
-- @param callback function|nil Called with result
function M.follow_up(client, message, opts, callback)
  opts = opts or {}
  local params = {
    type = "follow_up",
    message = message,
  }
  
  if opts.images then
    params.images = opts.images
  end
  
  client:request("follow_up", params, function(result)
    vim.schedule(function()
      if result and result.success then
        events.emit("agent_follow_up_queued", { message = message })
      end
      if callback then callback(result) end
    end)
  end)
end

--- Abort the current agent operation
-- @param client RPC client
-- @param callback function|nil Called with result
function M.abort(client, callback)
  client:request("abort", { type = "abort" }, function(result)
    vim.schedule(function()
      if result and result.success then
        state.update("agent.running", false)
        state.update("agent.current_task", nil)
        events.emit("agent_aborted")
      end
      if callback then callback(result) end
    end)
  end)
end

-- Alias for backward compatibility
function M.stop(client, callback)
  M.abort(client, callback)
end

--- Get current agent state
-- @param client RPC client
-- @param callback function Called with result containing state data
function M.status(client, callback)
  client:request("get_state", { type = "get_state" }, function(result)
    vim.schedule(function()
      if result and result.success then
        local data = result.data
        state.update("agent.running", data.isStreaming or false)
        state.update("agent.model", data.model)
        state.update("agent.thinking_level", data.thinkingLevel)
        state.update("agent.session_id", data.sessionId)
        state.update("agent.session_file", data.sessionFile)
        state.update("agent.session_name", data.sessionName)
        state.update("agent.message_count", data.messageCount)
        state.update("agent.pending_message_count", data.pendingMessageCount)
        state.update("agent.auto_compaction", data.autoCompactionEnabled)
        state.update("agent.steering_mode", data.steeringMode)
        state.update("agent.follow_up_mode", data.followUpMode)
      end
      if callback then callback(result) end
    end)
  end)
end

return M
