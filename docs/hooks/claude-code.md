# Claude Code

Claude Code is the reference target. Its hook system is the richest of the four agents, is the only one with a first-class approval contract, and is the shape all other integrations are normalized toward.

## Hook contract (upstream)

Claude Code fires hook commands at well-defined lifecycle points. Each invocation:

- Runs the configured shell command with the event's JSON on stdin.
- Reads stdout for a structured `hookSpecificOutput` decision object.
- Honors a `timeout` field on the hook entry. Default is **600s** for `type: command` hooks (per [upstream docs](https://code.claude.com/docs/en/hooks)); `PermissionRequest` entries explicitly override to `86400` (24h) so the user has all day to answer an approval card.

### Events Notchikko registers for

From `CLIHookConfig.supportedCLIs` (Claude Code entry):

```
SessionStart, SessionEnd,
UserPromptSubmit,
PreToolUse, PostToolUse, PostToolUseFailure,
PreCompact, PostCompact,
Stop, StopFailure,
SubagentStart, SubagentStop,
Notification, Elicitation,
WorktreeCreate, PermissionRequest
```

Sixteen events. Most are purely informational. The only one that **blocks** the CLI while Claude Code waits for a decision is `PermissionRequest`.

### Incoming JSON shape (partial)

Claude Code sends fields like:

| Field | Purpose |
|---|---|
| `session_id` | UUID, stable within a `claude` invocation |
| `cwd` | Absolute path |
| `hook_event_name` | One of the registered event names |
| `tool_name`, `tool_input` | For `PreToolUse` / `PostToolUse` / `PermissionRequest` |
| `permission_mode` | `default` / `bypassPermissions` / `acceptEdits` / `plan` |
| `transcript_path` | Path to the session's JSONL transcript (used to extract token usage) |
| `prompt` | Text of the user's submitted prompt |

### Blocking semantics

For `PermissionRequest`, Claude Code reads the hook's stdout and respects:

```json
{"hookSpecificOutput": {
  "hookEventName": "PermissionRequest",
  "decision": {"behavior": "allow" | "deny",
               "updatedInput": {...},         // optional, overrides tool_input
               "updatedPermissions": [...]}   // optional, persistent rule changes
}}
```

Note the **two distinct output schemas** Claude Code understands — do not confuse them:

| Event | Output key | Values |
|---|---|---|
| `PermissionRequest` | `decision.behavior` | `"allow"` / `"deny"` (two-valued) |
| `PreToolUse` | `permissionDecision` | `"allow"` / `"deny"` / `"ask"` / `"defer"` (four-valued) |

Notchikko only writes the `PermissionRequest` shape. `PreToolUse` exists in the same pipeline but Notchikko never uses its stdout decision — see [README §"PreToolUse is NOT an approval gate"](./README.md#pretooluse-is-not-an-approval-gate).

If the hook exits non-zero or prints garbage, Claude Code falls back to its **built-in in-terminal prompt** — the yellow "Do you want to proceed?" UI that asks the user in the CLI directly. This is the mechanism that caused the "card stays until end of task" bug: if the user answers in the terminal, Claude Code proceeds; the hook is still blocked on socket read; Notchikko's card is stuck until the hook process eventually dies.

## Config registration

Notchikko writes into `~/.claude/settings.json` under the `hooks` key. Claude Code's config format is *nested*:

```jsonc
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "*",                 // tool filter; "*" = all tools
        "hooks": [
          {"type": "command",
           "command": "/Users/you/.notchikko/hooks/notchikko-hook.sh claude-code"}
        ]
      }
    ],
    "PermissionRequest": [
      {
        "matcher": "*",
        "hooks": [
          {"type": "command",
           "command": "/Users/you/.notchikko/hooks/notchikko-hook.sh claude-code",
           "timeout": 86400}             // 24h — must outlast user's lunch break
        ]
      }
    ]
    // ... one entry per hookEvents[] item
  }
}
```

Two things to note:

- Every registration passes the **literal string `claude-code`** as the hook's first argument. The Python script's `source = sys.argv[1]` branch is how Notchikko distinguishes which CLI fired the hook — Claude Code itself has no idea.
- The `timeout: 86400` is specific to `PermissionRequest`. All other events use Claude Code's default (short). A 24h timeout means the hook process is patient enough to outlast a user who walked away; the app-side stale timer (`ApprovalManager.staleTimeout = 86400`) is aligned with it.

### Idempotent install

`HookInstaller.installJSON` checks each existing entry for the substring `notchikko` before appending, so repeated `Settings → Install` clicks don't create duplicate registrations.

## Notchikko's per-event handling

The Python hook (`handle_standard` path) maps `hook_event_name` → `status`:

| `hook_event_name` | Notchikko `status` | Downstream effect |
|---|---|---|
| `SessionStart` | `waiting_for_input` | Session added, pet state = `idle` |
| `SessionEnd` | `ended` | Session marked ended, eventually removed |
| `UserPromptSubmit` | `processing` | Pet → `thinking`; prompt text cached for menu |
| `PreToolUse` | `running_tool` | Pet → `reading` / `typing` / `building` by tool class |
| `PostToolUse` | `processing` | Pet returns to `thinking` |
| `PostToolUseFailure` | `error` | Pet → `error`, 5s auto-return timer |
| `PreCompact` / `PostCompact` | `compacting` / `processing` | Pet → `sweeping` and back |
| `Stop` | `waiting_for_input` | 3s celebration (`happy`) then return |
| `StopFailure` | `error` | Same as `PostToolUseFailure` |
| `Notification` / `Elicitation` | `notification` / `elicitation` | Pet → `approving`, non-blocking card |
| `PermissionRequest` | `permission_request` | Blocking approval card |
| `SubagentStart` / `SubagentStop` | (tracked, events dropped) | See below |
| `WorktreeCreate` | `worktree_create` | Purely informational |

### SubagentStart / SubagentStop — why they're dropped

Claude Code's subagents fire their own `PreToolUse` / `PostToolUse` events, which would cause the main pet to thrash while a subagent grinds. `ClaudeCodeAdapter` maintains a per-session `subagentDepth` counter; while depth > 0, tool events are suppressed. The passthrough set (`subagentPassthroughEvents` in `ClaudeCodeAdapter.swift`) is `{"Elicitation", "AskUserQuestion"}`. `Elicitation` is the one that actually fires — `AskUserQuestion` is defensive: Claude Code never delivers it as a top-level `hook_event_name` (questions arrive wrapped inside `PreToolUse` or `PermissionRequest` with `tool_name == "AskUserQuestion"`), so the passthrough entry is effectively dead code we keep in case upstream ever starts emitting it directly.

### Tool → pet-state mapping

```
Read, Grep, Glob         → reading
Edit, Write, NotebookEdit → typing
Bash                      → building
(any other)               → typing
```

Non-tool phases (`processing` → `thinking`, `compacting` → `sweeping`) are handled separately in `SessionManager`.

## Approval flow

Only `PermissionRequest` blocks. The hook:

1. Checks the app's `approvalCardEnabled` preference. If off, the hook **does not block** on Bash/Edit/Write/NotebookEdit — it sends the event fire-and-forget and exits, letting Claude Code fall back to its in-terminal prompt. `AskUserQuestion` still blocks regardless of this toggle (it's a user-input channel, not a policy gate).
2. Generates a UUID `request_id`.
3. Sends `{event: "PermissionRequest", tool, tool_input, request_id, ...}` over the socket.
4. Keeps the socket fd open, waits up to **3600s client-side** for the app's JSON response. The hook entry declares **86400s (24h)** to Claude Code — so the two numbers diverge: if the user ignores a card for more than an hour, the hook's own socket timeout fires first, `emit_fallback_allow()` prints `{behavior: "allow"}`, the tool proceeds silently, and Claude Code never hits its 24h limit. If you want the full 24h to actually be honored, bump the client-side `sock.settimeout(3600)` in `notchikko-hook.py` to match.
5. Translates the response into the `hookSpecificOutput.decision` format and prints to stdout.

### Response shapes Notchikko sends

| User action | Hook response → Claude Code decision |
|---|---|
| **Allow once** | `{behavior: "allow"}` |
| **Deny** | `{behavior: "deny", reason: "Denied by Notchikko"}` |
| **Always allow** | `{behavior: "allow", updatedPermissions: [{type: "addRules", rules: [{toolName, ruleContent: "*"}], behavior: "allow", destination: "localSettings"}]}` — writes to `.claude/settings.local.json` |
| **Auto approve (rest of session)** | `{behavior: "allow", updatedPermissions: [{type: "setMode", mode: "bypassPermissions", destination: "session"}]}` — switches the whole session to `--dangerously-skip-permissions` |

### AskUserQuestion

When `PermissionRequest` carries `tool_name: "AskUserQuestion"`, the card shows buttons for each option. On click, Notchikko sends `{answers: {question: selected}}`, and the hook rewrites it as `decision: {behavior: "allow", updatedInput: {..., answers}}`.

### Why approval cards can go stale

Three independent paths can leave a card visible after the approval has effectively been resolved elsewhere:

- User answers in Claude Code's built-in terminal prompt → tool runs → `PostToolUse` fires → but the hook is still blocked on socket read, and Notchikko doesn't know the approval happened. Mitigated by dismissing the card when a matching-tool `PostToolUse` arrives for the same session (`AppDelegate.handleAgentEvent` → `ApprovalManager.dismissStaleApprovals(for:tool:)`).
- User starts a new prompt / kills the session → `Stop`, `SessionEnd`, `prompt` events → `dismissStaleApprovals(for: session)`.
- Hook process truly dies (crash, CLI quit) → `SocketServer.onDisconnect` → `dismissOnDisconnect`.

## Token usage

On `Stop`, the hook reads the tail ~64KB of `transcript_path` (JSONL), finds the last `type: "assistant"` entry with a `usage` object, and forwards it. Notchikko caches it per session for menu display and token totals in the pet right-click menu.

## Caveats

- **Transcript-only CLIs lose PermissionRequest.** If hooks aren't installed, `TranscriptPoller` can reconstruct tool calls from JSONL but not approval prompts — because the approval never appears in the transcript. A user with no hooks gets a visible-but-passive pet.
- **`permission_mode` is advisory.** The hook reads `permission_mode` from the incoming event to decide whether to skip blocking (bypass means no card). But Claude Code might change modes mid-session; the next `PermissionRequest` reflects the new mode.
- **Session ID is Claude Code's notion of session.** If the user runs `/clear`, Claude Code may reuse the session; the pet stays on the same session row.
