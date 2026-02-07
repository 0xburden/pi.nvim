local M = {}

M.state = require("pi.state")
M.events = require("pi.events")
M.config = require("pi.config")

function M.setup(opts)
  M.config.setup(opts or {})

  -- Set up highlight groups using colorscheme colors
  -- Use linked highlights that adapt to colorscheme
  vim.api.nvim_set_hl(0, "PiChatNormal", { link = "NormalFloat" })
  vim.api.nvim_set_hl(0, "PiChatInput", { link = "Pmenu" })

  local Client = require("pi.rpc.client")
  local client = Client.new({
    host = M.config.get("host"),
    port = M.config.get("port"),
  })

  M.state.update("rpc_client", client)

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

function M.start(task)
  if not M.state.get("connected") then
    M.connect(function(success)
      if success then
        M._send_prompt(task)
      end
    end)
    return
  end
  M._send_prompt(task)
end

function M._send_prompt(task)
  local client = M.state.get("rpc_client")
  client:request("prompt", { type = "prompt", message = task }, function(result)
    vim.schedule(function()
      if result.error then
        vim.notify("Pi: Failed to send prompt - " .. result.error, vim.log.levels.ERROR)
      else
        vim.notify("Pi: Prompt sent", vim.log.levels.INFO)
        M.state.update("agent.running", true)
        M.state.update("agent.current_task", task)

        if M.config.get("auto_open_logs") then
          require("pi.ui.logs_viewer").open()
        end
      end
    end)
  end)
end

function M.pause()
  local client = M.state.get("rpc_client")
  if not client then return end
  client:request("pause", { type = "pause" }, function(result)
    vim.schedule(function()
      if result.error then
        vim.notify("Pi: Failed to pause - " .. result.error, vim.log.levels.ERROR)
      else
        M.state.update("agent.paused", true)
      end
    end)
  end)
end

function M.resume()
  local client = M.state.get("rpc_client")
  if not client then return end
  client:request("resume", { type = "resume" }, function(result)
    vim.schedule(function()
      if result.error then
        vim.notify("Pi: Failed to resume - " .. result.error, vim.log.levels.ERROR)
      else
        M.state.update("agent.paused", false)
      end
    end)
  end)
end

function M.stop()
  local client = M.state.get("rpc_client")
  if not client then return end
  client:request("abort", { type = "abort" }, function(result)
    vim.schedule(function()
      if result.error then
        vim.notify("Pi: Failed to stop - " .. result.error, vim.log.levels.ERROR)
      else
        M.state.update("agent.running", false)
        M.state.update("agent.paused", false)
        M.state.update("agent.current_task", nil)
      end
    end)
  end)
end

return M
