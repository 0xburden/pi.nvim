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
    add_line(string.format("Task: %s", agent.current_task:sub(1, 40)), PANEL_IDLE)
  end

  if sessions.current then
    add_line(string.format("Session: %s", sessions.current.name or "Unnamed"), PANEL_RUNNING)
  end

  add_line("", nil)
  add_line("Commands:", PANEL_TITLE)
  add_line("  :PiStart <task>  - Start agent")
  add_line("  :PiPause         - Pause agent")
  add_line("  :PiResume        - Resume agent")
  add_line("  :PiStop          - Stop agent")

  vim.api.nvim_buf_set_option(M.buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(M.buf, "modifiable", false)

  vim.api.nvim_buf_clear_namespace(M.buf, PANEL_NS, 0, -1)
  for _, hl in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(M.buf, PANEL_NS, hl.group, hl.line, 0, -1)
  end
end

return M