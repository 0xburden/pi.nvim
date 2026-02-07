local state = require("pi.state")
local events = require("pi.events")

local M = {}

-- Window/buffer handles
M.result_buf = nil
M.result_win = nil
M.input_buf = nil
M.input_win = nil

-- Event subscription
M.event_unsub = nil

-- Streaming state
M.current_response = ""
M.is_streaming = false
M.messages = {}

-- Constants
M.RESULT_BUF_NAME = "PiChat"
M.INPUT_BUF_NAME = "PiChatInput"

-- Open chat interface
function M.open()
  if M.is_open() then
    return
  end

  -- Create result buffer (main chat display)
  M.result_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(M.result_buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(M.result_buf, "bufhidden", "hide")
  vim.api.nvim_buf_set_option(M.result_buf, "swapfile", false)
  vim.api.nvim_buf_set_option(M.result_buf, "modifiable", false)
  vim.api.nvim_buf_set_name(M.result_buf, M.RESULT_BUF_NAME)
  vim.api.nvim_buf_set_option(M.result_buf, "wrap", true)
  vim.api.nvim_buf_set_option(M.result_buf, "linebreak", true)

  -- Create input buffer
  M.input_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(M.input_buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(M.input_buf, "bufhidden", "hide")
  vim.api.nvim_buf_set_option(M.input_buf, "swapfile", false)
  vim.api.nvim_buf_set_name(M.input_buf, M.INPUT_BUF_NAME)

  -- Create windows
  vim.cmd("botright 25vsplit")
  M.result_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(M.result_win, M.result_buf)
  vim.api.nvim_win_set_option(M.result_win, "wrap", true)
  vim.api.nvim_win_set_option(M.result_win, "cursorline", false)
  vim.api.nvim_win_set_option(M.result_win, "number", false)
  vim.api.nvim_win_set_option(M.result_win, "relativenumber", false)
  vim.api.nvim_win_set_option(M.result_win, "signcolumn", "no")

  vim.cmd("split")
  M.input_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(M.input_win, M.input_buf)
  vim.api.nvim_win_set_height(M.input_win, 3)
  vim.api.nvim_win_set_option(M.input_win, "wrap", true)
  vim.api.nvim_win_set_option(M.input_win, "number", false)
  vim.api.nvim_win_set_option(M.input_win, "relativenumber", false)
  vim.api.nvim_win_set_option(M.input_win, "signcolumn", "no")

  -- Set up input buffer
  M.setup_input_buffer()

  -- Subscribe to events
  M.subscribe_to_events()

  -- Load existing history
  M.load_history()

  -- Focus input
  vim.api.nvim_set_current_win(M.input_win)
  vim.cmd("startinsert!")

  state.update("ui.chat_open", true)
end

-- Set up input buffer keymaps and behavior
function M.setup_input_buffer()
  -- Submit on Enter in normal mode
  vim.api.nvim_buf_set_keymap(M.input_buf, "n", "<CR>", "", {
    noremap = true,
    silent = true,
    callback = function()
      M.submit()
    end,
  })

  -- Submit on Enter in insert mode
  vim.api.nvim_buf_set_keymap(M.input_buf, "i", "<CR>", "", {
    noremap = true,
    silent = true,
    callback = function()
      M.submit()
    end,
  })

  -- Close on q
  vim.api.nvim_buf_set_keymap(M.input_buf, "n", "q", "<cmd>PiChat<CR>", { noremap = true, silent = true })
  vim.api.nvim_buf_set_keymap(M.result_buf, "n", "q", "<cmd>PiChat<CR>", { noremap = true, silent = true })

  -- New line with Shift+Enter
  vim.api.nvim_buf_set_keymap(M.input_buf, "i", "<S-CR>", "<CR>", { noremap = true, silent = true })

  -- Set up buffer content
  vim.api.nvim_buf_set_lines(M.input_buf, 0, -1, false, { "Type your message..." })
  vim.api.nvim_buf_set_option(M.input_buf, "modifiable", true)

  -- Clear placeholder on first enter
  vim.api.nvim_create_autocmd("InsertEnter", {
    buffer = M.input_buf,
    once = true,
    callback = function()
      local lines = vim.api.nvim_buf_get_lines(M.input_buf, 0, -1, false)
      if #lines == 1 and lines[1] == "Type your message..." then
        vim.api.nvim_buf_set_lines(M.input_buf, 0, -1, false, { "" })
      end
    end,
  })
end

-- Submit message from input buffer
function M.submit()
  if not M.input_buf or not vim.api.nvim_buf_is_valid(M.input_buf) then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(M.input_buf, 0, -1, false)
  local text = table.concat(lines, "\n")

  -- Skip if placeholder or empty
  if text == "Type your message..." or text:match("^%s*$") then
    return
  end

  -- Send the message
  M.send_message(text)

  -- Clear input
  vim.api.nvim_buf_set_lines(M.input_buf, 0, -1, false, { "" })
end

-- Subscribe to RPC events
function M.subscribe_to_events()
  if M.event_unsub then
    M.event_unsub()
  end

  M.event_unsub = events.on("rpc_event", function(event)
    if not event then
      return
    end
    M.handle_event(event)
  end)
end

-- Handle incoming events
function M.handle_event(event)
  if event.type == "agent_start" then
    M.is_streaming = true
    M.current_response = ""
    M.add_message("assistant", "", true)

  elseif event.type == "agent_end" then
    M.is_streaming = false
    -- Finalize the message
    if M.current_response ~= "" then
      M.finalize_streaming_message()
    end
    M.current_response = ""

  elseif event.type == "message_update" then
    local delta = event.assistantMessageEvent
    if delta then
      if delta.type == "text_delta" and delta.delta then
        M.append_to_stream(delta.delta)
      elseif delta.type == "tool_call" then
        M.add_tool_call(delta.toolCall)
      end
    end

  elseif event.type == "error" then
    M.is_streaming = false
    M.add_message("system", "Error: " .. (event.error or "Unknown error"), false)
  end
end

-- Add a message to the display
function M.add_message(role, content, is_streaming)
  table.insert(M.messages, {
    role = role,
    content = content,
    streaming = is_streaming,
  })
  M.render()
end

-- Append to the currently streaming message
function M.append_to_stream(text)
  M.current_response = M.current_response .. text

  -- Update the last assistant message
  for i = #M.messages, 1, -1 do
    if M.messages[i].role == "assistant" and M.messages[i].streaming then
      M.messages[i].content = M.current_response
      break
    end
  end

  M.render()
end

-- Add tool call info
function M.add_tool_call(tool_call)
  local tool_text = string.format("[Using tool: %s]", tool_call and tool_call.name or "unknown")
  M.add_message("tool", tool_text, false)
end

-- Finalize streaming message
function M.finalize_streaming_message()
  for i = #M.messages, 1, -1 do
    if M.messages[i].streaming then
      M.messages[i].streaming = false
      break
    end
  end
end

-- Render all messages to buffer
function M.render()
  if not M.result_buf or not vim.api.nvim_buf_is_valid(M.result_buf) then
    return
  end

  local lines = {}

  for _, msg in ipairs(M.messages) do
    local header
    if msg.role == "user" then
      header = "👤 You"
    elseif msg.role == "assistant" then
      header = "🤖 Pi"
    elseif msg.role == "tool" then
      header = "🔧 Tool"
    elseif msg.role == "system" then
      header = "⚠️  System"
    end

    if header then
      table.insert(lines, header)
      table.insert(lines, string.rep("─", 40))

      if msg.content and msg.content ~= "" then
        for _, line in ipairs(vim.split(msg.content, "\n")) do
          table.insert(lines, line)
        end
      end

      table.insert(lines, "")
    end
  end

  -- Update buffer
  vim.api.nvim_buf_set_option(M.result_buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(M.result_buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(M.result_buf, "modifiable", false)

  -- Auto-scroll to bottom
  if M.result_win and vim.api.nvim_win_is_valid(M.result_win) then
    local line_count = vim.api.nvim_buf_line_count(M.result_buf)
    if line_count > 0 then
      vim.api.nvim_win_set_cursor(M.result_win, { line_count, 0 })
    end
  end
end

-- Send message to Pi
function M.send_message(text)
  local client = state.get("rpc_client")
  if not client then
    vim.notify("Pi: Not connected", vim.log.levels.ERROR)
    return
  end

  -- Add user message immediately
  M.add_message("user", text, false)

  -- Show streaming indicator
  M.is_streaming = true
  M.current_response = ""

  -- Send to Pi
  client:request("prompt", { type = "prompt", message = text }, function(result)
    vim.schedule(function()
      if result.error then
        M.is_streaming = false
        M.add_message("system", "Error: " .. result.error, false)
        return
      end
      -- Streaming will come via events
    end)
  end)
end

-- Load conversation history
function M.load_history()
  local client = state.get("rpc_client")
  if not client then
    return
  end

  client:request("get_messages", { type = "get_messages" }, function(result)
    vim.schedule(function()
      if result.error then
        return
      end

      local messages = result.data and result.data.messages or {}
      M.messages = {}

      for _, msg in ipairs(messages) do
        local role = msg.role
        local content = ""

        if type(msg.content) == "string" then
          content = msg.content
        elseif type(msg.content) == "table" then
          for _, block in ipairs(msg.content) do
            if block.type == "text" and block.text then
              content = content .. block.text
            end
          end
        end

        if role and content then
          table.insert(M.messages, {
            role = role,
            content = content,
            streaming = false,
          })
        end
      end

      M.render()
    end)
  end)
end

-- Close chat
function M.close()
  if M.event_unsub then
    M.event_unsub()
    M.event_unsub = nil
  end

  -- Close windows
  if M.input_win and vim.api.nvim_win_is_valid(M.input_win) then
    vim.api.nvim_win_close(M.input_win, true)
  end
  if M.result_win and vim.api.nvim_win_is_valid(M.result_win) then
    vim.api.nvim_win_close(M.result_win, true)
  end

  M.input_win = nil
  M.result_win = nil
  M.input_buf = nil
  M.result_buf = nil

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
  return M.result_win and vim.api.nvim_win_is_valid(M.result_win)
end

return M
