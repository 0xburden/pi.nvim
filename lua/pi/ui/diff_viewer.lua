local state = require("pi.state")

local M = {}
M.buf_left = nil   -- Before buffer
M.buf_right = nil  -- After buffer
M.win_left = nil
M.win_right = nil

-- Show diff for a file
-- @param filepath string: Path to file
-- @param after_content string|nil: Proposed new content (if nil, reads from pending queue)
function M.show(filepath, after_content)
  -- Close existing diff if open
  if M.is_open() then
    M.close()
  end
  
  -- Get before content (current file state)
  local before_content = vim.fn.readfile(filepath)
  
  -- Get after content from pending queue if not provided
  if not after_content then
    local pending = state.get("files.pending")
    after_content = pending and pending[filepath]
    if not after_content then
      vim.notify("No pending changes for: " .. filepath, vim.log.levels.WARN)
      return
    end
  end
  
  local after_lines = vim.split(after_content, "\n")
  
  -- Create buffers
  M.buf_left = vim.api.nvim_create_buf(false, true)
  M.buf_right = vim.api.nvim_create_buf(false, true)
  
  vim.api.nvim_buf_set_lines(M.buf_left, 0, -1, false, before_content)
  vim.api.nvim_buf_set_lines(M.buf_right, 0, -1, false, after_lines)
  
  vim.api.nvim_buf_set_name(M.buf_left, "Before: " .. filepath)
  vim.api.nvim_buf_set_name(M.buf_right, "After: " .. filepath)
  
  -- Make read-only
  vim.api.nvim_buf_set_option(M.buf_left, "modifiable", false)
  vim.api.nvim_buf_set_option(M.buf_right, "modifiable", false)
  
  -- Create split windows
  vim.cmd("vsplit")
  M.win_left = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(M.win_left, M.buf_left)
  
  vim.cmd("wincmd l")
  M.win_right = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(M.win_right, M.buf_right)
  
  -- Enable diff mode
  vim.cmd("windo diffthis")
  
  -- Set syntax highlighting
  local ft = vim.filetype.match({ filename = filepath })
  if ft then
    vim.api.nvim_buf_set_option(M.buf_left, "filetype", ft)
    vim.api.nvim_buf_set_option(M.buf_right, "filetype", ft)
  end
end

-- Close diff viewer
function M.close()
  if M.win_left and vim.api.nvim_win_is_valid(M.win_left) then
    vim.api.nvim_win_close(M.win_left, true)
  end
  if M.win_right and vim.api.nvim_win_is_valid(M.win_right) then
    vim.api.nvim_win_close(M.win_right, true)
  end
  
  if M.buf_left and vim.api.nvim_buf_is_valid(M.buf_left) then
    vim.api.nvim_buf_delete(M.buf_left, { force = true })
  end
  if M.buf_right and vim.api.nvim_buf_is_valid(M.buf_right) then
    vim.api.nvim_buf_delete(M.buf_right, { force = true })
  end
  
  M.win_left = nil
  M.win_right = nil
  M.buf_left = nil
  M.buf_right = nil
end

-- Check if open
function M.is_open()
  return M.win_left and vim.api.nvim_win_is_valid(M.win_left)
end

return M