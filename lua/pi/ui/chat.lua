local state = require("pi.state")
local events = require("pi.events")

local M = {}
M.buf = nil
M.win = nil
M.input_buf = nil
M.input_win = nil
M.status_win = nil
M.status_buf = nil

-- Event subscription
M.event_unsub = nil

-- Current message being streamed
M.current_response = nil
M.is_streaming = false

-- Get status text for status bar
function M.get_status_text()
  local client = state.get("rpc_client")
  if not client or not client.connected then
    return " ● Not connected "
  end
  
  if M.is_streaming then
    return " ⟳ Working... "
  end
  
  return " ○ Ready "
end

-- Update status bar
function M.update_status()
  if not M.status_buf or not vim.api.nvim_buf_is_valid(M.status_buf) then
    return
  end
  
  local status = M.get_status_text()
  vim.api.nvim_buf_set_option(M.status_buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(M.status_buf, 0, -1, false, { status })
  vim.api.nvim_buf_set_option(M.status_buf, "modifiable", false)
end

-- Open chat interface
function M.open()
  if M.is_open() then
    return
  end
  
  -- Create main buffer for conversation history
  M.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(M.buf, "buftype", "nofile")
  vim.api.nvim_buf_set_name(M.buf, "Pi Chat")
  vim.api.nvim_buf_set_option(M.buf, "wrap", true)
  vim.api.nvim_buf_set_option(M.buf, "linebreak", true)
  
  -- Create status buffer
  M.status_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(M.status_buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(M.status_buf, "modifiable", false)
  
  -- Create input buffer
  M.input_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(M.input_buf, "buftype", "prompt")
  vim.api.nvim_buf_set_option(M.input_buf, "modified", false)
  vim.fn.prompt_setprompt(M.input_buf, " λ ")
  
  -- Create status window (top)
  vim.cmd("botright 1split")
  M.status_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(M.status_win, M.status_buf)
  vim.api.nvim_win_set_option(M.status_win, "winfixheight", true)
  vim.api.nvim_win_set_option(M.status_win, "number", false)
  vim.api.nvim_win_set_option(M.status_win, "relativenumber", false)
  vim.api.nvim_win_set_option(M.status_win, "signcolumn", "no")
  vim.api.nvim_win_set_option(M.status_win, "cursorline", false)
  
  -- Create main chat window
  vim.cmd("belowright 20split")
  M.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(M.win, M.buf)
  
  -- Create input window
  vim.cmd("belowright 3split")
  M.input_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(M.input_win, M.input_buf)
  vim.api.nvim_win_set_option(M.input_win, "winfixheight", true)
  vim.api.nvim_win_set_option(M.input_win, "number", false)
  vim.api.nvim_win_set_option(M.input_win, "relativenumber", false)
  vim.api.nvim_win_set_option(M.input_win, "signcolumn", "no")
  
  -- Setup prompt callback
  vim.fn.prompt_setcallback(M.input_buf, function(text)
    if text ~= "" then
      M.send_message(text)
      -- Clear the prompt after sending
      vim.schedule(function()
        if M.input_buf and vim.api.nvim_buf_is_valid(M.input_buf) then
          vim.api.nvim_buf_set_lines(M.input_buf, 0, -1, false, {})
          vim.api.nvim_buf_set_option(M.input_buf, "modified", false)
        end
      end)
    end
  end)
  
  -- Add keymaps for closing
  vim.api.nvim_buf_set_keymap(M.input_buf, "n", "q", ":PiChat<CR>", { noremap = true, silent = true })
  vim.api.nvim_buf_set_keymap(M.buf, "n", "q", ":PiChat<CR>", { noremap = true, silent = true })
  vim.api.nvim_buf_set_keymap(M.status_buf, "n", "q", ":PiChat<CR>", { noremap = true, silent = true })
  
  -- Prevent modified state issues
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = M.input_buf,
    callback = function()
      vim.api.nvim_buf_set_option(M.input_buf, "modified", false)
    end,
  })
  
  -- Subscribe to RPC events
  M.subscribe_to_events()
  
  -- Initial status
  M.update_status()
  
  -- Focus input
  vim.api.nvim_set_current_win(M.input_win)
  
  state.update("ui.chat_open", true)
  
  -- Load history
  M.load_history()
end

-- Subscribe to RPC events
function M.subscribe_to_events()
  if M.event_unsub then
    M.event_unsub()
  end
  
  M.event_unsub = events.on("rpc_event", function(event)
    if not event then return end
    
    vim.notify("Chat received event: " .. tostring(event.type), vim.log.levels.INFO)
    
    -- Handle different event types
    if event.type == "agent_start" then
      M.is_streaming = true
      M.current_response = { content = "" }
      M.update_status()
      M.append_message("Pi", "", true) -- Start streaming message
      
    elseif event.type == "agent_end" then
      M.is_streaming = false
      M.current_response = nil
      M.update_status()
      
    elseif event.type == "message_update" then
      local delta = event.assistantMessageEvent
      if delta then
        if delta.type == "text_delta" and delta.delta then
          M.append_to_stream(delta.delta)
        elseif delta.type == "thinking_delta" and delta.delta then
          -- Show thinking in a different way or skip
        elseif delta.type == "tool_call" then
          M.append_tool_call(delta.toolCall)
        end
      end
      
    elseif event.type == "error" then
      M.is_streaming = false
      M.update_status()
      M.append_message("System", "Error: " .. (event.error or "Unknown error"), false)
    end
  end)
end

-- Append text to current streaming message
function M.append_to_stream(text)
  if not M.buf or not vim.api.nvim_buf_is_valid(M.buf) then
    return
  end
  
  if not M.current_response then
    M.current_response = { content = "" }
  end
  
  M.current_response.content = M.current_response.content .. text
  
  -- Update the last line
  vim.api.nvim_buf_set_option(M.buf, "modifiable", true)
  local line_count = vim.api.nvim_buf_line_count(M.buf)
  
  -- Find the last "Pi" message and update it
  local lines = vim.api.nvim_buf_get_lines(M.buf, 0, -1, false)
  local last_pi_line = nil
  for i = #lines, 1, -1 do
    if lines[i]:match("^=== Pi ===$") then
      last_pi_line = i
      break
    end
  end
  
  if last_pi_line then
    -- Replace content after header
    local content_lines = vim.split(M.current_response.content, "\n")
    local start_line = last_pi_line
    local end_line = line_count
    
    -- Keep the header, replace content
    vim.api.nvim_buf_set_lines(M.buf, start_line, end_line, false, content_lines)
    
    -- Scroll to bottom
    local new_line_count = vim.api.nvim_buf_line_count(M.buf)
    vim.api.nvim_win_set_cursor(M.win, { new_line_count, 0 })
  end
  
  vim.api.nvim_buf_set_option(M.buf, "modifiable", false)
end

-- Append tool call info
function M.append_tool_call(tool_call)
  if not M.buf or not vim.api.nvim_buf_is_valid(M.buf) then
    return
  end
  
  local tool_text = string.format("[Using tool: %s]", tool_call.name or "unknown")
  
  vim.api.nvim_buf_set_option(M.buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(M.buf, -1, -1, false, { "", tool_text, "" })
  vim.api.nvim_buf_set_option(M.buf, "modifiable", false)
  
  local line_count = vim.api.nvim_buf_line_count(M.buf)
  vim.api.nvim_win_set_cursor(M.win, { line_count, 0 })
end

-- Close chat
function M.close(force)
  if M.event_unsub then
    M.event_unsub()
    M.event_unsub = nil
  end
  
  -- Force modified to false before closing
  if M.input_buf and vim.api.nvim_buf_is_valid(M.input_buf) then
    vim.api.nvim_buf_set_option(M.input_buf, "modified", false)
  end
  if M.buf and vim.api.nvim_buf_is_valid(M.buf) then
    vim.api.nvim_buf_set_option(M.buf, "modified", false)
  end
  if M.status_buf and vim.api.nvim_buf_is_valid(M.status_buf) then
    vim.api.nvim_buf_set_option(M.status_buf, "modified", false)
  end
  
  local close_win = function(win)
    if win and vim.api.nvim_win_is_valid(win) then
      local ok, err = pcall(function()
        vim.api.nvim_win_close(win, force or false)
      end)
      if not ok then
        -- Try with force if normal close fails
        pcall(function()
          vim.api.nvim_win_close(win, true)
        end)
      end
    end
  end
  
  close_win(M.status_win)
  close_win(M.win)
  close_win(M.input_win)
  
  M.status_win = nil
  M.status_buf = nil
  M.win = nil
  M.input_win = nil
  M.buf = nil
  M.input_buf = nil
  
  state.update("ui.chat_open", false)
end

-- Toggle chat
function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

-- Check if open
function M.is_open()
  return M.win and vim.api.nvim_win_is_valid(M.win)
end

-- Load conversation history
function M.load_history()
  local client = state.get("rpc_client")
  if not client then return end
  
  client:request("get_messages", { type = "get_messages" }, function(result)
    vim.schedule(function()
      if result.error then
        return
      end
      
      M.render_history(result.data and result.data.messages or {})
    end)
  end)
end

-- Render conversation history
function M.render_history(messages)
  if not M.buf or not vim.api.nvim_buf_is_valid(M.buf) then
    return
  end
  
  local lines = {}
  
  for _, msg in ipairs(messages) do
    local role = msg.role == "user" and "You" or "Pi"
    table.insert(lines, string.format("=== %s ===", role))
    
    -- Handle different content types
    if type(msg.content) == "string" then
      table.insert(lines, msg.content)
    elseif type(msg.content) == "table" then
      -- Array of content blocks
      for _, block in ipairs(msg.content) do
        if block.type == "text" and block.text then
          table.insert(lines, block.text)
        end
      end
    end
    table.insert(lines, "")
  end
  
  vim.api.nvim_buf_set_option(M.buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(M.buf, "modifiable", false)
  
  -- Scroll to bottom
  local line_count = vim.api.nvim_buf_line_count(M.buf)
  if line_count > 0 then
    vim.api.nvim_win_set_cursor(M.win, { line_count, 0 })
  end
end

-- Send message
function M.send_message(text)
  local client = state.get("rpc_client")
  if not client then
    vim.notify("Pi: Not connected", vim.log.levels.ERROR)
    return
  end
  
  -- Add user message to display immediately
  M.append_message("You", text, false)
  
  -- Show that we're sending
  M.is_streaming = true
  M.update_status()
  
  client:request("prompt", { type = "prompt", message = text }, function(result)
    vim.schedule(function()
      if result.error then
        M.is_streaming = false
        M.update_status()
        M.append_message("System", "Error: " .. result.error, false)
        return
      end
      
      -- Prompt accepted - streaming will come via events
      -- Start a placeholder for the response
      M.append_message("Pi", "", true)
    end)
  end)
end

-- Append message to display
function M.append_message(role, content, is_streaming)
  if not M.buf or not vim.api.nvim_buf_is_valid(M.buf) then
    return
  end
  
  vim.api.nvim_buf_set_option(M.buf, "modifiable", true)
  
  local lines = {
    string.format("=== %s ===", role),
  }
  
  if content and content ~= "" then
    for _, line in ipairs(vim.split(content, "\n")) do
      table.insert(lines, line)
    end
  end
  
  if not is_streaming then
    table.insert(lines, "")
  end
  
  vim.api.nvim_buf_set_lines(M.buf, -1, -1, false, lines)
  vim.api.nvim_buf_set_option(M.buf, "modifiable", false)
  
  -- Scroll to bottom
  local line_count = vim.api.nvim_buf_line_count(M.buf)
  vim.api.nvim_win_set_cursor(M.win, { line_count, 0 })
end

return M
