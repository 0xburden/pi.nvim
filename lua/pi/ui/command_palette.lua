local M = {}

local commands_mod = require("pi.rpc.commands")
local state = require("pi.state")
local events = require("pi.events")

local is_selecting = false

local function ensure_client(callback)
  local client = state.get("rpc_client")
  if client and client.connected then
    callback(client)
    return
  end

  vim.schedule(function()
    vim.notify("Pi: Not connected", vim.log.levels.ERROR)
  end)
end

local function ensure_commands(callback)
  local cached = commands_mod.get_cached()
  if #cached > 0 then
    callback(cached)
    return
  end

  ensure_client(function(client)
    commands_mod.get_all(client, function(result)
      if result and result.success then
        callback(commands_mod.get_cached())
      else
        vim.schedule(function()
          vim.notify("Pi: Failed to load commands", vim.log.levels.WARN)
        end)
      end
    end)
  end)
end

local function format_item(entry)
  local cmd = entry.cmd
  local components = { "/" .. (cmd.name or "") }
  if cmd.description and cmd.description ~= "" then
    table.insert(components, "- " .. cmd.description)
  end
  if cmd.source and cmd.source ~= "" then
    table.insert(components, "[" .. cmd.source .. "]")
  end
  return table.concat(components, " ")
end

function M.open()
  if is_selecting then
    return
  end
  is_selecting = true

  ensure_commands(function(cmds)
    is_selecting = false
    if #cmds == 0 then
      vim.notify("Pi: No commands available", vim.log.levels.INFO)
      return
    end

    local entries = {}
    for _, cmd in ipairs(cmds) do
      table.insert(entries, { cmd = cmd })
    end

    vim.ui.select(entries, {
      prompt = "Run Pi command:",
      format_item = format_item,
    }, function(choice)
      if not choice or not choice.cmd then
        return
      end

      vim.ui.input({ prompt = "Args (optional): " }, function(input)
        local payload = "/" .. (choice.cmd.name or "")
        if input and input ~= "" then
          payload = payload .. " " .. input
        end
        require("pi").start(payload)
      end)
    end)
  end)
end

return M
