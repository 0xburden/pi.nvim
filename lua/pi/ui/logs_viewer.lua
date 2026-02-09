local state = require("pi.state")
local events = require("pi.events")
local config = require("pi.config")
local colors = require("pi.ui.colors")

local M = {}
M.buf = nil
M.win = nil

local LOGS_NS = vim.api.nvim_create_namespace("pi_logs")
local LOGS_INFO = "PiLogsInfo"
local LOGS_WARN = "PiLogsWarn"
local LOGS_ERROR = "PiLogsError"
local respect_user_highlights = config.get("ui.respect_user_highlights") ~= false
local respect_colorscheme = config.get("ui.respect_colorscheme") ~= false

local LOGS_HL_AUGROUP = vim.api.nvim_create_augroup("PiLogsHighlights", { clear = true })

local function apply_log_highlight(name, def)
  if respect_user_highlights and colors.has_user_colors(name) then
    return
  end
  colors.apply_highlight(name, def)
end

local function setup_log_highlights()
  apply_log_highlight(LOGS_INFO, { fg_link = "DiagnosticInfo" })
  apply_log_highlight(LOGS_WARN, { fg_link = "DiagnosticWarn" })
  apply_log_highlight(LOGS_ERROR, { fg_link = "DiagnosticError" })
end

setup_log_highlights()

if respect_colorscheme then
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = LOGS_HL_AUGROUP,
    callback = function()
      setup_log_highlights()
      if M.is_open() then
        M.render()
      end
    end,
  })
end

-- Open logs viewer
function M.open()
  if M.is_open() then
    return
  end
  
  -- Create buffer
  M.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(M.buf, "buftype", "nofile")
  vim.api.nvim_buf_set_name(M.buf, "Pi Logs")
  
  -- Create split window at bottom
  vim.cmd("botright split")
  M.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(M.win, M.buf)
  vim.api.nvim_win_set_height(M.win, 15)
  
  -- Set window options
  vim.api.nvim_win_set_option(M.win, "wrap", false)
  vim.api.nvim_win_set_option(M.win, "number", false)
  vim.api.nvim_win_set_option(M.win, "relativenumber", false)
  
  -- Render current logs
  M.render()
  
  -- Subscribe to new log entries
  M.unsubscribe = events.on("log_entry", function()
    if M.is_open() then
      M.render()
      -- Auto-scroll to bottom
      vim.api.nvim_win_set_cursor(M.win, { vim.api.nvim_buf_line_count(M.buf), 0 })
    end
  end)
  
  state.update("ui.logs_open", true)
end

-- Close logs viewer
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
  
  state.update("ui.logs_open", false)
end

-- Toggle logs viewer
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

-- Render logs
function M.render()
  if not M.buf or not vim.api.nvim_buf_is_valid(M.buf) then
    return
  end

  local entries = state.get("logs.entries") or {}
  local lines = {}
  local highlights = {}
  local function add_line(text, group)
    table.insert(lines, text)
    if group then
      table.insert(highlights, { line = #lines - 1, group = group })
    end
  end

  for _, entry in ipairs(entries) do
    local timestamp = os.date("%H:%M:%S", entry.timestamp / 1000)
    local level = (entry.level or "INFO"):upper()
    local message = entry.message or ""
    local line_text = string.format("[%s] %s: %s", timestamp, level, message)

    local group = LOGS_INFO
    if level == "WARN" or level == "WARNING" then
      group = LOGS_WARN
    elseif level == "ERROR" or level == "ERR" or level == "FATAL" then
      group = LOGS_ERROR
    end

    add_line(line_text, group)

    if entry.data then
      local json = vim.json.encode(entry.data)
      add_line("  " .. json, group)
    end
  end

  vim.api.nvim_buf_set_option(M.buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(M.buf, "modifiable", false)

  vim.api.nvim_buf_clear_namespace(M.buf, LOGS_NS, 0, -1)
  for _, hl in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(M.buf, LOGS_NS, hl.group, hl.line, 0, -1)
  end
end

return M