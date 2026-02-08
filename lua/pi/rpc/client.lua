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
  for id, callback in pairs(self.pending) do
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
  else
    local events = require("pi.events")
    vim.schedule(function()
      events.emit("rpc_event", message)
    end)
  end
end

return M
