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
  if not client then
    vim.notify("Pi: Not connected", vim.log.levels.ERROR)
    return
  end
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
    print("  buffer size: " .. #client.buffer)
  end
  print("Agent running: " .. tostring(state.get("agent.running")))
  print("Chat open: " .. tostring(state.get("ui.chat_open")))
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

vim.api.nvim_create_user_command("PiSessionNew", function()
  local client = require("pi.state").get("rpc_client")
  if not client then
    vim.notify("Pi: Not connected", vim.log.levels.ERROR)
    return
  end
  local session = require("pi.rpc.session")
  session.new(client, {}, function(result)
    if result and result.success then
      if result.data and result.data.cancelled then
        vim.notify("Pi: New session cancelled by extension", vim.log.levels.WARN)
      else
        vim.notify("Pi: New session started", vim.log.levels.INFO)
      end
    else
      vim.notify("Pi: Failed to start new session - " .. (result.error or "unknown"), vim.log.levels.ERROR)
    end
  end)
end, { desc = "Start a new session" })

vim.api.nvim_create_user_command("PiSessionStats", function()
  local client = require("pi.state").get("rpc_client")
  if not client then
    vim.notify("Pi: Not connected", vim.log.levels.ERROR)
    return
  end
  local session = require("pi.rpc.session")
  session.get_stats(client, function(result)
    if result and result.success then
      local data = result.data
      print("=== Session Statistics ===")
      print("  Session ID: " .. (data.sessionId or "?"))
      print("  Session File: " .. (data.sessionFile or "?"))
      print("  User Messages: " .. (data.userMessages or 0))
      print("  Assistant Messages: " .. (data.assistantMessages or 0))
      print("  Tool Calls: " .. (data.toolCalls or 0))
      print("  Total Messages: " .. (data.totalMessages or 0))
      if data.tokens then
        print("  Tokens:")
        print("    Input: " .. (data.tokens.input or 0))
        print("    Output: " .. (data.tokens.output or 0))
        print("    Cache Read: " .. (data.tokens.cacheRead or 0))
        print("    Cache Write: " .. (data.tokens.cacheWrite or 0))
        print("    Total: " .. (data.tokens.total or 0))
      end
      if data.cost then
        print(string.format("  Cost: $%.4f", data.cost))
      end
    else
      vim.notify("Pi: Failed to get stats - " .. (result.error or "unknown"), vim.log.levels.ERROR)
    end
  end)
end, { desc = "Show session statistics" })

vim.api.nvim_create_user_command("PiSessionExport", function(opts)
  local client = require("pi.state").get("rpc_client")
  if not client then
    vim.notify("Pi: Not connected", vim.log.levels.ERROR)
    return
  end
  local session = require("pi.rpc.session")
  local export_opts = {}
  if opts.args ~= "" then
    export_opts.outputPath = opts.args
  end
  session.export_html(client, export_opts, function(result)
    if result and result.success then
      local path = result.data and result.data.path or "?"
      vim.notify("Pi: Session exported to " .. path, vim.log.levels.INFO)
    else
      vim.notify("Pi: Export failed - " .. (result.error or "unknown"), vim.log.levels.ERROR)
    end
  end)
end, { nargs = "?", complete = "file", desc = "Export session to HTML" })

vim.api.nvim_create_user_command("PiSessionSwitch", function(opts)
  local client = require("pi.state").get("rpc_client")
  if not client then
    vim.notify("Pi: Not connected", vim.log.levels.ERROR)
    return
  end
  if opts.args == "" then
    vim.notify("Usage: :PiSessionSwitch <path/to/session.jsonl>", vim.log.levels.ERROR)
    return
  end
  local session = require("pi.rpc.session")
  session.switch(client, opts.args, function(result)
    if result and result.success then
      if result.data and result.data.cancelled then
        vim.notify("Pi: Session switch cancelled by extension", vim.log.levels.WARN)
      else
        vim.notify("Pi: Switched to session", vim.log.levels.INFO)
      end
    else
      vim.notify("Pi: Failed to switch session - " .. (result.error or "unknown"), vim.log.levels.ERROR)
    end
  end)
end, { nargs = 1, complete = "file", desc = "Switch to a different session file" })

vim.api.nvim_create_user_command("PiSessionName", function(opts)
  local client = require("pi.state").get("rpc_client")
  if not client then
    vim.notify("Pi: Not connected", vim.log.levels.ERROR)
    return
  end
  if opts.args == "" then
    vim.notify("Usage: :PiSessionName <name>", vim.log.levels.ERROR)
    return
  end
  local session = require("pi.rpc.session")
  session.set_name(client, opts.args, function(result)
    if result and result.success then
      vim.notify("Pi: Session name set to '" .. opts.args .. "'", vim.log.levels.INFO)
    else
      vim.notify("Pi: Failed to set name - " .. (result.error or "unknown"), vim.log.levels.ERROR)
    end
  end)
end, { nargs = "+", desc = "Set session display name" })

vim.api.nvim_create_user_command("PiSessionFork", function(opts)
  local client = require("pi.state").get("rpc_client")
  if not client then
    vim.notify("Pi: Not connected", vim.log.levels.ERROR)
    return
  end
  local session = require("pi.rpc.session")
  
  if opts.args ~= "" then
    -- Fork from specific entry ID
    session.fork(client, opts.args, function(result)
      if result and result.success then
        if result.data and result.data.cancelled then
          vim.notify("Pi: Fork cancelled by extension", vim.log.levels.WARN)
        else
          vim.notify("Pi: Forked from message", vim.log.levels.INFO)
        end
      else
        vim.notify("Pi: Fork failed - " .. (result.error or "unknown"), vim.log.levels.ERROR)
      end
    end)
  else
    -- Show available fork points
    session.get_fork_messages(client, function(result)
      if result and result.success then
        local messages = result.data and result.data.messages or {}
        if #messages == 0 then
          vim.notify("Pi: No messages available to fork from", vim.log.levels.INFO)
          return
        end
        
        -- Use vim.ui.select to pick a message
        local items = {}
        for _, msg in ipairs(messages) do
          local text = msg.text:sub(1, 60):gsub("\n", " ")
          if #msg.text > 60 then text = text .. "..." end
          table.insert(items, { id = msg.entryId, display = text })
        end
        
        vim.ui.select(items, {
          prompt = "Fork from message:",
          format_item = function(item) return item.display end,
        }, function(choice)
          if choice then
            session.fork(client, choice.id, function(fork_result)
              if fork_result and fork_result.success then
                vim.notify("Pi: Forked from message", vim.log.levels.INFO)
              else
                vim.notify("Pi: Fork failed", vim.log.levels.ERROR)
              end
            end)
          end
        end)
      else
        vim.notify("Pi: Failed to get fork messages - " .. (result.error or "unknown"), vim.log.levels.ERROR)
      end
    end)
  end
end, { nargs = "?", desc = "Fork from a previous message (interactive if no ID given)" })

-- Conversation commands
vim.api.nvim_create_user_command("PiMessages", function()
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

-- Bash commands
vim.api.nvim_create_user_command("PiBash", function(opts)
  local command = opts.args
  if command == "" then
    vim.notify("Usage: :PiBash <shell command>", vim.log.levels.ERROR)
    return
  end
  require("pi").bash(command)
end, { nargs = "+", desc = "Execute bash command (output added to next prompt)" })

vim.api.nvim_create_user_command("PiBashAbort", function()
  require("pi").abort_bash()
end, { desc = "Abort running bash command" })

vim.api.nvim_create_user_command("PiBashLast", function()
  local bash = require("pi.rpc.bash")
  local last = bash.get_last()
  
  if not last then
    vim.notify("No bash execution history", vim.log.levels.INFO)
    return
  end
  
  -- Open output in a scratch buffer
  local buf = vim.api.nvim_create_buf(false, true)
  local lines = {
    "# Command: " .. last.command,
    "# Exit code: " .. (last.exit_code or "?"),
    "# Truncated: " .. tostring(last.truncated or false),
    "",
  }
  
  if last.output then
    for _, line in ipairs(vim.split(last.output, "\n")) do
      table.insert(lines, line)
    end
  else
    table.insert(lines, "(no output)")
  end
  
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].filetype = "sh"
  vim.bo[buf].bufhidden = "wipe"
  
  vim.cmd("split")
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_buf_set_name(buf, "[Pi Bash Output]")
end, { desc = "Show last bash command output" })

vim.api.nvim_create_user_command("PiBashHistory", function()
  local bash = require("pi.rpc.bash")
  local history = bash.get_history()
  
  if #history == 0 then
    print("No bash execution history")
    return
  end
  
  print("=== Bash History (" .. #history .. " commands) ===")
  for i, exec in ipairs(history) do
    local status = exec.exit_code == 0 and "✓" or "✗"
    local truncated = exec.truncated and " (truncated)" or ""
    print(string.format("%d. [%s] %s%s", i, status, exec.command:sub(1, 60), truncated))
  end
end, { desc = "Show bash execution history" })

-- Extension UI commands
vim.api.nvim_create_user_command("PiExtensionStatuses", function()
  local extension = require("pi.ui.extension")
  local statuses = extension.get_statuses()
  
  if vim.tbl_isempty(statuses) then
    print("No extension statuses")
    return
  end
  
  print("=== Extension Statuses ===")
  for key, text in pairs(statuses) do
    print(string.format("  [%s] %s", key, text))
  end
end, { desc = "Show extension status entries" })

vim.api.nvim_create_user_command("PiExtensionWidgets", function()
  local extension = require("pi.ui.extension")
  local widgets = extension.get_widgets()
  
  if vim.tbl_isempty(widgets) then
    print("No extension widgets")
    return
  end
  
  print("=== Extension Widgets ===")
  for key, widget in pairs(widgets) do
    print(string.format("  [%s] (%s)", key, widget.placement))
    for _, line in ipairs(widget.lines or {}) do
      print("    " .. line)
    end
  end
end, { desc = "Show extension widgets" })

-- Model commands
vim.api.nvim_create_user_command("PiModel", function()
  local model_mod = require("pi.rpc.model")
  local current = model_mod.get_current()
  local level = model_mod.get_thinking_level()
  
  if current then
    print("Current Model: " .. model_mod.format(current))
    print("  ID: " .. (current.id or "?"))
    print("  Provider: " .. (current.provider or "?"))
    print("  Reasoning: " .. tostring(current.reasoning or false))
    print("  Context Window: " .. (current.contextWindow or "?"))
    print("  Thinking Level: " .. (level or "off"))
  else
    print("No model selected")
  end
end, { desc = "Show current model info" })

vim.api.nvim_create_user_command("PiModelSet", function(opts)
  local client = require("pi.state").get("rpc_client")
  if not client then
    vim.notify("Pi: Not connected", vim.log.levels.ERROR)
    return
  end
  
  local args = vim.split(opts.args, "%s+")
  if #args < 2 then
    vim.notify("Usage: :PiModelSet <provider> <modelId>", vim.log.levels.ERROR)
    return
  end
  
  local provider, modelId = args[1], args[2]
  local model_mod = require("pi.rpc.model")
  model_mod.set(client, provider, modelId, function(result)
    if result and result.success then
      vim.notify("Pi: Model set to " .. model_mod.format(result.data), vim.log.levels.INFO)
    else
      vim.notify("Pi: Failed to set model - " .. (result.error or "unknown"), vim.log.levels.ERROR)
    end
  end)
end, { nargs = "+", desc = "Set model: :PiModelSet <provider> <modelId>" })

vim.api.nvim_create_user_command("PiModelCycle", function()
  local client = require("pi.state").get("rpc_client")
  if not client then
    vim.notify("Pi: Not connected", vim.log.levels.ERROR)
    return
  end
  
  local model_mod = require("pi.rpc.model")
  model_mod.cycle(client, function(result)
    if result and result.success then
      if result.data and result.data.model then
        vim.notify("Pi: Cycled to " .. model_mod.format(result.data.model), vim.log.levels.INFO)
      else
        vim.notify("Pi: Only one model available", vim.log.levels.INFO)
      end
    else
      vim.notify("Pi: Failed to cycle model - " .. (result.error or "unknown"), vim.log.levels.ERROR)
    end
  end)
end, { desc = "Cycle to next available model" })

vim.api.nvim_create_user_command("PiModelList", function()
  local client = require("pi.state").get("rpc_client")
  if not client then
    vim.notify("Pi: Not connected", vim.log.levels.ERROR)
    return
  end
  
  local model_mod = require("pi.rpc.model")
  model_mod.get_available(client, function(result)
    if result and result.success then
      local models = result.data and result.data.models or {}
      if #models == 0 then
        print("No models available")
        return
      end
      
      print("=== Available Models ===")
      local current = model_mod.get_current()
      for _, model in ipairs(models) do
        local marker = (current and current.id == model.id) and " *" or ""
        local reasoning = model.reasoning and " [reasoning]" or ""
        print(string.format("  %s (%s)%s%s", model.name or model.id, model.provider, reasoning, marker))
      end
    else
      vim.notify("Pi: Failed to list models - " .. (result.error or "unknown"), vim.log.levels.ERROR)
    end
  end)
end, { desc = "List available models" })

vim.api.nvim_create_user_command("PiThinking", function(opts)
  local client = require("pi.state").get("rpc_client")
  if not client then
    vim.notify("Pi: Not connected", vim.log.levels.ERROR)
    return
  end
  
  local model_mod = require("pi.rpc.model")
  
  if opts.args == "" then
    -- Cycle thinking level
    model_mod.cycle_thinking_level(client, function(result)
      if result and result.success then
        if result.data and result.data.level then
          vim.notify("Pi: Thinking level: " .. result.data.level, vim.log.levels.INFO)
        else
          vim.notify("Pi: Model doesn't support thinking", vim.log.levels.WARN)
        end
      else
        vim.notify("Pi: Failed to cycle thinking - " .. (result.error or "unknown"), vim.log.levels.ERROR)
      end
    end)
  else
    -- Set specific level
    local level = opts.args
    local valid = { off = true, minimal = true, low = true, medium = true, high = true, xhigh = true }
    if not valid[level] then
      vim.notify("Pi: Invalid level. Use: off, minimal, low, medium, high, xhigh", vim.log.levels.ERROR)
      return
    end
    
    model_mod.set_thinking_level(client, level, function(result)
      if result and result.success then
        vim.notify("Pi: Thinking level set to " .. level, vim.log.levels.INFO)
      else
        vim.notify("Pi: Failed to set thinking - " .. (result.error or "unknown"), vim.log.levels.ERROR)
      end
    end)
  end
end, { nargs = "?", desc = "Set/cycle thinking level (off, minimal, low, medium, high, xhigh)" })

-- Maintenance commands
vim.api.nvim_create_user_command("PiCompact", function(opts)
  local client = require("pi.state").get("rpc_client")
  if not client then
    vim.notify("Pi: Not connected", vim.log.levels.ERROR)
    return
  end
  
  local maint = require("pi.rpc.maintenance")
  local instructions = opts.args ~= "" and opts.args or nil
  
  vim.notify("Pi: Compacting conversation...", vim.log.levels.INFO)
  maint.compact(client, instructions, function(result)
    if result and result.success then
      local data = result.data or {}
      local tokens_before = data.tokensBefore or "?"
      vim.notify(string.format("Pi: Compacted (was %s tokens)", tokens_before), vim.log.levels.INFO)
    else
      vim.notify("Pi: Compaction failed - " .. (result.error or "unknown"), vim.log.levels.ERROR)
    end
  end)
end, { nargs = "?", desc = "Compact conversation (optional: custom instructions)" })

vim.api.nvim_create_user_command("PiAutoCompact", function(opts)
  local client = require("pi.state").get("rpc_client")
  if not client then
    vim.notify("Pi: Not connected", vim.log.levels.ERROR)
    return
  end
  
  local maint = require("pi.rpc.maintenance")
  local enabled = opts.args == "on" or opts.args == "true" or opts.args == "1"
  local disabled = opts.args == "off" or opts.args == "false" or opts.args == "0"
  
  if not enabled and not disabled then
    -- Show current status
    local current = require("pi.state").get("agent.auto_compaction")
    vim.notify("Pi: Auto-compaction is " .. (current and "enabled" or "disabled"), vim.log.levels.INFO)
    return
  end
  
  maint.set_auto_compaction(client, enabled, function(result)
    if result and result.success then
      vim.notify("Pi: Auto-compaction " .. (enabled and "enabled" or "disabled"), vim.log.levels.INFO)
    else
      vim.notify("Pi: Failed - " .. (result.error or "unknown"), vim.log.levels.ERROR)
    end
  end)
end, { nargs = "?", desc = "Set auto-compaction (on/off)" })

vim.api.nvim_create_user_command("PiAutoRetry", function(opts)
  local client = require("pi.state").get("rpc_client")
  if not client then
    vim.notify("Pi: Not connected", vim.log.levels.ERROR)
    return
  end
  
  local maint = require("pi.rpc.maintenance")
  local enabled = opts.args == "on" or opts.args == "true" or opts.args == "1"
  local disabled = opts.args == "off" or opts.args == "false" or opts.args == "0"
  
  if not enabled and not disabled then
    -- Show current status
    local current = require("pi.state").get("agent.auto_retry")
    vim.notify("Pi: Auto-retry is " .. (current and "enabled" or "disabled"), vim.log.levels.INFO)
    return
  end
  
  maint.set_auto_retry(client, enabled, function(result)
    if result and result.success then
      vim.notify("Pi: Auto-retry " .. (enabled and "enabled" or "disabled"), vim.log.levels.INFO)
    else
      vim.notify("Pi: Failed - " .. (result.error or "unknown"), vim.log.levels.ERROR)
    end
  end)
end, { nargs = "?", desc = "Set auto-retry (on/off)" })

vim.api.nvim_create_user_command("PiAbortRetry", function()
  local client = require("pi.state").get("rpc_client")
  if not client then
    vim.notify("Pi: Not connected", vim.log.levels.ERROR)
    return
  end
  
  local maint = require("pi.rpc.maintenance")
  if not maint.is_retrying() then
    vim.notify("Pi: No retry in progress", vim.log.levels.WARN)
    return
  end
  
  maint.abort_retry(client, function(result)
    if result and result.success then
      vim.notify("Pi: Retry aborted", vim.log.levels.INFO)
    else
      vim.notify("Pi: Failed to abort retry - " .. (result.error or "unknown"), vim.log.levels.ERROR)
    end
  end)
end, { desc = "Abort in-progress retry" })

vim.api.nvim_create_user_command("PiSteeringMode", function(opts)
  local client = require("pi.state").get("rpc_client")
  if not client then
    vim.notify("Pi: Not connected", vim.log.levels.ERROR)
    return
  end
  
  local maint = require("pi.rpc.maintenance")
  local mode = opts.args
  
  if mode == "" then
    local current = require("pi.state").get("agent.steering_mode") or "one-at-a-time"
    vim.notify("Pi: Steering mode: " .. current, vim.log.levels.INFO)
    return
  end
  
  if mode ~= "all" and mode ~= "one-at-a-time" then
    vim.notify("Pi: Invalid mode. Use: all, one-at-a-time", vim.log.levels.ERROR)
    return
  end
  
  maint.set_steering_mode(client, mode, function(result)
    if result and result.success then
      vim.notify("Pi: Steering mode set to " .. mode, vim.log.levels.INFO)
    else
      vim.notify("Pi: Failed - " .. (result.error or "unknown"), vim.log.levels.ERROR)
    end
  end)
end, { nargs = "?", desc = "Set steering mode (all, one-at-a-time)" })

vim.api.nvim_create_user_command("PiFollowUpMode", function(opts)
  local client = require("pi.state").get("rpc_client")
  if not client then
    vim.notify("Pi: Not connected", vim.log.levels.ERROR)
    return
  end
  
  local maint = require("pi.rpc.maintenance")
  local mode = opts.args
  
  if mode == "" then
    local current = require("pi.state").get("agent.follow_up_mode") or "one-at-a-time"
    vim.notify("Pi: Follow-up mode: " .. current, vim.log.levels.INFO)
    return
  end
  
  if mode ~= "all" and mode ~= "one-at-a-time" then
    vim.notify("Pi: Invalid mode. Use: all, one-at-a-time", vim.log.levels.ERROR)
    return
  end
  
  maint.set_follow_up_mode(client, mode, function(result)
    if result and result.success then
      vim.notify("Pi: Follow-up mode set to " .. mode, vim.log.levels.INFO)
    else
      vim.notify("Pi: Failed - " .. (result.error or "unknown"), vim.log.levels.ERROR)
    end
  end)
end, { nargs = "?", desc = "Set follow-up mode (all, one-at-a-time)" })

-- Command discovery
vim.api.nvim_create_user_command("PiCommands", function(opts)
  local client = require("pi.state").get("rpc_client")
  if not client then
    vim.notify("Pi: Not connected", vim.log.levels.ERROR)
    return
  end
  
  local commands_mod = require("pi.rpc.commands")
  local filter = opts.args ~= "" and opts.args or nil
  
  commands_mod.get_all(client, function(result)
    if result and result.success then
      local commands = result.data and result.data.commands or {}
      
      -- Apply filter if specified
      if filter then
        local filtered = {}
        for _, cmd in ipairs(commands) do
          if cmd.source == filter then
            table.insert(filtered, cmd)
          end
        end
        commands = filtered
      end
      
      if #commands == 0 then
        print("No commands found" .. (filter and (" for source: " .. filter) or ""))
        return
      end
      
      print("=== Pi Commands (" .. #commands .. ") ===")
      
      -- Group by source
      local by_source = {}
      for _, cmd in ipairs(commands) do
        local source = cmd.source or "unknown"
        by_source[source] = by_source[source] or {}
        table.insert(by_source[source], cmd)
      end
      
      local order = { "extension", "prompt", "skill" }
      for _, source in ipairs(order) do
        local cmds = by_source[source]
        if cmds and #cmds > 0 then
          print("\n[" .. source:upper() .. "]")
          for _, cmd in ipairs(cmds) do
            local desc = cmd.description and (" - " .. cmd.description) or ""
            local loc = cmd.location and (" (" .. cmd.location .. ")") or ""
            print("  /" .. cmd.name .. desc .. loc)
          end
        end
      end
    else
      vim.notify("Pi: Failed to get commands - " .. (result.error or "unknown"), vim.log.levels.ERROR)
    end
  end)
end, { nargs = "?", desc = "List available commands (optional filter: extension, prompt, skill)" })

vim.api.nvim_create_user_command("PiRun", function(opts)
  local client = require("pi.state").get("rpc_client")
  if not client then
    vim.notify("Pi: Not connected", vim.log.levels.ERROR)
    return
  end
  
  local command = opts.args
  if command == "" then
    vim.notify("Usage: :PiRun <command> [args]", vim.log.levels.ERROR)
    return
  end
  
  -- Ensure command starts with /
  if not command:match("^/") then
    command = "/" .. command
  end
  
  -- Send as prompt (Pi will handle command execution)
  require("pi").start(command)
end, { nargs = "+", desc = "Run a Pi command (e.g., :PiRun skill:search query)" })

vim.api.nvim_create_user_command("PiPalette", function()
  require("pi.ui.command_palette").open()
end, { desc = "Open Pi command palette" })
