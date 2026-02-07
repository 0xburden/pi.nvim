local state = require("pi.state")
local events = require("pi.events")

local M = {}

local HIGHLIGHT_NS = vim.api.nvim_create_namespace("pi_chat_highlights")
local THINKING_HL = "PiChatThinking"
local USER_PROMPT_HL = "PiChatUserPrompt"
local TOOL_RESULT_HL = "PiChatToolResult"
local DIFF_ADD_HL = "PiChatDiffAdd"
local DIFF_DEL_HL = "PiChatDiffDel"

local function safe_get_highlight(name)
  local ok, hl = pcall(vim.api.nvim_get_hl_by_name, name, true)
  if not ok then
    return {}
  end
  return hl
end

local function setup_highlights()
  local comment_hl = safe_get_highlight("Comment")
  local thinking_opts = { italic = true }
  if comment_hl.foreground then
    thinking_opts.fg = comment_hl.foreground
  end
  if comment_hl.background then
    thinking_opts.bg = comment_hl.background
  end
  vim.api.nvim_set_hl(0, THINKING_HL, thinking_opts)

  local normal_hl = safe_get_highlight("Normal")
  local pmenu_hl = safe_get_highlight("Pmenu")
  local user_opts = {}
  if normal_hl.foreground then
    user_opts.fg = normal_hl.foreground
  end
  if pmenu_hl.background then
    user_opts.bg = pmenu_hl.background
  elseif pmenu_hl.foreground then
    user_opts.bg = pmenu_hl.foreground
  end
  if next(user_opts) == nil then
    user_opts.bg = 0x1f1f1f
  end
  vim.api.nvim_set_hl(0, USER_PROMPT_HL, user_opts)

  local diff_add_hl = safe_get_highlight("DiffAdd")
  local diff_del_hl = safe_get_highlight("DiffDelete")
  local function copy_highlight(src, name)
    local opts = {}
    if src.foreground then opts.fg = src.foreground end
    if src.background then opts.bg = src.background end
    if src.reverse then opts.reverse = src.reverse end
    if src.italic then opts.italic = src.italic end
    if src.bold then opts.bold = src.bold end
    vim.api.nvim_set_hl(0, name, opts)
  end
  copy_highlight(diff_add_hl, DIFF_ADD_HL)
  copy_highlight(diff_del_hl, DIFF_DEL_HL)

  local thinking_color = safe_get_highlight("Comment")
  if thinking_color.foreground or thinking_color.background then
    local tool_opts = {}
    if thinking_color.foreground then tool_opts.fg = thinking_color.foreground end
    if thinking_color.background then tool_opts.bg = thinking_color.background end
    vim.api.nvim_set_hl(0, TOOL_RESULT_HL, tool_opts)
  else
    vim.api.nvim_set_hl(0, TOOL_RESULT_HL, { fg = thinking_color.foreground, bg = thinking_color.background })
  end
end

setup_highlights()

-- Window/buffer handles
M.result_buf = nil
M.result_win = nil
M.input_buf = nil
M.input_win = nil
M.origin_win = nil

-- Event subscription
M.event_unsub = nil

-- Streaming state
M.current_response = ""
M.current_thinking = ""
M.is_streaming = false
M.messages = {}
M.agent_cwd = vim.fn.getcwd()

-- Session info
M.session_info = {
  model = nil,
  tokens = { input = 0, output = 0 },
}

-- Pending file paths to open after edits
M.pending_file_paths = {}
M.tool_call_context = {}
M.tool_spinner_active = false
M.tool_spinner_label = nil
M.spinner_frames = { "⠋", "⠙", "⠚", "⠞", "⠖", "⠦", "⠴", "⠲", "⠳", "⠓" }
M.spinner_index = 1

-- Constants
M.RESULT_BUF_NAME = "PiChat"
M.INPUT_BUF_NAME = "PiChatInput"

local function normalize_path(path, base)
  if not path or path == "" then
    return nil
  end
  if vim.startswith(path, "/") then
    return vim.fn.fnamemodify(path, ":p")
  end
  if base and base ~= "" then
    return vim.fn.fnamemodify(base .. "/" .. path, ":p")
  end
  return vim.fn.fnamemodify(path, ":p")
end

local function extract_path_from_text(text)
  if type(text) ~= "string" then
    return nil
  end
  for line in text:gmatch("[^\r\n]+") do
    local candidate = line:match("Filepath:%s*(.+)")
      or line:match("filepath:%s*(.+)")
      or line:match("File:%s*(.+)")
      or line:match("file:%s*(.+)")
    if candidate then
      return normalize_path(candidate)
    end
  end
  return nil
end

local function queue_file_path(path)
  local normalized = normalize_path(path, M.agent_cwd)
  if not normalized then
    return
  end
  M.pending_file_paths[normalized] = true
end

local function queue_text_path(text)
  local path = extract_path_from_text(text)
  if path then
    queue_file_path(path)
  end
end

local function register_tool_call_context(tool)
  local id = tool.id or tool.toolCallId
  if not id then
    return
  end
  local entry = M.tool_call_context[id] or {}
  entry.name = tool.name or tool.tool or entry.name
  local args = tool.arguments or tool.args or {}
  local direct = args.file or args.path or args.filepath
  if direct then
    entry.raw_path = direct
  end
  local command = args.command
  if command then
    entry.command = command
  end
  M.tool_call_context[id] = entry
end

local function start_tool_spinner(tool)
  local label = tool.name or tool.tool or "tool"
  local args = tool.arguments or tool.args or {}
  if args.command then
    label = string.format("%s (%s)", label, args.command)
  end
  M.tool_spinner_label = label
  M.tool_spinner_active = true
  if not M.spinner_index or M.spinner_index < 1 then
    M.spinner_index = 1
  end
end

local function stop_tool_spinner()
  M.tool_spinner_active = false
  M.tool_spinner_label = nil
end

local try_open_file

local function flush_pending_file_paths()
  if not next(M.pending_file_paths) then
    return
  end

  local to_open = {}
  for path in pairs(M.pending_file_paths) do
    table.insert(to_open, path)
  end
  M.pending_file_paths = {}

  for _, path in ipairs(to_open) do
    try_open_file(path)
  end
end

local function is_valid_target_window(win)
  return win and vim.api.nvim_win_is_valid(win) and win ~= M.result_win and win ~= M.input_win
end

local function choose_target_window()
  if is_valid_target_window(M.origin_win) then
    return M.origin_win
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if is_valid_target_window(win) then
      return win
    end
  end
  return nil
end

try_open_file = function(path)
  if not path then
    return
  end
  if vim.fn.filereadable(path) == 0 then
    vim.notify("Pi: File not readable: " .. path, vim.log.levels.WARN)
    return
  end
  M.open_file_in_other_window(path)
end
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

  local origin_win = vim.api.nvim_get_current_win()

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

  M.origin_win = origin_win
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

  if event_type == "agent_start" then
    M.is_streaming = true
    M.current_response = ""
    M.current_thinking = ""
    M.add_message("assistant", "", true)
    stop_tool_spinner()

  elseif event_type == "agent_end" then
    M.is_streaming = false
    M.finalize_streaming_message()
    M.current_response = ""
    M.current_thinking = ""
    M.pending_file_paths = {}
    M.tool_call_context = {}
    stop_tool_spinner()

  elseif event_type == "message_update" then
    local delta = event.assistantMessageEvent
    if not delta then return end
    
    local delta_type = delta.type
    
    if delta_type == "text_delta" and delta.delta then
      M.append_to_stream(delta.delta)
      
    elseif delta_type == "thinking_delta" and delta.delta then
      M.append_to_thinking(delta.delta)
      
    elseif delta_type == "tool_call" or delta_type == "tool_use" or delta_type == "toolcall_start" then
      local tool = delta.toolCall or delta.tool or {}
      register_tool_call_context(tool)
      start_tool_spinner(tool)
      
    elseif delta_type == "toolcall_delta" or delta_type == "toolcall_end" then
      local tool = delta.toolCall or delta.tool or {}
      register_tool_call_context(tool)
      if not M.tool_spinner_active then
        start_tool_spinner(tool)
      end

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

    if filepath and (tool_name == "edit" or tool_name == "write") then
      queue_file_path(filepath)
    end

    if result then
      if not filepath then
        filepath = extract_path_from_text(type(result) == "table" and (result.diff or result.output) or result)
        if filepath then
          queue_file_path(filepath)
        end
      end

      if type(result) == "table" then
        if result.diff then
          queue_text_path(result.diff)
        elseif result.output then
          queue_text_path(result.output)
        end
      else
        queue_text_path(result)
      end
    end

  end

  if event.type == "message_end" and event.message and event.message.role == "toolResult" then
    local tool_id = event.message.toolCallId
    local context_command
    if tool_id then
      local context = M.tool_call_context[tool_id]
      if context then
        context_command = context.command
        local resolved = context.filepath or context.raw_path
        if resolved then
          queue_file_path(resolved)
        end
      end
      M.tool_call_context[tool_id] = nil
    end

    local tool_name = event.message.toolName or event.message.tool or "tool"
    local tool_message_parts = {}
    for _, chunk in ipairs(event.message.content or {}) do
      if type(chunk) == "table" and chunk.text then
        table.insert(tool_message_parts, chunk.text)
      elseif type(chunk) == "string" then
        table.insert(tool_message_parts, chunk)
      end
    end
    local result_text = table.concat(tool_message_parts, "")

    if tool_name == "bash" and context_command and context_command:match("pwd") then
      local cwd_guess = vim.trim(result_text)
      if cwd_guess ~= "" then
        M.agent_cwd = cwd_guess
      end
    end

    if event.message.details and event.message.details.diff then
      queue_text_path(event.message.details.diff)
      result_text = result_text .. "\n\nDiff:\n" .. event.message.details.diff
    end

    local display = result_text ~= "" and result_text or "(no output)"
    M.add_message("tool_result", display, false)
    stop_tool_spinner()
    flush_pending_file_paths()
  end

  -- Always re-render after handling an event
  M.render()
end

function M.open_file_in_other_window(filepath)
  filepath = vim.fn.expand(filepath)

  if vim.fn.filereadable(filepath) == 0 then
    return
  end

  local target_win = choose_target_window()
  if not target_win then
    vim.cmd("topleft vsplit")
    target_win = vim.api.nvim_get_current_win()
  end

  vim.api.nvim_set_current_win(target_win)
  vim.cmd("silent! edit! " .. vim.fn.fnameescape(filepath))

  -- Return to chat
  vim.defer_fn(function()
    if M.input_win and vim.api.nvim_win_is_valid(M.input_win) then
      vim.api.nvim_set_current_win(M.input_win)
      vim.cmd("startinsert!")
    end
  end, 50)
end

function M.add_message(role, content, is_streaming)
  local entry = {
    role = role,
    content = content,
    streaming = is_streaming,
  }
  if role == "assistant" then
    entry.thinking = ""
  end
  table.insert(M.messages, entry)
  M.render()
end

function M.append_to_stream(text)
  M.current_response = M.current_response .. text
  
  for i = #M.messages, 1, -1 do
    if M.messages[i].role == "assistant" and M.messages[i].streaming then
      local full_content = M.current_response
      if M.current_thinking ~= "" then
        full_content = M.current_thinking .. "\n\n" .. M.current_response
      end
      M.messages[i].content = full_content
      M.messages[i].thinking = M.current_thinking
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
        full_content = M.current_thinking .. "\n\n" .. M.current_response
      end
      M.messages[i].content = full_content
      M.messages[i].thinking = M.current_thinking
      break
    end
  end
end

function M.add_tool_call(tool)
  local tool_name = tool.name or tool.tool or "unknown"
  local args = tool.arguments or tool.args or {}
  local filepath = args.file or args.path



  local display_text
  if filepath then
    display_text = string.format("🔧 %s: %s", tool_name, filepath)
  else
    display_text = string.format("🔧 %s", tool_name)
  end

  M.add_message("tool", display_text, false)

  if filepath and (tool_name == "edit" or tool_name == "write") then
    queue_file_path(filepath)
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
  local highlights = {}
  local function add_line(text, hl)
    table.insert(lines, text)
    if hl then
      table.insert(highlights, { line = #lines - 1, group = hl })
    end
  end
  local function ensure_separator()
    if #lines == 0 or lines[#lines] == "" then
      return
    end
    table.insert(lines, "")
  end
  local function split_text(text)
    text = text or ""
    return vim.split(text, "\n", { plain = true })
  end
  local function thinking_line_count(text)
    local parts = split_text(text)
    while #parts > 0 and parts[#parts] == "" do
      table.remove(parts)
    end
    return #parts
  end
  local function add_message_lines(content, hl, line_highlighter)
    for _, line in ipairs(split_text(content)) do
      local applied = hl
      if line_highlighter then
        applied = line_highlighter(line) or applied
      end
      add_line("  " .. line, applied)
    end
  end

  local function diff_line_highlight(line)
    if line:match("^%s*%+") then
      return DIFF_ADD_HL
    end
    if line:match("^%s*-") then
      return DIFF_DEL_HL
    end
    return nil
  end

  local width = math.max(40, (M.result_win and vim.api.nvim_win_is_valid(M.result_win)) and vim.api.nvim_win_get_width(M.result_win) - 4 or 40)

  -- Status line
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
    add_line("  " .. table.concat(status_parts, "  •  "))
    add_line("  " .. string.rep("─", width - 2))
  end

  -- Messages
  for _, msg in ipairs(M.messages) do
    ensure_separator()

    if msg.role == "user" then
      add_message_lines(msg.content, USER_PROMPT_HL)

    elseif msg.role == "assistant" then
      local content_lines = split_text(msg.content)
      local highlight_count = thinking_line_count(msg.thinking)
      for idx, line in ipairs(content_lines) do
        local line_hl = (highlight_count > 0 and idx <= highlight_count) and THINKING_HL or nil
        add_line("  " .. line, line_hl)
      end

    elseif msg.role == "tool" then
      add_message_lines(msg.content)

    elseif msg.role == "tool_result" then
      add_message_lines(msg.content, TOOL_RESULT_HL, diff_line_highlight)

    elseif msg.role == "system" then
      add_line("  ⚠️  " .. msg.content)
    end
  end

  if M.tool_spinner_active then
    ensure_separator()
    local frame = M.spinner_frames[M.spinner_index] or M.spinner_frames[1]
    local label = M.tool_spinner_label or "tool"
    add_line(string.format("  %s Running %s...", frame, label))
    M.spinner_index = (M.spinner_index % #M.spinner_frames) + 1
  end

  ensure_separator()
  add_line("  " .. string.rep("─", width - 2))
  add_line("  Enter=send  Shift+Enter=new line  q=close")

  vim.api.nvim_buf_set_option(M.result_buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(M.result_buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(M.result_buf, "modifiable", false)

  vim.api.nvim_buf_clear_namespace(M.result_buf, HIGHLIGHT_NS, 0, -1)
  for _, hl in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(M.result_buf, HIGHLIGHT_NS, hl.group, hl.line, 0, -1)
  end

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

  M.pending_file_paths = {}
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
            local thinking_text = ""

            if type(msg.content) == "string" then
              content = msg.content
            elseif type(msg.content) == "table" then
              for _, block in ipairs(msg.content) do
                if block.type == "text" and block.text then
                  content = content .. block.text
                elseif block.type == "thinking" and block.thinking then
                  thinking_text = thinking_text .. block.thinking
                  content = content .. block.thinking .. "\n\n"
                end
              end
            end

            if role then
              local entry = { role = role, content = content, streaming = false }
              if role == "assistant" then
                entry.thinking = thinking_text
              end
              table.insert(M.messages, entry)
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
  M.origin_win = nil

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
