--- Model Picker UI
-- A floating picker for selecting models, designed to be used inline
-- from the chat input.  Shows models grouped by provider with the
-- current model highlighted, fuzzy filtering, and keyboard navigation.

local M = {}

local state = require("pi.state")
local config = require("pi.config")
local model_rpc = require("pi.rpc.model")
local colors = require("pi.ui.colors")

-- UI state
local picker = {
  buf = nil,
  win = nil,
  input_buf = nil,
  input_win = nil,
  models = {},       -- all entries after fetch
  filtered = {},     -- entries after filter applied
  selected = 1,      -- 1-indexed into filtered
  filter_text = "",
  current_model_id = nil,
  on_done = nil,     -- callback after close
  augroup = nil,
}

local NS = vim.api.nvim_create_namespace("pi_model_picker")

-- ── Highlights ──────────────────────────────────────────────────────

local function setup_highlights()
  colors.apply_highlight("PiPickerSelected", { link = "PmenuSel" })
  colors.apply_highlight("PiPickerNormal", { link = "NormalFloat" })
  colors.apply_highlight("PiPickerBorder", { link = "FloatBorder" })
  colors.apply_highlight("PiPickerCurrent", { fg_link = "DiagnosticOk", bold = true })
  colors.apply_highlight("PiPickerProvider", { fg_link = "Comment", italic = true })
  colors.apply_highlight("PiPickerReasoning", { fg_link = "DiagnosticInfo" })
  colors.apply_highlight("PiPickerPrompt", { fg_link = "Question" })
  colors.apply_highlight("PiPickerNoResults", { fg_link = "Comment", italic = true })
end

-- ── Model entry helpers ─────────────────────────────────────────────

local function entry_id(entry)
  return entry.modelId or entry.name or ""
end

local function is_current(entry, current_id)
  if not current_id then return false end
  return entry_id(entry) == current_id
    or (entry.name and entry.name == current_id)
end

local function format_line(entry, current_id, width)
  local indicator = is_current(entry, current_id) and "● " or "  "
  local name = entry.name or entry.modelId or "unknown"
  local provider = entry.provider or ""
  local suffix = entry.reasoning and " 🧠" or ""
  local left = indicator .. name .. suffix
  local right = provider
  local pad = math.max(1, width - #left - #right - 2)
  return left .. string.rep(" ", pad) .. right
end

-- ── Sorting & filtering ─────────────────────────────────────────────

local function sort_models(models)
  table.sort(models, function(a, b)
    if a.provider ~= b.provider then
      return (a.provider or "") < (b.provider or "")
    end
    return (a.name or a.modelId or "") < (b.name or b.modelId or "")
  end)
end

local function fuzzy_match(pattern, text)
  if not pattern or pattern == "" then return true, 0 end
  local lp = pattern:lower()
  local lt = text:lower()
  local pi, score, consecutive = 1, 0, 0
  for ti = 1, #lt do
    if pi <= #lp and lp:sub(pi, pi) == lt:sub(ti, ti) then
      consecutive = consecutive + 1
      score = score + 1 + consecutive
      if pi == 1 and ti == 1 then score = score + 10 end
      pi = pi + 1
    else
      consecutive = 0
    end
  end
  if pi <= #lp then return false, 0 end
  return true, score - math.abs(#text - #pattern)
end

local function apply_filter()
  local text = picker.filter_text or ""
  if text == "" then
    picker.filtered = vim.deepcopy(picker.models)
  else
    local scored = {}
    for _, entry in ipairs(picker.models) do
      local haystack = (entry.name or "") .. " " .. (entry.provider or "") .. " " .. (entry.modelId or "")
      local ok, score = fuzzy_match(text, haystack)
      if ok then
        table.insert(scored, { entry = entry, score = score })
      end
    end
    table.sort(scored, function(a, b) return a.score > b.score end)
    picker.filtered = {}
    for _, s in ipairs(scored) do
      table.insert(picker.filtered, s.entry)
    end
  end
  picker.selected = math.max(1, math.min(picker.selected, #picker.filtered))
end

-- ── Rendering ───────────────────────────────────────────────────────

local function render_list()
  if not picker.buf or not vim.api.nvim_buf_is_valid(picker.buf) then return end

  local width = 60
  if picker.win and vim.api.nvim_win_is_valid(picker.win) then
    width = vim.api.nvim_win_get_width(picker.win)
  end

  local lines = {}
  local highlights = {}

  if #picker.filtered == 0 then
    table.insert(lines, "  No matching models")
    table.insert(highlights, { line = 0, group = "PiPickerNoResults", col_start = 0, col_end = -1 })
  else
    for i, entry in ipairs(picker.filtered) do
      local line = format_line(entry, picker.current_model_id, width)
      table.insert(lines, line)

      local line_idx = i - 1
      if i == picker.selected then
        table.insert(highlights, { line = line_idx, group = "PiPickerSelected", col_start = 0, col_end = -1 })
      elseif is_current(entry, picker.current_model_id) then
        table.insert(highlights, { line = line_idx, group = "PiPickerCurrent", col_start = 0, col_end = -1 })
      end
    end
  end

  vim.api.nvim_buf_set_option(picker.buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(picker.buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(picker.buf, "modifiable", false)

  vim.api.nvim_buf_clear_namespace(picker.buf, NS, 0, -1)
  for _, hl in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(picker.buf, NS, hl.group, hl.line, hl.col_start, hl.col_end)
  end

  -- Keep cursor on selected line
  if picker.win and vim.api.nvim_win_is_valid(picker.win) then
    local lc = vim.api.nvim_buf_line_count(picker.buf)
    if lc > 0 then
      local row = math.max(1, math.min(picker.selected, lc))
      pcall(vim.api.nvim_win_set_cursor, picker.win, { row, 0 })
    end
  end
end

local function render_input()
  if not picker.input_buf or not vim.api.nvim_buf_is_valid(picker.input_buf) then return end
  -- The input buffer is editable, managed by the user.  We just add a
  -- virtual text prompt indicator.
  vim.api.nvim_buf_clear_namespace(picker.input_buf, NS, 0, -1)
  vim.api.nvim_buf_set_extmark(picker.input_buf, NS, 0, 0, {
    virt_text = { { "🔍 ", "PiPickerPrompt" } },
    virt_text_pos = "inline",
  })
end

-- ── Window management ───────────────────────────────────────────────

local function calc_dimensions(anchor_win)
  local max_width = 70
  local max_height = 20
  local input_height = 1

  local screen_rows = vim.o.lines
  local screen_cols = vim.o.columns

  local width = math.min(max_width, screen_cols - 4)
  width = math.max(40, width)

  local list_height = math.min(max_height, math.max(3, #picker.filtered))

  -- Position above the anchor window (chat input) if possible
  local row, col
  if anchor_win and vim.api.nvim_win_is_valid(anchor_win) then
    local win_pos = vim.api.nvim_win_get_position(anchor_win)
    local win_width = vim.api.nvim_win_get_width(anchor_win)
    -- Place to the left edge of the anchor, above it
    col = win_pos[2]
    width = math.min(width, win_width)
    -- Total height = border(1) + input(1) + border(1) + list + border(1)
    local total = list_height + input_height + 4
    row = win_pos[1] - total
    if row < 0 then
      -- Not enough room above, place below
      row = win_pos[1] + vim.api.nvim_win_get_height(anchor_win) + 1
    end
  else
    -- Centered fallback
    local total_h = list_height + input_height + 4
    row = math.max(0, math.floor((screen_rows - total_h) / 2))
    col = math.max(0, math.floor((screen_cols - width) / 2))
  end

  return {
    row = math.max(0, row),
    col = math.max(0, col),
    width = width,
    list_height = list_height,
    input_height = input_height,
  }
end

local function open_windows(anchor_win)
  local dim = calc_dimensions(anchor_win)

  -- List buffer
  picker.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(picker.buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(picker.buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(picker.buf, "swapfile", false)
  vim.api.nvim_buf_set_option(picker.buf, "modifiable", false)

  picker.win = vim.api.nvim_open_win(picker.buf, false, {
    relative = "editor",
    row = dim.row,
    col = dim.col,
    width = dim.width,
    height = dim.list_height,
    style = "minimal",
    border = { "╭", "─", "╮", "│", "┤", "─", "├", "│" },
    title = " Select Model ",
    title_pos = "center",
    focusable = false,
    zindex = 250,
  })
  vim.api.nvim_win_set_option(picker.win, "cursorline", false)
  vim.api.nvim_win_set_option(picker.win, "wrap", false)
  vim.api.nvim_win_set_option(picker.win, "winhighlight", "Normal:PiPickerNormal,FloatBorder:PiPickerBorder")

  -- Input buffer (below the list)
  picker.input_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(picker.input_buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(picker.input_buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(picker.input_buf, "swapfile", false)
  vim.api.nvim_buf_set_lines(picker.input_buf, 0, -1, false, { "" })

  local input_row = dim.row + dim.list_height + 2 -- +2 for top/bottom border
  picker.input_win = vim.api.nvim_open_win(picker.input_buf, true, {
    relative = "editor",
    row = input_row,
    col = dim.col,
    width = dim.width,
    height = dim.input_height,
    style = "minimal",
    border = { "├", "─", "┤", "│", "╯", "─", "╰", "│" },
    title = " Filter (type to search) ",
    title_pos = "center",
    focusable = true,
    zindex = 251,
  })
  vim.api.nvim_win_set_option(picker.input_win, "winhighlight", "Normal:PiPickerNormal,FloatBorder:PiPickerBorder")
end

-- ── Keymaps & autocmds ──────────────────────────────────────────────

local function select_model()
  if #picker.filtered == 0 then return end
  local entry = picker.filtered[picker.selected]
  if not entry then return end

  local client = state.get("rpc_client")
  if not client or not client.connected then
    vim.notify("Pi: Not connected to agent", vim.log.levels.ERROR)
    M.close()
    return
  end

  M.close()

  model_rpc.set(client, entry.provider, entry.modelId, function(result)
    vim.schedule(function()
      if result and result.success then
        local display = model_rpc.format(result.data or entry.raw or entry)
        vim.notify("Pi: Model set to " .. display, vim.log.levels.INFO)

        local ok, chat = pcall(require, "pi.ui.chat")
        if ok and chat then
          chat.session_info.model = entry.name or entry.modelId
          if chat.is_open() then
            chat.render()
          end
        end
      else
        vim.notify("Pi: Failed to set model - " .. (result and result.error or "unknown"), vim.log.levels.ERROR)
      end
    end)
  end)
end

local function move_selection(delta)
  if #picker.filtered == 0 then return end
  picker.selected = picker.selected + delta
  if picker.selected < 1 then picker.selected = #picker.filtered end
  if picker.selected > #picker.filtered then picker.selected = 1 end
  render_list()
end

local function setup_keymaps()
  local ib = picker.input_buf
  if not ib then return end

  local opts = { buffer = ib, silent = true, nowait = true }

  -- Navigation
  vim.keymap.set("i", "<C-n>", function() move_selection(1) end, opts)
  vim.keymap.set("i", "<C-p>", function() move_selection(-1) end, opts)
  vim.keymap.set("i", "<Down>", function() move_selection(1) end, opts)
  vim.keymap.set("i", "<Up>", function() move_selection(-1) end, opts)
  vim.keymap.set("n", "j", function() move_selection(1) end, opts)
  vim.keymap.set("n", "k", function() move_selection(-1) end, opts)
  vim.keymap.set("n", "<Down>", function() move_selection(1) end, opts)
  vim.keymap.set("n", "<Up>", function() move_selection(-1) end, opts)

  -- Confirm
  vim.keymap.set("i", "<CR>", select_model, opts)
  vim.keymap.set("n", "<CR>", select_model, opts)

  -- Close
  vim.keymap.set("i", "<Esc>", function() M.close() end, opts)
  vim.keymap.set("n", "<Esc>", function() M.close() end, opts)
  vim.keymap.set("n", "q", function() M.close() end, opts)
  vim.keymap.set("i", "<C-c>", function() M.close() end, opts)

  -- Scrolling the list
  vim.keymap.set("i", "<C-d>", function() move_selection(5) end, opts)
  vim.keymap.set("i", "<C-u>", function() move_selection(-5) end, opts)
end

local function setup_autocmds()
  picker.augroup = vim.api.nvim_create_augroup("PiModelPicker", { clear = true })

  -- Live filter on text change
  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
    group = picker.augroup,
    buffer = picker.input_buf,
    callback = function()
      local lines = vim.api.nvim_buf_get_lines(picker.input_buf, 0, 1, false)
      picker.filter_text = lines[1] or ""
      apply_filter()
      -- Resize list window if needed
      if picker.win and vim.api.nvim_win_is_valid(picker.win) then
        local new_h = math.max(1, math.min(20, #picker.filtered))
        if new_h == 0 then new_h = 1 end
        vim.api.nvim_win_set_height(picker.win, new_h)
      end
      render_list()
    end,
  })

  -- Close on BufLeave (user clicks elsewhere)
  vim.api.nvim_create_autocmd("BufLeave", {
    group = picker.augroup,
    buffer = picker.input_buf,
    callback = function()
      -- Defer so that entering the list buffer doesn't immediately close
      vim.defer_fn(function()
        if M.is_open() then
          local cur_buf = vim.api.nvim_get_current_buf()
          if cur_buf ~= picker.input_buf and cur_buf ~= picker.buf then
            M.close()
          end
        end
      end, 50)
    end,
  })
end

-- ── Public API ──────────────────────────────────────────────────────

--- Check if the picker is currently open
function M.is_open()
  return picker.win ~= nil and vim.api.nvim_win_is_valid(picker.win)
end

--- Close the picker and clean up
function M.close()
  if picker.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, picker.augroup)
    picker.augroup = nil
  end

  if picker.input_win and vim.api.nvim_win_is_valid(picker.input_win) then
    vim.api.nvim_win_close(picker.input_win, true)
  end
  if picker.win and vim.api.nvim_win_is_valid(picker.win) then
    vim.api.nvim_win_close(picker.win, true)
  end

  -- Buffers are set to bufhidden=wipe, closing the window wipes them.
  picker.buf = nil
  picker.win = nil
  picker.input_buf = nil
  picker.input_win = nil
  picker.models = {}
  picker.filtered = {}
  picker.selected = 1
  picker.filter_text = ""
  picker.current_model_id = nil

  -- Return focus to chat input if it's still open
  local ok, chat = pcall(require, "pi.ui.chat")
  if ok and chat.is_open() and chat.input_win and vim.api.nvim_win_is_valid(chat.input_win) then
    vim.api.nvim_set_current_win(chat.input_win)
    vim.cmd("startinsert!")
  end
end

--- Open the model picker
---@param opts table|nil { filter: string|nil, anchor_win: number|nil, on_select: fun(entry)|nil }
function M.open(opts)
  if M.is_open() then M.close() end
  opts = opts or {}

  setup_highlights()

  local client = state.get("rpc_client")
  if not client or not client.connected then
    vim.notify("Pi: Not connected to agent", vim.log.levels.ERROR)
    return
  end

  -- Resolve current model id for the indicator
  local current = model_rpc.get_current()
  picker.current_model_id = current and (current.id or current.name or current.modelId) or nil

  -- Show a temporary "loading" state
  picker.models = {}
  picker.filtered = {}
  picker.filter_text = opts.filter or ""
  picker.selected = 1

  -- Fetch models
  model_rpc.get_available(client, function(result)
    vim.schedule(function()
      if not result or not result.success then
        vim.notify("Pi: Failed to fetch models - " .. (result and result.error or "unknown"), vim.log.levels.ERROR)
        return
      end

      local raw = result.data and result.data.models or {}
      if #raw == 0 then
        vim.notify("Pi: No models available", vim.log.levels.WARN)
        return
      end

      local entries = {}
      for _, m in ipairs(raw) do
        table.insert(entries, {
          provider = m.provider or "unknown",
          modelId = m.id or m.modelId or m.name or "unknown",
          name = m.name or m.id or m.modelId,
          reasoning = m.reasoning == true,
          raw = m,
        })
      end
      sort_models(entries)

      picker.models = entries
      apply_filter()

      -- Pre-select current model if no filter text
      if picker.filter_text == "" and picker.current_model_id then
        for i, entry in ipairs(picker.filtered) do
          if is_current(entry, picker.current_model_id) then
            picker.selected = i
            break
          end
        end
      end

      -- Open the windows
      open_windows(opts.anchor_win)
      render_list()
      render_input()
      setup_keymaps()
      setup_autocmds()

      -- Seed filter text if provided
      if picker.filter_text ~= "" and picker.input_buf and vim.api.nvim_buf_is_valid(picker.input_buf) then
        vim.api.nvim_buf_set_lines(picker.input_buf, 0, -1, false, { picker.filter_text })
        -- Place cursor at end
        local len = #picker.filter_text
        pcall(vim.api.nvim_win_set_cursor, picker.input_win, { 1, len })
      end

      vim.cmd("startinsert!")
    end)
  end)
end

return M
