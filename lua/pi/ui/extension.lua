--- Extension UI Protocol Handler
-- Handles extension_ui_request events from Pi and sends responses
-- Supports dialog methods (select, confirm, input, editor) and fire-and-forget methods

local M = {}

local state = require("pi.state")
local events = require("pi.events")

-- Track if we've set up event listeners
M._setup_done = false

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
  
  vim.ui.select(items, {
    prompt = request.title or "Select:",
  }, function(choice)
    if choice then
      M.send_response(request.id, { value = choice })
    else
      M.send_response(request.id, { cancelled = true })
    end
  end)
end

--- Handle confirm dialog - yes/no confirmation
-- @param request table { id, title, message?, timeout? }
function M.handle_confirm(request)
  local prompt = request.title or "Confirm"
  if request.message then
    prompt = prompt .. "\n" .. request.message
  end
  
  vim.ui.select({ "Yes", "No" }, {
    prompt = prompt,
  }, function(choice)
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
  vim.ui.input({
    prompt = request.title or "Input: ",
    default = request.placeholder or "",
  }, function(input)
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
  
  -- Submit on Ctrl+S or :w
  vim.api.nvim_buf_set_name(buf, "pi-extension-editor")
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    once = true,
    callback = function()
      if responded then return end
      responded = true
      local content = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      M.send_response(request.id, { value = content })
      vim.api.nvim_win_close(win, true)
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
    if responded then return end
    responded = true
    M.send_response(request.id, { cancelled = true })
    vim.api.nvim_win_close(win, true)
  end, { buffer = buf, silent = true })
  
  vim.keymap.set("n", "q", function()
    if responded then return end
    responded = true
    M.send_response(request.id, { cancelled = true })
    vim.api.nvim_win_close(win, true)
  end, { buffer = buf, silent = true })
  
  -- Handle window close
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      if responded then return end
      responded = true
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
