# Trae CLI

Trae CLI (a.k.a. Coco) is the outlier among the four agents. Its hook system uses **YAML** (not JSON), a **nested event-body** payload shape, **snake_case event names**, and does **not emit a session ID**. The integration handles all of this with a dedicated Python path (`handle_trae_cli`) that sidesteps the standard pipeline entirely.

> **Integration-source disclaimer.** The public [`bytedance/trae-agent`](https://github.com/bytedance/trae-agent) repo (as of 2026-04) documents configuration via `trae_config.yaml` and does not mention a hook system, `traecli.yaml`, `event_type`, or `pre_tool_use` / `post_tool_use` events anywhere in its README or linked docs. The contract documented below was reverse-engineered from runtime payloads observed against the ByteDance internal Trae / Coco build that Notchikko was integrated with. If the public build differs, this page is the one that's wrong — the hook script is authoritative either way.

## Hook contract (as integrated)

Config file: `~/.trae/traecli.yaml`. Trae CLI reads hooks from YAML, not JSON, and groups multiple event matchers under a single hook entry:

```yaml
hooks:
  - type: command
    command: '/Users/you/.notchikko/hooks/notchikko-hook.sh trae-cli'
    matchers:
      - event: user_prompt_submit
      - event: pre_tool_use
      - event: post_tool_use
      - event: stop
      - event: subagent_stop
```

One hook block, five events, all routing to the same command.

### Events Notchikko registers for

```
user_prompt_submit,
pre_tool_use, post_tool_use,
stop, subagent_stop
```

No session-lifecycle events (`SessionStart`/`SessionEnd`) because Trae CLI doesn't emit them. No `PermissionRequest`. No compaction events. No notification channel.

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

`TRAE_EVENT_MAP` mirrors Gemini's approach but is much smaller:

| Trae event | Normalized to | Status |
|---|---|---|
| `user_prompt_submit` | `UserPromptSubmit` | `processing` |
| `pre_tool_use` | `PreToolUse` | `running_tool` |
| `post_tool_use` | `PostToolUse` | `processing` |
| `stop` | `Stop` | `waiting_for_input` |
| `subagent_stop` | `SubagentStop` | `subagent_stop` |

Events outside this map exit 0 silently.

### No `session_id`

This is the biggest semantic gap. Trae CLI does not tell the hook which session the event belongs to. The Python hook fabricates one:

```python
session_id = f"trae-{os.getppid()}"
```

The parent PID is the `coco` / `traecli` process, which is stable for the duration of a single CLI invocation. Reusing the same terminal for a second Trae CLI run will produce a different PPID, so sessions stay distinct — but if Trae CLI re-execs internally, the "session" will flip. In practice the approximation is good enough for the pet.

### No blocking

None of Trae CLI's hook events are documented as blocking, and the hook doesn't even attempt it:

```python
# Trae CLI 不支持审批阻塞，直接发送
sock.sendall(json.dumps(output).encode())
sock.close()
```

The socket is opened, the event is sent, the socket is closed immediately — no `request_id`, no waiting, no stdout decision. Trae CLI has no permissions surface Notchikko can plug into.

## Config registration

Because the config format is YAML, the install path is the only one in `HookInstaller` that uses `installYAML` instead of `installJSON`. The installer:

1. Reads existing YAML as a string (not parsed — avoids a YAML dependency).
2. Checks for the literal substring `notchikko`; if present, skip (idempotent).
3. If the file already has a top-level `hooks:` key, append a new hook entry under it.
4. Otherwise append a whole `hooks:` block at the end.

The whole install is string-concatenation, which means the resulting YAML is *correct but not re-parsed*. If upstream Trae CLI changes its YAML schema in a breaking way, the install will silently produce a file Trae no longer reads.

## Notchikko's per-event handling

After `handle_trae_cli` reshapes the payload into Notchikko's unified schema, the event looks exactly like a Claude Code event and flows through `SocketServer` → `ClaudeCodeAdapter` unchanged:

- `pre_tool_use` → pet transitions based on tool-class mapping (`bash` → `building`, `read` → `reading`, etc.).
- `post_tool_use` → returns to `thinking`.
- `stop` → 3s celebration then idle (no token usage because Trae CLI doesn't ship `transcript_path`).
- `subagent_stop` → decrements `subagentDepth` in `ClaudeCodeAdapter`. Note: the matching `SubagentStart` is *not* registered on Trae CLI's side (it doesn't emit one), so the depth counter is never actually incremented — subagent_stop is effectively a no-op safety net.

### Terminal detection

Trae CLI events still benefit from `detect_terminal_info()` in the hook — the PPID-walking code runs regardless of `source`. The `terminal_pid` / `pid_chain` / `terminal_tty` are attached to every Trae event, so the pet's click-to-jump and VS Code tab focus work for Trae sessions when the CLI is running under a recognized terminal.

## Caveats

- **No session lifecycle.** Notchikko synthesizes `SessionStart` on the first event for an unknown session (via `ClaudeCodeAdapter.knownSessions`) and relies on the PPID trick for session IDs. When the Trae CLI process exits, Notchikko has no signal — the session sits idle until the 60s / 120s timers transition it to `sleeping`, and is eventually evicted by LRU.
- **No token usage, ever.** Without `transcript_path` or any equivalent, the menu shows no token stats for Trae sessions.
- **No approval cards.** Same as Gemini / Codex. If Trae CLI adds a permission hook in the future, `handle_trae_cli` would need to grow a blocking branch mirroring `handle_blocking_response`.
- **YAML installer is deliberately primitive.** It does not understand YAML — it appends text. Hand-edited `traecli.yaml` files with unusual indentation may end up with valid but ugly diffs after Notchikko installs.
- **`subagent_stop` without `subagent_start`.** The Python event map exposes it but Notchikko can't detect when Trae CLI *enters* a subagent scope, so the subagent-mute logic in `ClaudeCodeAdapter` doesn't apply. Trae subagents currently render their tool events as main-session activity.
