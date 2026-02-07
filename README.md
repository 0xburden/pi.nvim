# pi.nvim

Native Neovim integration for the [Pi coding agent](https://github.com/badlogic/pi-mono).

## Features

- 🚀 **Native RPC** - Direct communication with Pi via TCP/JSON-RPC
- 📊 **Real-time Status** - Live control panel showing agent state
- 📝 **Log Streaming** - Watch agent output in real-time
- 🔄 **Diff Viewer** - Review changes side-by-side before applying
- ✅ **Approval Workflow** - Approve or reject agent modifications
- 💬 **Chat Interface** - Interactive conversation with the agent
- 📁 **Session Management** - Save and restore agent sessions
- 🗂️ **File Tree** - Track pending and modified files

## Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "your-username/pi.nvim",
  config = function()
    require("pi").setup({
      -- Auto-connect on startup
      auto_connect = true,
      
      -- Require approval before applying changes
      approval_mode = true,
      
      -- Custom keymaps
      keymaps = {
        toggle_panel = "<leader>pt",
        toggle_logs = "<leader>pl",
        approve = "<leader>pa",
        reject = "<leader>pr",
      }
    })
  end
}
```

### Using [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  "your-username/pi.nvim",
  config = function()
    require("pi").setup()
  end
}
```

## Requirements

- Neovim >= 0.8.0
- Pi agent running with RPC enabled (default port: 43863)

## Quick Start

1. **Start Pi agent** with RPC enabled:
   ```bash
   pi --rpc
   ```

2. **Connect from Neovim**:
   ```vim
   :PiConnect
   ```

3. **Start a task**:
   ```vim
   :PiStart "Refactor the utils module to use TypeScript"
   ```

4. **Monitor progress**:
   ```vim
   :PiToggle    " Show control panel
   :PiLogs      " Show log stream
   ```

5. **Review changes**:
   ```vim
   :PiApprove   " Apply the current change
   :PiReject    " Discard the current change
   ```

## Commands

| Command | Description |
|---------|-------------|
| `:PiConnect` | Connect to Pi RPC server |
| `:PiDisconnect` | Disconnect from server |
| `:PiStart <task>` | Start agent with task description |
| `:PiPause` | Pause the running agent |
| `:PiResume` | Resume a paused agent |
| `:PiStop` | Stop the running agent |
| `:PiToggle` | Toggle control panel |
| `:PiLogs` | Toggle logs viewer |
| `:PiDiff [file]` | Show diff for file |
| `:PiApprove` | Approve pending change |
| `:PiReject` | Reject pending change |
| `:PiSessionList` | List saved sessions |
| `:PiSessionLoad <id>` | Load a session |
| `:PiSessionSave [name]` | Save current session |

## Configuration

```lua
require("pi").setup({
  -- Connection settings
  host = "127.0.0.1",
  port = 43863,
  auto_connect = false,
  
  -- UI settings
  auto_open_panel = true,
  auto_open_logs = false,
  panel_position = "top-right",
  
  -- Feature settings
  auto_stream_logs = true,
  approval_mode = true,
  watch_files = true,
  
  -- Display settings
  max_log_entries = 1000,
  log_format = "timestamp",
  
  -- Keymaps (set to false to disable)
  keymaps = {
    toggle_panel = "<leader>pt",
    toggle_logs = "<leader>pl",
    approve = "<leader>pa",
    reject = "<leader>pr",
  }
})
```

## Architecture

```
User Command → RPC Client → Pi Agent
                    ↓
            RPC Response/Event
                    ↓
            State Manager (single source of truth)
                    ↓
            Event System (notify listeners)
                    ↓
            UI Components (update displays)
```

## API

```lua
local pi = require("pi")

-- Initialize
pi.setup({ auto_connect = true })

-- Connection
pi.connect()
pi.disconnect()

-- Agent control
pi.start("Write a function to...")
pi.pause()
pi.resume()
pi.stop()

-- UI
require("pi.ui.control_panel").toggle()
require("pi.ui.logs_viewer").toggle()
require("pi.ui.diff_viewer").show("/path/to/file")

-- State
local state = require("pi.state")
state.update("agent.running", true)
local is_running = state.get("agent.running")

-- Events
local events = require("pi.events")
events.on("agent_started", function(data)
  print("Agent started!")
end)
```

## Troubleshooting

### "Not connected to agent" error
- Ensure Pi agent is running with RPC: `pi --rpc`
- Check the port matches (default: 43863)
- Try manually connecting: `:PiConnect`

### UI not updating
- Check that events are being emitted: `events.emit("state_updated", path, value)`
- Verify UI components subscribe to events: `events.on("state_updated", callback)`

### File changes not showing
- Ensure file watcher is active
- Check that the file is in the watched directory
- Verify approval mode is enabled

## License

MIT

## Contributing

Contributions welcome! Please read the [PLAN.md](PLAN.md) for the implementation roadmap.