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
end, { nargs = "+", desc = "Send prompt to Pi agent" })

vim.api.nvim_create_user_command("PiSteer", function(opts)
  local message = opts.args
  if message == "" then
    vim.notify("Usage: :PiSteer <message>", vim.log.levels.ERROR)
    return
  end
  require("pi").steer(message)
end, { nargs = "+", desc = "Steer agent mid-run (interrupt with new instructions)" })

vim.api.nvim_create_user_command("PiFollowUp", function(opts)
  local message = opts.args
  if message == "" then
    vim.notify("Usage: :PiFollowUp <message>", vim.log.levels.ERROR)
    return
  end
  require("pi").follow_up(message)
end, { nargs = "+", desc = "Queue follow-up message (processed after agent finishes)" })

vim.api.nvim_create_user_command("PiAbort", function()
  require("pi").abort()
end, { desc = "Abort current agent operation" })

-- Alias for backward compatibility
vim.api.nvim_create_user_command("PiStop", function()
  require("pi").abort()
end, { desc = "Abort current agent operation (alias for :PiAbort)" })

vim.api.nvim_create_user_command("PiStatus", function()
  require("pi").status(function(result)
    if result and result.success then
      local data = result.data
      print("Pi Agent Status:")
      print("  Streaming: " .. tostring(data.isStreaming))
      print("  Model: " .. (data.model and data.model.name or "none"))
      print("  Thinking: " .. (data.thinkingLevel or "off"))
      print("  Session: " .. (data.sessionName or data.sessionId or "none"))
      print("  Messages: " .. (data.messageCount or 0))
      print("  Pending: " .. (data.pendingMessageCount or 0))
      print("  Auto-compact: " .. tostring(data.autoCompactionEnabled))
    else
      vim.notify("Pi: Failed to get status", vim.log.levels.ERROR)
    end
  end)
end, { desc = "Show Pi agent status" })

-- UI commands
vim.api.nvim_create_user_command("PiToggle", function()
  local pi = require("pi")
  if not require("pi.state").get("connected") then
    pi.connect(function(success, err)
      if success then
        require("pi.ui.control_panel").toggle()
      else
        vim.notify("Pi: Failed to connect - " .. tostring(err), vim.log.levels.ERROR)
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
  require("pi.ui.chat").toggle()
end, { desc = "Toggle Pi chat" })

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
  local client = state.get("rpc_client")
  print("Connected: " .. tostring(state.get("connected")))
  print("Client exists: " .. (client and "yes" or "no"))
  if client then
    print("  job_id: " .. tostring(client.job_id))
    print("  connected: " .. tostring(client.connected))
    print("  request_id: " .. tostring(client.request_id))
    print("  pending requests: " .. vim.tbl_count(client.pending))
  end
  print("Chat open: " .. tostring(state.get("ui.chat_open")))
  
  -- Show recent RPC log
  local log_path = vim.fn.stdpath("cache") .. "/pi_rpc/debug.log"
  print("\n=== RPC Log (last 20 lines) ===")
  local lines = vim.fn.readfile(log_path)
  local start_idx = math.max(1, #lines - 19)
  for i = start_idx, #lines do
    print(lines[i])
  end
end, { desc = "Debug Pi connection" })

vim.api.nvim_create_user_command("PiTestRPC", function()
  local client = require("pi.state").get("rpc_client")
  if not client then
    vim.notify("No RPC client. Run :PiConnect first", vim.log.levels.ERROR)
    return
  end
  
  vim.notify("Testing get_state...", vim.log.levels.INFO)
  client:request("get_state", { type = "get_state" }, function(result)
    vim.schedule(function()
      if result.success then
        vim.notify("RPC test SUCCESS", vim.log.levels.INFO)
        print(vim.inspect(result.data):sub(1, 500))
      else
        vim.notify("RPC test FAILED: " .. tostring(result.error), vim.log.levels.ERROR)
      end
    end)
  end)
end, { desc = "Test RPC connection" })

-- Test file opening
vim.api.nvim_create_user_command("PiTestOpen", function(opts)
  local chat = require("pi.ui.chat")
  local filepath = opts.args ~= "" and opts.args or vim.fn.expand("%:p")
  chat.open_file_in_other_window(filepath)
end, { nargs = "?", complete = "file", desc = "Test opening file in other window" })

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

-- Conversation commands
vim.api.nvim_create_user_command("PiMessages", function(opts)
  local client = require("pi.state").get("rpc_client")
  if not client then
    vim.notify("Pi: Not connected", vim.log.levels.ERROR)
    return
  end
  
  local conversation = require("pi.rpc.conversation")
  conversation.get_messages(client, function(result)
    if result and result.success then
      local messages = result.data and result.data.messages or {}
      
      if #messages == 0 then
        print("No messages in conversation")
        return
      end
      
      print("=== Conversation (" .. #messages .. " messages) ===")
      for i, msg in ipairs(messages) do
        local formatted = conversation.format_message(msg)
        local role = formatted.role:upper()
        local text = formatted.text:sub(1, 100)
        if #formatted.text > 100 then
          text = text .. "..."
        end
        
        -- Add tool info for tool results
        local extra = ""
        if formatted.role == "toolResult" then
          extra = " [" .. (formatted.tool_name or "?") .. "]"
        elseif formatted.role == "assistant" and #formatted.tool_calls > 0 then
          local tools = {}
          for _, tc in ipairs(formatted.tool_calls) do
            table.insert(tools, tc.name)
          end
          extra = " → " .. table.concat(tools, ", ")
        end
        
        print(string.format("%d. [%s]%s %s", i, role, extra, text:gsub("\n", " ")))
      end
    else
      vim.notify("Failed to get messages: " .. (result.error or "unknown"), vim.log.levels.ERROR)
    end
  end)
end, { desc = "Show conversation messages" })

vim.api.nvim_create_user_command("PiLastResponse", function()
  local client = require("pi.state").get("rpc_client")
  if not client then
    vim.notify("Pi: Not connected", vim.log.levels.ERROR)
    return
  end
  
  local conversation = require("pi.rpc.conversation")
  conversation.get_last_assistant_text(client, function(result)
    if result and result.success then
      local text = result.data and result.data.text
      if text then
        -- Open in a scratch buffer for easy copying
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, "\n"))
        vim.bo[buf].buftype = "nofile"
        vim.bo[buf].filetype = "markdown"
        vim.bo[buf].bufhidden = "wipe"
        
        -- Open in a split
        vim.cmd("split")
        vim.api.nvim_win_set_buf(0, buf)
        vim.api.nvim_buf_set_name(buf, "[Pi Last Response]")
      else
        vim.notify("No assistant response yet", vim.log.levels.INFO)
      end
    else
      vim.notify("Failed to get last response", vim.log.levels.ERROR)
    end
  end)
end, { desc = "Show last assistant response in buffer" })
