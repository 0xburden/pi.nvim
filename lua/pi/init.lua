local M = {}

M.state = require("pi.state")
M.events = require("pi.events")
M.config = require("pi.config")

-- Process handle for spawned Pi
M.pi_process = nil

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

-- Check if Pi RPC is already running by attempting connection
-- NOTE: Returns false since Pi doesn't have RPC server mode in v0.52.7
function M.is_running(callback)
  vim.schedule(function() callback(false) end)
end

-- NOTE: Pi RPC server mode is not available in current version (0.52.7)
-- This function is kept for when/if RPC support is added to Pi
function M.spawn(callback)
  vim.schedule(function()
    vim.notify("Pi: RPC server mode is not available in Pi v0.52.7", vim.log.levels.ERROR)
    vim.notify("Pi: Please start Pi manually in a separate terminal", vim.log.levels.INFO)
    vim.notify("Pi: Or check if there's a pi-rpc extension/package available", vim.log.levels.INFO)
  end)
  if callback then vim.schedule(function() callback(false) end) end
end

-- Stop the spawned Pi process
function M.stop_process()
  if not M.pi_process then
    vim.notify("Pi: No spawned process to stop", vim.log.levels.WARN)
    return
  end

  -- Kill the process
  local uv = vim.loop
  uv.kill(M.pi_process.pid, "sigterm")

  if M.pi_process.handle then
    M.pi_process.handle:close()
  end

  M.pi_process = nil
  vim.notify("Pi: Process stopped", vim.log.levels.INFO)
end

-- Ensure Pi is running and connected (auto-spawn if needed)
-- NOTE: Pi v0.52.7 does not have RPC server mode - this requires manual setup
-- @param opts table: { auto_spawn = true, spawn_callback = function }
function M.ensure_connected(opts, callback)
  opts = opts or { auto_spawn = true }

  -- Already connected?
  if M.state.get("connected") then
    if callback then vim.schedule(function() callback(true) end) end
    return
  end

  vim.schedule(function()
    vim.notify("═══════════════════════════════════════════════════", vim.log.levels.WARN)
    vim.notify("Pi: RPC server mode is NOT available in Pi v0.52.7", vim.log.levels.WARN)
    vim.notify("Pi: The plugin was designed for a future RPC-enabled version", vim.log.levels.WARN)
    vim.notify("Pi: Current implementation is based on PLAN.md specification", vim.log.levels.WARN)
    vim.notify("═══════════════════════════════════════════════════", vim.log.levels.WARN)
  end)

  -- Try to connect anyway (in case user has a custom RPC wrapper)
  M.connect(function(success, err)
    if callback then callback(success) end
  end)
end

-- Connect to Pi agent
function M.connect(callback)
  local client = M.state.get("rpc_client")

  if not client then
    vim.notify("Pi: Client not initialized", vim.log.levels.ERROR)
    return
  end

  client:connect(function(success, err)
    vim.schedule(function()
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
        vim.notify("Pi: Connection failed - " .. tostring(err), vim.log.levels.ERROR)
      end

      if callback then callback(success, err) end
    end)
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

-- Start agent with task (auto-spawns Pi if needed)
function M.start(task, opts)
  opts = opts or {}

  -- Ensure we're connected (auto-spawn if needed)
  M.ensure_connected({ auto_spawn = opts.auto_spawn ~= false }, function(connected)
    if not connected then
      vim.notify("Pi: Failed to connect to agent", vim.log.levels.ERROR)
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