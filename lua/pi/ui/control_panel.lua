local state = require("pi.state")
local events = require("pi.events")
local config = require("pi.config")
local colors = require("pi.ui.colors")

local M = {}
M.buf = nil
M.win = nil

local PANEL_NS = vim.api.nvim_create_namespace("pi_control_panel")
local PANEL_TITLE = "PiPanelTitle"
local PANEL_RUNNING = "PiPanelRunning"
local PANEL_IDLE = "PiPanelIdle"
local PANEL_ERROR = "PiPanelError"
local respect_user_highlights = config.get("ui.respect_user_highlights") ~= false
local respect_colorscheme = config.get("ui.respect_colorscheme") ~= false

local PANEL_HL_AUGROUP = vim.api.nvim_create_augroup("PiControlPanelHighlights", { clear = true })

local function apply_panel_highlight(name, def)
  if respect_user_highlights and colors.has_user_colors(name) then
    return
  end
  colors.apply_highlight(name, def)
end

local function setup_panel_highlights()
  apply_panel_highlight(PANEL_TITLE, { fg_link = "Title", bold = true })
  apply_panel_highlight(PANEL_RUNNING, { fg_link = "String" })
  apply_panel_highlight(PANEL_IDLE, { fg_link = "Comment" })
  apply_panel_highlight(PANEL_ERROR, { fg_link = "ErrorMsg" })
end

setup_panel_highlights()

if respect_colorscheme then
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = PANEL_HL_AUGROUP,
    callback = function()
      setup_panel_highlights()
      if M.is_open() then
        M.render()
      end
    end,
  })
end

-- Open control panel
function M.open()
  if M.is_open() then
    return
  end
  
  -- Create buffer
  M.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(M.buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(M.buf, "swapfile", false)
  vim.api.nvim_buf_set_name(M.buf, "Pi Control Panel")
  
  -- Create window (top-right corner)
  local width = 50
  local height = 10
  local ui = vim.api.nvim_list_uis()[1]
  
  M.win = vim.api.nvim_open_win(M.buf, false, {
    relative = "editor",
    width = width,
    height = height,
    col = ui.width - width - 2,
    row = 1,
    style = "minimal",
    border = "rounded",
  })
  
  -- Set window options
  vim.api.nvim_win_set_option(M.win, "winblend", 10)
  
  -- Initial render
  M.render()
  
  -- Subscribe to state changes
  M.unsubscribe = events.on("state_updated", function()
    if M.is_open() then
      M.render()
    end
  end)
  
  state.update("ui.control_panel_open", true)
end

-- Close control panel
function M.close()
  if not M.is_open() then
    return
  end
  
  if M.unsubscribe then
    M.unsubscribe()
  end
  
  if M.win and vim.api.nvim_win_is_valid(M.win) then
    vim.api.nvim_win_close(M.win, true)
  end
  
  if M.buf and vim.api.nvim_buf_is_valid(M.buf) then
    vim.api.nvim_buf_delete(M.buf, { force = true })
  end
  
  M.win = nil
  M.buf = nil
  
  state.update("ui.control_panel_open", false)
end

-- Toggle control panel
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

-- Render content
function M.render()
  if not M.buf or not vim.api.nvim_buf_is_valid(M.buf) then
    return
  end

  local agent = state.get("agent") or {}
  local sessions = state.get("sessions") or {}

  local lines = {}
  local highlights = {}
  local function add_line(text, group)
    table.insert(lines, text)
    if group then
      table.insert(highlights, { line = #lines - 1, group = group })
    end
  end

  local max_text_width = 46
  local function truncate(text)
    if not text then return "" end
    text = tostring(text)
    if #text > max_text_width then
      return text:sub(1, max_text_width - 3) .. "..."
    end
    return text
  end

  local function format_model(model)
    if not model then return nil end
    if type(model) == "string" then
      return model
    end
    local name = model.name or model.id or "model"
    local provider = model.provider and (" (" .. model.provider .. ")") or ""
    return name .. provider
  end

  local function format_tool(tool)
    if not tool then return nil end
    local label = tool.name or tool.tool or "tool"
    local args = tool.args or {}
    local extra = args.command or args.file or args.path or args.filepath
    if extra then
      label = label .. " (" .. extra .. ")"
    end
    return label
  end

  add_line("╔══════════════════════════════════════════════╗", PANEL_TITLE)
  add_line("║              PI CODING AGENT                 ║", PANEL_TITLE)
  add_line("╚══════════════════════════════════════════════╝", PANEL_TITLE)
  add_line("", nil)

  local connected = state.get("connected")
  local conn_icon = connected and "●" or "○"
  local conn_highlight = connected and PANEL_RUNNING or PANEL_ERROR
  add_line(string.format("Connection: %s", conn_icon), conn_highlight)

  local status_text = "Idle"
  if agent.running then
    status_text = agent.paused and "Paused" or "Running"
  end
  local status_highlight = agent.running and not agent.paused and PANEL_RUNNING or PANEL_IDLE
  add_line(string.format("Status: %s", status_text), status_highlight)

  if agent.current_task then
    add_line(string.format("Task: %s", truncate(agent.current_task)), PANEL_IDLE)
  end

  local session_name = agent.session_name or (sessions.current and sessions.current.name)
  if session_name then
    add_line(string.format("Session: %s", truncate(session_name)), PANEL_RUNNING)
  end

  if agent.message_count ~= nil then
    add_line(string.format("Messages: %s", agent.message_count), PANEL_IDLE)
  end

  if agent.model then
    add_line(string.format("Model: %s", truncate(format_model(agent.model))), PANEL_IDLE)
  end

  if agent.thinking_level then
    add_line(string.format("Thinking: %s", agent.thinking_level), PANEL_IDLE)
  end

  if agent.steering_mode then
    add_line(string.format("Steering: %s", agent.steering_mode), PANEL_IDLE)
  end

  if agent.follow_up_mode then
    add_line(string.format("Follow-up: %s", agent.follow_up_mode), PANEL_IDLE)
  end

  if agent.pending_message_count ~= nil then
    add_line(string.format("Queue: %s", agent.pending_message_count), PANEL_IDLE)
  end

  if agent.auto_compaction ~= nil then
    add_line(string.format("Auto-compact: %s", agent.auto_compaction and "on" or "off"), PANEL_IDLE)
  end

  if agent.auto_retry ~= nil then
    add_line(string.format("Auto-retry: %s", agent.auto_retry and "on" or "off"), PANEL_IDLE)
  end

  if agent.current_tool then
    add_line(string.format("Tool: %s", truncate(format_tool(agent.current_tool))), PANEL_RUNNING)
  end

  if agent.current_turn then
    local turn_id = agent.current_turn.turnId or agent.current_turn.turn or agent.current_turn.id or "active"
    add_line(string.format("Turn: %s", truncate(turn_id)), PANEL_RUNNING)
  end

  if config.get("ui.show_compaction_status") ~= false and agent.compacting then
    local reason = agent.compaction_reason or "running"
    add_line(string.format("Compacting: %s", truncate(reason)), PANEL_RUNNING)
  end

  if config.get("ui.show_retry_status") ~= false and agent.retrying then
    local info = agent.retry_info or {}
    local attempt = info.attempt or "?"
    local max_attempts = info.max_attempts or "?"
    local retry_line = string.format("Retrying: %s/%s", attempt, max_attempts)
    if info.delay_ms then
      retry_line = retry_line .. string.format(" in %dms", info.delay_ms)
    end
    add_line(truncate(retry_line), PANEL_ERROR)
  end

  local bash = state.get("bash") or {}
  if bash.running then
    local command = bash.current_command or "running"
    add_line(string.format("Bash: %s", truncate(command)), PANEL_RUNNING)
  end

  if config.get("ui.extension_status_panel") ~= false then
    local statuses = state.get("ui.statuses") or {}
    local widgets = state.get("ui.widgets") or {}

    if not vim.tbl_isempty(statuses) or not vim.tbl_isempty(widgets) then
      add_line("", nil)
      add_line("Extensions:", PANEL_TITLE)

      local status_keys = vim.tbl_keys(statuses)
      table.sort(status_keys)
      for _, key in ipairs(status_keys) do
        add_line(string.format("  %s: %s", key, truncate(statuses[key])), PANEL_IDLE)
      end

      local widget_keys = vim.tbl_keys(widgets)
      table.sort(widget_keys)
      for _, key in ipairs(widget_keys) do
        local widget = widgets[key]
        local placement = widget and widget.placement or ""
        add_line(string.format("  %s (%s)", key, placement), PANEL_IDLE)
        for _, line in ipairs(widget.lines or {}) do
          add_line(string.format("    %s", truncate(line)), PANEL_IDLE)
        end
      end
    end
  end

  add_line("", nil)
  add_line("Commands:", PANEL_TITLE)
  add_line("  :PiStart <task>  - Start agent")
  add_line("  :PiPause         - Pause agent")
  add_line("  :PiResume        - Resume agent")
  add_line("  :PiStop          - Stop agent")
  add_line("  :PiChatAttach    - Attach image")

  if M.win and vim.api.nvim_win_is_valid(M.win) then
    local ui = vim.api.nvim_list_uis()[1]
    local max_height = ui and (ui.height - 4) or #lines
    local height = math.min(#lines, max_height)
    if height < 6 then
      height = 6
    end
    pcall(vim.api.nvim_win_set_height, M.win, height)
  end

  vim.api.nvim_buf_set_option(M.buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(M.buf, "modifiable", false)

  vim.api.nvim_buf_clear_namespace(M.buf, PANEL_NS, 0, -1)
  for _, hl in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(M.buf, PANEL_NS, hl.group, hl.line, 0, -1)
  end
end

return M