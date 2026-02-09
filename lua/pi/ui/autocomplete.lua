local M = {}

local config = require("pi.config")
local commands = require("pi.rpc.commands")

local namespace = vim.api.nvim_create_namespace("pi_autocomplete")
local hint_ns = vim.api.nvim_create_namespace("pi_autocomplete_hint")

local win = nil
local buf = nil
local items = {}
local selected_index = 1
local filter_text = ""

local hint_buf = nil
local hint_win = nil
local hint_timer = nil
local hint_on_close = nil

local function get_max_items()
  local max_items = config.get("ui.autocomplete_max_items")
  if not max_items or max_items < 1 then
    max_items = 10
  end
  return max_items
end

local function reset_state()
  items = {}
  selected_index = 1
  filter_text = ""
end

local function render_lines()
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local lines = {}
  local highlights = {}

  if #items == 0 then
    table.insert(lines, "  No commands found")
    table.insert(highlights, { line = 0, group = "Comment" })
  else
    for idx, item in ipairs(items) do
      local display = "  " .. (item.name or "")
      if item.description and item.description ~= "" then
        display = display .. " - " .. item.description
      end
      if item.source and item.source ~= "" then
        display = display .. " [" .. item.source .. "]"
      end
      table.insert(lines, display)
      local group = (idx == selected_index) and "PmenuSel" or "Pmenu"
      table.insert(highlights, { line = idx - 1, group = group })
    end
  end

  vim.api.nvim_buf_set_option(buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, "modifiable", false)

  vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
  for _, hl in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(buf, namespace, hl.group, hl.line, 0, -1)
  end

  if win and vim.api.nvim_win_is_valid(win) then
    local height = math.min(get_max_items(), math.max(1, #lines))
    vim.api.nvim_win_set_height(win, height)
    local cursor_line = math.max(1, math.min(#lines, selected_index))
    vim.api.nvim_win_set_cursor(win, { cursor_line, 0 })
  end
end

local function ensure_buffer()
  if buf and vim.api.nvim_buf_is_valid(buf) then
    return buf
  end
  buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(buf, "swapfile", false)
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
  vim.api.nvim_buf_set_option(buf, "filetype", "pi-autocomplete")
  return buf
end

local function ensure_hint_buf()
  if hint_buf and vim.api.nvim_buf_is_valid(hint_buf) then
    return hint_buf
  end
  hint_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(hint_buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(hint_buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(hint_buf, "swapfile", false)
  vim.api.nvim_buf_set_option(hint_buf, "modifiable", false)
  vim.api.nvim_buf_set_option(hint_buf, "filetype", "pi-autocomplete-hint")
  return hint_buf
end

local function create_window(anchor_win, cursor_row, cursor_col, width)
  if not anchor_win or not vim.api.nvim_win_is_valid(anchor_win) then
    return nil
  end

  local rows = vim.o.lines
  local cols = vim.o.columns
  local win_pos = vim.api.nvim_win_get_position(anchor_win)
  local screen_row = win_pos[1] + cursor_row
  local screen_col = win_pos[2] + cursor_col
  local height = math.min(get_max_items(), math.max(1, math.max(#items, 1)))

  if screen_row + height + 1 > rows then
    screen_row = math.max(0, win_pos[1] + cursor_row - height - 1)
  end
  if screen_col + width > cols then
    screen_col = math.max(0, cols - width - 1)
  end

  return vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    row = screen_row,
    col = screen_col,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    focusable = false,
    zindex = 200,
  })
end

local function close_hint_timer()
  if hint_timer then
    pcall(vim.fn.timer_stop, hint_timer)
    hint_timer = nil
  end
end

function M.close_hint()
  close_hint_timer()
  if hint_win and vim.api.nvim_win_is_valid(hint_win) then
    vim.api.nvim_win_close(hint_win, true)
    hint_win = nil
  end
  if hint_buf and vim.api.nvim_buf_is_valid(hint_buf) then
    vim.api.nvim_buf_delete(hint_buf, { force = true })
    hint_buf = nil
  end
  if hint_on_close then
    local cb = hint_on_close
    hint_on_close = nil
    cb()
  end
end

local function build_hint_lines(cmd)
  if not cmd then
    return {}
  end

  local name = cmd.name or ""
  if vim.startswith(name, "/") then
    name = name:sub(2)
  end

  local signature = "/" .. name
  local arg_sources = {}
  if type(cmd.arguments) == "table" then
    for _, arg in ipairs(cmd.arguments) do
      if type(arg) == "table" and arg.name then
        table.insert(arg_sources, "[" .. arg.name .. "]")
      elseif type(arg) == "string" then
        table.insert(arg_sources, arg)
      end
    end
  end
  if #arg_sources == 0 and type(cmd.params) == "table" then
    for _, arg in ipairs(cmd.params) do
      if type(arg) == "string" then
        table.insert(arg_sources, arg)
      end
    end
  end
  if #arg_sources == 0 and type(cmd.parameters) == "table" then
    for _, arg in ipairs(cmd.parameters) do
      table.insert(arg_sources, tostring(arg))
    end
  end
  if #arg_sources == 0 and type(cmd.signature) == "string" and cmd.signature ~= "" then
    table.insert(arg_sources, cmd.signature)
  elseif #arg_sources == 0 and type(cmd.usage) == "string" and cmd.usage ~= "" then
    table.insert(arg_sources, cmd.usage)
  elseif #arg_sources == 0 and type(cmd.syntax) == "string" and cmd.syntax ~= "" then
    table.insert(arg_sources, cmd.syntax)
  end

  if #arg_sources > 0 then
    signature = signature .. " " .. table.concat(arg_sources, " ")
  end

  local lines = {}
  table.insert(lines, signature)

  if cmd.description and cmd.description ~= "" then
    table.insert(lines, "")
    table.insert(lines, cmd.description)
  end
  if cmd.source and cmd.source ~= "" then
    table.insert(lines, "")
    table.insert(lines, "Source: " .. cmd.source)
  end
  if cmd.location and cmd.location ~= "" then
    table.insert(lines, "Location: " .. cmd.location)
  end

  return lines
end

local function calculate_hint_size(lines)
  local max_width = 0
  for _, line in ipairs(lines) do
    max_width = math.max(max_width, #line)
  end
  local width = math.min(vim.o.columns - 4, math.max(20, max_width + 4))
  local height = math.min(#lines, vim.o.lines - 4)
  if height < 1 then height = 1 end
  return width, height
end

local function open_hint_window(anchor_win, cursor_row, cursor_col, width, height)
  if not anchor_win or not vim.api.nvim_win_is_valid(anchor_win) then
    return nil
  end
  local win_pos = vim.api.nvim_win_get_position(anchor_win)
  local row = win_pos[1] + cursor_row
  local col = win_pos[2] + cursor_col
  if row + height + 1 > vim.o.lines then
    row = math.max(0, win_pos[1] + cursor_row - height - 1)
  end
  if col + width > vim.o.columns then
    col = math.max(0, vim.o.columns - width - 1)
  end
  return vim.api.nvim_open_win(hint_buf, false, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    focusable = false,
    zindex = 210,
  })
end

local function schedule_hint_close(duration)
  close_hint_timer()
  hint_timer = vim.fn.timer_start(duration or 4000, function()
    vim.schedule(function()
      M.close_hint()
    end)
  end)
end

function M.show_parameter_hint(item, anchor_win, cursor_row, cursor_col, opts)
  opts = opts or {}
  if not item or not anchor_win or not vim.api.nvim_win_is_valid(anchor_win) then
    return
  end

  local raw_name = item.name or ""
  if vim.startswith(raw_name, "/") then
    raw_name = raw_name:sub(2)
  end
  local cmd = commands.find(raw_name) or { name = raw_name, description = item.description, source = item.source, location = item.location }
  local lines = build_hint_lines(cmd)
  if #lines == 0 then
    return
  end

  M.close_hint()
  local buffer = ensure_hint_buf()
  vim.api.nvim_buf_set_option(buffer, "modifiable", true)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buffer, "modifiable", false)

  local width, height = calculate_hint_size(lines)
  hint_win = open_hint_window(anchor_win, cursor_row, cursor_col, width, height)
  if hint_win and vim.api.nvim_win_is_valid(hint_win) then
    vim.api.nvim_buf_add_highlight(buffer, hint_ns, "PmenuSel", 0, 0, -1)
    vim.api.nvim_buf_set_option(buffer, "wrap", true)
    vim.api.nvim_win_set_option(hint_win, "winblend", 0)
    vim.api.nvim_win_set_option(hint_win, "cursorline", false)
  end

  hint_on_close = opts.on_close
  schedule_hint_close(opts.duration)
end

function M.open(anchor_win, cursor_row, cursor_col, max_width)
  if M.is_open() or not anchor_win then
    return
  end

  ensure_buffer()

  max_width = max_width or 60
  max_width = math.min(max_width, vim.o.columns - 4)
  max_width = math.max(20, max_width)

  win = create_window(anchor_win, cursor_row, cursor_col, max_width)
  if not win then
    return
  end

  vim.api.nvim_win_set_option(win, "wrap", false)
  vim.api.nvim_win_set_option(win, "cursorline", true)
  vim.api.nvim_win_set_option(win, "winblend", 0)
  vim.api.nvim_win_set_option(win, "signcolumn", "no")

  render_lines()
end

function M.close(opts)
  opts = opts or {}
  if not opts.keep_hint then
    M.close_hint()
  end
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_delete(buf, { force = true })
  end
  win = nil
  buf = nil
  reset_state()
end

function M.is_open()
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

function M.set_items(new_items)
  local max_items = get_max_items()
  items = {}
  for i = 1, math.min(max_items, #new_items) do
    items[i] = new_items[i]
  end
  if selected_index > #items then
    selected_index = #items
  end
  if selected_index < 1 then
    selected_index = 1
  end
end

local function build_filtered_items(entries)
  local filtered = {}
  for _, entry in ipairs(entries) do
    table.insert(filtered, entry)
  end
  return filtered
end

function M.filter(text)
  filter_text = text or ""
  local fuzzy = config.get("ui.autocomplete_fuzzy") ~= false
  local lower_text = filter_text:lower()
  local all_items = commands.get_completion_items()
  local scored = {}

  for _, item in ipairs(all_items) do
    local name = (item.name or ""):sub(2)
    local matched = false
    local score = 0

    if lower_text == "" then
      matched = true
    else
      if fuzzy then
        local ok, fuzzy_score = M.fuzzy_match(lower_text, name:lower())
        matched = ok
        score = fuzzy_score or 0
      else
        local prefix_match = name:lower():find(lower_text, 1, true)
        if prefix_match == 1 then
          matched = true
          score = 100 - #name
        end
      end
      if not matched and item.description then
        if item.description:lower():find(lower_text, 1, true) then
          matched = true
          score = -1
        end
      end
    end

    if matched then
      table.insert(scored, { item = item, score = score })
    end
  end

  table.sort(scored, function(a, b)
    return (a.score or 0) > (b.score or 0)
  end)

  local sorted = {}
  for _, entry in ipairs(scored) do
    table.insert(sorted, entry.item)
  end

  M.set_items(sorted)
  render_lines()
end

function M.fuzzy_match(pattern, text)
  if not pattern or pattern == "" then
    return true, 0
  end
  local pat_idx = 1
  local text_idx = 1
  local score = 0
  local consecutive = 0

  while pat_idx <= #pattern and text_idx <= #text do
    if pattern:sub(pat_idx, pat_idx) == text:sub(text_idx, text_idx) then
      consecutive = consecutive + 1
      score = score + 1 + consecutive
      if pat_idx == 1 and text_idx == 1 then
        score = score + 10
      end
      pat_idx = pat_idx + 1
    else
      consecutive = 0
    end
    text_idx = text_idx + 1
  end

  local matched = pat_idx > #pattern
  if matched then
    local diff = math.abs(#text - #pattern)
    score = score - diff
  end
  return matched, score
end

function M.select_next()
  if #items == 0 then
    return
  end
  selected_index = math.min(#items, selected_index + 1)
  render_lines()
end

function M.select_prev()
  if #items == 0 then
    return
  end
  selected_index = math.max(1, selected_index - 1)
  render_lines()
end

function M.get_selected()
  if #items == 0 then
    return nil
  end
  return items[selected_index]
end

function M.render()
  render_lines()
end

return M
