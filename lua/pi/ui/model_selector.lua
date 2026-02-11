--- Model Selection Dropdown
-- Provides an interactive model picker using vim.ui.select
-- with current model indicator and provider grouping.

local M = {}

local state = require("pi.state")
local model_rpc = require("pi.rpc.model")

local is_open = false

--- Build a display label for a model entry
---@param entry table { provider: string, modelId: string, name: string|nil, reasoning: boolean|nil }
---@param current_id string|nil The currently active model id
---@return string
local function format_entry(entry, current_id)
  local name = entry.name or entry.modelId
  local indicator = ""
  if current_id and (entry.modelId == current_id or entry.name == current_id) then
    indicator = "● "
  end
  local suffix = ""
  if entry.reasoning then
    suffix = " 🧠"
  end
  return string.format("%s%s/%s%s", indicator, entry.provider, name, suffix)
end

--- Sort entries by provider then name
---@param models table[] List of model entries
local function sort_models(models)
  table.sort(models, function(a, b)
    if a.provider ~= b.provider then
      return (a.provider or "") < (b.provider or "")
    end
    return (a.name or a.modelId or "") < (b.name or b.modelId or "")
  end)
end

--- Resolve the currently active model id for matching
---@return string|nil
local function get_current_model_id()
  local current = model_rpc.get_current()
  if not current then return nil end
  return current.id or current.name or current.modelId
end

--- Open the model selector dropdown
--- Fetches available models from the agent and presents them in vim.ui.select
---@param opts table|nil Optional: { on_select: fun(model)|nil }
function M.open(opts)
  if is_open then return end
  opts = opts or {}

  local client = state.get("rpc_client")
  if not client or not client.connected then
    vim.notify("Pi: Not connected to agent", vim.log.levels.ERROR)
    return
  end

  is_open = true

  model_rpc.get_available(client, function(result)
    -- Already inside vim.schedule from model_rpc.get_available
    is_open = false

    if not result or not result.success then
      vim.notify("Pi: Failed to fetch models - " .. (result and result.error or "unknown"), vim.log.levels.ERROR)
      return
    end

    local raw_models = result.data and result.data.models or {}
    if #raw_models == 0 then
      vim.notify("Pi: No models available", vim.log.levels.WARN)
      return
    end

    local entries = {}
    for _, m in ipairs(raw_models) do
      table.insert(entries, {
        provider = m.provider or "unknown",
        modelId = m.id or m.modelId or m.name or "unknown",
        name = m.name or m.id or m.modelId,
        reasoning = m.reasoning == true,
        raw = m,
      })
    end

    sort_models(entries)

    local current_id = get_current_model_id()

    vim.ui.select(entries, {
      prompt = "Select Model:",
      format_item = function(entry)
        return format_entry(entry, current_id)
      end,
    }, function(choice)
      if not choice then return end

      model_rpc.set(client, choice.provider, choice.modelId, function(set_result)
        -- Already inside vim.schedule from model_rpc.set
        if set_result and set_result.success then
          local display = model_rpc.format(set_result.data or choice.raw)
          vim.notify("Pi: Model set to " .. display, vim.log.levels.INFO)

          local ok, chat = pcall(require, "pi.ui.chat")
          if ok and chat then
            chat.session_info.model = choice.name or choice.modelId
            if chat.is_open() then
              chat.render()
            end
          end

          if opts.on_select then
            opts.on_select(choice)
          end
        else
          vim.notify(
            "Pi: Failed to set model - " .. (set_result and set_result.error or "unknown"),
            vim.log.levels.ERROR
          )
        end
      end)
    end)
  end)
end

--- Open the thinking level selector
--- Only shown if the current model supports thinking/reasoning
---@param opts table|nil Optional: { on_select: fun(level)|nil }
function M.open_thinking_level(opts)
  if is_open then return end
  opts = opts or {}

  local client = state.get("rpc_client")
  if not client or not client.connected then
    vim.notify("Pi: Not connected to agent", vim.log.levels.ERROR)
    return
  end

  if not model_rpc.supports_thinking() then
    vim.notify("Pi: Current model does not support thinking levels", vim.log.levels.WARN)
    return
  end

  local levels = { "off", "minimal", "low", "medium", "high", "xhigh" }
  local current_level = model_rpc.get_thinking_level() or "off"

  is_open = true

  vim.ui.select(levels, {
    prompt = "Thinking Level:",
    format_item = function(level)
      local indicator = level == current_level and "● " or "  "
      return indicator .. level
    end,
  }, function(choice)
    is_open = false
    if not choice then return end

    model_rpc.set_thinking_level(client, choice, function(result)
      -- Already inside vim.schedule from model_rpc.set_thinking_level
      if result and result.success then
        vim.notify("Pi: Thinking level set to " .. choice, vim.log.levels.INFO)

        local ok, chat = pcall(require, "pi.ui.chat")
        if ok and chat and chat.is_open() then
          chat.render()
        end

        if opts.on_select then
          opts.on_select(choice)
        end
      else
        vim.notify(
          "Pi: Failed to set thinking level - " .. (result and result.error or "unknown"),
          vim.log.levels.ERROR
        )
      end
    end)
  end)
end

return M
