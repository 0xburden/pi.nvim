# Pi.nvim Implementation Plan

## Current Status

The pi.nvim plugin has a basic foundation with:
- RPC client connecting via stdin/stdout to `pi --mode rpc`
- Basic agent control (prompt, abort)
- Partial session management
- UI components (control panel, diff viewer, logs viewer, chat)

## Gap Analysis: Missing RPC Commands

Based on the official [Pi RPC documentation](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/rpc.md), here are the missing features:

### 1. Prompting Commands
| Command | Status | Priority |
|---------|--------|----------|
| `prompt` | ✅ Implemented (with images & streamingBehavior support) | - |
| `steer` | ✅ Implemented | - |
| `follow_up` | ✅ Implemented | - |
| `abort` | ✅ Implemented | - |

### 2. State Commands
| Command | Status | Priority |
|---------|--------|----------|
| `get_state` | ✅ Implemented | - |
| `get_messages` | ✅ Implemented | - |

### 3. Model Commands
| Command | Status | Priority |
|---------|--------|----------|
| `set_model` | ✅ Implemented | - |
| `cycle_model` | ✅ Implemented | - |
| `get_available_models` | ✅ Implemented | - |

### 4. Thinking Commands
| Command | Status | Priority |
|---------|--------|----------|
| `set_thinking_level` | ✅ Implemented | - |
| `cycle_thinking_level` | ✅ Implemented | - |

### 5. Queue Mode Commands
| Command | Status | Priority |
|---------|--------|----------|
| `set_steering_mode` | ✅ Implemented | - |
| `set_follow_up_mode` | ✅ Implemented | - |

### 6. Compaction Commands
| Command | Status | Priority |
|---------|--------|----------|
| `compact` | ✅ Implemented | - |
| `set_auto_compaction` | ✅ Implemented | - |

### 7. Retry Commands
| Command | Status | Priority |
|---------|--------|----------|
| `set_auto_retry` | ✅ Implemented | - |
| `abort_retry` | ✅ Implemented | - |

### 8. Bash Commands
| Command | Status | Priority |
|---------|--------|----------|
| `bash` | ✅ Implemented | - |
| `abort_bash` | ✅ Implemented | - |

### 9. Session Commands (Extended)
| Command | Status | Priority |
|---------|--------|----------|
| `new_session` | ✅ Implemented | - |
| `get_session_stats` | ✅ Implemented | - |
| `export_html` | ✅ Implemented | - |
| `switch_session` | ✅ Implemented | - |
| `fork` | ✅ Implemented | - |
| `get_fork_messages` | ✅ Implemented | - |
| `get_last_assistant_text` | ✅ Implemented | - |
| `set_session_name` | ✅ Implemented | - |

### 10. Command Discovery
| Command | Status | Priority |
|---------|--------|----------|
| `get_commands` | ✅ Implemented | - |

### 11. Event Handling
The client now emits typed events and updates state automatically:

| Event | Status | Priority |
|-------|--------|----------|
| `agent_start` | ✅ Implemented | - |
| `agent_end` | ✅ Implemented | - |
| `turn_start` / `turn_end` | ✅ Emitted (no state update) | - |
| `message_start` / `message_end` | ✅ Implemented | - |
| `message_update` (streaming) | ✅ Implemented + delta events | - |
| `tool_execution_*` | ✅ Implemented | - |
| `auto_compaction_*` | ✅ Implemented | - |
| `auto_retry_*` | ✅ Implemented | - |
| `extension_error` | ✅ Implemented (logs warning) | - |
| `extension_ui_request` | ✅ Emitted (handler in Phase 5) | - |

### 12. Extension UI Protocol
Full extension UI support implemented:

| Method | Type | Status |
|--------|------|--------|
| `select` | Dialog | ✅ via vim.ui.select |
| `confirm` | Dialog | ✅ via vim.ui.select |
| `input` | Dialog | ✅ via vim.ui.input |
| `editor` | Dialog | ✅ via floating buffer |
| `notify` | Fire-and-forget | ✅ via vim.notify |
| `setStatus` | Fire-and-forget | ✅ stored in state |
| `setWidget` | Fire-and-forget | ✅ stored in state |
| `setTitle` | Fire-and-forget | ✅ via vim.opt.titlestring |
| `set_editor_text` | Fire-and-forget | ✅ stored in state |

### 13. Non-existent Commands in Current Code
The current code uses `pause` and `resume` commands which are **NOT** in the official RPC spec. These need to be reviewed.

## Implementation Phases

### Phase 1: Core Prompting (High Priority) ✅ COMPLETE

**Files modified:**
- `lua/pi/rpc/agent.lua` - Added `steer`, `follow_up`, improved `prompt` with options
- `lua/pi/init.lua` - Exposed new functions, removed invalid `pause`/`resume`
- `plugin/pi.lua` - Added `:PiSteer`, `:PiFollowUp`, `:PiAbort`, `:PiStatus` commands

**New Vim commands:**
- `:PiSteer <message>` - Interrupt agent mid-run with new instructions
- `:PiFollowUp <message>` - Queue message to be processed after agent finishes
- `:PiAbort` - Abort current operation
- `:PiStatus` - Show detailed agent status

**API additions:**
- `require("pi").steer(message, opts)` - Steer agent mid-run
- `require("pi").follow_up(message, opts)` - Queue follow-up message
- `require("pi").abort()` - Abort current operation
- `require("pi").status(callback)` - Get agent status
- All prompt functions now support `opts.images` for image attachments

---

### Phase 2: Conversation History & Messages (High Priority) ✅ COMPLETE

**New file:** `lua/pi/rpc/conversation.lua`

**Implemented:**
- `get_messages(client, callback)` - Retrieve full conversation history
- `get_last_assistant_text(client, callback)` - Get last assistant response
- `send(client, message, opts, callback)` - Convenience alias for agent.prompt
- `clear_local()` - Clear local conversation state
- Helper functions: `extract_text()`, `extract_thinking()`, `extract_tool_calls()`, `format_message()`, `get_formatted()`

**New Vim commands:**
- `:PiMessages` - Show conversation summary (message count, roles, truncated content)
- `:PiLastResponse` - Open last assistant response in a split buffer for easy copying

**State additions:**
- `conversation.messages` - Array of AgentMessage objects
- `conversation.last_assistant_text` - Cached last response text
- Extended `agent.*` state with all fields from `get_state`
- Added `ui.statuses`, `ui.widgets`, `ui.editor_prefill` for extension UI

---

### Phase 3: Bash Commands (High Priority) ✅ COMPLETE

**New file:** `lua/pi/rpc/bash.lua`

**Implemented:**
- `execute(client, command, callback)` - Run shell command, output added to next prompt
- `abort(client, callback)` - Abort running bash command
- `is_running()` - Check if bash command is running
- `get_last()` - Get last execution result
- `get_history()` - Get all execution history (max 50)
- `clear_history()` - Clear local history

**New Vim commands:**
- `:PiBash <command>` - Execute bash command
- `:PiBashAbort` - Abort running bash command
- `:PiBashLast` - Show last bash output in split buffer
- `:PiBashHistory` - Show execution history summary

**State additions:**
- `bash.running` - Whether a bash command is currently executing
- `bash.current_command` - The currently running command
- `bash.last_execution` - Last execution result
- `bash.executions` - History of executions

**Events emitted:**
- `bash_start`, `bash_end`, `bash_error`, `bash_aborted`, `bash_history_cleared`

---

### Phase 4: Typed Event System (High Priority) ✅ COMPLETE

**File modified:** `lua/pi/rpc/client.lua`

**Implemented:**
- `_handle_message()` now emits typed events based on message type
- All events also emit `rpc_event` for backward compatibility
- State automatically updated based on event type:
  - `agent_start/end` → `agent.running`
  - `message_start/update/end` → `agent.current_message`, `agent.last_message`
  - `tool_execution_*` → `agent.current_tool`, `agent.last_tool_result`
  - `auto_compaction_*` → `agent.compacting`, `agent.last_compaction`
  - `auto_retry_*` → `agent.retrying`, `agent.retry_info`
  - `extension_error` → Logs warning via vim.notify
- Added `message_delta_<type>` events for fine-grained streaming handling
- Added `client:send(message)` for sending raw messages (used for extension UI responses)

**Events emitted:**
- `agent_start`, `agent_end`
- `turn_start`, `turn_end`
- `message_start`, `message_update`, `message_end`
- `message_delta_text_delta`, `message_delta_thinking_delta`, etc.
- `tool_execution_start`, `tool_execution_update`, `tool_execution_end`
- `auto_compaction_start`, `auto_compaction_end`
- `auto_retry_start`, `auto_retry_end`
- `extension_error`, `extension_ui_request`

**State additions:**
- `agent.current_message`, `agent.last_message`
- `agent.current_tool`, `agent.last_tool_result`
- `agent.compacting`, `agent.compaction_reason`, `agent.last_compaction`
- `agent.retrying`, `agent.retry_info`

---

### Phase 5: Extension UI Protocol (High Priority) ✅ COMPLETE

**New file:** `lua/pi/ui/extension.lua`

**Implemented:**

**Dialog methods (require response):**
- `handle_select(request)` - User selects from list via vim.ui.select
- `handle_confirm(request)` - Yes/No confirmation via vim.ui.select
- `handle_input(request)` - Free-form text via vim.ui.input
- `handle_editor(request)` - Multi-line editing in floating buffer with Ctrl+S/Esc

**Fire-and-forget methods:**
- `handle_notify(request)` - Display notification via vim.notify
- `handle_set_status(request)` - Store status in state
- `handle_set_widget(request)` - Store widget in state
- `handle_set_title(request)` - Set vim.opt.titlestring
- `handle_set_editor_text(request)` - Store prefill text in state

**Helper functions:**
- `send_response(request_id, data)` - Send extension_ui_response to Pi
- `get_statuses()`, `get_widgets()` - Query current extension state
- `clear_statuses()`, `clear_widgets()` - Reset extension state

**New Vim commands:**
- `:PiExtensionStatuses` - Show extension status entries
- `:PiExtensionWidgets` - Show extension widgets

**Events emitted:**
- `extension_status_changed`, `extension_widget_changed`
- `extension_editor_prefill`, `extension_statuses_cleared`, `extension_widgets_cleared`

---

### Phase 6: Session Management (Medium Priority) ✅ COMPLETE

**File modified:** `lua/pi/rpc/session.lua`

**Implemented:**
- `current(client, callback)` - Get current session from state
- `new(client, opts, callback)` - Start new session (with parentSession support)
- `get_stats(client, callback)` - Get token usage, cost, message counts
- `export_html(client, opts, callback)` - Export session to HTML file
- `switch(client, sessionPath, callback)` - Switch to different session file
- `fork(client, entryId, callback)` - Fork from previous message
- `get_fork_messages(client, callback)` - Get forkable user messages
- `set_name(client, name, callback)` - Set session display name

**New Vim commands:**
- `:PiSessionNew` - Start new session
- `:PiSessionStats` - Show token usage, costs, message counts
- `:PiSessionExport [path]` - Export to HTML
- `:PiSessionSwitch <path>` - Switch to session file
- `:PiSessionName <name>` - Set display name
- `:PiSessionFork [entryId]` - Fork from message (interactive if no ID)

**Events emitted:**
- `session_changed`, `session_switched`, `session_forked`, `session_name_changed`

---

### Phase 7: Model Management (Medium Priority) ✅ COMPLETE

**New file:** `lua/pi/rpc/model.lua`

**Implemented:**
- `set(client, provider, modelId, callback)` - Set specific model
- `cycle(client, callback)` - Cycle to next available model
- `get_available(client, callback)` - List all configured models
- `set_thinking_level(client, level, callback)` - Set reasoning level
- `cycle_thinking_level(client, callback)` - Cycle thinking levels
- `get_current()` - Get current model from state
- `get_thinking_level()` - Get current thinking level
- `supports_thinking()` - Check if model supports reasoning
- `format(model)` - Format model for display

**New Vim commands:**
- `:PiModel` - Show current model info
- `:PiModelSet <provider> <modelId>` - Set specific model
- `:PiModelCycle` - Cycle to next model
- `:PiModelList` - List all available models
- `:PiThinking [level]` - Set/cycle thinking level (off, minimal, low, medium, high, xhigh)

**Events emitted:**
- `model_changed`, `thinking_level_changed`

---

### Phase 8: Compaction & Retry (Low Priority) ✅ COMPLETE

**New file:** `lua/pi/rpc/maintenance.lua`

**Implemented:**

**Compaction:**
- `compact(client, customInstructions, callback)` - Manual compaction
- `set_auto_compaction(client, enabled, callback)` - Toggle auto-compaction
- `is_compacting()`, `get_last_compaction()` - Status helpers

**Retry:**
- `set_auto_retry(client, enabled, callback)` - Toggle auto-retry
- `abort_retry(client, callback)` - Abort in-progress retry
- `is_retrying()`, `get_retry_info()` - Status helpers

**Queue Modes:**
- `set_steering_mode(client, mode, callback)` - "all" or "one-at-a-time"
- `set_follow_up_mode(client, mode, callback)` - "all" or "one-at-a-time"

**New Vim commands:**
- `:PiCompact [instructions]` - Compact conversation
- `:PiAutoCompact [on|off]` - Toggle/show auto-compaction
- `:PiAutoRetry [on|off]` - Toggle/show auto-retry
- `:PiAbortRetry` - Abort in-progress retry
- `:PiSteeringMode [mode]` - Set/show steering mode
- `:PiFollowUpMode [mode]` - Set/show follow-up mode

**Events emitted:**
- `compaction_start`, `compaction_end`, `compaction_error`
- `auto_compaction_changed`, `auto_retry_changed`, `retry_aborted`
- `steering_mode_changed`, `follow_up_mode_changed`

---

### Phase 9: Command Discovery ✅ COMPLETE

**New file:** `lua/pi/rpc/commands.lua`

**Implemented:**
- `get_all(client, callback)` - Fetch all commands from Pi
- `get_cached()` - Get commands from state
- `filter_by_source(source)` - Filter by extension/prompt/skill
- `get_extensions()`, `get_prompts()`, `get_skills()` - Convenience filters
- `find(name)` - Find command by name
- `format(cmd)` - Format for display
- `get_completion_items()` - For telescope/fzf integration

**New Vim commands:**
- `:PiCommands [filter]` - List commands (grouped by source)
- `:PiRun <command>` - Run a Pi command (e.g., `:PiRun skill:search query`)

**Events emitted:**
- `commands_loaded`

---

### Phase 10: Chat UI Integration
**File to modify:** `lua/pi/ui/chat.lua`

Integrate with conversation history and streaming events:

```lua
local M = {}

local buf = nil
local win = nil

function M.open()
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
    return
  end
  
  buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].filetype = "pi-chat"
  
  -- Create floating window
  local width = math.floor(vim.o.columns * 0.8)
  local height = math.floor(vim.o.lines * 0.8)
  local col = math.floor((vim.o.columns - width) / 2)
  local row = math.floor((vim.o.lines - height) / 2)
  
  win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = col,
    row = row,
    style = "minimal",
    border = "rounded",
    title = " Pi Chat ",
    title_pos = "center",
  })
  
  -- Set up keymaps
  vim.keymap.set("n", "q", M.close, { buffer = buf, silent = true })
  vim.keymap.set("n", "i", M.prompt_input, { buffer = buf, silent = true })
  
  -- Load conversation history
  M.load_history()
  
  -- Subscribe to events
  M.setup_event_listeners()
end

function M.setup_event_listeners()
  local events = require("pi.events")
  
  -- Handle streaming message updates
  events.on("message_update", function(event)
    local delta = event.assistantMessageEvent
    if delta.type == "text_delta" then
      M.append_text(delta.delta)
    end
  end)
  
  events.on("agent_end", function()
    M.append_text("\n---\n")
  end)
end

function M.load_history()
  local client = require("pi.state").get("rpc_client")
  if not client then return end
  
  require("pi.rpc.conversation").get_messages(client, function(result)
    if result and result.success then
      M.display_messages(result.data.messages)
    end
  end)
end

function M.display_messages(messages)
  local lines = {}
  for _, msg in ipairs(messages) do
    if msg.role == "user" then
      table.insert(lines, "**User:** " .. (type(msg.content) == "string" and msg.content or vim.inspect(msg.content)))
    elseif msg.role == "assistant" then
      table.insert(lines, "**Assistant:**")
      -- Handle content blocks
      if type(msg.content) == "table" then
        for _, block in ipairs(msg.content) do
          if block.type == "text" then
            for _, line in ipairs(vim.split(block.text, "\n")) do
              table.insert(lines, line)
            end
          elseif block.type == "thinking" then
            table.insert(lines, "_Thinking: " .. block.thinking:sub(1, 50) .. "..._")
          elseif block.type == "toolCall" then
            table.insert(lines, "_Tool: " .. block.name .. "_")
          end
        end
      end
    end
    table.insert(lines, "")
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
end

function M.append_text(text)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  local lines = vim.api.nvim_buf_get_lines(buf, -2, -1, false)
  local last_line = lines[1] or ""
  vim.api.nvim_buf_set_lines(buf, -2, -1, false, { last_line .. text })
end

function M.prompt_input()
  vim.ui.input({ prompt = "Message: " }, function(input)
    if not input or input == "" then return end
    M.send_message(input)
  end)
end

function M.send_message(text)
  local client = require("pi.state").get("rpc_client")
  if not client then
    vim.notify("Pi: Not connected", vim.log.levels.ERROR)
    return
  end
  
  M.append_text("\n**User:** " .. text .. "\n\n**Assistant:** ")
  
  require("pi.rpc.agent").start(client, text, function(result)
    if result.error then
      M.append_text("\n_Error: " .. result.error .. "_")
    end
  end)
end

function M.close()
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
  win = nil
  buf = nil
end

return M
```

---

## Updated State Structure

Add these paths to `lua/pi/state.lua`:

```lua
M.state = {
  -- Existing fields...
  
  -- Conversation
  conversation = {
    messages = {},
  },
  
  -- Model
  model = {
    current = nil,
    available = {},
    thinking_level = "medium",
  },
  
  -- Bash
  bash = {
    executions = {},
  },
  
  -- Session
  session = {
    current = nil,
    available = {},
    stats = nil,
    name = nil,
  },
  
  -- UI
  ui = {
    control_panel_open = false,
    diff_viewer_open = false,
    logs_open = false,
    chat_open = false,
    statuses = {},      -- Extension status entries
    widgets = {},       -- Extension widgets
    editor_prefill = nil,
  },
  
  -- Commands
  commands = {
    available = {},
  },
}
```

---

## Vim Commands Reference

| Command | Description |
|---------|-------------|
| `:PiConnect` | Connect to Pi RPC |
| `:PiDisconnect` | Disconnect from Pi |
| `:PiStart <task>` | Send prompt to agent |
| `:PiSteer <message>` | Interrupt and steer agent |
| `:PiFollowUp <message>` | Queue follow-up message |
| `:PiAbort` | Abort current operation |
| `:PiToggle` | Toggle control panel |
| `:PiLogs` | Toggle logs viewer |
| `:PiChat` | Open chat interface |
| `:PiDiff` | Show diff for current file |
| `:PiApprove` | Approve pending changes |
| `:PiReject` | Reject pending changes |
| `:PiSessionNew` | Start new session |
| `:PiSessionSwitch <path>` | Switch to session file |
| `:PiSessionFork <entryId>` | Fork from message |
| `:PiSessionName <name>` | Set session name |
| `:PiBash <command>` | Execute bash command |
| `:PiModelSet <provider> <model>` | Set model |
| `:PiModelCycle` | Cycle to next model |
| `:PiCompact` | Compact conversation |

---

## Testing Checklist

- [x] Can connect to Pi RPC process
- [x] Can send prompts and receive responses
- [x] Streaming text displays in real-time (via typed events)
- [x] Can steer agent mid-run (`:PiSteer`)
- [x] Can queue follow-up messages (`:PiFollowUp`)
- [x] Extension UI dialogs work (select, confirm, input, editor)
- [x] Extension notifications display (via vim.notify)
- [x] Bash commands execute and show output (`:PiBash`, `:PiBashLast`)
- [x] Session management works (`:PiSessionNew`, `:PiSessionSwitch`, `:PiSessionFork`)
- [x] Conversation history available (`:PiMessages`, `:PiLastResponse`)
- [x] Tool execution events update state
- [x] Model switching works (`:PiModelSet`, `:PiModelCycle`)
- [x] Compaction works (`:PiCompact`, `:PiAutoCompact`)
- [x] Command discovery works (`:PiCommands`)

## Implementation Complete! 🎉

All RPC commands from the Pi specification have been implemented. The plugin now supports:

### Commands by Category

**Prompting:** `:PiStart`, `:PiSteer`, `:PiFollowUp`, `:PiAbort`
**Conversation:** `:PiMessages`, `:PiLastResponse`  
**Bash:** `:PiBash`, `:PiBashAbort`, `:PiBashLast`, `:PiBashHistory`
**Session:** `:PiSession`, `:PiSessionNew`, `:PiSessionStats`, `:PiSessionExport`, `:PiSessionSwitch`, `:PiSessionName`, `:PiSessionFork`
**Model:** `:PiModel`, `:PiModelSet`, `:PiModelCycle`, `:PiModelList`, `:PiThinking`
**Maintenance:** `:PiCompact`, `:PiAutoCompact`, `:PiAutoRetry`, `:PiAbortRetry`, `:PiSteeringMode`, `:PiFollowUpMode`
**Commands:** `:PiCommands`, `:PiRun`
**Extension UI:** `:PiExtensionStatuses`, `:PiExtensionWidgets`
**Debug:** `:PiStatus`, `:PiDebug`, `:PiTestRPC`

### Files Created/Modified

```
lua/pi/rpc/
├── client.lua      # RPC client with typed event handling
├── agent.lua       # Prompting commands
├── conversation.lua # Conversation history
├── bash.lua        # Bash execution
├── session.lua     # Session management  
├── model.lua       # Model management
├── maintenance.lua # Compaction, retry, queue modes
└── commands.lua    # Command discovery

lua/pi/ui/
└── extension.lua   # Extension UI protocol

lua/pi/
├── init.lua        # Main entry with setup()
├── state.lua       # State management (extended)
├── events.lua      # Event system
└── config.lua      # Configuration
```

## Notes

1. ~~The `pause` and `resume` commands in the current code don't exist in the official RPC spec.~~ **RESOLVED**: Removed `pause`/`resume`, replaced with proper `steer`/`follow_up` flow.

2. The official spec uses `abort` for stopping. Added `:PiAbort` command (`:PiStop` kept as alias for compatibility).

3. Extension UI protocol is critical for full functionality - many Pi extensions rely on it.

4. ~~Image support in prompts (`images` field) should be implemented.~~ **DONE**: Added `images` parameter support to `prompt`, `steer`, and `follow_up`.

## Phase 11: UI Overhaul (In Progress)

In response to the UI_OVERHAUL.md plan, we are rebuilding the chat experience with syntax-highlighted assistant responses, slash-command autocomplete, and colorscheme-aware styling.

### Key Deliverables

- Implement robust markdown parsing + syntax highlighting for assistant messages (treesitter + optional render-markdown).
- Add a floating slash-command autocomplete window that respects Pi command metadata.
- Build a colors utilities module so every UI component (chat, panels, logs, tree) honors the active colorscheme and user overrides.
- Apply rendering/performance polish (debounced streaming renders, spinner animation, reliable keymaps) to keep the UI responsive.

### Testing Checklist

- [x] Phase 1: Code blocks and inline code are parsed/highlighted, including streaming/incomplete blocks and inline code toggles.
- [x] Phase 1: render-markdown integration works when enabled; custom treesitter fallback triggers when disabled.
- [x] Phase 2: Slash-command autocomplete opens on `/`, supports fuzzy filtering, keyboard navigation, and command loading state.
- [x] Phase 3: All new highlight groups use the colors.lua helpers and reapply on `ColorScheme`; respects `respect_user_highlights` and `custom_highlights` config.
- [x] Phase 3: Control panel, file tree, and logs viewer render with the updated highlight names and colors, not hard-coded values.
- [x] Phase 4: Rendering is debounced for streaming, spinner animation runs independently, and new keymaps use `vim.keymap.set` with autocomplete-aware behavior.
