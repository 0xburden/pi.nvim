local M = {}

M.state = require("pi.state")
M.events = require("pi.events")
M.config = require("pi.config")

-- Initialize plugin
function M.setup(opts)
  -- Merge user config
  M.config.setup(opts or {})
  
  -- Create RPC client
  local Client = require("pi.rpc.client")
  local client = Client.new({
    host = M.config.get("host"),
    port = M.config.get("port"),
  })
  
  M.state.update("rpc_client", client)
  
  -- Auto-connect if configured
  if M.config.get("auto_connect") then
    M.connect()
  end
end

-- Connect to Pi agent
function M.connect(callback)
  local client = M.state.get("rpc_client")
  
  if not client then
    vim.notify("Pi: Client not initialized", vim.log.levels.ERROR)
    return
  end
  
  client:connect(function(success, err)
    if success then
      M.state.update("connected", true)
      vim.notify("Pi: Connected to agent", vim.log.levels.INFO)
      
      -- Auto-open control panel if configured
      if M.config.get("auto_open_panel") then
        require("pi.ui.control_panel").open()
      end
      
      -- Start log streaming if configured
      if M.config.get("auto_stream_logs") then
        local logs = require("pi.rpc.logs")
        logs.stream(client)
      end
    else
      vim.notify("Pi: Connection failed - " .. err, vim.log.levels.ERROR)
    end
    
    if callback then callback(success, err) end
  end)
end

-- Disconnect from Pi agent
function M.disconnect()
  local client = M.state.get("rpc_client")
  
  if client then
    client:disconnect()
    M.state.update("connected", false)
    vim.notify("Pi: Disconnected", vim.log.levels.INFO)
  end
end

-- Start agent with task
function M.start(task)
  if not M.state.get("connected") then
    vim.notify("Pi: Not connected to agent", vim.log.levels.ERROR)
    return
  end
  
  local client = M.state.get("rpc_client")
  local agent = require("pi.rpc.agent")
  
  agent.start(client, task, function(result)
    if result.error then
      vim.notify("Pi: Failed to start - " .. result.error, vim.log.levels.ERROR)
    else
      vim.notify("Pi: Agent started", vim.log.levels.INFO)
      
      -- Auto-open logs if configured
      if M.config.get("auto_open_logs") then
        require("pi.ui.logs_viewer").open()
      end
    end
  end)
end

-- Pause agent
function M.pause()
  local client = M.state.get("rpc_client")
  local agent = require("pi.rpc.agent")
  
  agent.pause(client, function(result)
    if result.error then
      vim.notify("Pi: Failed to pause - " .. result.error, vim.log.levels.ERROR)
    end
  end)
end

-- Resume agent
function M.resume()
  local client = M.state.get("rpc_client")
  local agent = require("pi.rpc.agent")
  
  agent.resume(client, function(result)
    if result.error then
      vim.notify("Pi: Failed to resume - " .. result.error, vim.log.levels.ERROR)
    end
  end)
end

-- Stop agent
function M.stop()
  local client = M.state.get("rpc_client")
  local agent = require("pi.rpc.agent")
  
  agent.stop(client, function(result)
    if result.error then
      vim.notify("Pi: Failed to stop - " .. result.error, vim.log.levels.ERROR)
    end
  end)
end

return M