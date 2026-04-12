---
name: hook-guide
description: "Notchikko hook system reference — the full event pipeline from CLI hook to Clawd animation. MUST use this skill when: adding/modifying hook events, changing the hook script (notchikko-hook.sh), editing ClaudeCodeAdapter event conversion, updating SessionManager event handling, adding approval tools, adding new CLI integrations, or touching any file in IPC/, Agent/, or Session/. Also use when the user mentions hooks, events, socket, approval flow, or agent adapters."
---

# Notchikko Hook System

This skill contains the complete reference for the event-driven pipeline that connects CLI agent hooks to Clawd's animation states.

## Pipeline

```
CLI (Claude Code / Codex)
  │  hook event
  ▼
notchikko-hook.sh [source]        ← Resources/notchikko-hook.sh
  │  Python3 inline: reads stdin JSON, maps event, sends to socket
  ▼
Unix Socket /tmp/notchikko.sock   ← IPC/SocketServer.swift
  │
  ▼
ClaudeCodeAdapter                 ← Agent/ClaudeCodeAdapter.swift
  │  HookEvent → AgentEvent (+ synthetic sessionStart injection)
  ▼
SessionManager                    ← Session/SessionManager.swift
  │  AgentEvent → NotchikkoState (priority-based transitions)
  ▼
ThemeProvider → NotchikkoView     ← SVG rendered in WKWebView
```

## All 16 Hook Events

| Hook Event | status_map value | AgentEvent | NotchikkoState | SVG Dir |
|---|---|---|---|---|
| `SessionStart` | `waiting_for_input` | `.sessionStart` | `idle` | `idle/` |
| `SessionEnd` | `ended` | `.sessionEnd` | `sleeping` | `sleeping/` |
| `UserPromptSubmit` | `processing` | `.prompt` | `thinking` | `thinking/` |
| `PreToolUse` | `running_tool` | `.toolUse(.pre)` | by tool* | by tool* |
| `PostToolUse` | `processing` | `.toolUse(.post(true))` | `thinking` | `thinking/` |
| `PostToolUseFailure` | `error` | `.toolUse(.post(false))` | `error` | `error/` |
| `PreCompact` | `compacting` | `.compact` | `sweeping` | `sweeping/` |
| `PostCompact` | `processing` | `.prompt` | `thinking` | `thinking/` |
| `Stop` | `waiting_for_input` | `.stop` | `happy` | `happy/` |
| `StopFailure` | `error` | `.error` | `error` | `error/` |
| `SubagentStart` | `subagent_start` | `.prompt` | `thinking` | `thinking/` |
| `SubagentStop` | `subagent_stop` | `.stop` | `happy` | `happy/` |
| `Notification` | `notification` | `.notification` | (unchanged) | - |
| `Elicitation` | `elicitation` | `.notification` | (unchanged) | - |
| `WorktreeCreate` | `worktree_create` | `.prompt` | `thinking` | `thinking/` |
| `PermissionRequest` | `permission_request` | `.notification` | (unchanged) | - |

*PreToolUse maps by tool name — see next section.

## Tool → State Mapping

`SessionManager.stateForTool(_:)`:

| Tool Names | State | SVG Dir |
|---|---|---|
| `Read`, `Grep`, `Glob` | `reading` | `reading/` |
| `Edit`, `Write`, `NotebookEdit` | `typing` | `typing/` |
| `Bash` | `building` | `building/` |
| All others | `typing` | `typing/` |

## State Priority & Transitions

`SessionManager.transition(to:)` only accepts a new state if its priority > current, OR current is `idle`/`sleeping`. This prevents low-priority events from interrupting important animations.

```
sleeping(10) < idle(20) < thinking(50) < sweeping(53) < reading(55)
< typing(60) < building(70) < happy(80) < error(90) < approving(95) < dragging(100)
```

Auto-return timers: error → idle after 5s, happy → auto-switch session after 3s, any → idle after 60s, any → sleeping after 120s.

## Approval Flow

Only for modification tools: `Bash`, `Edit`, `Write`, `NotebookEdit`.

1. Hook script checks `skipDangerousModePermissionPrompt` in `~/.claude/settings.json` — if true, skips approval entirely
2. Hook script generates UUID `request_id`, adds it to the JSON payload
3. Sends to socket and blocks waiting for response (5 min timeout, default allow)
4. `SocketServer` keeps the client fd open in `pendingResponses[requestId]`
5. `SocketServer.onApprovalRequest` → `ApprovalManager.handleApprovalRequest` → shows `ApprovalCardView`
6. State → `.approving` (priority 95, high reveal)
7. User clicks Allow/Deny or presses `⌘Y`/`⌘N`
8. `ApprovalManager.approve()/deny()` → `SocketServer.respond(requestId:json:)` writes back JSON and closes fd
9. Hook script reads response, outputs to stdout for CLI consumption

## Data Formats

### CLI stdin → Hook script
```json
{
  "hook_event_name": "PreToolUse",
  "session_id": "abc-123",
  "cwd": "/path/to/project",
  "tool_name": "Bash",
  "tool_input": { "command": "npm test" }
}
```

### Hook script → Socket (maps to HookEvent in Swift)
```json
{
  "session_id": "abc-123",
  "cwd": "/path/to/project",
  "event": "PreToolUse",
  "status": "running_tool",
  "tool": "Bash",
  "tool_input": { "command": "npm test" },
  "source": "claude-code",
  "request_id": "uuid (only for approval requests)"
}
```

### Approval response
```json
{"decision": "allow"}
{"decision": "deny", "reason": "Denied by Notchikko"}
```

## Adding a New Hook Event — Checklist

1. **`notchikko-hook.sh`**: add entry to `status_map` dict
2. **`HookInstaller.supportedCLIs`**: add event name to the `hookEvents` array for each CLI that supports it
3. **`ClaudeCodeAdapter.convert()`**: add `case` to map the event string → `AgentEvent`
4. **`SessionManager.handleEvent()`**: add `case` to handle the `AgentEvent` and set appropriate `NotchikkoState`
5. If it needs a new visual state: add case to `NotchikkoState` enum (svgName, revealAmount, priority, soundKey) and create SVG directory in `Resources/themes/clawd/{state}/`

## Adding a New Approval Tool

1. **`notchikko-hook.sh`**: add tool name to `approval_tools` set
2. That's it — the rest of the approval pipeline is tool-agnostic

## Adding a New CLI Integration

1. Add `CLIHookConfig` entry to `HookInstaller.supportedCLIs` with the CLI's settings path and supported hook events
2. Optionally create a new `AgentBridge` implementation if the CLI uses a different protocol than hooks (currently all CLIs use the same hook script)
3. The hook script accepts a `source` argument (`notchikko-hook.sh codex`) which gets forwarded as `source` in the JSON payload

## Key Files

| File | Role |
|---|---|
| `Resources/notchikko-hook.sh` | Hook script (bash + inline Python3) |
| `IPC/SocketServer.swift` | Unix socket server, manages pending approval fds |
| `IPC/HookInstaller.swift` | Registers hooks in CLI settings files |
| `Agent/AgentEvent.swift` | `HookEvent` (wire format), `AgentEvent` (app model), `ToolPhase` |
| `Agent/ClaudeCodeAdapter.swift` | HookEvent → AgentEvent conversion + synthetic session injection |
| `Agent/AgentBridge.swift` | Protocol for agent adapters |
| `Agent/AgentRegistry.swift` | Merges multiple adapter streams via TaskGroup |
| `Session/SessionManager.swift` | Event → state machine, multi-session tracking, timers |
| `Notchikko/NotchikkoState.swift` | 11 states with priority, svgName, revealAmount, soundKey |
| `Approval/ApprovalManager.swift` | Manages pending approval requests |
| `Approval/ApprovalCardView.swift` | SwiftUI approval card UI |
