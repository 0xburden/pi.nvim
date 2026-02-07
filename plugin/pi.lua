-- Only load once
if vim.g.loaded_pi then
  return
end
vim.g.loaded_pi = true

-- Main commands
vim.api.nvim_create_user_command("PiConnect", function()
  require("pi").connect()
end, { desc = "Connect to Pi RPC process" })

vim.api.nvim_create_user_command("PiDisconnect", function()
  require("pi").disconnect()
end, { desc = "Disconnect from Pi" })

vim.api.nvim_create_user_command("PiStart", function(opts)
  local task = opts.args
  if task == "" then
    vim.notify("Usage: :PiStart <task description>", vim.log.levels.ERROR)
    return
  end
  require("pi").start(task)
end, { nargs = "+", desc = "Start Pi agent with task" })

vim.api.nvim_create_user_command("PiPause", function()
  require("pi").pause()
end, { desc = "Pause the agent" })

vim.api.nvim_create_user_command("PiResume", function()
  require("pi").resume()
end, { desc = "Resume the agent" })

vim.api.nvim_create_user_command("PiStop", function()
  require("pi").stop()
end, { desc = "Stop/abort the agent" })

-- UI commands
vim.api.nvim_create_user_command("PiToggle", function()
  local pi = require("pi")
  if not require("pi.state").get("connected") then
    pi.connect(function(success)
      if success then
        require("pi.ui.control_panel").toggle()
      end
    end)
  else
    require("pi.ui.control_panel").toggle()
  end
end, { desc = "Toggle Pi control panel (auto-connects)" })

vim.api.nvim_create_user_command("PiLogs", function()
  require("pi.ui.logs_viewer").toggle()
end, { desc = "Toggle Pi logs viewer" })

vim.api.nvim_create_user_command("PiChat", function()
  local pi = require("pi")
  if not require("pi.state").get("connected") then
    pi.connect(function(success)
      if success then
        require("pi.ui.chat").toggle()
      end
    end)
  else
    require("pi.ui.chat").toggle()
  end
end, { desc = "Toggle Pi chat (auto-connects)" })

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
vim.api.nvim_create_user_command("PiSession", function()
  local client = require("pi.state").get("rpc_client")
  local session = require("pi.rpc.session")
  session.current(client, function(result)
    if result and result.success and result.data then
      local data = result.data
      print("Current Session:")
      print("  ID: " .. (data.sessionId or "none"))
      print("  Name: " .. (data.sessionName or "unnamed"))
      print("  File: " .. (data.sessionFile or "none"))
      print("  Messages: " .. (data.messageCount or 0))
    else
      vim.notify("No active session", vim.log.levels.INFO)
    end
  end)
end, { desc = "Show current session info" })

-- Debug command
vim.api.nvim_create_user_command("PiDebug", function()
  local events = require("pi.events")
  local state = require("pi.state")
  
  print("=== Pi Debug Info ===")
  print("Connected: " .. tostring(state.get("connected")))
  print("Client: " .. (state.get("rpc_client") and "yes" or "no"))
  print("Chat open: " .. tostring(state.get("ui.chat_open")))
  
  -- Subscribe to all events for 10 seconds
  print("\nListening to events for 10 seconds...")
  local unsub = events.on("rpc_event", function(evt)
    print("Event: " .. vim.inspect(evt):sub(1, 200))
  end)
  
  vim.defer_fn(function()
    unsub()
    print("\nDebug session ended")
  end, 10000)
end, { desc = "Debug Pi events (10s capture)" })

vim.api.nvim_create_user_command("PiSessionNew", function(opts)
  local client = require("pi.state").get("rpc_client")
  local session = require("pi.rpc.session")
  session.new(client, {}, function(result)
    if result and result.success then
      vim.notify("New session started", vim.log.levels.INFO)
    else
      vim.notify("Failed to start new session", vim.log.levels.ERROR)
    end
  end)
end, { desc = "Start a new session" })
