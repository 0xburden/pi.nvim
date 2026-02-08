local M = {}

M.state = require("pi.state")
M.events = require("pi.events")
M.config = require("pi.config")

function M.setup(opts)
  M.config.setup(opts or {})

  local Client = require("pi.rpc.client")
  local client = Client.new()

  M.state.update("rpc_client", client)

  -- Set up extension UI handling
  require("pi.ui.extension").setup()

  if M.config.get("auto_connect") then
    M.connect()
  end
end

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

        if M.config.get("auto_open_panel") then
          require("pi.ui.control_panel").open()
        end
      else
        vim.notify("Pi: Connection failed - " .. tostring(err), vim.log.levels.ERROR)
      end

      if callback then callback(success, err) end
    end)
  end)
end

function M.disconnect()
  local client = M.state.get("rpc_client")
  if client then
    client:disconnect()
    M.state.update("connected", false)
    vim.notify("Pi: Disconnected", vim.log.levels.INFO)
  end
end

--- Send a prompt to the agent
-- @param task string The task/prompt to send
-- @param opts table|nil Options: { images = {...}, streamingBehavior = "steer"|"followUp" }
function M.start(task, opts)
  if not M.state.get("connected") then
    M.connect(function(success)
      if success then
        M._send_prompt(task, opts)
      end
    end)
    return
  end
  M._send_prompt(task, opts)
end

function M._send_prompt(task, opts)
  local client = M.state.get("rpc_client")
  if not client then
    vim.notify("Pi: Not connected", vim.log.levels.ERROR)
    return
  end
  
  local agent = require("pi.rpc.agent")
  agent.prompt(client, task, opts, function(result)
    vim.schedule(function()
      if result.error then
        vim.notify("Pi: Failed to send prompt - " .. result.error, vim.log.levels.ERROR)
      else
        vim.notify("Pi: Prompt sent", vim.log.levels.INFO)
        if M.config.get("auto_open_logs") then
          require("pi.ui.logs_viewer").open()
        end
      end
    end)
  end)
end

--- Steer the agent mid-run (interrupt with new instructions)
-- @param message string The steering message
-- @param opts table|nil Options: { images = {...} }
function M.steer(message, opts)
  local client = M.state.get("rpc_client")
  if not client then
    vim.notify("Pi: Not connected", vim.log.levels.ERROR)
    return
  end
  
  local agent = require("pi.rpc.agent")
  agent.steer(client, message, opts, function(result)
    vim.schedule(function()
      if result.error then
        vim.notify("Pi: Failed to steer - " .. result.error, vim.log.levels.ERROR)
      else
        vim.notify("Pi: Steering message sent", vim.log.levels.INFO)
      end
    end)
  end)
end

--- Queue a follow-up message to be processed after agent finishes
-- @param message string The follow-up message
-- @param opts table|nil Options: { images = {...} }
function M.follow_up(message, opts)
  local client = M.state.get("rpc_client")
  if not client then
    vim.notify("Pi: Not connected", vim.log.levels.ERROR)
    return
  end
  
  local agent = require("pi.rpc.agent")
  agent.follow_up(client, message, opts, function(result)
    vim.schedule(function()
      if result.error then
        vim.notify("Pi: Failed to queue follow-up - " .. result.error, vim.log.levels.ERROR)
      else
        vim.notify("Pi: Follow-up queued", vim.log.levels.INFO)
      end
    end)
  end)
end

--- Abort the current agent operation
function M.abort()
  local client = M.state.get("rpc_client")
  if not client then return end
  
  local agent = require("pi.rpc.agent")
  agent.abort(client, function(result)
    vim.schedule(function()
      if result.error then
        vim.notify("Pi: Failed to abort - " .. result.error, vim.log.levels.ERROR)
      else
        vim.notify("Pi: Agent aborted", vim.log.levels.INFO)
      end
    end)
  end)
end

-- Alias for backward compatibility
function M.stop()
  M.abort()
end

--- Get current agent status
function M.status(callback)
  local client = M.state.get("rpc_client")
  if not client then
    vim.notify("Pi: Not connected", vim.log.levels.ERROR)
    return
  end
  
  local agent = require("pi.rpc.agent")
  agent.status(client, callback)
end

--- Get conversation messages
function M.get_messages(callback)
  local client = M.state.get("rpc_client")
  if not client then
    vim.notify("Pi: Not connected", vim.log.levels.ERROR)
    return
  end
  
  local conversation = require("pi.rpc.conversation")
  conversation.get_messages(client, callback)
end

--- Get last assistant response text
function M.get_last_response(callback)
  local client = M.state.get("rpc_client")
  if not client then
    vim.notify("Pi: Not connected", vim.log.levels.ERROR)
    return
  end
  
  local conversation = require("pi.rpc.conversation")
  conversation.get_last_assistant_text(client, callback)
end

--- Execute a bash command (output added to conversation context on next prompt)
-- @param command string The shell command to execute
-- @param callback function|nil Called with result
function M.bash(command, callback)
  local client = M.state.get("rpc_client")
  if not client then
    vim.notify("Pi: Not connected", vim.log.levels.ERROR)
    return
  end
  
  local bash = require("pi.rpc.bash")
  bash.execute(client, command, function(result)
    vim.schedule(function()
      if result and result.success then
        local data = result.data or {}
        local exit_code = data.exitCode or 0
        local truncated = data.truncated and " (truncated)" or ""
        vim.notify(string.format("Pi: Bash completed (exit %d)%s", exit_code, truncated), vim.log.levels.INFO)
      elseif result and result.error then
        vim.notify("Pi: Bash failed - " .. result.error, vim.log.levels.ERROR)
      end
      if callback then callback(result) end
    end)
  end)
end

--- Abort a running bash command
function M.abort_bash()
  local client = M.state.get("rpc_client")
  if not client then return end
  
  local bash = require("pi.rpc.bash")
  if not bash.is_running() then
    vim.notify("Pi: No bash command running", vim.log.levels.WARN)
    return
  end
  
  bash.abort(client, function(result)
    vim.schedule(function()
      if result and result.success then
        vim.notify("Pi: Bash command aborted", vim.log.levels.INFO)
      else
        vim.notify("Pi: Failed to abort bash", vim.log.levels.ERROR)
      end
    end)
  end)
end

return M
