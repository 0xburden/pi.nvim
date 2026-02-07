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
M.current_thinking = ""
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
  local existing = vim.fn.bufnr(name)
  if existing ~= -1 and vim.api.nvim_buf_is_valid(existing) then
    return existing
  end
  
  local buf = vim.api.nvim_create_buf(false, scratch or false)
  vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(buf, "bufhidden", "hide")
  vim.api.nvim_buf_set_option(buf, "swapfile", false)
  
  local ok = pcall(vim.api.nvim_buf_set_name, buf, name)
  if not ok then
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

  M.result_buf = get_or_create_buf(M.RESULT_BUF_NAME, true)
  vim.api.nvim_buf_set_option(M.result_buf, "modifiable", false)
  vim.api.nvim_buf_set_option(M.result_buf, "wrap", true)
  vim.api.nvim_buf_set_option(M.result_buf, "linebreak", true)

  M.input_buf = get_or_create_buf(M.INPUT_BUF_NAME, true)

  local total_width = vim.o.columns
  local chat_width = math.max(50, math.floor(total_width * 0.4))

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


  vim.cmd("belowright 3split")
  M.input_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(M.input_win, M.input_buf)
  vim.api.nvim_win_set_option(M.input_win, "wrap", true)
  vim.api.nvim_win_set_option(M.input_win, "number", false)
  vim.api.nvim_win_set_option(M.input_win, "relativenumber", false)
  vim.api.nvim_win_set_option(M.input_win, "signcolumn", "no")
  vim.api.nvim_win_set_option(M.input_win, "foldcolumn", "0")
  vim.api.nvim_win_set_option(M.input_win, "colorcolumn", "")

  M.setup_input_buffer()
  M.subscribe_to_events()
  M.load_history()

  vim.api.nvim_set_current_win(M.input_win)
  vim.cmd("startinsert!")

  state.update("ui.chat_open", true)
end

function M.setup_input_buffer()
  vim.api.nvim_buf_set_keymap(M.input_buf, "n", "<CR>", "", {
    noremap = true, silent = true, callback = function() M.submit() end,
  })
  vim.api.nvim_buf_set_keymap(M.input_buf, "i", "<CR>", "", {
    noremap = true, silent = true, callback = function() M.submit() end,
  })
  vim.api.nvim_buf_set_keymap(M.input_buf, "n", "q", "<cmd>PiChat<CR>", { noremap = true, silent = true })
  vim.api.nvim_buf_set_keymap(M.result_buf, "n", "q", "<cmd>PiChat<CR>", { noremap = true, silent = true })
  vim.api.nvim_buf_set_keymap(M.input_buf, "i", "<S-CR>", "<CR>", { noremap = true, silent = true })

  vim.api.nvim_buf_set_lines(M.input_buf, 0, -1, false, { "Type your message..." })
  vim.api.nvim_buf_set_option(M.input_buf, "modifiable", true)

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

function M.submit()
  if not M.input_buf or not vim.api.nvim_buf_is_valid(M.input_buf) then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(M.input_buf, 0, -1, false)
  local text = table.concat(lines, "\n")

  if text == "Type your message..." or text:match("^%s*$") then
    return
  end

  M.send_message(text)
  vim.api.nvim_buf_set_lines(M.input_buf, 0, -1, false, { "" })
end

function M.subscribe_to_events()
  if M.event_unsub then
    M.event_unsub()
  end

  M.event_unsub = events.on("rpc_event", function(event)
    if not event then return end
    vim.schedule(function() M.handle_event(event) end)
  end)
end

-- Handle ALL event types from Pi
function M.handle_event(event)
  local event_type = event.type

  -- Debug: print event type
  print(string.format("[Pi] Event: %s", event_type))

  if event_type == "agent_start" then
    M.is_streaming = true
    M.current_response = ""
    M.current_thinking = ""
    M.add_message("assistant", "", true)

  elseif event_type == "agent_end" then
    M.is_streaming = false
    M.finalize_streaming_message()
    M.current_response = ""
    M.current_thinking = ""

  elseif event_type == "message_update" then
    local delta = event.assistantMessageEvent
    if not delta then return end
    
    local delta_type = delta.type
    
    if delta_type == "text_delta" and delta.delta then
      M.append_to_stream(delta.delta)
      
    elseif delta_type == "thinking_delta" and delta.delta then
      M.append_to_thinking(delta.delta)
      
    elseif delta_type == "tool_call" or delta_type == "tool_use" then
      local tool = delta.toolCall or delta.tool or {}
      M.add_tool_call(tool)
      
    elseif delta_type == "content_block_start" then
      -- New content block started
      
    elseif delta_type == "content_block_stop" then
      -- Content block ended
    end
    
    if event.usage then
      M.session_info.tokens.input = event.usage.prompt_tokens or M.session_info.tokens.input
      M.session_info.tokens.output = event.usage.completion_tokens or M.session_info.tokens.output
    end

  elseif event_type == "tool_result" then
    -- Tool execution completed - may contain diff/output
    local result = event.result or event.output or event.content
    local tool_name = event.tool_name or event.tool or "tool"

    -- Check for file path in various locations
    local filepath = event.file or event.filepath
    if not filepath and event.args then
      filepath = event.args.file or event.args.path
    end
    if not filepath and result then
      if type(result) == "table" then
        filepath = result.file or result.path or result.filepath
      end
    end

    -- Open file if it's an edit/write operation
    if filepath and (tool_name == "edit" or tool_name == "write") then
      if not M.edited_files[filepath] then
        M.edited_files[filepath] = true
        vim.defer_fn(function()
          M.open_file_in_other_window(filepath)
        end, 100)
      end
    end

    if result then
      -- Format tool result nicely
      local content
      if type(result) == "table" then
        -- Try to extract meaningful content
        if result.diff then
          content = "Diff:\n" .. result.diff
        elseif result.output then
          content = tostring(result.output)
        else
          content = vim.inspect(result)
        end
      else
        content = tostring(result)
      end

      -- Truncate if too long
      if #content > 1000 then
        content = content:sub(1, 1000) .. "... (truncated)"
      end

      M.add_message("tool_result", "[" .. tool_name .. " result]:\n" .. content, false)
    end

  elseif event_type == "error" then
    M.is_streaming = false
    M.add_message("system", "Error: " .. (event.error or "Unknown error"), false)
  end
  
  -- Always re-render after handling an event
  M.render()
end

function M.open_file_in_other_window(filepath)
  filepath = vim.fn.expand(filepath)
  print(string.format("[Pi] open_file_in_other_window: %s", filepath))

  if vim.fn.filereadable(filepath) == 0 then
    print(string.format("[Pi] File not readable: %s", filepath))
    return
  end

  -- Focus the leftmost code window
  vim.cmd("normal! \\<C-w>h")

  -- Check if this is a chat window
  local current_win = vim.api.nvim_get_current_win()
  if current_win == M.result_win or current_win == M.input_win then
    vim.cmd("normal! \\<C-w>l")
    vim.cmd("normal! \\<C-w>h")
    current_win = vim.api.nvim_get_current_win()
  end

  -- Open the file
  print(string.format("[Pi] Opening in window: %d", current_win))
  vim.api.nvim_set_current_win(current_win)
  vim.cmd("edit " .. vim.fn.fnameescape(filepath))

  -- Return to chat
  vim.defer_fn(function()
    if M.input_win and vim.api.nvim_win_is_valid(M.input_win) then
      vim.api.nvim_set_current_win(M.input_win)
      vim.cmd("startinsert!")
    end
  end, 50)
end

function M.add_message(role, content, is_streaming)
  table.insert(M.messages, {
    role = role,
    content = content,
    streaming = is_streaming,
  })
  M.render()
end

function M.append_to_stream(text)
  M.current_response = M.current_response .. text
  
  for i = #M.messages, 1, -1 do
    if M.messages[i].role == "assistant" and M.messages[i].streaming then
      local full_content = M.current_response
      if M.current_thinking ~= "" then
        full_content = "💭 Thinking:\n" .. M.current_thinking .. "\n\n" .. M.current_response
      end
      M.messages[i].content = full_content
      break
    end
  end
end

function M.append_to_thinking(text)
  M.current_thinking = M.current_thinking .. text
  
  for i = #M.messages, 1, -1 do
    if M.messages[i].role == "assistant" and M.messages[i].streaming then
      local full_content = M.current_response
      if M.current_thinking ~= "" then
        full_content = "💭 Thinking:\n" .. M.current_thinking .. "\n\n" .. M.current_response
      end
      M.messages[i].content = full_content
      break
    end
  end
end

function M.add_tool_call(tool)
  local tool_name = tool.name or tool.tool or "unknown"
  local args = tool.arguments or tool.args or {}
  local filepath = args.file or args.path

  print(string.format("[Pi] Tool call: %s, filepath: %s", tool_name, filepath or "nil"))

  local display_text
  if filepath then
    display_text = string.format("🔧 %s: %s", tool_name, filepath)
  else
    display_text = string.format("🔧 %s", tool_name)
  end

  M.add_message("tool", display_text, false)

  -- Open file immediately when tool is called (for edit/write tools)
  if filepath and (tool_name == "edit" or tool_name == "write") then
    if not M.edited_files[filepath] then
      M.edited_files[filepath] = true
      print(string.format("[Pi] Opening file: %s", filepath))
      vim.defer_fn(function()
        M.open_file_in_other_window(filepath)
      end, 100)
    end
  end
end

function M.finalize_streaming_message()
  for i = #M.messages, 1, -1 do
    if M.messages[i].streaming then
      M.messages[i].streaming = false
      break
    end
  end
end

function M.render()
  if not M.result_buf or not vim.api.nvim_buf_is_valid(M.result_buf) then
    return
  end

  local lines = {}
  local width = math.max(40, (M.result_win and vim.api.nvim_win_is_valid(M.result_win)) and vim.api.nvim_win_get_width(M.result_win) - 4 or 40)

  -- Title
  table.insert(lines, "")
  table.insert(lines, "  ╭" .. string.rep("─", width - 4) .. "╮")
  local title = "π  Pi Chat"
  local title_padding = math.floor((width - 4 - #title) / 2)
  table.insert(lines, "  │" .. string.rep(" ", title_padding) .. title .. string.rep(" ", width - 4 - title_padding - #title) .. "│")
  table.insert(lines, "  ╰" .. string.rep("─", width - 4) .. "╯")
  table.insert(lines, "")

  -- Status
  local status_parts = {}
  if M.session_info.model then
    local model_name = M.session_info.model:match("([^/]+)$") or M.session_info.model
    table.insert(status_parts, "model: " .. model_name)
  end
  if M.session_info.tokens.input > 0 or M.session_info.tokens.output > 0 then
    table.insert(status_parts, string.format("%.1fk/%.1fk", M.session_info.tokens.input / 1000, M.session_info.tokens.output / 1000))
  end
  if M.is_streaming then
    table.insert(status_parts, "● working")
  end

  if #status_parts > 0 then
    table.insert(lines, "  " .. table.concat(status_parts, "  •  "))
    table.insert(lines, "  " .. string.rep("─", width - 2))
    table.insert(lines, "")
  end

  -- Messages
  for _, msg in ipairs(M.messages) do
    if msg.role == "user" then
      table.insert(lines, "  ┌─ 👤 You")
      for _, line in ipairs(vim.split(msg.content, "\n")) do
        table.insert(lines, "  │ " .. line)
      end
      table.insert(lines, "  └")
      
    elseif msg.role == "assistant" then
      if msg.streaming then
        table.insert(lines, "  ┌─ 🤖 Pi ●")
      else
        table.insert(lines, "  ┌─ 🤖 Pi")
      end
      for _, line in ipairs(vim.split(msg.content, "\n")) do
        table.insert(lines, "  │ " .. line)
      end
      table.insert(lines, "  └")
      
    elseif msg.role == "tool" then
      table.insert(lines, "  " .. msg.content)
      
    elseif msg.role == "tool_result" then
      -- Show tool results in a compact format
      for _, line in ipairs(vim.split(msg.content, "\n")) do
        table.insert(lines, "  │ " .. line)
      end
      
    elseif msg.role == "system" then
      table.insert(lines, "  ⚠️  " .. msg.content)
    end
    table.insert(lines, "")
  end

  -- Footer
  table.insert(lines, "  " .. string.rep("─", width - 2))
  table.insert(lines, "  Enter=send  Shift+Enter=new line  q=close")

  vim.api.nvim_buf_set_option(M.result_buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(M.result_buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(M.result_buf, "modifiable", false)

  if M.result_win and vim.api.nvim_win_is_valid(M.result_win) then
    local line_count = vim.api.nvim_buf_line_count(M.result_buf)
    if line_count > 0 then
      local scroll_to = math.max(1, line_count - 3)
      vim.api.nvim_win_set_cursor(M.result_win, { scroll_to, 0 })
    end
  end
end

function M.send_message(text)
  local client = state.get("rpc_client")
  if not client then
    vim.notify("Pi: Not connected", vim.log.levels.ERROR)
    return
  end

  M.edited_files = {}
  M.add_message("user", text, false)
  M.is_streaming = true
  M.current_response = ""
  M.current_thinking = ""

  client:request("prompt", { type = "prompt", message = text }, function(result)
    vim.schedule(function()
      if result.error then
        M.is_streaming = false
        M.add_message("system", "Error: " .. result.error, false)
      end
    end)
  end)
end

function M.load_history()
  local client = state.get("rpc_client")
  if not client then return end

  client:request("get_state", { type = "get_state" }, function(state_result)
    vim.schedule(function()
      if state_result.success and state_result.data then
        local data = state_result.data
        if data.model then
          M.session_info.model = data.model.name or data.model.id or "Unknown"
        end
      end

      client:request("get_messages", { type = "get_messages" }, function(result)
        vim.schedule(function()
          if result.error then return end

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
                elseif block.type == "thinking" and block.thinking then
                  content = content .. "💭 " .. block.thinking .. "\n\n"
                end
              end
            end

            if role then
              table.insert(M.messages, { role = role, content = content, streaming = false })
            end
          end

          M.render()
        end)
      end)
    end)
  end)
end

function M.close()
  if M.event_unsub then
    M.event_unsub()
    M.event_unsub = nil
  end

  if M.input_win and vim.api.nvim_win_is_valid(M.input_win) then
    vim.api.nvim_win_close(M.input_win, true)
  end
  if M.result_win and vim.api.nvim_win_is_valid(M.result_win) then
    vim.api.nvim_win_close(M.result_win, true)
  end

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

function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

function M.is_open()
  return M.result_win and vim.api.nvim_win_is_valid(M.result_win)
end

return M
