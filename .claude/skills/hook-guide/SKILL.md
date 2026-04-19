---
name: hook-guide
description: "Notchikko hook system reference — the full event pipeline from CLI hook to Clawd animation. MUST use this skill when: adding/modifying hook events, changing the hook script (notchikko-hook.sh), editing ClaudeCodeAdapter event conversion, updating SessionManager event handling, adding approval tools, adding new CLI integrations, or touching any file in IPC/, Agent/, or Session/. Also use when the user mentions hooks, events, socket, approval flow, or agent adapters."
allowed-tools: Read Grep Glob Edit Write Bash
paths: "Notchikko/IPC/**,Notchikko/Agent/**,Notchikko/Session/**,Notchikko/Approval/**,Notchikko/Resources/notchikko-hook.sh"
---

# Notchikko Hook System

## Pipeline

```
CLI (Claude Code / Codex / Gemini CLI / Trae CLI)
  │  hook event (stdin JSON)
  ▼
notchikko-hook.sh [source]        ← Resources/notchikko-hook.sh
  │  Bash wrapper → inline Python3 (python3 -c "...")
  │  ⚠️ NEVER insert code with double quotes — breaks the bash wrapper
  │  Normalizes all CLI formats → unified Notchikko JSON
  │  Blocks on PermissionRequest only (not PreToolUse)
  ▼
Unix Socket /tmp/notchikko.sock   ← IPC/SocketServer.swift
  │  with request_id → onApprovalRequest (blocking, fd kept open)
  │  without request_id → onEvent (fire-and-forget, fd closed)
  ▼
ClaudeCodeAdapter                 ← Agent/ClaudeCodeAdapter.swift
  │  HookEvent → AgentEvent (+ synthetic sessionStart injection)
  ▼
SessionManager                    ← Session/SessionManager.swift
  │  AgentEvent → NotchikkoState
  ▼
ThemeProvider → NotchikkoView     ← SVG rendered in WKWebView
```

---

## Supported CLI Agents

### Claude Code 🤖
- **Config**: `~/.claude/settings.json`
- **Format**: JSON `{ "hooks": { "EventName": [{ "matcher": "*", "hooks": [{ "type": "command", "command": "...", "timeout": N }] }] } }`
- **Events**: SessionStart, SessionEnd, UserPromptSubmit, PreToolUse, PostToolUse, PostToolUseFailure, PreCompact, PostCompact, Stop, StopFailure, SubagentStart, SubagentStop, Notification, Elicitation, WorktreeCreate, PermissionRequest
- **Stdin key**: `hook_event_name`
- **Blocking events**: PermissionRequest (for approval + AskUserQuestion)
- **Approval response**: `{ "hookSpecificOutput": { "hookEventName": "PermissionRequest", "decision": { "behavior": "allow|deny" } } }`
- **AskUserQuestion response**: `{ "hookSpecificOutput": { "hookEventName": "PermissionRequest", "decision": { "behavior": "allow", "updatedInput": { "questions": [...], "answers": {"question": "selected_option"} } } } }`
- **Bypass mode**: `{ "decision": { "behavior": "allow", "updatedPermissions": [{ "type": "setMode", "mode": "bypassPermissions", "destination": "session" }] } }`
- **PermissionRequest timeout**: 86400s (24h) — must set explicitly, default is 600s
- **PermissionRequest matcher**: `"*"` required for AskUserQuestion to fire
- **Token usage**: Stop event has `transcript_path` — hook reads transcript tail for last assistant message `usage`

### OpenAI Codex 📦
- **Config**: `~/.codex/hooks.json` (NOT config.json!)
- **Format**: Same JSON structure as Claude Code
- **Events**: SessionStart, SessionEnd, UserPromptSubmit, PreToolUse, PostToolUse, Stop
- **Stdin key**: `hook_event_name`
- **Limitations**: PreToolUse only supports Bash tool interception; no PermissionRequest; no AskUserQuestion (`request_user_input` has no hook event yet)
- **Approval**: Not supported (no PermissionRequest event)

### Gemini CLI 💎
- **Config**: `~/.gemini/settings.json`
- **Format**: Same JSON structure as Claude Code
- **Events**: SessionStart, SessionEnd, BeforeAgent, BeforeTool, AfterTool, AfterAgent, Notification, PreCompress
- **Stdin key**: `hook_event_name`
- **Event name mapping** (Gemini → Notchikko internal):
  ```
  BeforeAgent  → UserPromptSubmit
  BeforeTool   → PreToolUse
  AfterTool    → PostToolUse
  AfterAgent   → Stop
  PreCompress  → PreCompact (but no PostCompact mapping — avoid sweeping stuck state)
  ```
- **Tool name mapping** (snake_case → PascalCase):
  ```
  read_file / read_many_files → Read
  write_file                  → Write
  replace                     → Edit
  run_shell_command           → Bash
  glob / list_directory       → Glob
  grep_search / search_file_content → Grep
  ask_user                    → AskUserQuestion
  google_web_search           → WebSearch
  web_fetch                   → WebFetch
  ```
- **Approval**: Not supported (no PermissionRequest equivalent)

### Trae CLI 🦎
- **Config**: `~/.trae/traecli.yaml`
- **Format**: YAML (separate parsing in HookInstaller)
- **Events**: session_start, session_end, user_prompt_submit, pre_tool_use, post_tool_use, post_tool_use_failure, pre_compact, post_compact, stop, subagent_start, subagent_stop, notification, permission_request
- **Stdin format**: Different from Claude Code! Uses `event_type` + nested body:
  ```json
  { "event_type": "pre_tool_use", "pre_tool_use": { "cwd": "...", "tool_name": "...", "tool_input": {...} } }
  ```
- **Session ID**: Uses real `session_id` from event body when available; falls back to `'trae-' + str(os.getppid())` for older builds
- **Approval**: Not supported (Trae CLI does not read hook stdout; `permission_request` fires as non-blocking notification only)

---

## Claude Code Hook Events — Complete Reference

### PreToolUse
- **Fires**: Before every tool execution (regardless of permission settings)
- **Matcher**: Tool name (`Bash`, `Edit`, `Write`, `Read`, `AskUserQuestion`, MCP tools, etc.)
- **Stdin**: `hook_event_name`, `session_id`, `cwd`, `tool_name`, `tool_input`, `tool_use_id`, `permission_mode`, `transcript_path`
- **Notchikko behavior**: Fire-and-forget (never blocks). Maps to `.toolUse(.pre)`. AskUserQuestion → `.notification` (non-blocking notification card)
- **Output**: `permissionDecision: "allow|deny|ask|defer"`, `updatedInput`, `additionalContext`
- **Precedence**: `deny > defer > ask > allow`

### PermissionRequest
- **Fires**: Only when Claude Code needs user confirmation (permission dialog about to show)
- **Matcher**: Tool name — `"*"` required for AskUserQuestion to trigger
- **Stdin**: `hook_event_name`, `session_id`, `cwd`, `tool_name`, `tool_input`, `permission_mode`, `permission_suggestions`
- **Timeout**: Default 600s for command hooks. **Must set to 86400 for interactive approval.**
- **Notchikko behavior**: Blocks. Generates `request_id`, sends to socket, waits for app response.
  - Approval tools (Bash/Edit/Write/NotebookEdit): Shows 4-button approval card
  - AskUserQuestion: Shows interactive option card with clickable buttons
- **Output**: `decision: { behavior: "allow|deny", updatedInput, updatedPermissions, message }`

### PostToolUse
- **Fires**: After tool succeeds
- **Stdin**: `tool_name`, `tool_input`, `tool_response`, `tool_use_id`
- **Notchikko behavior**: Maps to `.toolUse(.post(success: true))`

### PostToolUseFailure
- **Fires**: After tool fails
- **Stdin**: `tool_name`, `tool_input`, `tool_use_id`, `error`, `is_interrupt`
- **Notchikko behavior**: Maps to `.toolUse(.post(success: false))` → `error` state → returns to idle after 5s

### UserPromptSubmit
- **Fires**: When user submits a prompt
- **Stdin**: `prompt`
- **Notchikko behavior**: Maps to `.prompt` → `thinking` state

### Stop
- **Fires**: When Claude finishes responding
- **Stdin**: `transcript_path` (hook reads this for token usage extraction)
- **Notchikko behavior**: Maps to `.stop(usage:)` → `happy` state → 3s celebration → auto-switch session
- **Token extraction**: Hook reads last 64KB of transcript, finds last `assistant` message, extracts `usage.{input_tokens, output_tokens, cache_read_input_tokens, cache_creation_input_tokens}`

### SessionStart / SessionEnd
- **Notchikko behavior**: Session creation/destruction, terminal PID/tty/pidChain capture

### SubagentStart / SubagentStop
- **Notchikko behavior**: Silently dropped (return nil from `convert()`) to avoid affecting main Notchikko state

### Notification / Elicitation
- **Notchikko behavior**: Maps to `.notification`. Elicitation shows notification card. Empty Notification events ignored.

### PreCompact / PostCompact
- **Notchikko behavior**: PreCompact → `.compact` → `sweeping` state. PostCompact → `.prompt` → `thinking` state.

### WorktreeCreate
- **Notchikko behavior**: Maps to `.prompt` → `thinking` state

---

## Approval Flow (PermissionRequest path only)

```
PermissionRequest event fires
  │
  ▼ Hook script
  │ tool_name in approval_tools AND approval_enabled? → generates request_id, blocks
  │ tool_name == "AskUserQuestion"? → generates request_id, blocks
  │ Otherwise → fire-and-forget (no request_id)
  │
  ▼ SocketServer (request_id present → onApprovalRequest)
  │ Stores fd in pendingResponses[requestId]
  │
  ▼ AppDelegate.onApprovalRequest
  │ bypass mode? → auto-allow (respond + close fd)
  │ approvalCardEnabled off + not AskUser? → auto-allow
  │ Otherwise → ApprovalManager.handleApprovalRequest → showApprovalPanel
  │
  ▼ ApprovalCardView
  │ Approval tools: [Deny] [Allow Once] [Always Allow] [Auto Approve]
  │ AskUserQuestion: [Option A] [Option B] [Option C] ...
  │
  ▼ User clicks button
  │
  ▼ ApprovalManager sends response via SocketServer.respond()
  │ approve:         { decision: "allow" }
  │ deny:            { decision: "deny", reason: "..." }
  │ alwaysAllow:     { decision: "allow", allow_tool: "Write" }
  │ autoApprove:     { decision: "allow", bypass: true } (+ approve all pending)
  │ answerQuestion:  { answers: { "question text": "selected option" } }
  │
  ▼ Hook script reads response, outputs hookSpecificOutput
  │ approval:     { hookEventName: "PermissionRequest", decision: { behavior: "allow|deny" } }
  │ + alwaysAllow: { ..., decision: { behavior: "allow", updatedPermissions: [addRules: {toolName, ruleContent:"*"}, destination: "localSettings"] } }
  │ + autoApprove: { ..., decision: { behavior: "allow", updatedPermissions: [setMode: bypassPermissions, destination: "session"] } }
  │ askUser:      { ..., decision: { behavior: "allow", updatedInput: { questions, answers } } }
  │
  ▼ Claude Code receives, continues or stops
```

### Card Lifecycle
- Cards auto-hide after configurable delay (Settings → Approval → auto-hide delay)
- Fade out via `alphaValue` animation (0.25s), hover restores via `ApprovalTrackingView` NSTrackingArea (0.15s fade in)
- `onSessionEvent` only clears notification cards, not blocking approval cards
- Stale timer: 86400s (matches hook timeout), closes orphaned socket fds via `closePending()`

---

## Tool → State Mapping

`SessionManager.stateForTool(_:)`:

| Tool Names | State | SVG Dir |
|---|---|---|
| `Read`, `Grep`, `Glob` | `reading` | `reading/` |
| `Edit`, `Write`, `NotebookEdit` | `typing` | `typing/` |
| `Bash` | `building` | `building/` |
| All others (including MCP tools) | `typing` | `typing/` |

---

## Timer System

`resetTimers()` cancels **all three** timers (forgetting returnTimer causes error→idle override):

| Timer | Delay | Action |
|---|---|---|
| `idleTimer` | 60s | transition → `.idle` |
| `sleepTimer` | 120s | transition → `.sleeping` |
| `returnTimer` | 5s (error) or 3s (happy) | transition → `.idle` or auto-switch session |

---

## Data Formats

### CLI stdin → Hook script (Claude Code)
```json
{
  "hook_event_name": "PermissionRequest",
  "session_id": "abc-123",
  "cwd": "/path/to/project",
  "permission_mode": "default",
  "tool_name": "Bash",
  "tool_input": { "command": "npm test" },
  "permission_suggestions": [...]
}
```

### Hook script → Socket (maps to HookEvent in Swift)
```json
{
  "session_id": "abc-123",
  "cwd": "/path/to/project",
  "event": "PermissionRequest",
  "status": "permission_request",
  "tool": "Bash",
  "tool_input": { "command": "npm test" },
  "source": "claude-code",
  "permission_mode": "default",
  "request_id": "uuid (only for blocking requests)",
  "terminal_pid": 12345,
  "terminal_tty": "/dev/ttys001",
  "pid_chain": [12345, 12344, 12343],
  "usage": { "input_tokens": 100, "output_tokens": 50, "cache_read": 1000, "cache_creation": 500 }
}
```

---

## Adding a New CLI Integration — Checklist

1. **`HookInstaller.supportedCLIs`**: Add `CLIHookConfig` with name, displayName, icon, settingsPath, hookEvents, configFormat
2. **Hook script**: If event names differ from Claude Code, add a mapping dict (see `GEMINI_EVENT_MAP`, `GEMINI_TOOL_MAP`). If stdin format is completely different, add a new source branch (see Trae CLI section)
3. **`CLIHookConfig.metadata(for:)`** automatically picks up the new agent's icon/name from supportedCLIs

### Config paths for each CLI
| CLI | Config Path | Format |
|---|---|---|
| Claude Code | `~/.claude/settings.json` | JSON |
| Codex | `~/.codex/hooks.json` | JSON |
| Gemini CLI | `~/.gemini/settings.json` | JSON |
| Trae CLI | `~/.trae/traecli.yaml` | YAML |

---

## Adding a New Approval Tool

1. **Hook script**: Add tool name to `approval_tools` set (line ~262)
2. That's it — the rest of the pipeline is tool-agnostic

---

## Key Files

| File | Role |
|---|---|
| `Resources/notchikko-hook.sh` | Hook script (bash + inline Python3) — **never add double-quoted code** |
| `IPC/SocketServer.swift` | Unix socket server, pending approval fds, `closePending()` for stale cleanup |
| `IPC/HookInstaller.swift` | Registers hooks in CLI config files, `matcher: "*"` + `timeout: 86400` for PermissionRequest |
| `Agent/AgentEvent.swift` | `HookEvent` (wire format with `TokenUsage`), `AgentEvent` (app model), `ToolPhase` |
| `Agent/ClaudeCodeAdapter.swift` | HookEvent → AgentEvent conversion, AskUserQuestion/PermissionRequest detail extraction |
| `Session/SessionManager.swift` | Event → state machine, multi-session tracking (working-first priority), 3 timers |
| `Notchikko/NotchikkoState.swift` | 11 states with revealAmount and soundKey |
| `Approval/ApprovalManager.swift` | Pending requests, `alwaysAllowTool`/`autoApproveSession` with bypass, `answerQuestion`, `parseQuestions` |
| `Approval/ApprovalCardView.swift` | 4-button approval card + AskUserQuestion option buttons |
| `App/AppDelegate.swift` | Wires all callbacks, `showApprovalPanel` with `ApprovalTrackingView` for hover |
