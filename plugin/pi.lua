-- Only load once
if vim.g.loaded_pi then
  return
end
vim.g.loaded_pi = true

-- Main commands
vim.api.nvim_create_user_command("PiConnect", function()
  require("pi").connect()
end, {})

vim.api.nvim_create_user_command("PiDisconnect", function()
  require("pi").disconnect()
end, {})

-- Spawn/stop Pi RPC process
vim.api.nvim_create_user_command("PiSpawn", function()
  require("pi").spawn(function(success)
    if success then
      vim.notify("Pi: Spawned successfully", vim.log.levels.INFO)
    end
  end)
end, { desc = "Spawn Pi RPC server process" })

vim.api.nvim_create_user_command("PiStopProcess", function()
  require("pi").stop_process()
end, { desc = "Stop the spawned Pi RPC process" })

vim.api.nvim_create_user_command("PiStart", function(opts)
  local task = opts.args
  if task == "" then
    vim.notify("Usage: :PiStart <task description>", vim.log.levels.ERROR)
    return
  end
  require("pi").start(task)
end, { nargs = "+", desc = "Start Pi agent with task (auto-spawns if needed)" })

vim.api.nvim_create_user_command("PiPause", function()
  require("pi").pause()
end, {})

vim.api.nvim_create_user_command("PiResume", function()
  require("pi").resume()
end, {})

vim.api.nvim_create_user_command("PiStop", function()
  require("pi").stop()
end, {})

-- UI commands with auto-spawn
vim.api.nvim_create_user_command("PiToggle", function()
  local pi = require("pi")
  -- Auto-spawn and connect if needed, then toggle panel
  pi.ensure_connected({ auto_spawn = true }, function(connected)
    if connected then
      require("pi.ui.control_panel").toggle()
    else
      vim.notify("Pi: Could not connect to agent", vim.log.levels.ERROR)
    end
  end)
end, { desc = "Toggle Pi control panel (auto-spawns if needed)" })

vim.api.nvim_create_user_command("PiLogs", function()
  require("pi.ui.logs_viewer").toggle()
end, { desc = "Toggle Pi logs viewer" })

vim.api.nvim_create_user_command("PiChat", function()
  local pi = require("pi")
  -- Auto-spawn and connect if needed, then open chat
  pi.ensure_connected({ auto_spawn = true }, function(connected)
    if connected then
      require("pi.ui.chat").toggle()
    else
      vim.notify("Pi: Could not connect to agent", vim.log.levels.ERROR)
    end
  end)
end, { desc = "Toggle Pi chat interface (auto-spawns if needed)" })

vim.api.nvim_create_user_command("PiDiff", function(opts)
  local filepath = opts.args
  if filepath == "" then
    filepath = vim.fn.expand("%:p")
  end
  require("pi.ui.diff_viewer").show(filepath)
end, { nargs = "?", complete = "file", desc = "Show diff for file" })

-- Approval commands
vim.api.nvim_create_user_command("PiApprove", function()
  require("pi.ui.approval").approve()
end, { desc = "Approve pending change" })

vim.api.nvim_create_user_command("PiReject", function()
  require("pi.ui.approval").reject()
end, { desc = "Reject pending change" })

-- Session commands
vim.api.nvim_create_user_command("PiSessionList", function()
  local client = require("pi.state").get("rpc_client")
  local session = require("pi.rpc.session")

  session.list(client, function(result)
    if result.error then
      vim.notify("Failed to list sessions: " .. result.error, vim.log.levels.ERROR)
      return
    end

    if #result.sessions == 0 then
      vim.notify("No saved sessions", vim.log.levels.INFO)
      return
    end

    print("Available sessions:")
    for _, s in ipairs(result.sessions) do
      print(string.format("  %s - %s", s.id, s.name or "Unnamed"))
    end
  end)
end, { desc = "List available sessions" })

vim.api.nvim_create_user_command("PiSessionLoad", function(opts)
  local session_id = opts.args
  if session_id == "" then
    vim.notify("Usage: :PiSessionLoad <session_id>", vim.log.levels.ERROR)
    return
  end

  local client = require("pi.state").get("rpc_client")
  local session = require("pi.rpc.session")

  session.load(client, session_id, function(result)
    if result.error then
      vim.notify("Failed to load session: " .. result.error, vim.log.levels.ERROR)
    else
      vim.notify("Session loaded!", vim.log.levels.INFO)
    end
  end)
end, { nargs = 1, desc = "Load a session" })

vim.api.nvim_create_user_command("PiSessionSave", function(opts)
  local name = opts.args
  local client = require("pi.state").get("rpc_client")
  local session = require("pi.rpc.session")

  session.save(client, name, function(result)
    if result.error then
      vim.notify("Failed to save session: " .. result.error, vim.log.levels.ERROR)
    else
      vim.notify("Session saved!", vim.log.levels.INFO)
    end
  end)
end, { nargs = "?", desc = "Save current session" })
