local state = require("pi.state")
local events = require("pi.events")
local config = require("pi.config")
local colors = require("pi.ui.colors")

local M = {}
M.buf = nil
M.win = nil

local TREE_NS = vim.api.nvim_create_namespace("pi_file_tree")
local TREE_TITLE = "PiFileTreeTitle"
local TREE_PENDING = "PiFileTreePending"
local TREE_MODIFIED = "PiFileTreeModified"
local respect_user_highlights = config.get("ui.respect_user_highlights") ~= false
local respect_colorscheme = config.get("ui.respect_colorscheme") ~= false

local TREE_HL_AUGROUP = vim.api.nvim_create_augroup("PiFileTreeHighlights", { clear = true })

local function apply_tree_highlight(name, def)
  if respect_user_highlights and colors.has_user_colors(name) then
    return
  end
  colors.apply_highlight(name, def)
end

local function setup_tree_highlights()
  apply_tree_highlight(TREE_TITLE, { fg_link = "Title", bold = true })
  apply_tree_highlight(TREE_PENDING, { fg_link = "DiagnosticWarn" })
  apply_tree_highlight(TREE_MODIFIED, { fg_link = "DiagnosticOk" })
end

setup_tree_highlights()

if respect_colorscheme then
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = TREE_HL_AUGROUP,
    callback = function()
      setup_tree_highlights()
      if M.is_open() then
        M.render()
      end
    end,
  })
end

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

  local pending = state.get("files.pending") or {}
  local modified = state.get("files.modified") or {}

  local lines = {}
  local highlights = {}
  local function add_line(text, group)
    table.insert(lines, text)
    if group then
      table.insert(highlights, { line = #lines - 1, group = group })
    end
  end

  add_line("╔══════════════════════════════════════╗", TREE_TITLE)
  add_line("║          FILES IN PROGRESS           ║", TREE_TITLE)
  add_line("╚══════════════════════════════════════╝", TREE_TITLE)
  add_line("", nil)

  if vim.tbl_count(pending) > 0 then
    add_line("Pending Approval:", TREE_PENDING)
    for filepath in pairs(pending) do
      add_line("  ⏳ " .. vim.fn.fnamemodify(filepath, ":~:.") , TREE_PENDING)
    end
    add_line("", nil)
  end

  if #modified > 0 then
    add_line("Modified:", TREE_MODIFIED)
    for _, filepath in ipairs(modified) do
      add_line("  ✓ " .. vim.fn.fnamemodify(filepath, ":~:.") , TREE_MODIFIED)
    end
  end

  vim.api.nvim_buf_set_option(M.buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(M.buf, "modifiable", false)

  vim.api.nvim_buf_clear_namespace(M.buf, TREE_NS, 0, -1)
  for _, hl in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(M.buf, TREE_NS, hl.group, hl.line, 0, -1)
  end
end

return M