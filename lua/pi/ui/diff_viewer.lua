local state = require("pi.state")

local M = {}
M.buf_left = nil   -- Before buffer
M.buf_right = nil  -- After buffer
M.win_left = nil
M.win_right = nil

-- Show diff for a file
function M.show(filepath)
  -- Close existing diff if open
  if M.is_open() then
    M.close()
  end
  
  -- Get file content (before and after)
  local before_content = vim.fn.readfile(filepath)
  
  local client = state.get("rpc_client")
  local files_rpc = require("pi.rpc.files")
  
  files_rpc.read(client, filepath, function(result)
    if result.error then
      vim.notify("Failed to read file: " .. result.error, vim.log.levels.ERROR)
      return
    end
    
    local after_content = vim.split(result.content, "\n")
    
    -- Create buffers
    M.buf_left = vim.api.nvim_create_buf(false, true)
    M.buf_right = vim.api.nvim_create_buf(false, true)
    
    vim.api.nvim_buf_set_lines(M.buf_left, 0, -1, false, before_content)
    vim.api.nvim_buf_set_lines(M.buf_right, 0, -1, false, after_content)
    
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
  end)
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