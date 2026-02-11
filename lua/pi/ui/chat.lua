local state = require("pi.state")
local events = require("pi.events")
local config = require("pi.config")
local commands = require("pi.rpc.commands")
local autocomplete = require("pi.ui.autocomplete")
local colors = require("pi.ui.colors")
local image_utils = require("pi.util.images")

local M = {}
local commands_loading = false

local use_render_markdown = false
local syntax_enabled = config.get("ui.syntax_highlighting") ~= false
local inline_enabled = config.get("ui.inline_code_highlighting") ~= false

-- Register markdown treesitter parser for our custom filetype (like avante.nvim)
vim.treesitter.language.register("markdown", "PiChat")

local markdown
local syntax

markdown = require("pi.ui.markdown")
if syntax_enabled then
  syntax = require("pi.ui.syntax")
end

local HIGHLIGHT_NS = vim.api.nvim_create_namespace("pi_chat_highlights")
local INPUT_STATUS_NS = vim.api.nvim_create_namespace("pi_chat_input_status")
local HIGHLIGHT_AUGROUP = vim.api.nvim_create_augroup("PiChatHighlights", { clear = true })
local THINKING_HL = "PiChatThinking"
local USER_PROMPT_HL = "PiChatUserPrompt"
local TOOL_RESULT_HL = "PiChatToolResult"
local DIFF_ADD_HL = "PiChatDiffAdd"
local DIFF_DEL_HL = "PiChatDiffDel"
local last_render_time = 0
local render_debounce_ms = 16
local pending_render_timer

local spinner_interval = 100
local spinner_timer

local respect_user_highlights = config.get("ui.respect_user_highlights") ~= false
local respect_colorscheme = config.get("ui.respect_colorscheme") ~= false
local custom_highlights = config.get("ui.custom_highlights") or {}

local function resolve_code_bg()
  local setting = config.get("ui.code_block_bg")
  if setting == "none" then
    return nil
  end
  if type(setting) == "string" then
    if setting ~= "" and setting ~= "auto" then
      local num = tonumber(setting:gsub("#", ""), 16)
      if num then
        return num
      end
    end
  elseif type(setting) == "number" then
    return setting
  end
  return colors.get_code_bg()
end

local function setup_highlights()
  local code_bg = resolve_code_bg()
  local user_bg = colors.get_user_message_bg()
  local highlights = {
    [THINKING_HL] = {
      fg_link = "Comment",
      italic = true,
    },
    [USER_PROMPT_HL] = {
      bg = user_bg,
    },
    [TOOL_RESULT_HL] = {
      fg_link = "Special",
    },
    ["PiChatCodeBlock"] = {
      bg = code_bg,
    },
    ["PiChatInlineCode"] = {
      fg_link = "String",
      bg = code_bg,
    },
    ["PiChatCodeFence"] = {
      fg_link = "Comment",
      italic = true,
    },
    [DIFF_ADD_HL] = {
      link = "DiffAdd",
    },
    [DIFF_DEL_HL] = {
      link = "DiffDelete",
    },
  }

  for name, def in pairs(custom_highlights) do
    if highlights[name] then
      highlights[name] = vim.tbl_deep_extend("force", highlights[name], def)
    else
      highlights[name] = def
    end
  end

  for name, def in pairs(highlights) do
    if respect_user_highlights and not custom_highlights[name] and colors.has_user_colors(name) then
      goto continue
    end
    colors.apply_highlight(name, def)
    ::continue::
  end
end

setup_highlights()

if respect_colorscheme then
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = HIGHLIGHT_AUGROUP,
    callback = function()
      setup_highlights()
      if M.is_open() then
        M.render()
      end
    end,
  })
end

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
M.tool_streams = {}
M.pending_images = {}
M.tool_spinner_active = false
M.tool_spinner_label = nil
M.spinner_frames = { "⠋", "⠙", "⠚", "⠞", "⠖", "⠦", "⠴", "⠲", "⠳", "⠓" }
M.spinner_index = 1
M.parameter_hint_active = false

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

local function build_image_payloads(images)
  local payloads = {}
  local display = {}
  for _, image in ipairs(images) do
    table.insert(payloads, { data = image.data, mimeType = image.mimeType })
    table.insert(display, { path = image.path, mimeType = image.mimeType })
  end
  return payloads, display
end

local function collect_pending_images()
  if #M.pending_images == 0 then
    return nil, nil
  end
  local payloads, display = build_image_payloads(M.pending_images)
  M.pending_images = {}
  return payloads, display
end

local function format_image_label(image)
  if type(image) == "string" then
    return image
  end
  return image.path or image.file or image.uri or "(image)"
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

local function format_tool_label(tool_name, args)
  local label = tool_name or "tool"
  local parts = {}
  if args then
    if args.command then table.insert(parts, args.command) end
    if args.file then table.insert(parts, args.file) end
    if args.path then table.insert(parts, args.path) end
    if args.filepath then table.insert(parts, args.filepath) end
  end
  if #parts > 0 then
    label = string.format("%s (%s)", label, table.concat(parts, ", "))
  end
  return label
end

local function safe_encode(value)
  if value == nil then
    return ""
  end
  if type(value) == "string" then
    return value
  end
  if type(value) == "table" then
    local ok, encoded = pcall(vim.json.encode, value)
    if ok then
      return encoded
    end
  end
  return tostring(value)
end

local function format_tool_result_text(result, meta)
  local text = ""
  if type(result) == "string" then
    text = result
  elseif type(result) == "table" then
    if result.output then
      text = result.output
    elseif result.diff then
      text = result.diff
    elseif result.result then
      text = safe_encode(result.result)
    else
      text = safe_encode(result)
    end
  elseif result ~= nil then
    text = tostring(result)
  end

  local truncated = meta and (meta.truncated or (type(result) == "table" and result.truncated))
  local full_path = meta and (meta.fullOutputPath or (type(result) == "table" and result.fullOutputPath))
  if truncated or full_path then
    local notes = {}
    if truncated then
      table.insert(notes, "truncated")
    end
    if full_path then
      table.insert(notes, "full output: " .. full_path)
    end
    local note = "(" .. table.concat(notes, ", ") .. ")"
    if text ~= "" then
      text = text .. "\n\n" .. note
    else
      text = note
    end
  end

  if text == "" then
    text = "(no output)"
  end
  return text
end

local function format_partial_text(partial)
  if partial == nil then
    return nil
  end
  if type(partial) == "string" then
    return partial
  end
  if type(partial) == "table" then
    if partial.output then
      return partial.output
    end
    return safe_encode(partial)
  end
  return tostring(partial)
end

local function ensure_tool_stream(tool_id, tool_name, args)
  if not tool_id then
    return nil
  end
  local stream = M.tool_streams[tool_id]
  if not stream then
    local header = string.format("Running %s", format_tool_label(tool_name, args))
    M.add_message("tool", header, false, { tool_id = tool_id, tool_name = tool_name })
    stream = {
      header_index = #M.messages,
      output_index = nil,
      name = tool_name,
      args = args,
      partial = "",
      finalized = false,
    }
    M.tool_streams[tool_id] = stream
  end
  return stream
end

local function update_tool_stream_output(tool_id, tool_name, args, text, is_final, opts)
  local stream = ensure_tool_stream(tool_id, tool_name, args)
  if not stream then
    return
  end
  if not stream.output_index then
    M.add_message("tool_result", text, not is_final, {
      tool_id = tool_id,
      tool_name = tool_name,
      is_error = opts and opts.is_error,
    })
    stream.output_index = #M.messages
  else
    local entry = M.messages[stream.output_index]
    if entry then
      entry.content = text
      entry.streaming = not is_final
      entry.is_error = opts and opts.is_error
    end
  end
  stream.finalized = is_final or stream.finalized
end

local function append_tool_stream_partial(tool_id, tool_name, args, partial, opts)
  local stream = ensure_tool_stream(tool_id, tool_name, args)
  if not stream then
    return
  end
  local chunk = format_partial_text(partial)
  if not chunk or chunk == "" then
    return
  end
  stream.partial = (stream.partial or "") .. chunk
  update_tool_stream_output(tool_id, tool_name, args, stream.partial, false, opts)
end

local function handle_tool_result_metadata(tool_name, result, args)
  local filepath = nil
  if args then
    filepath = args.file or args.path or args.filepath
  end
  if not filepath and result and type(result) == "table" then
    filepath = result.file or result.path or result.filepath
  end

  if filepath and (tool_name == "edit" or tool_name == "write") then
    queue_file_path(filepath)
  end

  if result then
    if not filepath then
      local candidate = type(result) == "table" and (result.diff or result.output) or result
      local extracted = extract_path_from_text(candidate)
      if extracted then
        queue_file_path(extracted)
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

  return filepath
end

local function stop_spinner_animation()
  if spinner_timer then
    vim.fn.timer_stop(spinner_timer)
    spinner_timer = nil
  end
end

local function start_spinner_animation()
  if spinner_timer or not M.tool_spinner_active then
    return
  end
  spinner_timer = vim.fn.timer_start(spinner_interval, function()
    vim.schedule(function()
      if not M.tool_spinner_active then
        stop_spinner_animation()
        return
      end
      M.spinner_index = (M.spinner_index % #M.spinner_frames) + 1
      M.render()
    end)
  end, { ["repeat"] = -1 })
end

local function start_tool_spinner(tool)
  local label = format_tool_label(tool.name or tool.tool, tool.arguments or tool.args or {})
  M.tool_spinner_label = label
  M.tool_spinner_active = true
  if not M.spinner_index or M.spinner_index < 1 then
    M.spinner_index = 1
  end
  start_spinner_animation()
end

local function stop_tool_spinner()
  M.tool_spinner_active = false
  M.tool_spinner_label = nil
  stop_spinner_animation()
end

local try_open_file
local render_input_status

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
  vim.api.nvim_buf_set_option(M.result_buf, "filetype", "PiChat")
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
  vim.api.nvim_win_set_option(M.result_win, "conceallevel", 2)
  vim.api.nvim_win_set_option(M.result_win, "concealcursor", "nvi")

  vim.cmd("belowright 6split")
  M.input_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(M.input_win, M.input_buf)
  vim.api.nvim_win_set_option(M.input_win, "wrap", true)
  vim.api.nvim_win_set_option(M.input_win, "number", false)
  vim.api.nvim_win_set_option(M.input_win, "relativenumber", false)
  vim.api.nvim_win_set_option(M.input_win, "signcolumn", "no")
  vim.api.nvim_win_set_option(M.input_win, "foldcolumn", "0")
  vim.api.nvim_win_set_option(M.input_win, "colorcolumn", "")
  vim.api.nvim_win_set_option(M.input_win, "winhighlight", "WinSeparator:Normal")

  M.setup_input_buffer()
  M.subscribe_to_events()

  vim.api.nvim_set_current_win(M.input_win)
  vim.cmd("startinsert!")

  M.origin_win = origin_win
  state.update("ui.chat_open", true)
  render_input_status()
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
  local autocomplete_enabled = config.get("ui.autocomplete_enabled") ~= false
  local function handle_enter()
    if autocomplete_enabled and autocomplete.is_open() then
      M.accept_autocomplete()
      return
    end
    M.submit()
  end

  vim.keymap.set("n", "<CR>", handle_enter, { buffer = M.input_buf, silent = true })
  vim.keymap.set("i", "<CR>", handle_enter, { buffer = M.input_buf, silent = true })
  vim.keymap.set("n", "q", "<cmd>PiChat<CR>", { buffer = M.input_buf, silent = true })
  vim.keymap.set("n", "q", "<cmd>PiChat<CR>", { buffer = M.result_buf, silent = true })
  vim.keymap.set("i", "<S-CR>", "<CR>", { buffer = M.input_buf, silent = true })

  -- Model selection keybindings (input buffer only to avoid overriding scroll keys)
  vim.keymap.set({ "n", "i" }, "<C-e>", function()
    require("pi.ui.model_selector").open()
  end, { buffer = M.input_buf, silent = true, desc = "Select model" })
  vim.keymap.set({ "n", "i" }, "<C-t>", function()
    require("pi.ui.model_selector").open_thinking_level()
  end, { buffer = M.input_buf, silent = true, desc = "Select thinking level" })

  if config.get("ui.allow_image_attachments") ~= false then
    vim.keymap.set({ "n", "i" }, "<C-g>", function()
      M.attach_image()
    end, { buffer = M.input_buf, silent = true, desc = "Attach image" })
  end

  if autocomplete_enabled then
    local termcodes = vim.api.nvim_replace_termcodes

    vim.keymap.set("i", "<C-n>", function()
      if autocomplete.is_open() then
        autocomplete.select_next()
        return ""
      end
      return termcodes("<C-n>", true, false, true)
    end, { buffer = M.input_buf, expr = true, silent = true })

    vim.keymap.set("i", "<C-p>", function()
      if autocomplete.is_open() then
        autocomplete.select_prev()
        return ""
      end
      return termcodes("<C-p>", true, false, true)
    end, { buffer = M.input_buf, expr = true, silent = true })

    vim.keymap.set("i", "<Tab>", function()
      if autocomplete.is_open() then
        M.accept_autocomplete()
        return ""
      end
      return termcodes("<Tab>", true, false, true)
    end, { buffer = M.input_buf, expr = true, silent = true })

    vim.keymap.set("i", "<Esc>", function()
      if autocomplete.is_open() then
        autocomplete.close()
        return ""
      end
      return "<Esc>"
    end, { buffer = M.input_buf, expr = true, silent = true })

    vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
      buffer = M.input_buf,
      callback = function()
        M.handle_text_change()
      end,
    })

    vim.api.nvim_create_autocmd("BufLeave", {
      buffer = M.input_buf,
      callback = function()
        autocomplete.close()
      end,
    })
  end

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
      render_input_status()
    end,
  })
end

local function clear_input_buffer()
  if M.input_buf and vim.api.nvim_buf_is_valid(M.input_buf) then
    vim.api.nvim_buf_set_lines(M.input_buf, 0, -1, false, { "" })
  end
end

--- Handle slash commands that should be intercepted locally (not sent to the agent).
--- Returns true if the input was handled, false otherwise.
local function handle_local_slash_command(text)
  local trimmed = vim.trim(text)

  -- /model [filter] — open the model selector, optionally pre-filtered
  if trimmed == "/model" or trimmed:match("^/model%s+") then
    local model_arg = trimmed:match("^/model%s+(.+)") or ""
    clear_input_buffer()
    local model_picker = require("pi.ui.model_picker")
    local filter = (model_arg ~= "") and model_arg or nil
    model_picker.open({ filter = filter, anchor_win = M.input_win })
    return true
  end

  -- /thinking [level] — open thinking level selector or set directly
  local thinking_match = trimmed == "/thinking" or trimmed:match("^/thinking%s+")
  local thinking_arg = thinking_match and (trimmed:match("^/thinking%s+(.+)") or "") or nil
  if thinking_match then
    clear_input_buffer()
    if thinking_arg ~= "" then
      -- Direct set: /thinking high
      local client = state.get("rpc_client")
      if client and client.connected then
        local model_rpc = require("pi.rpc.model")
        model_rpc.set_thinking_level(client, thinking_arg, function(result)
          vim.schedule(function()
            if result and result.success then
              vim.notify("Pi: Thinking level set to " .. thinking_arg, vim.log.levels.INFO)
              M.render()
            else
              vim.notify("Pi: Failed to set thinking level - " .. (result and result.error or "unknown"), vim.log.levels.ERROR)
            end
          end)
        end)
      else
        vim.notify("Pi: Not connected to agent", vim.log.levels.ERROR)
      end
    else
      require("pi.ui.model_selector").open_thinking_level()
    end
    return true
  end

  return false
end

function M.submit()
  if not M.input_buf or not vim.api.nvim_buf_is_valid(M.input_buf) then
    return
  end

  autocomplete.close()

  local lines = vim.api.nvim_buf_get_lines(M.input_buf, 0, -1, false)
  local text = table.concat(lines, "\n")

  if text == "Type your message..." or text:match("^%s*$") then
    return
  end

  -- Intercept local slash commands before sending to agent
  if handle_local_slash_command(text) then
    return
  end

  local function do_send(opts)
    local sent = M.send_message(text, opts)
    if sent then
      clear_input_buffer()
    end
  end

  if M.is_streaming then
    M.handle_streaming_submit(text, do_send)
    return
  end

  do_send(nil)
end

function M.attach_image(path)
  if config.get("ui.allow_image_attachments") == false then
    vim.notify("Pi: Image attachments disabled", vim.log.levels.WARN)
    return
  end

  if not M.is_open() then
    vim.notify("Pi: Chat is not open", vim.log.levels.WARN)
    return
  end

  if not path or path == "" then
    vim.ui.input({ prompt = "Attach image (png/jpeg): " }, function(input)
      if input and input ~= "" then
        M.attach_image(input)
      end
    end)
    return
  end

  local expanded = vim.fn.expand(path)
  if vim.fn.filereadable(expanded) == 0 then
    vim.notify("Pi: Image not found: " .. expanded, vim.log.levels.ERROR)
    return
  end

  local encoded, err = image_utils.encode_image(expanded)
  if not encoded then
    vim.notify("Pi: Failed to attach image - " .. tostring(err), vim.log.levels.ERROR)
    return
  end

  table.insert(M.pending_images, encoded)
  vim.notify("Pi: Attached image " .. expanded, vim.log.levels.INFO)
  M.render()
end

function M.handle_streaming_submit(text, callback)
  local default = config.get("ui.streaming_prompt_default") or "follow_up"
  local behavior

  if default == "steer" then
    behavior = "steer"
  elseif default == "follow_up" or default == "followUp" then
    behavior = "followUp"
  end

  if default ~= "block" and behavior then
    vim.notify("Pi: Agent is streaming - sending as " .. (behavior == "steer" and "steer" or "follow-up"), vim.log.levels.INFO)
    callback({ streamingBehavior = behavior })
    return
  end

  local options = {
    { label = "Steer now", behavior = "steer" },
    { label = "Queue follow-up", behavior = "followUp" },
    { label = "Cancel", behavior = nil },
  }

  vim.ui.select(options, {
    prompt = "Agent is streaming. Choose delivery:",
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    if not choice or not choice.behavior then
      return
    end
    callback({ streamingBehavior = choice.behavior })
  end)
end

function M.handle_text_change()
  if config.get("ui.autocomplete_enabled") == false then
    return
  end

  if not M.input_win or not vim.api.nvim_win_is_valid(M.input_win) then
    autocomplete.close()
    return
  end

  if not M.input_buf or not vim.api.nvim_buf_is_valid(M.input_buf) then
    autocomplete.close()
    return
  end

  local ok, cursor = pcall(vim.api.nvim_win_get_cursor, M.input_win)
  if not ok or not cursor then
    autocomplete.close()
    return
  end

  local line = vim.api.nvim_buf_get_lines(M.input_buf, cursor[1] - 1, cursor[1], false)[1] or ""
  local before_cursor = line:sub(1, cursor[2])
  local slash_match = before_cursor:match("^%s*/([%w_%-]*)$") or before_cursor:match("%s+/([%w_%-]*)$")
  if not slash_match then
    if M.parameter_hint_active then
      return
    end
    autocomplete.close()
    return
  end

  local width = math.floor(vim.api.nvim_win_get_width(M.input_win) * 0.8)
  local cached = commands.get_cached()

  if #cached == 0 then
    if commands_loading then
      return
    end
    commands_loading = true

    autocomplete.set_items({ { name = "/...", description = "Loading commands...", source = "system" } })
    if not autocomplete.is_open() then
      autocomplete.open(M.input_win, cursor[1], cursor[2], width)
    else
      autocomplete.render()
    end

    local client = state.get("rpc_client")
    if not client then
      commands_loading = false
      autocomplete.close()
      return
    end

    commands.get_all(client, function(result)
      vim.schedule(function()
        commands_loading = false
        if result and result.error then
          autocomplete.close()
          return
        end

        if not M.input_win or not vim.api.nvim_win_is_valid(M.input_win) then
          autocomplete.close()
          return
        end
        if not M.input_buf or not vim.api.nvim_buf_is_valid(M.input_buf) then
          autocomplete.close()
          return
        end

        local current_cursor = vim.api.nvim_win_get_cursor(M.input_win)
        local current_line = vim.api.nvim_buf_get_lines(M.input_buf, current_cursor[1] - 1, current_cursor[1], false)[1] or ""
        local current_before = current_line:sub(1, current_cursor[2])
        local current_match = current_before:match("^%s*/([%w_%-]*)$") or current_before:match("%s+/([%w_%-]*)$")
        if current_match then
          autocomplete.filter(current_match)
          local new_width = math.floor(vim.api.nvim_win_get_width(M.input_win) * 0.8)
          if not autocomplete.is_open() then
            autocomplete.open(M.input_win, current_cursor[1], current_cursor[2], new_width)
          else
            autocomplete.render()
          end
        else
          autocomplete.close()
        end
      end)
    end)

    return
  end

  autocomplete.filter(slash_match)
  if not autocomplete.is_open() then
    autocomplete.open(M.input_win, cursor[1], cursor[2], width)
  else
    autocomplete.render()
  end
end

function M.accept_autocomplete()
  local selected = autocomplete.get_selected()
  if not selected then
    autocomplete.close()
    return
  end

  if not M.input_win or not vim.api.nvim_win_is_valid(M.input_win) then
    autocomplete.close()
    return
  end
  if not M.input_buf or not vim.api.nvim_buf_is_valid(M.input_buf) then
    autocomplete.close()
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(M.input_win)
  local line = vim.api.nvim_buf_get_lines(M.input_buf, cursor[1] - 1, cursor[1], false)[1] or ""
  local before_cursor = line:sub(1, cursor[2])
  local prefix = before_cursor:match("^(.*)/[%w_%-]*$") or before_cursor
  local after_cursor = line:sub(cursor[2] + 1)
  local command_name = selected.name or ""
  local replacement = prefix .. command_name .. " " .. after_cursor
  vim.api.nvim_buf_set_lines(M.input_buf, cursor[1] - 1, cursor[1], false, { replacement })
  local new_col = #prefix + #command_name + 1
  vim.api.nvim_win_set_cursor(M.input_win, { cursor[1], new_col })
  local anchor_win = M.input_win
  local hint_row = cursor[1]
  local hint_col = new_col
  autocomplete.close({ keep_hint = true })
  if anchor_win and vim.api.nvim_win_is_valid(anchor_win) then
    autocomplete.show_parameter_hint(selected, anchor_win, hint_row, hint_col, {
      on_close = function()
        M.parameter_hint_active = false
      end,
    })
    M.parameter_hint_active = true
  end
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
    M.tool_streams = {}
    stop_tool_spinner()

  elseif event_type == "disconnected" then
    M.is_streaming = false
    M.finalize_streaming_message()
    stop_tool_spinner()
    M.add_message("system", "Agent disconnected (exit code: " .. tostring(event.exit_code or "?") .. ")", false)

  elseif event_type == "reconnected" then
    M.add_message("system", "Agent reconnected", false)
    M.load_history()

  elseif event_type == "turn_start" then
    -- silently ignored in chat UI

  elseif event_type == "turn_end" then
    -- silently ignored in chat UI

  elseif event_type == "tool_execution_start" then
    local tool_id = event.toolCallId
    local tool_name = event.toolName or event.tool or "tool"
    local args = event.args or {}
    register_tool_call_context({ id = tool_id, name = tool_name, args = args })
    if config.get("ui.show_tool_streaming") ~= false then
      ensure_tool_stream(tool_id, tool_name, args)
    end
    start_tool_spinner({ name = tool_name, args = args })

  elseif event_type == "tool_execution_update" then
    if config.get("ui.show_tool_streaming") ~= false then
      append_tool_stream_partial(event.toolCallId, event.toolName or event.tool, event.args or {}, event.partialResult, { is_error = event.isError })
    end

  elseif event_type == "tool_execution_end" then
    local tool_id = event.toolCallId
    local tool_name = event.toolName or event.tool or "tool"
    local args = event.args or {}
    local result_text = format_tool_result_text(event.result, event)
    update_tool_stream_output(tool_id, tool_name, args, result_text, true, { is_error = event.isError })
    handle_tool_result_metadata(tool_name, event.result, args)
    stop_tool_spinner()
    flush_pending_file_paths()

  elseif event_type == "auto_compaction_start" then
    if config.get("ui.show_compaction_status") ~= false then
      local message_text = "Auto-compaction started"
      if event.reason then
        message_text = message_text .. ": " .. tostring(event.reason)
      end
      M.add_message("system", message_text, false)
    end

  elseif event_type == "auto_compaction_end" then
    if config.get("ui.show_compaction_status") ~= false then
      local message_text = "Auto-compaction finished"
      if event.aborted then
        message_text = "Auto-compaction aborted"
      elseif event.error then
        message_text = "Auto-compaction error: " .. tostring(event.error)
      end
      local summary = {}
      if event.result and event.result.tokensBefore then
        table.insert(summary, "tokens before: " .. tostring(event.result.tokensBefore))
      end
      if event.result and event.result.tokensAfter then
        table.insert(summary, "after: " .. tostring(event.result.tokensAfter))
      end
      if #summary > 0 then
        message_text = message_text .. " (" .. table.concat(summary, ", ") .. ")"
      end
      M.add_message("system", message_text, false)
    end

  elseif event_type == "auto_retry_start" then
    if config.get("ui.show_retry_status") ~= false then
      local attempt = event.attempt or "?"
      local max_attempts = event.maxAttempts or "?"
      local message_text = string.format("Auto-retry %s/%s", attempt, max_attempts)
      if event.delayMs then
        message_text = message_text .. string.format(" in %dms", event.delayMs)
      end
      local err = event.errorMessage or event.error
      if err then
        message_text = message_text .. ": " .. tostring(err)
      end
      M.add_message("system", message_text, false)
    end

  elseif event_type == "auto_retry_end" then
    if config.get("ui.show_retry_status") ~= false then
      local final_error = event.finalError or event.error
      local message_text = "Auto-retry finished"
      if event.aborted then
        message_text = "Auto-retry aborted"
      elseif final_error then
        message_text = "Auto-retry failed: " .. tostring(final_error)
      end
      M.add_message("system", message_text, false)
    end

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
    local args = event.args or {}
    if event.file or event.filepath then
      args = vim.tbl_extend("force", args, { file = event.file or event.filepath })
    end
    handle_tool_result_metadata(tool_name, result, args)

  end

  if event.type == "message_end" and event.message then
    if event.message.role == "toolResult" then
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
      local stream = tool_id and M.tool_streams[tool_id]
      if stream then
        update_tool_stream_output(tool_id, tool_name, stream.args or {}, display, true, { is_error = event.message.isError })
        M.tool_streams[tool_id] = nil
      else
        M.add_message("tool_result", display, false, { tool_id = tool_id, tool_name = tool_name, is_error = event.message.isError })
      end
      stop_tool_spinner()
      flush_pending_file_paths()

    elseif event.message.role == "bashExecution" then
      local parts = {}
      if type(event.message.content) == "string" then
        table.insert(parts, event.message.content)
      else
        for _, chunk in ipairs(event.message.content or {}) do
          if type(chunk) == "table" and chunk.text then
            table.insert(parts, chunk.text)
          elseif type(chunk) == "string" then
            table.insert(parts, chunk)
          end
        end
      end
      local result_text = table.concat(parts, "")
      local display = result_text ~= "" and result_text or "(no output)"
      M.add_message("tool_result", display, false, { tool_name = "bash" })
    end
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

function M.add_message(role, content, is_streaming, opts)
  opts = opts or {}
  local entry = {
    role = role,
    content = content,
    streaming = is_streaming,
    images = opts.images,
    tool_id = opts.tool_id,
    tool_name = opts.tool_name,
    is_error = opts.is_error,
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

render_input_status = function()
  if not M.input_buf or not vim.api.nvim_buf_is_valid(M.input_buf) then
    return
  end

  vim.api.nvim_buf_clear_namespace(M.input_buf, INPUT_STATUS_NS, 0, -1)

  local virt_lines = {}

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
  if #M.pending_images > 0 then
    table.insert(status_parts, string.format("%d image(s) attached", #M.pending_images))
  end
  local sep_width = 40
  if M.input_win and vim.api.nvim_win_is_valid(M.input_win) then
    sep_width = vim.api.nvim_win_get_width(M.input_win)
  end
  local sep_line = string.rep("─", sep_width)

  -- Top separator (above input line)
  vim.api.nvim_buf_set_extmark(M.input_buf, INPUT_STATUS_NS, 0, 0, {
    virt_lines = { { { sep_line, THINKING_HL } } },
    virt_lines_above = true,
  })

  -- Bottom separator (below input line)
  table.insert(virt_lines, { { sep_line, THINKING_HL } })

  if #status_parts > 0 then
    table.insert(virt_lines, { { table.concat(status_parts, "  •  "), THINKING_HL } })
  end

  local footer = "Enter=send  Shift+Enter=new line  q=close  Ctrl+e=model"
  if config.get("ui.allow_image_attachments") ~= false then
    footer = footer .. "  Ctrl+g=attach"
  end
  table.insert(virt_lines, { { footer, THINKING_HL } })

  if #virt_lines > 0 then
    local line_count = vim.api.nvim_buf_line_count(M.input_buf)
    vim.api.nvim_buf_set_extmark(M.input_buf, INPUT_STATUS_NS, line_count - 1, 0, {
      virt_lines = virt_lines,
      virt_lines_above = false,
    })
  end
end

local function perform_render()
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
    if hl and not use_render_markdown then
      table.insert(line_highlights, { line = idx, group = hl })
    end
    return idx
  end

  local function add_range_highlight(line, col_start, col_end, group)
    if use_render_markdown then
      return
    end
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

  local function diff_line_highlight(line)
    if not line then
      return nil
    end
    if line:match("^%s*%+") then
      return DIFF_ADD_HL
    elseif line:match("^%s*%-") then
      return DIFF_DEL_HL
    end
    return nil
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
        add_line("> " .. line)
      end
      add_line("", nil)
    end
    local body = strip_thinking(msg.content or "", thinking)
    for _, line in ipairs(split_text(body)) do
      add_line(line)
    end
    add_line("", nil)
  end

  local function render_user_markdown(msg)
    local start_line = #lines
    for _, line in ipairs(split_text(msg.content)) do
      local pad = math.max(0, width - #line)
      add_line(line .. string.rep(" ", pad))
    end
    if msg.images and #msg.images > 0 then
      local att = "Attachments:"
      local pad = math.max(0, width - #att)
      add_line(att .. string.rep(" ", pad))
      for _, image in ipairs(msg.images) do
        local label = string.format("[Image] %s", format_image_label(image))
        local img_pad = math.max(0, width - #label)
        add_line(label .. string.rep(" ", img_pad))
      end
    end
    local end_line = #lines - 1
    for l = start_line, end_line do
      table.insert(line_highlights, { line = l, group = USER_PROMPT_HL })
    end
    add_line("", nil)
  end

  local function render_user_attachments(msg, highlight)
    if not msg.images or #msg.images == 0 then
      return
    end
    for _, image in ipairs(msg.images) do
      add_message_lines("[Image] " .. format_image_label(image), highlight)
    end
  end

  local function render_tool_markdown(msg)
    add_line("**Tool:**")
    add_line("", nil)
    for _, line in ipairs(split_text(msg.content)) do
      add_line(line)
    end
    add_line("", nil)
  end

  local function render_tool_result_markdown(msg)
    local content = msg.content or ""
    local has_diff = content:match("\n%s*[+-]") or content:match("^[+-]")
    local lang = has_diff and "diff" or ""
    add_line("```" .. lang)
    for _, line in ipairs(split_text(content)) do
      add_line(line)
    end
    add_line("```")
    add_line("", nil)
  end

  local function render_system_markdown(msg)
    add_line("> ⚠️ " .. (msg.content or ""))
    add_line("", nil)
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

  for _, msg in ipairs(M.messages) do
    ensure_separator()

    if msg.role == "user" then
      if use_render_markdown then
        render_user_markdown(msg)
      else
        add_message_lines(msg.content, USER_PROMPT_HL)
        render_user_attachments(msg, USER_PROMPT_HL)
      end

    elseif msg.role == "assistant" then
      render_assistant(msg)

    elseif msg.role == "tool" then
      if use_render_markdown then
        render_tool_markdown(msg)
      else
        add_message_lines(msg.content)
      end

    elseif msg.role == "tool_result" then
      if use_render_markdown then
        render_tool_result_markdown(msg)
      else
        add_message_lines(msg.content, TOOL_RESULT_HL, diff_line_highlight)
      end

    elseif msg.role == "system" then
      if use_render_markdown then
        render_system_markdown(msg)
      else
        add_line("  ⚠️  " .. (msg.content or ""))
      end
    end
  end

  if M.tool_spinner_active then
    ensure_separator()
    local frame = M.spinner_frames[M.spinner_index] or M.spinner_frames[1]
    local label = M.tool_spinner_label or "tool"
    add_line(string.format("  %s Running %s...", frame, label))
  end

  ensure_separator()

  vim.api.nvim_buf_set_option(M.result_buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(M.result_buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(M.result_buf, "modifiable", false)

  vim.api.nvim_buf_clear_namespace(M.result_buf, HIGHLIGHT_NS, 0, -1)

  for _, hl in ipairs(line_highlights) do
    vim.api.nvim_buf_add_highlight(M.result_buf, HIGHLIGHT_NS, hl.group, hl.line, 0, -1)
  end

  if not use_render_markdown then
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
  end

  if M.result_win and vim.api.nvim_win_is_valid(M.result_win) then
    local line_count = vim.api.nvim_buf_line_count(M.result_buf)
    if line_count > 0 then
      local scroll_to = math.max(1, line_count - 3)
      vim.api.nvim_win_set_cursor(M.result_win, { scroll_to, 0 })
    end
  end
end

local function do_render()
  if pending_render_timer then
    vim.fn.timer_stop(pending_render_timer)
    pending_render_timer = nil
  end
  last_render_time = vim.loop.now()
  perform_render()
  render_input_status()
end

function M.render()
  if not M.result_buf or not vim.api.nvim_buf_is_valid(M.result_buf) then
    return
  end

  local now = vim.loop.now()
  local elapsed = now - last_render_time
  if M.is_streaming and elapsed < render_debounce_ms then
    if not pending_render_timer then
      local wait = math.max(1, render_debounce_ms - elapsed)
      pending_render_timer = vim.fn.timer_start(wait, function()
        vim.schedule(function()
          pending_render_timer = nil
          do_render()
        end)
      end)
    end
    return
  end

  do_render()
end

function M.send_message(text, opts)
  opts = opts or {}
  local client = state.get("rpc_client")
  if not client then
    vim.notify("Pi: Not connected", vim.log.levels.ERROR)
    return false
  end

  local images_payload, display_images = collect_pending_images()

  if not M.is_streaming then
    M.pending_file_paths = {}
    M.is_streaming = true
    M.current_response = ""
    M.current_thinking = ""
  end

  M.add_message("user", text, false, { images = display_images })

  local prompt_opts = {}
  if images_payload then
    prompt_opts.images = images_payload
  end
  if opts.streamingBehavior then
    prompt_opts.streamingBehavior = opts.streamingBehavior
  end

  local agent = require("pi.rpc.agent")
  agent.prompt(client, text, prompt_opts, function(result)
    vim.schedule(function()
      if result and result.error then
        -- If the error is a timeout but the agent is still running (we're
        -- receiving streaming events), don't kill the streaming state or
        -- show an error — the agent is just busy processing.
        local is_timeout = type(result.error) == "string" and result.error:match("^Timeout:")
        local agent_still_running = state.get("agent.running")
        if is_timeout and agent_still_running then
          -- Silently ignore — agent acknowledged via events, not via
          -- the request-response.  The prompt is being processed.
          return
        end
        M.is_streaming = false
        M.add_message("system", "Error: " .. result.error, false)
      end
    end)
  end)
  return true
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

            if role == "toolResult" or role == "tool_result" then
              role = "tool_result"
            elseif role == "bashExecution" then
              role = "tool_result"
            end

            if role then
              local entry = { role = role, content = content, streaming = false, images = msg.images }
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
  autocomplete.close()
  autocomplete.close_hint()
  stop_spinner_animation()
  if pending_render_timer then
    vim.fn.timer_stop(pending_render_timer)
    pending_render_timer = nil
  end

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
