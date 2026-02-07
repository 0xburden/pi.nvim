local state = require("pi.state")
local events = require("pi.events")

local M = {}
M.buf = nil
M.win = nil

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
  
  local agent = state.get("agent")
  local sessions = state.get("sessions")
  
  local lines = {
    "╔══════════════════════════════════════════════╗",
    "║              PI CODING AGENT                 ║",
    "╚══════════════════════════════════════════════╝",
    "",
  }
  
  -- Connection status
  local conn_icon = state.get("connected") and "●" or "○"
  local conn_color = state.get("connected") and "DiagnosticOk" or "DiagnosticError"
  table.insert(lines, string.format("Connection: %s", conn_icon))
  
  -- Agent status
  local status_text = "Idle"
  if agent.running then
    status_text = agent.paused and "Paused" or "Running"
  end
  table.insert(lines, string.format("Status: %s", status_text))
  
  -- Current task
  if agent.current_task then
    table.insert(lines, string.format("Task: %s", agent.current_task:sub(1, 40)))
  end
  
  -- Session info
  if sessions.current then
    table.insert(lines, string.format("Session: %s", sessions.current.name or "Unnamed"))
  end
  
  table.insert(lines, "")
  table.insert(lines, "Commands:")
  table.insert(lines, "  :PiStart <task>  - Start agent")
  table.insert(lines, "  :PiPause         - Pause agent")
  table.insert(lines, "  :PiResume        - Resume agent")
  table.insert(lines, "  :PiStop          - Stop agent")
  
  -- Update buffer
  vim.api.nvim_buf_set_option(M.buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(M.buf, "modifiable", false)
end

return M