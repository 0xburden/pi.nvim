local state = require("pi.state")
local events = require("pi.events")

local M = {}
M.buf = nil
M.win = nil

-- Open file tree
function M.open()
  if M.is_open() then
    return
  end
  
  M.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(M.buf, "buftype", "nofile")
  vim.api.nvim_buf_set_name(M.buf, "Pi Files")
  
  -- Create left sidebar
  vim.cmd("topleft vsplit")
  M.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(M.win, M.buf)
  vim.api.nvim_win_set_width(M.win, 40)
  
  -- Make read-only
  vim.api.nvim_buf_set_option(M.buf, "modifiable", false)
  
  -- Render
  M.render()
  
  -- Subscribe to state changes
  M.unsubscribe = events.on("state_updated", function(path)
    if path:match("^files%.") and M.is_open() then
      M.render()
    end
  end)
end

-- Close file tree
function M.close()
  if M.unsubscribe then
    M.unsubscribe()
  end
  
  if M.win and vim.api.nvim_win_is_valid(M.win) then
    vim.api.nvim_win_close(M.win, true)
  end
  
  M.win = nil
  M.buf = nil
end

-- Toggle file tree
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

-- Render file tree
function M.render()
  if not M.buf or not vim.api.nvim_buf_is_valid(M.buf) then
    return
  end
  
  local lines = {
    "╔══════════════════════════════════════╗",
    "║          FILES IN PROGRESS           ║",
    "╚══════════════════════════════════════╝",
    "",
  }
  
  -- Pending files
  local pending = state.get("files.pending")
  if vim.tbl_count(pending) > 0 then
    table.insert(lines, "Pending Approval:")
    for filepath, _ in pairs(pending) do
      table.insert(lines, "  ⏳ " .. vim.fn.fnamemodify(filepath, ":~:."))
    end
    table.insert(lines, "")
  end
  
  -- Modified files
  local modified = state.get("files.modified")
  if #modified > 0 then
    table.insert(lines, "Modified:")
    for _, filepath in ipairs(modified) do
      table.insert(lines, "  ✓ " .. vim.fn.fnamemodify(filepath, ":~:."))
    end
  end
  
  vim.api.nvim_buf_set_option(M.buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(M.buf, "modifiable", false)
end

return M