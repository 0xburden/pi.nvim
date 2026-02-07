local uv = vim.loop
local json = vim.json or vim.fn.json_decode

local Client = {}
Client.__index = Client

-- Create new RPC client instance
function Client.new(opts)
  local self = setmetatable({}, Client)
  self.host = opts.host or "127.0.0.1"
  self.port = opts.port or 43863
  self.socket = nil
  self.connected = false
  self.request_id = 0
  self.pending = {}  -- pending request callbacks
  self.buffer = ""   -- buffer for incomplete JSON messages
  return self
end

-- Connect to Pi RPC server
function Client:connect(callback)
  self.socket = uv.new_tcp()
  
  self.socket:connect(self.host, self.port, function(err)
    if err then
      callback(false, "Connection failed: " .. err)
      return
    end
    
    self.connected = true
    
    -- Start reading responses
    self.socket:read_start(function(read_err, chunk)
      if read_err then
        self:_handle_error(read_err)
        return
      end
      
      if chunk then
        self:_handle_data(chunk)
      else
        -- Connection closed
        self:disconnect()
      end
    end)
    
    callback(true)
  end)
end

-- Disconnect from server
function Client:disconnect()
  if self.socket and not self.socket:is_closing() then
    self.socket:close()
  end
  self.connected = false
  self.socket = nil
end

-- Send RPC request
function Client:request(method, params, callback)
  if not self.connected then
    callback({ error = "Not connected" })
    return
  end
  
  self.request_id = self.request_id + 1
  local id = self.request_id
  
  local message = {
    jsonrpc = "2.0",
    id = id,
    method = method,
    params = params or {}
  }
  
  -- Store callback for this request
  self.pending[id] = callback
  
  -- Send request
  local data = vim.json.encode(message) .. "\n"
  self.socket:write(data)
end

-- Handle incoming data (may be partial JSON)
function Client:_handle_data(chunk)
  self.buffer = self.buffer .. chunk
  
  -- Try to extract complete JSON messages
  while true do
    local newline = self.buffer:find("\n")
    if not newline then break end
    
    local line = self.buffer:sub(1, newline - 1)
    self.buffer = self.buffer:sub(newline + 1)
    
    -- Parse and handle message
    local ok, message = pcall(vim.json.decode, line)
    if ok then
      self:_handle_message(message)
    else
      vim.notify("Pi: Failed to parse JSON: " .. line, vim.log.levels.ERROR)
    end
  end
end

-- Handle complete JSON message
function Client:_handle_message(message)
  if message.id then
    -- This is a response to our request
    local callback = self.pending[message.id]
    if callback then
      self.pending[message.id] = nil
      -- Schedule callback on main thread
      vim.schedule(function()
        callback(message.result or message.error)
      end)
    end
  else
    -- This is a notification/event
    self:_handle_event(message)
  end
end

-- Handle server events (notifications)
function Client:_handle_event(event)
  local events = require("pi.events")
  vim.schedule(function()
    events.emit("rpc_event", event)
  end)
end

-- Handle errors
function Client:_handle_error(err)
  vim.schedule(function()
    vim.notify("Pi RPC error: " .. tostring(err), vim.log.levels.ERROR)
  end)
  self:disconnect()
end

return Client