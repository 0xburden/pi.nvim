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

-- Session info
M.session_info = {
  model = nil,
  tokens = { input = 0, output = 0 },
}

-- Track edited files
M.edited_files = {}

-- Constants
M.RESULT_BUF_NAME = "PiChat"
M.INPUT_BUF_NAME = "PiChatInput"

-- Get or create buffer
local function get_or_create_buf(name, scratch)
  -- Check if buffer already exists
  local existing = vim.fn.bufnr(name)
  if existing ~= -1 and vim.api.nvim_buf_is_valid(existing) then
    return existing
  end
  
  -- Create new buffer
  local buf = vim.api.nvim_create_buf(false, scratch or false)
  vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(buf, "bufhidden", "hide")
  vim.api.nvim_buf_set_option(buf, "swapfile", false)
  
  -- Set name with pcall to handle race conditions
  local ok, err = pcall(vim.api.nvim_buf_set_name, buf, name)
  if not ok then
    -- Name might exist from a recently closed buffer, try to find it
    existing = vim.fn.bufnr(name)
    if existing ~= -1 then
      vim.api.nvim_buf_delete(existing, { force = true })
      pcall(vim.api.nvim_buf_set_name, buf, name)
    end
  end
  
  return buf
end

-- Open chat interface
function M.open()
  if M.is_open() then
    return
  end

  -- Create result buffer (main chat display)
  M.result_buf = get_or_create_buf(M.RESULT_BUF_NAME, true)
  vim.api.nvim_buf_set_option(M.result_buf, "modifiable", false)
  vim.api.nvim_buf_set_option(M.result_buf, "wrap", true)
  vim.api.nvim_buf_set_option(M.result_buf, "linebreak", true)

  -- Create input buffer
  M.input_buf = get_or_create_buf(M.INPUT_BUF_NAME, true)

  -- Calculate width (40% of screen or minimum 50 columns)
  local total_width = vim.o.columns
  local chat_width = math.max(50, math.floor(total_width * 0.4))

  -- Create main result window (right side, wider)
  vim.cmd("botright " .. chat_width .. "vsplit")
  M.result_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(M.result_win, M.result_buf)
  vim.api.nvim_win_set_option(M.result_win, "wrap", true)
  vim.api.nvim_win_set_option(M.result_win, "cursorline", false)
  vim.api.nvim_win_set_option(M.result_win, "number", false)
  vim.api.nvim_win_set_option(M.result_win, "relativenumber", false)
  vim.api.nvim_win_set_option(M.result_win, "signcolumn", "no")
  vim.api.nvim_win_set_option(M.result_win, "foldcolumn", "0")
  vim.api.nvim_win_set_option(M.result_win, "colorcolumn", "")
  -- Set subtle background color for contrast
  vim.api.nvim_win_set_option(M.result_win, "winhighlight",
    "Normal:PiChatNormal,EndOfBuffer:PiChatNormal")

  -- Create input window below (3 lines tall)
  vim.cmd("belowright 3split")
  M.input_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(M.input_win, M.input_buf)
  vim.api.nvim_win_set_option(M.input_win, "wrap", true)
  vim.api.nvim_win_set_option(M.input_win, "number", false)
  vim.api.nvim_win_set_option(M.input_win, "relativenumber", false)
  vim.api.nvim_win_set_option(M.input_win, "signcolumn", "no")
  vim.api.nvim_win_set_option(M.input_win, "foldcolumn", "0")
  vim.api.nvim_win_set_option(M.input_win, "colorcolumn", "")
  -- Slightly different background for input area
  vim.api.nvim_win_set_option(M.input_win, "winhighlight",
    "Normal:PiChatInput,EndOfBuffer:PiChatInput")

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
    -- Capture usage info if available
    if event.usage then
      M.session_info.tokens.input = event.usage.prompt_tokens or M.session_info.tokens.input
      M.session_info.tokens.output = event.usage.completion_tokens or M.session_info.tokens.output
    end

  elseif event.type == "error" then
    M.is_streaming = false
    M.add_message("system", "Error: " .. (event.error or "Unknown error"), false)

  elseif event.type == "file_edit" or event.type == "tool_result" then
    -- Track and open edited files
    local filepath = nil
    if event.filepath then
      filepath = event.filepath
    elseif event.toolCall and event.toolCall.name == "edit" then
      filepath = event.toolCall.arguments and event.toolCall.arguments.file
    end

    if filepath and not M.edited_files[filepath] then
      M.edited_files[filepath] = true
      M.open_file_in_other_window(filepath)
    end
  end
end

-- Open a file in the window to the left of chat
function M.open_file_in_other_window(filepath)
  -- Only open if file exists
  if vim.fn.filereadable(filepath) == 0 then
    return
  end

  -- Find the leftmost window that's not our chat windows
  local current_tab = vim.api.nvim_get_current_tabpage()
  local wins = vim.api.nvim_tabpage_list_wins(current_tab)

  -- Get our chat window IDs
  local chat_wins = {}
  if M.result_win and vim.api.nvim_win_is_valid(M.result_win) then
    chat_wins[M.result_win] = true
  end
  if M.input_win and vim.api.nvim_win_is_valid(M.input_win) then
    chat_wins[M.input_win] = true
  end

  -- Find a non-chat window
  local target_win = nil
  for _, win in ipairs(wins) do
    if not chat_wins[win] then
      target_win = win
      break
    end
  end

  -- If no other window exists, create one
  if not target_win then
    vim.cmd("topleft vsplit")
    target_win = vim.api.nvim_get_current_win()
  end

  -- Open the file in the target window
  vim.api.nvim_set_current_win(target_win)
  vim.cmd("edit " .. vim.fn.fnameescape(filepath))

  -- Return focus to input window
  if M.input_win and vim.api.nvim_win_is_valid(M.input_win) then
    vim.api.nvim_set_current_win(M.input_win)
    vim.cmd("startinsert!")
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

-- Render all messages to buffer (Pi TUI style)
function M.render()
  if not M.result_buf or not vim.api.nvim_buf_is_valid(M.result_buf) then
    return
  end

  local lines = {}
  local width = math.max(40, vim.api.nvim_win_get_width(M.result_win) - 4)

  -- Title bar
  table.insert(lines, "")
  table.insert(lines, "  ╭" .. string.rep("─", width - 4) .. "╮")
  table.insert(lines, "  │" .. string.rep(" ", width - 4) .. "│")
  
  local title = "π  Pi Chat"
  local title_padding = math.floor((width - 4 - #title) / 2)
  table.insert(lines, "  │" .. string.rep(" ", title_padding) .. title .. string.rep(" ", width - 4 - title_padding - #title) .. "│")
  table.insert(lines, "  │" .. string.rep(" ", width - 4) .. "│")
  table.insert(lines, "  ╰" .. string.rep("─", width - 4) .. "╯")
  table.insert(lines, "")

  -- Status line
  local status_parts = {}
  if M.session_info.model then
    local model_name = M.session_info.model:match("([^/]+)$") or M.session_info.model
    table.insert(status_parts, "model: " .. model_name)
  end
  if M.session_info.tokens.input > 0 or M.session_info.tokens.output > 0 then
    table.insert(status_parts, string.format("%.1f%%/%.0fk", 
      (M.session_info.tokens.input / 1000), M.session_info.tokens.output / 1000))
  end
  if M.is_streaming then
    table.insert(status_parts, "● working")
  end

  if #status_parts > 0 then
    local status = "  " .. table.concat(status_parts, "  •  ")
    table.insert(lines, status)
    table.insert(lines, "  " .. string.rep("─", width - 2))
    table.insert(lines, "")
  end

  -- Messages
  for i, msg in ipairs(M.messages) do
    if msg.role == "user" then
      -- User message - right aligned style
      table.insert(lines, "  ┌─ You")
      if msg.content and msg.content ~= "" then
        for _, line in ipairs(vim.split(msg.content, "\n")) do
          table.insert(lines, "  │ " .. line)
        end
      end
      table.insert(lines, "  └")
      
    elseif msg.role == "assistant" then
      -- Pi message
      if msg.streaming then
        table.insert(lines, "  ┌─ Pi " .. "⠋ thinking...")
      else
        table.insert(lines, "  ┌─ Pi")
      end
      if msg.content and msg.content ~= "" then
        for _, line in ipairs(vim.split(msg.content, "\n")) do
          table.insert(lines, "  │ " .. line)
        end
      end
      table.insert(lines, "  └")
      
    elseif msg.role == "tool" then
      -- Tool call - dim
      table.insert(lines, "  ○ " .. msg.content)
      
    elseif msg.role == "system" then
      -- System/error message
      table.insert(lines, "  ⚠ " .. msg.content)
    end
    
    table.insert(lines, "")
  end

  -- Footer
  table.insert(lines, "")
  table.insert(lines, "  " .. string.rep("─", width - 2))
  table.insert(lines, "  Press q to close • Enter to send • Shift+Enter for new line")

  -- Update buffer
  vim.api.nvim_buf_set_option(M.result_buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(M.result_buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(M.result_buf, "modifiable", false)

  -- Auto-scroll to bottom
  if M.result_win and vim.api.nvim_win_is_valid(M.result_win) then
    local line_count = vim.api.nvim_buf_line_count(M.result_buf)
    if line_count > 0 then
      -- Scroll to near bottom but show some context
      local scroll_to = math.max(1, line_count - 3)
      vim.api.nvim_win_set_cursor(M.result_win, { scroll_to, 0 })
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

  -- Clear edited files tracking for new session
  M.edited_files = {}

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

-- Load conversation history and session info
function M.load_history()
  local client = state.get("rpc_client")
  if not client then
    return
  end

  -- Get session state for model info
  client:request("get_state", { type = "get_state" }, function(state_result)
    vim.schedule(function()
      if state_result.success and state_result.data then
        local data = state_result.data
        if data.model then
          M.session_info.model = data.model.name or data.model.id or "Unknown"
        end
      end

      -- Now get messages
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

  -- Wipe buffers to free the names
  if M.input_buf and vim.api.nvim_buf_is_valid(M.input_buf) then
    vim.api.nvim_buf_delete(M.input_buf, { force = true })
  end
  if M.result_buf and vim.api.nvim_buf_is_valid(M.result_buf) then
    vim.api.nvim_buf_delete(M.result_buf, { force = true })
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
