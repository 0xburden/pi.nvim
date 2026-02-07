local state = require("pi.state")
local events = require("pi.events")

local M = {}
M.buf = nil
M.win = nil

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
  
  local entries = state.get("logs.entries")
  local lines = {}
  
  for _, entry in ipairs(entries) do
    local timestamp = os.date("%H:%M:%S", entry.timestamp / 1000)
    local level = entry.level or "INFO"
    local message = entry.message or ""
    
    local line = string.format("[%s] %s: %s", timestamp, level, message)
    table.insert(lines, line)
    
    -- If there's structured data, show it
    if entry.data then
      local json = vim.json.encode(entry.data)
      table.insert(lines, "  " .. json)
    end
  end
  
  vim.api.nvim_buf_set_option(M.buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(M.buf, "modifiable", false)
end

return M