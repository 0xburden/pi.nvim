local M = {}

function M.new(opts)
  local self = {
    host = opts.host or "127.0.0.1",
    port = opts.port or 43863,
    job_id = nil,
    connected = false,
    request_id = 0,
    pending = {},
    buffer = "",
    on_event = nil,
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

  local cmd = { "pi", "--mode", "rpc" }
  if self.port then
    table.insert(cmd, "--rpc-port")
    table.insert(cmd, tostring(self.port))
  end

  local client = self

  self.job_id = vim.fn.jobstart(cmd, {
    on_stdout = function(_, data, _)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            vim.schedule(function()
              client:_handle_line(line)
            end)
          end
        end
      end
    end,
    on_stderr = function(_, data, _)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            vim.schedule(function()
              vim.notify("Pi stderr: " .. line, vim.log.levels.WARN)
            end)
          end
        end
      end
    end,
    on_exit = function(_, code, _)
      vim.schedule(function()
        vim.notify("Pi process exited with code " .. code, vim.log.levels.INFO)
      end)
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

  self.connected = true
  vim.defer_fn(function()
    callback(true)
  end, 500)
end

function M:disconnect()
  if self.job_id then
    vim.fn.jobstop(self.job_id)
    self.job_id = nil
    self.connected = false
  end
end

function M:request(method, params, callback)
  if not self.connected or not self.job_id then
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
    if k ~= "type" then
      cmd[k] = v
    end
  end

  self.pending[id] = callback

  local json = vim.json.encode(cmd) .. "\n"
  vim.fn.chansend(self.job_id, json)
end

function M:_handle_line(line)
  local ok, message = pcall(vim.json.decode, line)
  if not ok then
    vim.notify("Pi: Failed to parse JSON: " .. line:sub(1, 100), vim.log.levels.ERROR)
    return
  end

  if message.type == "response" and message.id then
    local callback = self.pending[message.id]
    if callback then
      self.pending[message.id] = nil
      if message.success then
        callback({ success = true, data = message.data })
      else
        callback({ error = message.error or "Unknown error" })
      end
    end
  else
    -- All non-response messages are events
    local events = require("pi.events")
    events.emit("rpc_event", message)
  end
end

return M
