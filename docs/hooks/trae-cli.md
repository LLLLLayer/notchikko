# Trae CLI

Trae CLI (a.k.a. Coco) uses **YAML** (not JSON), a **nested event-body** payload shape, and **snake_case event names**. The integration handles all of this with a dedicated Python path (`handle_trae_cli`) that normalizes the payload before feeding it into the standard pipeline.

## Hook contract

Config file: `~/.trae/traecli.yaml`. Trae CLI reads hooks from YAML, not JSON, and groups multiple event matchers under a single hook entry:

```yaml
hooks:
  - type: command
    command: '/Users/you/.notchikko/hooks/notchikko-hook.sh trae-cli'
    matchers:
      - event: session_start
      - event: session_end
      - event: user_prompt_submit
      - event: pre_tool_use
      - event: post_tool_use
      - event: post_tool_use_failure
      - event: pre_compact
      - event: post_compact
      - event: stop
      - event: subagent_start
      - event: subagent_stop
      - event: notification
      - event: permission_request
```

One hook block, thirteen events, all routing to the same command.

### Events Notchikko registers for

```
session_start, session_end,
user_prompt_submit,
pre_tool_use, post_tool_use, post_tool_use_failure,
pre_compact, post_compact,
stop,
subagent_start, subagent_stop,
notification, permission_request
```

Full parity with Claude Code's lifecycle surface (minus `Elicitation` and `WorktreeCreate` which Trae CLI does not expose).

### JSON payload shape

Unlike Claude Code / Codex / Gemini, Trae CLI wraps the event body under a key named after the event:

```jsonc
// What arrives on stdin for a pre_tool_use event:
{
  "event_type": "pre_tool_use",
  "pre_tool_use": {
    "cwd": "/Users/you/project",
    "tool_name": "bash",
    "tool_input": {...},
    "prompt": "..."            // only on user_prompt_submit
  }
}
```

Not a flat top-level object. The Python hook's `handle_trae_cli` indexes into `input_data[event_type]` to get the body.

### Event name translation

`TRAE_EVENT_MAP` normalizes snake_case Trae CLI events to PascalCase Notchikko events:

| Trae event | Normalized to | Status |
|---|---|---|
| `session_start` | `SessionStart` | `waiting_for_input` |
| `session_end` | `SessionEnd` | `ended` |
| `user_prompt_submit` | `UserPromptSubmit` | `processing` |
| `pre_tool_use` | `PreToolUse` | `running_tool` |
| `post_tool_use` | `PostToolUse` | `processing` |
| `post_tool_use_failure` | `PostToolUseFailure` | `error` |
| `pre_compact` | `PreCompact` | `compacting` |
| `post_compact` | `PostCompact` | `processing` |
| `stop` | `Stop` | `waiting_for_input` |
| `subagent_start` | `SubagentStart` | `subagent_start` |
| `subagent_stop` | `SubagentStop` | `subagent_stop` |
| `notification` | `Notification` | `notification` |
| `permission_request` | `PermissionRequest` | `permission_request` |

Events outside this map exit 0 silently.

### Session ID

Trae CLI may provide a `session_id` in the event body (e.g. from `session_start`). When available, the hook uses it directly. When absent (older Trae CLI builds), the hook fabricates one from the parent PID:

```python
session_id = event_body.get("session_id", "") or f"trae-{os.getppid()}"
```

The PPID is the `coco` / `traecli` process, which is stable for the duration of a single CLI invocation. Reusing the same terminal for a second Trae CLI run will produce a different PPID, so sessions stay distinct.

### Non-blocking contract

Trae CLI's hook system is **non-blocking** — hooks run as side-effects and Trae CLI does not read hook stdout. This means `permission_request` fires as a **notification only**; Notchikko cannot send an approval decision back to Trae CLI the way it does for Claude Code's blocking `PermissionRequest`.

The hook sends all events as fire-and-forget:

```python
sock.sendall(json.dumps(output).encode())
sock.close()
```

No `request_id`, no waiting, no stdout decision.

## Config registration

Because the config format is YAML, the install path is the only one in `HookInstaller` that uses `installYAML` instead of `installJSON`. The installer:

1. Reads existing YAML as a string (not parsed — avoids a YAML dependency).
2. Checks for the literal substring `notchikko`; if present, skip (idempotent).
3. If the file already has a top-level `hooks:` key, finds the end of the hooks list and inserts the new entry there (not at the end of the file).
4. Otherwise appends a whole `hooks:` block at the end.

The whole install is string-concatenation, which means the resulting YAML is *correct but not re-parsed*. If upstream Trae CLI changes its YAML schema in a breaking way, the install will silently produce a file Trae no longer reads.

## Notchikko's per-event handling

After `handle_trae_cli` reshapes the payload into Notchikko's unified schema, the event looks exactly like a Claude Code event and flows through `SocketServer` → `ClaudeCodeAdapter` unchanged:

- `session_start` → creates session with real `session_id` if available; eliminates the need for synthetic session injection.
- `session_end` → proper session cleanup, timer cancellation.
- `user_prompt_submit` → `thinking` state.
- `pre_tool_use` → Notchikko transitions based on tool-class mapping (`bash` → `building`, `read` → `reading`, etc.).
- `post_tool_use` → returns to `thinking`.
- `post_tool_use_failure` → `error` state → returns to idle after 5s.
- `pre_compact` → `sweeping` state.
- `post_compact` → `thinking` state.
- `stop` → 3s celebration then idle (no token usage because Trae CLI doesn't ship `transcript_path`).
- `subagent_start` / `subagent_stop` → subagent depth tracking in `ClaudeCodeAdapter`. With both events now registered, the mute logic for subagent tool events works correctly.
- `notification` → shows notification card if message is non-empty.
- `permission_request` → shows a non-blocking `.permissionRequest` notification (no approval card since stdout is not read).

### Terminal detection

Trae CLI events still benefit from `detect_terminal_info()` in the hook — the PPID-walking code runs regardless of `source`. The `terminal_pid` / `pid_chain` / `terminal_tty` are attached to every Trae event, so Notchikko's click-to-jump and VS Code tab focus work for Trae sessions when the CLI is running under a recognized terminal.

## Caveats

- **No token usage.** Without `transcript_path` or any equivalent, the menu shows no token stats for Trae sessions.
- **No blocking approval.** Trae CLI does not read hook stdout, so `permission_request` can only drive a visual notification — not an interactive approval card with allow/deny actions. If Trae CLI adds stdout-reading in the future, `handle_trae_cli` would need to grow a blocking branch mirroring `handle_blocking_response`.
- **YAML installer is deliberately primitive.** It does not understand YAML — it manipulates text. Hand-edited `traecli.yaml` files with unusual indentation may end up with valid but ugly diffs after Notchikko installs.
- **Session ID fallback.** When `session_id` is not provided by Trae CLI, the PPID hack means that if Trae CLI re-execs internally, the "session" will flip. In practice the approximation is good enough.
