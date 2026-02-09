--- Extension UI Protocol Handler
-- Handles extension_ui_request events from Pi and sends responses
-- Supports dialog methods (select, confirm, input, editor) and fire-and-forget methods

local M = {}

local state = require("pi.state")
local events = require("pi.events")

-- Track if we've set up event listeners
M._setup_done = false

local function update_footer(win, text)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  local config = vim.api.nvim_win_get_config(win)
  config.footer = text
  config.footer_pos = "center"
  vim.api.nvim_win_set_config(win, config)
end

local function start_countdown(timeout_ms, on_tick, on_timeout)
  if not timeout_ms or timeout_ms <= 0 then
    return nil
  end

  local remaining = math.ceil(timeout_ms / 1000)
  local timer = vim.loop.new_timer()

  local function stop()
    if timer then
      timer:stop()
      timer:close()
      timer = nil
    end
  end

  if on_tick then
    vim.schedule(function()
      on_tick(remaining)
    end)
  end

  timer:start(1000, 1000, function()
    remaining = remaining - 1
    if remaining <= 0 then
      stop()
      if on_timeout then
        vim.schedule(on_timeout)
      end
    elseif on_tick then
      vim.schedule(function()
        on_tick(remaining)
      end)
    end
  end)

  return stop
end

local function max_display_width(lines)
  local max_width = 0
  for _, line in ipairs(lines) do
    max_width = math.max(max_width, vim.fn.strdisplaywidth(line))
  end
  return max_width
end

local function open_choice_window(request, items, on_choice)
  local title = request.title or "Select"
  local lines = { title }

  if request.message then
    for _, line in ipairs(vim.split(request.message, "\n")) do
      table.insert(lines, line)
    end
  end

  table.insert(lines, "")
  local option_start = #lines + 1

  local function item_label(item)
    if type(item) == "table" then
      return item.label or item.name or item.title or tostring(item)
    end
    return tostring(item)
  end

  for i, item in ipairs(items) do
    table.insert(lines, string.format("%d. %s", i, item_label(item)))
  end

  if #items == 0 then
    table.insert(lines, "(no options)")
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false

  local width = math.min(max_display_width(lines) + 4, vim.o.columns - 4)
  local height = math.min(#lines + 2, vim.o.lines - 4)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " " .. title .. " ",
    title_pos = "center",
  })

  local responded = false
  local selected = 1
  local ns = vim.api.nvim_create_namespace("pi_extension_select")
  local stop_timer

  local function highlight_selection()
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    if #items == 0 then
      return
    end
    local line = option_start + selected - 1
    vim.api.nvim_buf_add_highlight(buf, ns, "Visual", line - 1, 0, -1)
  end

  local function finish(choice)
    if responded then
      return
    end
    responded = true
    if stop_timer then stop_timer() end
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    on_choice(choice)
  end

  local footer_base = " <CR> select | q cancel "
  stop_timer = start_countdown(request.timeout, function(remaining)
    update_footer(win, footer_base .. string.format("| timeout %ds ", remaining))
  end, function()
    finish(nil)
  end)

  if not stop_timer then
    update_footer(win, footer_base)
  end

  vim.keymap.set("n", "q", function()
    if stop_timer then stop_timer() end
    finish(nil)
  end, { buffer = buf, silent = true })

  vim.keymap.set("n", "<Esc>", function()
    if stop_timer then stop_timer() end
    finish(nil)
  end, { buffer = buf, silent = true })

  vim.keymap.set("n", "j", function()
    if #items == 0 then return end
    selected = math.min(selected + 1, #items)
    highlight_selection()
  end, { buffer = buf, silent = true })

  vim.keymap.set("n", "k", function()
    if #items == 0 then return end
    selected = math.max(selected - 1, 1)
    highlight_selection()
  end, { buffer = buf, silent = true })

  vim.keymap.set("n", "<Down>", function()
    if #items == 0 then return end
    selected = math.min(selected + 1, #items)
    highlight_selection()
  end, { buffer = buf, silent = true })

  vim.keymap.set("n", "<Up>", function()
    if #items == 0 then return end
    selected = math.max(selected - 1, 1)
    highlight_selection()
  end, { buffer = buf, silent = true })

  vim.keymap.set("n", "<CR>", function()
    if stop_timer then stop_timer() end
    local choice = items[selected]
    finish(choice)
  end, { buffer = buf, silent = true })

  for i = 1, #items do
    vim.keymap.set("n", tostring(i), function()
      if stop_timer then stop_timer() end
      finish(items[i])
    end, { buffer = buf, silent = true })
  end

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      if responded then return end
      responded = true
      if stop_timer then stop_timer() end
      on_choice(nil)
    end,
  })

  highlight_selection()
end

local function open_input_window(request, on_submit)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "prompt"
  vim.bo[buf].bufhidden = "wipe"

  local prompt_base = request.title or "Input"
  local function update_prompt(remaining)
    local suffix = remaining and string.format(" (%ds)", remaining) or ""
    vim.fn.prompt_setprompt(buf, prompt_base .. suffix .. ": ")
  end

  local responded = false
  local win
  local stop_timer

  local function finish(value)
    if responded then
      return
    end
    responded = true
    if stop_timer then stop_timer() end
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    on_submit(value)
  end

  vim.fn.prompt_setcallback(buf, function(input)
    finish(input)
  end)

  vim.fn.prompt_setinterrupt(buf, function()
    finish(nil)
  end)

  if request.placeholder then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { request.placeholder })
  end

  local width = math.min(math.max(40, #prompt_base + 10), vim.o.columns - 4)
  local height = 3
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " " .. prompt_base .. " ",
    title_pos = "center",
  })

  local footer_base = " <Enter> submit | <Esc> cancel "
  stop_timer = start_countdown(request.timeout, function(remaining)
    update_prompt(remaining)
    update_footer(win, footer_base .. string.format("| timeout %ds ", remaining))
  end, function()
    finish(nil)
  end)

  if not stop_timer then
    update_prompt(nil)
    update_footer(win, footer_base)
  end

  vim.keymap.set("i", "<Esc>", function()
    if stop_timer then stop_timer() end
    finish(nil)
  end, { buffer = buf, silent = true })

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      if responded then return end
      responded = true
      if stop_timer then stop_timer() end
      on_submit(nil)
    end,
  })

  vim.cmd("startinsert")
end

--- Initialize extension UI handling
function M.setup()
  if M._setup_done then return end
  M._setup_done = true
  
  events.on("extension_ui_request", function(request)
    M.handle_request(request)
  end)
end

--- Handle an extension UI request
-- @param request table The extension_ui_request message
function M.handle_request(request)
  local method = request.method
  
  if method == "select" then
    M.handle_select(request)
  elseif method == "confirm" then
    M.handle_confirm(request)
  elseif method == "input" then
    M.handle_input(request)
  elseif method == "editor" then
    M.handle_editor(request)
  elseif method == "notify" then
    M.handle_notify(request)
  elseif method == "setStatus" then
    M.handle_set_status(request)
  elseif method == "setWidget" then
    M.handle_set_widget(request)
  elseif method == "setTitle" then
    M.handle_set_title(request)
  elseif method == "set_editor_text" then
    M.handle_set_editor_text(request)
  else
    vim.notify("Pi: Unknown extension UI method: " .. tostring(method), vim.log.levels.WARN)
  end
end

--- Handle select dialog - user chooses from a list
-- @param request table { id, title, options, timeout? }
function M.handle_select(request)
  local items = request.options or {}

  open_choice_window(request, items, function(choice)
    if choice ~= nil then
      M.send_response(request.id, { value = choice })
    else
      M.send_response(request.id, { cancelled = true })
    end
  end)
end

--- Handle confirm dialog - yes/no confirmation
-- @param request table { id, title, message?, timeout? }
function M.handle_confirm(request)
  open_choice_window(request, { "Yes", "No" }, function(choice)
    if choice == "Yes" then
      M.send_response(request.id, { confirmed = true })
    elseif choice == "No" then
      M.send_response(request.id, { confirmed = false })
    else
      M.send_response(request.id, { cancelled = true })
    end
  end)
end

--- Handle input dialog - free-form text input
-- @param request table { id, title?, placeholder? }
function M.handle_input(request)
  open_input_window(request, function(input)
    if input ~= nil then
      M.send_response(request.id, { value = input })
    else
      M.send_response(request.id, { cancelled = true })
    end
  end)
end

--- Handle editor dialog - multi-line text editor
-- Opens a scratch buffer for editing
-- @param request table { id, title?, prefill? }
function M.handle_editor(request)
  -- Create a scratch buffer
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].filetype = "markdown"
  
  -- Set prefill content
  local lines = {}
  if request.prefill then
    lines = vim.split(request.prefill, "\n")
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  
  -- Open in a floating window
  local width = math.floor(vim.o.columns * 0.8)
  local height = math.floor(vim.o.lines * 0.6)
  local col = math.floor((vim.o.columns - width) / 2)
  local row = math.floor((vim.o.lines - height) / 2)
  
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = col,
    row = row,
    style = "minimal",
    border = "rounded",
    title = " " .. (request.title or "Edit") .. " ",
    title_pos = "center",
    footer = " <C-s> submit | <Esc> cancel ",
    footer_pos = "center",
  })
  
  -- Track if we've sent a response
  local responded = false
  local stop_timer

  local function finish(response)
    if responded then return end
    responded = true
    if stop_timer then stop_timer() end
    M.send_response(request.id, response)
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local footer_base = " <C-s> submit | <Esc> cancel "
  stop_timer = start_countdown(request.timeout, function(remaining)
    update_footer(win, footer_base .. string.format("| timeout %ds ", remaining))
  end, function()
    finish({ cancelled = true })
  end)

  if not stop_timer then
    update_footer(win, footer_base)
  end
  
  -- Submit on Ctrl+S or :w
  vim.api.nvim_buf_set_name(buf, "pi-extension-editor")
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    once = true,
    callback = function()
      local content = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      finish({ value = content })
    end,
  })
  
  -- Also allow Ctrl+S
  vim.keymap.set("n", "<C-s>", function()
    vim.cmd("write")
  end, { buffer = buf, silent = true })
  
  vim.keymap.set("i", "<C-s>", function()
    vim.cmd("stopinsert")
    vim.cmd("write")
  end, { buffer = buf, silent = true })
  
  -- Cancel on Escape or close
  vim.keymap.set("n", "<Esc>", function()
    finish({ cancelled = true })
  end, { buffer = buf, silent = true })
  
  vim.keymap.set("n", "q", function()
    finish({ cancelled = true })
  end, { buffer = buf, silent = true })
  
  -- Handle window close
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      if responded then return end
      responded = true
      if stop_timer then stop_timer() end
      M.send_response(request.id, { cancelled = true })
    end,
  })
end

--- Handle notify - display a notification (fire-and-forget)
-- @param request table { message, notifyType? }
function M.handle_notify(request)
  local level = vim.log.levels.INFO
  local notify_type = request.notifyType or "info"
  
  if notify_type == "warning" then
    level = vim.log.levels.WARN
  elseif notify_type == "error" then
    level = vim.log.levels.ERROR
  end
  
  vim.notify(request.message or "", level, {
    title = "Pi Extension",
  })
end

--- Handle setStatus - set status bar entry (fire-and-forget)
-- @param request table { statusKey, statusText? }
function M.handle_set_status(request)
  local statuses = state.get("ui.statuses") or {}
  
  if request.statusText then
    statuses[request.statusKey] = request.statusText
  else
    statuses[request.statusKey] = nil
  end
  
  state.update("ui.statuses", statuses)
  events.emit("extension_status_changed", {
    key = request.statusKey,
    text = request.statusText,
  })
end

--- Handle setWidget - set widget content (fire-and-forget)
-- @param request table { widgetKey, widgetLines?, widgetPlacement? }
function M.handle_set_widget(request)
  local widgets = state.get("ui.widgets") or {}
  
  if request.widgetLines then
    widgets[request.widgetKey] = {
      lines = request.widgetLines,
      placement = request.widgetPlacement or "aboveEditor",
    }
  else
    widgets[request.widgetKey] = nil
  end
  
  state.update("ui.widgets", widgets)
  events.emit("extension_widget_changed", {
    key = request.widgetKey,
    widget = widgets[request.widgetKey],
  })
end

--- Handle setTitle - set window title (fire-and-forget)
-- @param request table { title }
function M.handle_set_title(request)
  if request.title then
    vim.opt.titlestring = request.title
    state.update("ui.title", request.title)
  end
end

--- Handle set_editor_text - prefill chat input (fire-and-forget)
-- @param request table { text }
function M.handle_set_editor_text(request)
  state.update("ui.editor_prefill", request.text)
  events.emit("extension_editor_prefill", { text = request.text })
end

--- Send a response to an extension UI request
-- @param request_id string The request ID to respond to
-- @param data table The response data (value, confirmed, cancelled, etc.)
function M.send_response(request_id, data)
  local client = state.get("rpc_client")
  if not client then
    vim.notify("Pi: Cannot send extension UI response - not connected", vim.log.levels.ERROR)
    return
  end
  
  local response = vim.tbl_extend("force", {
    type = "extension_ui_response",
    id = request_id,
  }, data)
  
  local ok, err = client:send(response)
  if not ok then
    vim.notify("Pi: Failed to send extension UI response: " .. tostring(err), vim.log.levels.ERROR)
  end
end

--- Get all current extension statuses
-- @return table { key = text, ... }
function M.get_statuses()
  return state.get("ui.statuses") or {}
end

--- Get all current extension widgets
-- @return table { key = { lines, placement }, ... }
function M.get_widgets()
  return state.get("ui.widgets") or {}
end

--- Clear all extension statuses
function M.clear_statuses()
  state.update("ui.statuses", {})
  events.emit("extension_statuses_cleared")
end

--- Clear all extension widgets
function M.clear_widgets()
  state.update("ui.widgets", {})
  events.emit("extension_widgets_cleared")
end

return M
