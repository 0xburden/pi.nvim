local state = require("pi.state")
local events = require("pi.events")
local config = require("pi.config")

local M = {}

local has_render_markdown = pcall(require, "render-markdown")
local use_render_markdown = has_render_markdown and config.get("ui.use_render_markdown") ~= false
local syntax_enabled = config.get("ui.syntax_highlighting") ~= false
local inline_enabled = config.get("ui.inline_code_highlighting") ~= false

local markdown
local syntax

if not use_render_markdown then
  markdown = require("pi.ui.markdown")
  if syntax_enabled then
    syntax = require("pi.ui.syntax")
  end
end

local HIGHLIGHT_NS = vim.api.nvim_create_namespace("pi_chat_highlights")
local THINKING_HL = "PiChatThinking"
local USER_PROMPT_HL = "PiChatUserPrompt"
local TOOL_RESULT_HL = "PiChatToolResult"
local DIFF_ADD_HL = "PiChatDiffAdd"
local DIFF_DEL_HL = "PiChatDiffDel"

local function safe_get_highlight(name)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  if not ok or not hl then
    return {}
  end
  return hl
end

local function setup_highlights()
  local comment_hl = safe_get_highlight("Comment")
  local thinking_opts = { italic = true }
  if comment_hl.fg then
    thinking_opts.fg = comment_hl.fg
  end
  if comment_hl.bg then
    thinking_opts.bg = comment_hl.bg
  end
  vim.api.nvim_set_hl(0, THINKING_HL, thinking_opts)

  local normal_hl = safe_get_highlight("Normal")
  local pmenu_hl = safe_get_highlight("Pmenu")
  local user_opts = {}
  if normal_hl.fg then
    user_opts.fg = normal_hl.fg
  end
  if pmenu_hl.bg then
    user_opts.bg = pmenu_hl.bg
  elseif pmenu_hl.fg then
    user_opts.bg = pmenu_hl.fg
  end
  if next(user_opts) == nil then
    user_opts.bg = 0x1f1f1f
  end
  vim.api.nvim_set_hl(0, USER_PROMPT_HL, user_opts)

  local diff_add_hl = safe_get_highlight("DiffAdd")
  local diff_del_hl = safe_get_highlight("DiffDelete")
  local function copy_highlight(src, name)
    local opts = {}
    if src.fg then opts.fg = src.fg end
    if src.bg then opts.bg = src.bg end
    if src.reverse then opts.reverse = src.reverse end
    if src.italic then opts.italic = src.italic end
    if src.bold then opts.bold = src.bold end
    vim.api.nvim_set_hl(0, name, opts)
  end
  copy_highlight(diff_add_hl, DIFF_ADD_HL)
  copy_highlight(diff_del_hl, DIFF_DEL_HL)

  local tool_hl = safe_get_highlight("Special")
  vim.api.nvim_set_hl(0, TOOL_RESULT_HL, {
    fg = tool_hl.fg or comment_hl.fg,
    bg = tool_hl.bg or comment_hl.bg,
  })

  local code_bg = pmenu_hl.bg or normal_hl.bg
  local code_block_opts = {}
  if code_bg then
    code_block_opts.bg = code_bg
  end
  vim.api.nvim_set_hl(0, "PiChatCodeBlock", code_block_opts)

  local string_hl = safe_get_highlight("String")
  local inline_opts = {}
  if string_hl.fg then
    inline_opts.fg = string_hl.fg
  end
  if code_bg then
    inline_opts.bg = code_bg
  end
  vim.api.nvim_set_hl(0, "PiChatInlineCode", inline_opts)

  local fence_opts = {}
  if comment_hl.fg then
    fence_opts.fg = comment_hl.fg
  end
  fence_opts.italic = true
  vim.api.nvim_set_hl(0, "PiChatCodeFence", fence_opts)
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

  local client = state.get("rpc_client")

  -- Auto-connect if no client exists or not connected
  if not client or not client.connected then
    if not client then
      -- Initialize client if it doesn't exist
      local Client = require("pi.rpc.client")
      client = Client.new()
      state.update("rpc_client", client)
    end

    -- Show connecting message
    vim.notify("Pi: Connecting...", vim.log.levels.INFO)

    -- Open UI immediately with loading state
    M._open_ui()
    M._show_connecting_state()

    -- Start connection
    client:connect(function(success, err)
      vim.schedule(function()
        if success then
          state.update("connected", true)
          vim.notify("Pi: Connected", vim.log.levels.INFO)
          M._clear_connecting_state()
          M.load_history()
        else
          vim.notify("Pi: Connection failed - " .. tostring(err), vim.log.levels.ERROR)
          M._show_connection_error(tostring(err or "Unknown error"))
        end
      end)
    end)
    return
  end

  -- Already connected - open UI and load history
  M._open_ui()
  M.load_history()
end

-- Open UI without loading history (used during connection)
function M._open_ui()
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

  vim.api.nvim_set_current_win(M.input_win)
  vim.cmd("startinsert!")

  M.origin_win = origin_win
  state.update("ui.chat_open", true)
end

function M._show_connecting_state()
  if not M.result_buf or not vim.api.nvim_buf_is_valid(M.result_buf) then
    return
  end
  local lines = {
    "",
    "  Connecting to Pi...",
    "",
    "  Please wait while we establish a connection.",
    "",
  }
  vim.api.nvim_buf_set_option(M.result_buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(M.result_buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(M.result_buf, "modifiable", false)
end

function M._clear_connecting_state()
  if not M.result_buf or not vim.api.nvim_buf_is_valid(M.result_buf) then
    return
  end
  vim.api.nvim_buf_set_option(M.result_buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(M.result_buf, 0, -1, false, {})
  vim.api.nvim_buf_set_option(M.result_buf, "modifiable", false)
end

function M._show_connection_error(err)
  if not M.result_buf or not vim.api.nvim_buf_is_valid(M.result_buf) then
    return
  end
  local lines = {
    "",
    "  ⚠️  Connection failed",
    "",
    "  " .. err,
    "",
    "  Press 'q' to close, then try :PiChat again.",
    "",
  }
  vim.api.nvim_buf_set_option(M.result_buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(M.result_buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(M.result_buf, "modifiable", false)
end

function M.setup_input_buffer()
  vim.keymap.set("n", "<CR>", function()
    M.submit()
  end, { buffer = M.input_buf, silent = true })
  vim.keymap.set("i", "<CR>", function()
    M.submit()
  end, { buffer = M.input_buf, silent = true })
  vim.keymap.set("n", "q", "<cmd>PiChat<CR>", { buffer = M.input_buf, silent = true })
  vim.keymap.set("n", "q", "<cmd>PiChat<CR>", { buffer = M.result_buf, silent = true })
  vim.keymap.set("i", "<S-CR>", "<CR>", { buffer = M.input_buf, silent = true })

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
  local line_highlights = {}
  local range_highlights = {}

  local width = 40
  if M.result_win and vim.api.nvim_win_is_valid(M.result_win) then
    width = math.max(40, vim.api.nvim_win_get_width(M.result_win) - 4)
  end

  local function add_line(text, hl)
    table.insert(lines, text or "")
    local idx = #lines - 1
    if hl then
      table.insert(line_highlights, { line = idx, group = hl })
    end
    return idx
  end

  local function add_range_highlight(line, col_start, col_end, group)
    if line == nil or col_start == nil or col_end == nil or not group then
      return
    end
    if col_end <= col_start then
      return
    end
    table.insert(range_highlights, {
      line = line,
      col_start = col_start,
      col_end = col_end,
      group = group,
    })
  end

  local function ensure_separator()
    if #lines == 0 or lines[#lines] == "" then
      return
    end
    add_line("", nil)
  end

  local function split_text(text)
    return vim.split(text or "", "\n", { plain = true })
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
      local line_text = "  " .. line
      if hl == USER_PROMPT_HL then
        local pad = math.max(0, width - #line_text)
        line_text = line_text .. string.rep(" ", pad)
      end
      add_line(line_text, applied)
    end
  end

  local function strip_thinking(content, thinking)
    thinking = thinking or ""
    content = content or ""
    if thinking == "" then
      return content
    end
    local prefix = thinking .. "\n\n"
    if content:sub(1, #prefix) == prefix then
      return content:sub(#prefix + 1)
    end
    return content
  end

  local function render_assistant_markdown(msg)
    local thinking = msg.thinking or ""
    if thinking ~= "" then
      for _, line in ipairs(split_text(thinking)) do
        add_line("  > " .. line, THINKING_HL)
      end
      add_line("", nil)
    end
    local body = strip_thinking(msg.content or "", thinking)
    for _, line in ipairs(split_text(body)) do
      add_line("  " .. line)
    end
  end

  local function render_assistant_custom(msg)
    local thinking_left = thinking_line_count(msg.thinking or "")
    local blocks = markdown.parse(msg.content or "", msg.streaming)

    for _, block in ipairs(blocks) do
      if block.type == "code" then
        local header = block.lang and ("  ```" .. block.lang) or "  ```"
        add_line(header, "PiChatCodeFence")
        local code_start = #lines
        for _, code_line in ipairs(vim.split(block.content or "", "\n", { plain = true })) do
          add_line("  " .. code_line, "PiChatCodeBlock")
        end
        if syntax and block.lang and block.lang ~= "" then
          local highlights = syntax.get_highlights(block.content or "", block.lang)
          for _, hl in ipairs(highlights) do
            local target_line = code_start + hl.line
            add_range_highlight(target_line, 2 + hl.col_start, 2 + hl.col_end, hl.hl_group)
          end
        end
        if block.incomplete then
          add_line("  ``` (streaming...)", "PiChatCodeFence")
        else
          add_line("  ```", "PiChatCodeFence")
        end
      elseif block.type == "text_with_inline" then
        local line_hl
        if thinking_left > 0 then
          line_hl = THINKING_HL
          thinking_left = thinking_left - 1
        end
        local text = "  "
        local cursor = #text
        local inline_ranges = {}
        for _, segment in ipairs(block.segments or {}) do
          local segment_text = segment.content or ""
          if inline_enabled and segment.type == "code" then
            table.insert(inline_ranges, { start = cursor, end_col = cursor + #segment_text })
          end
          text = text .. segment_text
          cursor = cursor + #segment_text
        end
        local line_idx = add_line(text, line_hl)
        for _, rng in ipairs(inline_ranges) do
          add_range_highlight(line_idx, rng.start, rng.end_col, "PiChatInlineCode")
        end
      else
        local line_hl
        if thinking_left > 0 then
          line_hl = THINKING_HL
          thinking_left = thinking_left - 1
        end
        add_line("  " .. (block.content or ""), line_hl)
      end
    end
  end

  local function render_assistant(msg)
    if use_render_markdown then
      render_assistant_markdown(msg)
    else
      render_assistant_custom(msg)
    end
  end

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

  for _, msg in ipairs(M.messages) do
    ensure_separator()

    if msg.role == "user" then
      add_message_lines(msg.content, USER_PROMPT_HL)

    elseif msg.role == "assistant" then
      render_assistant(msg)

    elseif msg.role == "tool" then
      add_message_lines(msg.content)

    elseif msg.role == "tool_result" then
      add_message_lines(msg.content, TOOL_RESULT_HL, diff_line_highlight)

    elseif msg.role == "system" then
      add_line("  ⚠️  " .. (msg.content or ""))
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
  for _, hl in ipairs(line_highlights) do
    vim.api.nvim_buf_add_highlight(M.result_buf, HIGHLIGHT_NS, hl.group, hl.line, 0, -1)
  end

  local function apply_range(entry)
    if not entry or entry.line == nil or not entry.group then
      return
    end
    local has_highlight = vim.highlight and vim.highlight.range
    if has_highlight then
      vim.highlight.range(
        M.result_buf,
        HIGHLIGHT_NS,
        entry.group,
        { entry.line, entry.col_start },
        { entry.line, entry.col_end }
      )
    else
      vim.api.nvim_buf_set_extmark(M.result_buf, HIGHLIGHT_NS, entry.line, entry.col_start, {
        end_col = entry.col_end,
        hl_group = entry.group,
      })
    end
  end

  for _, entry in ipairs(range_highlights) do
    apply_range(entry)
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
  if not client then
    M.add_message("system", "Not connected to Pi agent", false)
    return
  end

  -- Get state first
  client:request("get_state", { type = "get_state" }, function(state_result)
    vim.schedule(function()
      if state_result.success and state_result.data then
        local data = state_result.data
        if data.model then
          M.session_info.model = data.model.name or data.model.id or "Unknown"
        end
      elseif state_result.error then
        vim.notify("Pi: Failed to get state - " .. state_result.error, vim.log.levels.WARN)
      end

      -- Always try to get messages even if state failed
      client:request("get_messages", { type = "get_messages" }, function(result)
        vim.schedule(function()
          if result.error then
            vim.notify("Pi: Failed to load messages - " .. result.error, vim.log.levels.WARN)
            return
          end

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
