local config = require("pi.config")

local M = {}

function M.new()
  local self = {
    job_id = nil,
    connected = false,
    request_id = 0,
    pending = {},
    buffer = "",
  }
  setmetatable(self, { __index = M })
  return self
end

local function append_log(entry)
  local state = require("pi.state")
  local events = require("pi.events")
  local entries = state.get("logs.entries") or {}
  table.insert(entries, entry)
  local max_entries = config.get("max_log_entries") or 1000
  if #entries > max_entries then
    table.remove(entries, 1)
  end
  state.update("logs.entries", entries)
  events.emit("log_entry", entry)
end

local function merge_messages(existing, incoming)
  local seen = {}
  for _, msg in ipairs(existing) do
    local id = msg.entryId or msg.id
    if id then
      seen[id] = true
    else
      local signature = string.format("%s:%s:%s", msg.role or "?", msg.timestamp or "", vim.json.encode(msg.content) or "")
      seen[signature] = true
    end
  end

  for _, msg in ipairs(incoming) do
    local id = msg.entryId or msg.id
    if id then
      if not seen[id] then
        table.insert(existing, msg)
        seen[id] = true
      end
    else
      local signature = string.format("%s:%s:%s", msg.role or "?", msg.timestamp or "", vim.json.encode(msg.content) or "")
      if not seen[signature] then
        table.insert(existing, msg)
        seen[signature] = true
      end
    end
  end

  return existing
end

function M:connect(callback)
  if self.job_id then
    vim.schedule(function()
      callback(true)
    end)
    return
  end

  local cmd = { "pi", "--mode", "rpc", "--no-session" }

  self.job_id = vim.fn.jobstart(cmd, {
    on_stdout = function(_, data, _)
      if data then
        for _, chunk in ipairs(data) do
          if chunk and chunk ~= "" then
            self:_handle_chunk(chunk)
          end
        end
      end
    end,
    on_stderr = function(_, data, _)
      -- Stderr is ignored - Pi may log there
    end,
    on_exit = function(_, _, _)
      self.job_id = nil
      self.connected = false
    end,
    stdout_buffered = false,
  })

  if self.job_id <= 0 then
    vim.schedule(function()
      callback(false, "Failed to start pi process")
    end)
    return
  end

  -- Pi needs ~2 seconds to initialize before accepting commands
  vim.defer_fn(function()
    self:_retry_connect(callback, vim.loop.now())
  end, 2000)
end

function M:_retry_connect(final_callback, start_time)
  local elapsed_ms = vim.loop.now() - start_time
  local max_wait_ms = 60000

  if elapsed_ms > max_wait_ms then
    self:disconnect()
    vim.schedule(function()
      final_callback(false, "Timeout waiting for Pi RPC after 60s")
    end)
    return
  end

  self:request("get_state", { type = "get_state" }, function(result)
    if result and result.success then
      self.connected = true
      vim.schedule(function()
        final_callback(true)
      end)
    else
      vim.defer_fn(function()
        self:_retry_connect(final_callback, start_time)
      end, 500)
    end
  end)
end

function M:disconnect()
  if self.job_id then
    pcall(vim.fn.jobstop, self.job_id)
    self.job_id = nil
  end
  self.connected = false
  -- Reject all pending requests
  for _, callback in pairs(self.pending) do
    vim.schedule(function()
      callback({ error = "Disconnected" })
    end)
  end
  self.pending = {}
  self.buffer = ""
end

function M:request(method, params, callback)
  if not self.job_id then
    vim.schedule(function()
      callback({ error = "Not connected" })
    end)
    return
  end

  self.request_id = self.request_id + 1
  local id = tostring(self.request_id)

  local cmd = {
    type = params.type or method,
    id = id,
  }
  for k, v in pairs(params) do
    -- Don't allow params to overwrite critical fields
    if k ~= "type" and k ~= "id" then
      cmd[k] = v
    end
  end

  self.pending[id] = callback

  -- Set up 30-second timeout
  vim.defer_fn(function()
    if self.pending[id] then
      self.pending[id] = nil
      vim.schedule(function()
        callback({ error = "Timeout: " .. method })
      end)
    end
  end, 30000)

  local json = vim.json.encode(cmd) .. "\n"
  vim.fn.chansend(self.job_id, json)
end

function M:_handle_chunk(chunk)
  self.buffer = self.buffer .. chunk

  -- Try to process newline-delimited messages
  while true do
    local newline = self.buffer:find("\n")
    if not newline then
      break
    end
    local line = self.buffer:sub(1, newline - 1)
    self.buffer = self.buffer:sub(newline + 1)
    line = line:gsub("\r$", "")
    if line ~= "" then
      self:_handle_line(line)
    end
  end

  -- If buffer has content without newline, try to parse as complete JSON
  -- This handles Pi's RPC responses which may not end with newline
  if self.buffer ~= "" then
    local ok, message = pcall(vim.json.decode, self.buffer)
    if ok and message then
      self:_handle_message(message)
      self.buffer = ""
    end
  end

  -- Prevent unbounded buffer growth
  if #self.buffer > 100000 then
    self.buffer = self.buffer:sub(-50000)
  end
end

function M:_handle_line(line)
  local ok, message = pcall(vim.json.decode, line)
  if not ok then
    return
  end
  self:_handle_message(message)
end

function M:_handle_message(message)
  local events = require("pi.events")
  local state = require("pi.state")
  
  -- Handle responses to our requests
  if message.type == "response" and message.id then
    local callback = self.pending[message.id]
    if callback then
      self.pending[message.id] = nil
      vim.schedule(function()
        if message.success then
          callback({ success = true, data = message.data })
        else
          callback({ error = message.error or "Unknown error" })
        end
      end)
    end
    return
  end
  
  -- Handle typed events from Pi
  vim.schedule(function()
    local event_type = message.type
    
    -- Always emit the raw event for backward compatibility
    events.emit("rpc_event", message)
    
    -- Emit typed event if it has a type
    if event_type then
      events.emit(event_type, message)
    end
    
    -- Update state based on event type
    if event_type == "agent_start" then
      state.update("agent.running", true)
      append_log({
        timestamp = vim.loop.now(),
        level = "INFO",
        message = "Agent started",
      })
      
    elseif event_type == "agent_end" then
      state.update("agent.running", false)
      -- Store the messages from this run without duplication
      if message.messages then
        local conv_messages = state.get("conversation.messages") or {}
        conv_messages = merge_messages(conv_messages, message.messages)
        state.update("conversation.messages", conv_messages)
      end
      append_log({
        timestamp = vim.loop.now(),
        level = "INFO",
        message = "Agent ended",
      })
      
    elseif event_type == "message_start" then
      state.update("agent.current_message", message.message)
      
    elseif event_type == "message_update" then
      state.update("agent.current_message", message.message)
      -- Also emit the specific delta type for fine-grained handling
      local delta = message.assistantMessageEvent
      if delta and delta.type then
        events.emit("message_delta_" .. delta.type, {
          message = message.message,
          delta = delta,
        })
      end
      
    elseif event_type == "message_end" then
      state.update("agent.current_message", nil)
      state.update("agent.last_message", message.message)
      
    elseif event_type == "tool_execution_start" then
      local tool_info = {
        id = message.toolCallId,
        name = message.toolName,
        args = message.args,
      }
      state.update("agent.current_tool", tool_info)
      append_log({
        timestamp = vim.loop.now(),
        level = "INFO",
        message = string.format("Tool started: %s", message.toolName or "tool"),
        data = tool_info,
      })
      
    elseif event_type == "tool_execution_update" then
      local current = state.get("agent.current_tool") or {}
      current.partial_result = message.partialResult
      state.update("agent.current_tool", current)
      
    elseif event_type == "tool_execution_end" then
      state.update("agent.current_tool", nil)
      local tool_result = {
        id = message.toolCallId,
        name = message.toolName,
        result = message.result,
        is_error = message.isError,
      }
      state.update("agent.last_tool_result", tool_result)
      append_log({
        timestamp = vim.loop.now(),
        level = message.isError and "ERROR" or "INFO",
        message = string.format("Tool ended: %s", message.toolName or "tool"),
        data = tool_result,
      })
      
    elseif event_type == "turn_start" then
      state.update("agent.current_turn", message)
      append_log({
        timestamp = vim.loop.now(),
        level = "INFO",
        message = "Turn started",
        data = message,
      })
      
    elseif event_type == "turn_end" then
      state.update("agent.current_turn", nil)
      state.update("agent.last_turn", message)
      append_log({
        timestamp = vim.loop.now(),
        level = "INFO",
        message = "Turn ended",
        data = message,
      })
      
    elseif event_type == "auto_compaction_start" then
      state.update("agent.compacting", true)
      state.update("agent.compaction_reason", message.reason)
      append_log({
        timestamp = vim.loop.now(),
        level = "INFO",
        message = "Auto-compaction started",
        data = { reason = message.reason },
      })
      
    elseif event_type == "auto_compaction_end" then
      state.update("agent.compacting", false)
      state.update("agent.compaction_reason", nil)
      state.update("agent.last_compaction", {
        result = message.result,
        error = message.error,
        aborted = message.aborted,
        reason = message.reason,
      })
      append_log({
        timestamp = vim.loop.now(),
        level = message.error and "ERROR" or "INFO",
        message = "Auto-compaction ended",
        data = {
          result = message.result,
          error = message.error,
          aborted = message.aborted,
        },
      })
      
    elseif event_type == "auto_retry_start" then
      state.update("agent.retrying", true)
      state.update("agent.retry_info", {
        attempt = message.attempt,
        max_attempts = message.maxAttempts,
        delay_ms = message.delayMs,
        error = message.errorMessage or message.error,
        will_retry = message.willRetry,
      })
      append_log({
        timestamp = vim.loop.now(),
        level = "WARN",
        message = "Auto-retry scheduled",
        data = {
          attempt = message.attempt,
          max_attempts = message.maxAttempts,
          delay_ms = message.delayMs,
          error = message.errorMessage or message.error,
        },
      })
      
    elseif event_type == "auto_retry_end" then
      state.update("agent.retrying", false)
      state.update("agent.retry_info", nil)
      state.update("agent.last_retry", {
        final_error = message.finalError or message.error,
        will_retry = message.willRetry,
        aborted = message.aborted,
      })
      append_log({
        timestamp = vim.loop.now(),
        level = message.finalError and "ERROR" or "INFO",
        message = "Auto-retry ended",
        data = {
          final_error = message.finalError or message.error,
          will_retry = message.willRetry,
          aborted = message.aborted,
        },
      })
      
    elseif event_type == "extension_error" then
      -- Log extension errors
      vim.notify(
        string.format("Pi extension error [%s]: %s", message.event or "?", message.error or "unknown"),
        vim.log.levels.WARN
      )
      
    elseif event_type == "extension_ui_request" then
      -- Handled by pi.ui.extension module
    end
  end)
end

--- Send a raw message to Pi (for extension UI responses, etc.)
-- @param message table The message to send
function M:send(message)
  if not self.job_id then
    return false, "Not connected"
  end
  local json = vim.json.encode(message) .. "\n"
  vim.fn.chansend(self.job_id, json)
  return true
end

return M
