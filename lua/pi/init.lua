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
function M.is_running(callback)
  local client = M.state.get("rpc_client")
  if not client then
    vim.schedule(function() callback(false) end)
    return
  end

  -- Try to connect with short timeout
  local timer = vim.loop.new_timer()
  local connected = false
  local callback_called = false

  local function safe_callback(result)
    if not callback_called then
      callback_called = true
      vim.schedule(function() callback(result) end)
    end
  end

  client:connect(function(success, err)
    connected = success
    if success then
      -- Disconnect immediately, we were just checking
      client:disconnect()
    end
    if timer then
      timer:stop()
      timer:close()
    end
    safe_callback(success)
  end)

  -- Timeout after 500ms
  timer:start(500, 0, function()
    if not connected then
      client:disconnect()
      timer:close()
      safe_callback(false)
    end
  end)
end

-- Spawn Pi with RPC enabled
function M.spawn(callback)
  if M.pi_process then
    vim.schedule(function()
      vim.notify("Pi: Process already spawned (PID: " .. M.pi_process.pid .. ")", vim.log.levels.WARN)
    end)
    if callback then vim.schedule(function() callback(true) end) end
    return
  end

  local uv = vim.loop
  local port = M.config.get("port") or 43863

  vim.schedule(function()
    vim.notify("Pi: Starting RPC server on port " .. port .. "...", vim.log.levels.INFO)
  end)

  -- Collect stderr for error reporting
  local stderr_data = {}

  -- Spawn pi with RPC flag
  local handle, pid
  local stdout = uv.new_pipe(false)
  local stderr = uv.new_pipe(false)

  handle, pid = uv.spawn("pi", {
    args = { "--rpc", "--rpc-port", tostring(port) },
    stdio = { nil, stdout, stderr },
    detached = true,
  }, function(code, signal)
    -- Process exited
    vim.schedule(function()
      if code ~= 0 then
        vim.notify("Pi: Process exited with code " .. code, vim.log.levels.WARN)
      end
    end)
    M.pi_process = nil
    if handle then
      handle:close()
    end
  end)

  if not handle then
    vim.schedule(function()
      vim.notify("Pi: Failed to spawn process. Is 'pi' in your PATH?", vim.log.levels.ERROR)
    end)
    if callback then vim.schedule(function() callback(false) end) end
    return
  end

  M.pi_process = { handle = handle, pid = pid }

  -- Read stdout/stderr for debugging
  local function on_read(stream, name)
    return function(err, data)
      if err then
        return
      end
      if data then
        if name == "stderr" then
          table.insert(stderr_data, data)
        end
        vim.schedule(function()
          -- Log to messages for debugging
          vim.notify("Pi [" .. name .. "]: " .. data:gsub("%s+$", ""), vim.log.levels.DEBUG)
        end)
      end
    end
  end

  stdout:read_start(on_read(stdout, "stdout"))
  stderr:read_start(on_read(stderr, "stderr"))

  -- Wait a moment for the server to start, then verify
  vim.defer_fn(function()
    -- Check if process is still running
    local running = uv.kill(pid, 0)
    if running ~= 0 then
      vim.schedule(function()
        local err_msg = table.concat(stderr_data, "\n")
        vim.notify("Pi: Process failed to start. Error: " .. err_msg, vim.log.levels.ERROR)
      end)
      M.pi_process = nil
      if callback then callback(false) end
      return
    end

    vim.schedule(function()
      vim.notify("Pi: RPC server started (PID: " .. pid .. ")", vim.log.levels.INFO)
    end)
    if callback then callback(true) end
  end, 1500)
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
-- @param opts table: { auto_spawn = true, spawn_callback = function }
function M.ensure_connected(opts, callback)
  opts = opts or { auto_spawn = true }

  -- Already connected?
  if M.state.get("connected") then
    if callback then vim.schedule(function() callback(true) end) end
    return
  end

  -- Check if Pi is running elsewhere
  M.is_running(function(running)
    if running then
      -- Pi is running, just connect
      M.connect(function(success)
        if callback then callback(success) end
      end)
    elseif opts.auto_spawn then
      -- Need to spawn Pi
      M.spawn(function(spawned)
        if spawned then
          -- Wait a bit for server to be ready
          vim.defer_fn(function()
            M.connect(function(success)
              if callback then callback(success) end
            end)
          end, 2500)
        else
          if callback then callback(false) end
        end
      end)
    else
      vim.schedule(function()
        vim.notify("Pi: Not running and auto-spawn disabled", vim.log.levels.ERROR)
      end)
      if callback then vim.schedule(function() callback(false) end) end
    end
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