local state = require("pi.state")
local conversation = require("pi.rpc.conversation")

local M = {}
M.buf = nil
M.win = nil
M.input_buf = nil
M.input_win = nil

-- Open chat interface
function M.open()
  if M.is_open() then
    return
  end
  
  -- Create main buffer for conversation history
  M.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(M.buf, "buftype", "nofile")
  vim.api.nvim_buf_set_name(M.buf, "Pi Chat")
  
  -- Create input buffer
  M.input_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(M.input_buf, "buftype", "prompt")
  vim.fn.prompt_setprompt(M.input_buf, "> ")
  
  -- Create windows
  vim.cmd("botright split")
  M.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(M.win, M.buf)
  vim.api.nvim_win_set_height(M.win, 20)
  
  vim.cmd("split")
  M.input_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(M.input_win, M.input_buf)
  vim.api.nvim_win_set_height(M.input_win, 3)
  
  -- Setup prompt callback
  vim.fn.prompt_setcallback(M.input_buf, function(text)
    if text ~= "" then
      M.send_message(text)
    end
  end)
  
  -- Load conversation history
  M.load_history()
  
  state.update("ui.chat_open", true)
end

-- Close chat
function M.close()
  if M.win and vim.api.nvim_win_is_valid(M.win) then
    vim.api.nvim_win_close(M.win, true)
  end
  if M.input_win and vim.api.nvim_win_is_valid(M.input_win) then
    vim.api.nvim_win_close(M.input_win, true)
  end
  
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
  
  conversation.history(client, function(result)
    if result.error then
      vim.notify("Failed to load history: " .. result.error, vim.log.levels.ERROR)
      return
    end
    
    M.render_history(result.messages or {})
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
    table.insert(lines, msg.content)
    table.insert(lines, "")
  end
  
  vim.api.nvim_buf_set_option(M.buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(M.buf, "modifiable", false)
  
  -- Scroll to bottom
  local line_count = vim.api.nvim_buf_line_count(M.buf)
  vim.api.nvim_win_set_cursor(M.win, { line_count, 0 })
end

-- Send message
function M.send_message(text)
  local client = state.get("rpc_client")
  
  -- Add user message to display
  M.append_message("You", text)
  
  conversation.send(client, text, function(result)
    if result.error then
      vim.notify("Failed to send message: " .. result.error, vim.log.levels.ERROR)
      return
    end
    
    -- Add Pi's response
    if result.response then
      M.append_message("Pi", result.response)
    end
  end)
end

-- Append message to display
function M.append_message(role, content)
  if not M.buf or not vim.api.nvim_buf_is_valid(M.buf) then
    return
  end
  
  local lines = {
    string.format("=== %s ===", role),
    content,
    ""
  }
  
  vim.api.nvim_buf_set_option(M.buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(M.buf, -1, -1, false, lines)
  vim.api.nvim_buf_set_option(M.buf, "modifiable", false)
  
  -- Scroll to bottom
  local line_count = vim.api.nvim_buf_line_count(M.buf)
  vim.api.nvim_win_set_cursor(M.win, { line_count, 0 })
end

return M