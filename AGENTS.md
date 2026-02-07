# AGENTS.md - Pi.nvim Project Guide

## Project Overview

**pi.nvim** is a Neovim plugin that provides a native UI for the Pi coding agent. It uses Pi's RPC protocol for communication and provides real-time visualization of agent operations, file changes, and conversation history.

### Key Features
- Native RPC communication with Pi agent via TCP/JSON-RPC
- Real-time status panel and log streaming
- Side-by-side diff viewer for proposed changes
- File change approval/rejection workflow
- Session persistence and management
- Chat interface with the agent

---

## Working with This Project

### Project Structure

```
pi.nvim/
├── lua/pi/
│   ├── init.lua              # Main entry point
│   ├── state.lua             # Global state management
│   ├── events.lua            # Event system
│   ├── config.lua            # Configuration
│   ├── rpc/                  # RPC client and wrappers
│   │   ├── client.lua        # Core RPC client
│   │   ├── agent.lua         # Agent control methods
│   │   ├── files.lua         # File operations
│   │   ├── logs.lua          # Log streaming
│   │   ├── conversation.lua  # Chat interface
│   │   └── session.lua       # Session management
│   ├── ui/                   # UI components
│   │   ├── control_panel.lua # Status/control UI
│   │   ├── diff_viewer.lua   # Side-by-side diff
│   │   ├── logs_viewer.lua   # Structured log view
│   │   ├── chat.lua          # Conversation UI
│   │   ├── file_tree.lua     # File modification tree
│   │   └── approval.lua      # Approve/reject UI
│   └── watcher.lua           # File change monitoring
├── plugin/pi.lua             # Vim commands
└── doc/pi.txt                # Help documentation
```

---

## Task Tracking with PLAN.md

The `PLAN.md` file contains the complete implementation plan with **checkboxes** for tracking progress. **Always update these checklists as you work.**

### How to Use the Checklists

Each phase in PLAN.md has testing checklists like this:

```markdown
**Testing Checklist:**
- [ ] Can connect to Pi RPC server
- [ ] Handles connection failures gracefully
- [ ] Can send requests and receive responses
```

#### When Starting a Task:
1. **Read the relevant section** in PLAN.md
2. **Check if prerequisites are complete** - previous phase checkboxes should be checked
3. **Create/update the corresponding file(s)** in the lua/ directory
4. **Mark tasks in progress** by leaving them unchecked but noting progress

#### When Completing a Task:
1. **Test the implementation** against the checklist items
2. **Update PLAN.md** - change `[ ]` to `[x]` for completed items
3. **Commit your work** with a descriptive message
4. **Move to the next task** in the phase

#### Example Workflow:

```bash
# 1. Check current status in PLAN.md
# Look for unchecked items in the current phase

# 2. Implement the file
nvim lua/pi/rpc/client.lua
# ... write code based on PLAN.md examples ...

# 3. Test manually in Neovim
:lua require("pi.rpc.client").new({port=43863})

# 4. Update PLAN.md - mark checklist items complete
nvim PLAN.md
# Change: - [ ] Can connect to Pi RPC server
# To:     - [x] Can connect to Pi RPC server

# 5. Commit
git add lua/pi/rpc/client.lua PLAN.md
git commit -m "feat(rpc): implement client connection handling

- TCP socket connection to Pi RPC server
- JSON message parsing with buffering
- Request/response correlation with id tracking
- Event emission for server notifications

From PLAN.md Phase 1.1"
```

---

## Implementation Phases

Work through these phases **in order**. Each phase builds on the previous.

### Phase 1: Foundation (Week 1)
**Files to create:**
- `lua/pi/rpc/client.lua` - RPC client implementation
- `lua/pi/events.lua` - Event system
- `lua/pi/state.lua` - State management

**Key checklists in PLAN.md:**
- 1.1 Basic RPC Client testing checklist
- 1.2 Event System events list
- 1.3 State Management testing checklist

**Success criteria:**
- [ ] All three foundation files created and working
- [ ] Can connect/disconnect from Pi RPC
- [ ] Events propagate correctly
- [ ] State updates trigger UI notifications

---

### Phase 2: RPC Wrappers (Week 1-2)
**Files to create:**
- `lua/pi/rpc/agent.lua` - Agent control (start/pause/resume/stop)
- `lua/pi/rpc/files.lua` - File operations (read/write/list/stat)
- `lua/pi/rpc/logs.lua` - Log streaming
- `lua/pi/rpc/session.lua` - Session management
- `lua/pi/rpc/conversation.lua` - Chat interface

**Key checklists in PLAN.md:**
- Phase 2 testing checklist (after all wrapper sections)

**Success criteria:**
- [ ] All RPC wrappers implemented
- [ ] Each wrapper updates state correctly
- [ ] Errors are handled gracefully
- [ ] Events emitted for state changes

---

### Phase 3: Core UI Components (Week 2-3)
**Files to create:**
- `lua/pi/ui/control_panel.lua` - Floating status window
- `lua/pi/ui/diff_viewer.lua` - Side-by-side diff
- `lua/pi/ui/logs_viewer.lua` - Bottom panel for logs

**Key checklists in PLAN.md:**
- 3.1 Control Panel testing checklist
- (Diff viewer and logs viewer sections)

**Success criteria:**
- [ ] Control panel shows real-time status
- [ ] Diff viewer displays file changes
- [ ] Logs stream and auto-scroll
- [ ] All UI components can be toggled

---

### Phase 4: File Watching and Approval (Week 3-4)
**Files to create:**
- `lua/pi/watcher.lua` - File system watching
- `lua/pi/ui/approval.lua` - Approve/reject workflow

**Key checklists in PLAN.md:**
- 4.1 File Watcher (implicit)
- 4.2 Approval System testing checklist

**Success criteria:**
- [ ] File watcher detects external changes
- [ ] Approval queue manages multiple files
- [ ] Can approve/reject changes
- [ ] Approved changes are applied, rejected are discarded

---

### Phase 5: Integration and Polish (Week 4-5)
**Files to create:**
- `lua/pi/init.lua` - Main entry point with setup()
- `lua/pi/config.lua` - Configuration management
- `plugin/pi.lua` - Vim commands

**Key checklists in PLAN.md:**
- (No explicit checklist - ensure all prior checklists pass)

**Success criteria:**
- [ ] Plugin can be initialized with require("pi").setup()
- [ ] All commands work (:PiConnect, :PiStart, etc.)
- [ ] Configuration merges correctly
- [ ] Keymaps are set up properly

---

### Phase 6: Advanced Features (Week 5-6)
**Files to create:**
- `lua/pi/ui/chat.lua` - Chat interface
- `lua/pi/ui/file_tree.lua` - File modification tree

**Key checklists in PLAN.md:**
- 6.1 Chat Interface testing checklist
- 6.2 File Tree testing checklist

**Success criteria:**
- [ ] Chat interface works end-to-end
- [ ] File tree displays pending/modified files
- [ ] All UI components integrate smoothly

---

### Phase 7: Documentation (Week 6)
**Files to create:**
- `doc/pi.txt` - Vim help documentation
- `README.md` - User-facing documentation

**Key checklists in PLAN.md:**
- 7.1 Help Documentation
- 7.2 Testing Guide

**Success criteria:**
- [ ] All commands documented
- [ ] Configuration options documented
- [ ] API documented
- [ ] Tests exist for core functionality

---

## Important Technical Constraints

### 1. Never Block the Main Thread
- Always use callbacks for RPC operations
- Use `vim.schedule()` to update UI from callbacks
- **Example from PLAN.md:**
```lua
-- GOOD: Schedule UI update on main thread
vim.schedule(function()
  callback(message.result or message.error)
end)
```

### 2. Handle Partial JSON
- Buffer stdout data until complete JSON messages are received
- Split on newlines and parse individually
- **Implementation in:** `lua/pi/rpc/client.lua` `_handle_data()`

### 3. Clean Up Resources
- Close file watchers when done
- Stop RPC client on disconnect
- Remove event listeners when UI closes
- **Pattern:** Store unsubscribe functions and call them in close()

### 4. State Management Rules
- `state.lua` is the **single source of truth**
- Never mutate state directly - always use `state.update(path, value)`
- UI components subscribe to `state_updated` events
- State paths use dot notation: `"agent.running"`, `"files.pending"`

---

## RPC Protocol Reference

Pi uses JSON-RPC 2.0 over TCP on port 43863 (default).

### Connection
```
Host: 127.0.0.1
Port: 43863 (configurable)
Protocol: Line-delimited JSON-RPC
```

### Request Format
```json
{"jsonrpc":"2.0","id":1,"method":"agent.start","params":{"task":"..."}}
```

### Response Format
```json
{"jsonrpc":"2.0","id":1,"result":{"sessionId":"..."}}
```

### Event/Notification Format
```json
{"jsonrpc":"2.0","method":"logs.entry","params":{"timestamp":123,"message":"..."}}
```

**Methods implemented:**
- `agent.start`, `agent.pause`, `agent.resume`, `agent.stop`, `agent.status`
- `files.read`, `files.write`, `files.list`, `files.stat`
- `logs.stream`, `logs.stop`, `logs.history`
- `session.list`, `session.load`, `session.save`, `session.delete`, `session.current`
- `conversation.history`, `conversation.send`, `conversation.clear`

---

## Testing Your Changes

### Manual Testing Checklist

When implementing each component, verify:

1. **Connection:**
   ```vim
   :lua require("pi").connect()
   " Should show: "Pi: Connected to agent"
   ```

2. **Agent Control:**
   ```vim
   :PiStart "Write a function to calculate fibonacci"
   :PiPause
   :PiResume
   :PiStop
   ```

3. **UI Components:**
   ```vim
   :PiToggle     " Show/hide control panel
   :PiLogs       " Show/hide logs
   :PiDiff       " Show diff for current file
   ```

4. **Approval Workflow:**
   ```vim
   :PiApprove    " When changes are pending
   :PiReject     " When changes are pending
   ```

### Automated Testing

If adding tests to `tests/` directory:
```lua
-- tests/rpc/client_spec.lua
local client = require("pi.rpc.client")

describe("RPC Client", function()
  it("creates a new client", function()
    local c = client.new({ port = 43863 })
    assert.is_not_nil(c)
    assert.equals(43863, c.port)
  end)
end)
```

---

## Commit Message Guidelines

Prefix commits with the component and reference the PLAN.md phase:

```
feat(rpc): implement agent control methods

- Add start/pause/resume/stop wrappers
- Update state on each operation
- Emit appropriate events

Phase 2.1 from PLAN.md
```

**Prefixes:**
- `feat()` - New feature
- `fix()` - Bug fix
- `refactor()` - Code restructuring
- `docs()` - Documentation
- `test()` - Tests

**Components:**
- `rpc` - RPC client and wrappers
- `ui` - UI components
- `state` - State management
- `events` - Event system
- `config` - Configuration
- `plugin` - Vim commands

---

## Common Issues and Solutions

### Issue: "Not connected to agent" error
**Cause:** RPC client not connected or connection dropped
**Solution:**
```vim
:PiConnect
" Check if Pi agent is running on the configured port
```

### Issue: UI not updating
**Cause:** Event not being emitted or UI not subscribed
**Solution:**
- Verify `events.emit()` is called in the RPC wrapper
- Check that UI component calls `events.on("state_updated", ...)`
- Ensure `vim.schedule()` wraps UI updates

### Issue: Partial JSON errors
**Cause:** Not buffering incoming data properly
**Solution:**
- Check `_handle_data()` buffers until newline
- Verify JSON is valid before parsing

### Issue: File changes not showing in diff
**Cause:** File watcher not active or diff viewer not receiving content
**Solution:**
- Verify `watcher.watch(filepath)` is called
- Check that `files.read()` returns content correctly
- Ensure diff buffers are created with correct content

---

## Before Submitting Work

### Final Checklist
- [ ] All checkboxes for completed phases are marked in PLAN.md
- [ ] Code follows existing patterns in the project
- [ ] No blocking calls on main thread
- [ ] Error handling in place for all RPC calls
- [ ] UI components clean up resources on close
- [ ] Documentation updated if adding new commands or options
- [ ] Commit messages reference PLAN.md phases

### Verify Integration
```vim
" Full workflow test:
:PiConnect
:PiStart "Refactor the utils module"
:PiToggle    " Should show running status
:PiLogs      " Should stream logs
:PiApprove   " When changes appear
:PiStop
:PiDisconnect
```

---

## Resources

- **PLAN.md** - Complete implementation plan with code examples
- **Pi Documentation** - `/home/burden/.local/share/pnpm/global/5/.pnpm/@mariozechner+pi-coding-agent@*/node_modules/@mariozechner/pi-coding-agent/docs/`
- **Neovim Lua API** - https://neovim.io/doc/user/lua.html
- **libuv (vim.loop)** - https://docs.libuv.org/

---

## Questions?

If unsure about implementation details:
1. Check the PLAN.md code examples - they're production-ready
2. Look at existing implementations in the lua/pi/ directory
3. Follow the patterns established in Phase 1 for consistency
