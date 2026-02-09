local M = {}

-- Default configuration
local defaults = {
  -- Connection
  auto_connect = false,

  -- UI
  auto_open_panel = true,
  auto_open_logs = false,
  panel_position = "top-right",  -- top-right, top-left, bottom-right, bottom-left

  -- Features
  auto_stream_logs = true,
  approval_mode = true,  -- Require approval before applying changes
  watch_files = true,

  -- Display
  max_log_entries = 1000,
  log_format = "timestamp",  -- timestamp, simple

  -- UI
  ui = {
    code_block_bg = "auto",        -- "auto", "none", "#RRGGBB", or numeric hex
    syntax_highlighting = true,      -- Custom renderer only
    inline_code_highlighting = true, -- Custom renderer only
    use_render_markdown = true,      -- Use render-markdown.nvim when available

    autocomplete_enabled = true,
    autocomplete_fuzzy = true,
    autocomplete_max_items = 10,

    respect_colorscheme = true,
    respect_user_highlights = true,
    custom_highlights = {},
  },

  -- Keymaps
  keymaps = {
    toggle_panel = "<leader>pt",
    toggle_logs = "<leader>pl",
    approve = "<leader>pa",
    reject = "<leader>pr",
  }
}

M.config = vim.deepcopy(defaults)

-- Setup configuration
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts)

  -- Setup keymaps if enabled
  if M.config.keymaps then
    M.setup_keymaps()
  end
end

-- Setup keymaps
function M.setup_keymaps()
  local maps = M.config.keymaps

  if maps.toggle_panel then
    vim.keymap.set("n", maps.toggle_panel, "<cmd>PiToggle<cr>", { desc = "Toggle Pi panel" })
  end

  if maps.toggle_logs then
    vim.keymap.set("n", maps.toggle_logs, "<cmd>PiLogs<cr>", { desc = "Toggle Pi logs" })
  end

  if maps.approve then
    vim.keymap.set("n", maps.approve, "<cmd>PiApprove<cr>", { desc = "Approve change" })
  end

  if maps.reject then
    vim.keymap.set("n", maps.reject, "<cmd>PiReject<cr>", { desc = "Reject change" })
  end
end

-- Get config value
function M.get(key)
  local keys = vim.split(key, ".", { plain = true })
  local value = M.config

  for _, k in ipairs(keys) do
    value = value[k]
    if value == nil then return nil end
  end

  return value
end

return M