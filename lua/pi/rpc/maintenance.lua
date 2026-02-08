--- Maintenance RPC Commands
-- Compaction, retry, and queue mode management

local M = {}

local state = require("pi.state")
local events = require("pi.events")

-- ============================================================================
-- Compaction
-- ============================================================================

--- Manually compact conversation context to reduce token usage
-- @param client RPC client
-- @param customInstructions string|nil Optional instructions for compaction summary
-- @param callback function|nil Called with result { summary, firstKeptEntryId, tokensBefore, details }
function M.compact(client, customInstructions, callback)
  local params = { type = "compact" }
  if customInstructions then
    params.customInstructions = customInstructions
  end
  
  state.update("agent.compacting", true)
  events.emit("compaction_start", { manual = true })
  
  client:request("compact", params, function(result)
    vim.schedule(function()
      state.update("agent.compacting", false)
      
      if result and result.success then
        state.update("agent.last_compaction", result.data)
        events.emit("compaction_end", {
          manual = true,
          result = result.data,
        })
      else
        events.emit("compaction_error", {
          error = result and result.error,
        })
      end
      
      if callback then callback(result) end
    end)
  end)
end

--- Enable or disable automatic compaction
-- @param client RPC client
-- @param enabled boolean Whether to enable auto-compaction
-- @param callback function|nil Called with result
function M.set_auto_compaction(client, enabled, callback)
  client:request("set_auto_compaction", {
    type = "set_auto_compaction",
    enabled = enabled,
  }, function(result)
    vim.schedule(function()
      if result and result.success then
        state.update("agent.auto_compaction", enabled)
        events.emit("auto_compaction_changed", { enabled = enabled })
      end
      if callback then callback(result) end
    end)
  end)
end

-- ============================================================================
-- Retry
-- ============================================================================

--- Enable or disable automatic retry on transient errors
-- @param client RPC client
-- @param enabled boolean Whether to enable auto-retry
-- @param callback function|nil Called with result
function M.set_auto_retry(client, enabled, callback)
  client:request("set_auto_retry", {
    type = "set_auto_retry",
    enabled = enabled,
  }, function(result)
    vim.schedule(function()
      if result and result.success then
        state.update("agent.auto_retry", enabled)
        events.emit("auto_retry_changed", { enabled = enabled })
      end
      if callback then callback(result) end
    end)
  end)
end

--- Abort an in-progress retry (cancel the delay and stop retrying)
-- @param client RPC client
-- @param callback function|nil Called with result
function M.abort_retry(client, callback)
  client:request("abort_retry", { type = "abort_retry" }, function(result)
    vim.schedule(function()
      if result and result.success then
        state.update("agent.retrying", false)
        state.update("agent.retry_info", nil)
        events.emit("retry_aborted")
      end
      if callback then callback(result) end
    end)
  end)
end

-- ============================================================================
-- Queue Modes
-- ============================================================================

--- Set steering message delivery mode
-- @param client RPC client
-- @param mode string "all" (deliver all at once) or "one-at-a-time" (default)
-- @param callback function|nil Called with result
function M.set_steering_mode(client, mode, callback)
  client:request("set_steering_mode", {
    type = "set_steering_mode",
    mode = mode,
  }, function(result)
    vim.schedule(function()
      if result and result.success then
        state.update("agent.steering_mode", mode)
        events.emit("steering_mode_changed", { mode = mode })
      end
      if callback then callback(result) end
    end)
  end)
end

--- Set follow-up message delivery mode
-- @param client RPC client
-- @param mode string "all" (deliver all at once) or "one-at-a-time" (default)
-- @param callback function|nil Called with result
function M.set_follow_up_mode(client, mode, callback)
  client:request("set_follow_up_mode", {
    type = "set_follow_up_mode",
    mode = mode,
  }, function(result)
    vim.schedule(function()
      if result and result.success then
        state.update("agent.follow_up_mode", mode)
        events.emit("follow_up_mode_changed", { mode = mode })
      end
      if callback then callback(result) end
    end)
  end)
end

-- ============================================================================
-- Helpers
-- ============================================================================

--- Check if compaction is currently running
-- @return boolean
function M.is_compacting()
  return state.get("agent.compacting") or false
end

--- Check if retry is in progress
-- @return boolean
function M.is_retrying()
  return state.get("agent.retrying") or false
end

--- Get last compaction result
-- @return table|nil { summary, firstKeptEntryId, tokensBefore, details }
function M.get_last_compaction()
  return state.get("agent.last_compaction")
end

--- Get current retry info
-- @return table|nil { attempt, max_attempts, delay_ms, error }
function M.get_retry_info()
  return state.get("agent.retry_info")
end

return M
