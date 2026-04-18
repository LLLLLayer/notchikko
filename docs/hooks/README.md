# Notchikko Hook Integration — Research & Design

Notchikko is a passive observer. It does not call into any CLI agent, does not intercept process stdio, and does not patch binaries. Everything it displays — which session is active, which tool is running, whether an approval is pending, how many tokens the agent has burned — comes from **hook events** that the agent itself fires at well-known points in its lifecycle.

This folder documents, for each supported CLI agent:

1. The hook contract Notchikko depends on (upstream API, not Notchikko's invention).
2. Where Notchikko registers itself in the agent's config.
3. How the raw hook payload is normalized into Notchikko's unified `AgentEvent` model.
4. Which events can block the agent, and the response format Notchikko sends back.
5. Caveats and places where the integration is lossy or best-effort.

| Agent | File | Config file | Tool coverage | Approval support |
|---|---|---|---|---|
| Claude Code | [`claude-code.md`](./claude-code.md) | `~/.claude/settings.json` | All tools | Full (blocking `PermissionRequest`) |
| OpenAI Codex | [`codex.md`](./codex.md) | `~/.codex/hooks.json` | **Bash only** (upstream) | None used (Notchikko chooses not to block; `PreToolUse` is blockable upstream) |
| Gemini CLI | [`gemini-cli.md`](./gemini-cli.md) | `~/.gemini/settings.json` | All tools | None (no approval event upstream) |
| Trae CLI | [`trae-cli.md`](./trae-cli.md) | `~/.trae/traecli.yaml` | All tools | None (non-blocking contract) |

## Shared pipeline

```
 Agent CLI
    │  (spawns hook on configured events)
    ▼
 notchikko-hook.sh     ← 18-line bash wrapper; checks /tmp/notchikko.sock
    │  exec python3 notchikko-hook.py <source>
    ▼
 notchikko-hook.py     ← reads stdin JSON, normalizes per-agent schema
    │  (Unix domain socket at /tmp/notchikko.sock)
    ▼
 SocketServer          ← inside Notchikko.app, AsyncStream of HookEvent
    │
    ▼
 ClaudeCodeAdapter     ← HookEvent → AgentEvent, with synthetic sessionStart
    │
    ▼
 SessionManager / ApprovalManager / NotchikkoState
    │
    ▼
 Pet SVG + approval card + menu bar
```

### Why the hook splits into .sh + .py

The wrapper is intentionally thin:

- `.sh` exists only so agents that expect a shell command (the common case) can `exec` into Python without `python3 -c "…"` f-string escaping hell.
- `.py` is where all the real parsing and socket I/O lives.

Both files live at `~/.notchikko/hooks/`. An app update does **not** auto-sync them — the Settings UI surfaces a "Reinstall" banner when the installed `.sh` still contains the old inline-Python pattern or when `.py` is missing.

### Fail-open everywhere

The hook is designed to never block the agent on Notchikko's account. Missing socket, missing Python interpreter, malformed JSON, socket timeout — every error path exits 0. For the **blocking branch specifically** (`PermissionRequest` on an approval-eligible tool while `approvalCardEnabled` is on), the hook also emits a synthetic `{"hookSpecificOutput": {"decision": {"behavior": "allow"}}}` on stdout so Claude Code doesn't fall back to its in-terminal prompt. For non-blocking events, errors simply exit 0 with no stdout — there's no decision surface to emit into. Users who quit Notchikko while hooks are still installed lose the pet, not their agent workflow.

### PreToolUse is NOT an approval gate

Claude Code (and equivalents on other agents) fire **two** tool-phase events: one before any tool call, one only when the tool actually needs user confirmation. Notchikko treats the second (`PermissionRequest`) as the single source of truth for approval cards. `PreToolUse` is used only to drive visual state (`reading` / `building` / `typing`). Any design that blocks on `PreToolUse` would also prompt for pre-approved or `bypassPermissions`-mode tools, which is wrong.

### Unified event model

Every agent's per-event schema is collapsed, inside `notchikko-hook.py` or `ClaudeCodeAdapter.convert()`, into one of these cases:

```
AgentEvent:
  .sessionStart(sessionId, cwd, source, terminalPid, pidChain)
  .sessionEnd(sessionId)
  .prompt(sessionId, text?)
  .toolUse(sessionId, tool, phase: .pre | .post(success))
  .notification(sessionId, message, detail)
  .compact(sessionId)
  .stop(sessionId, usage?)
  .error(sessionId, message)
```

Everything downstream (pet state machine, approval card, danmaku, session menu) consumes only this enum. Adding a new CLI is, by design, a question of "can you produce these cases from its hook output?"

### Synthetic session injection

Not every CLI sends a `SessionStart` as its first event for a given session — some only send it on cold boot and Notchikko might have been launched mid-session. `ClaudeCodeAdapter` tracks `knownSessions`, and on the first event for an unknown session ID it synthesizes a `.sessionStart` before forwarding the real event. This is why the pet appears correctly even if Notchikko starts after the agent.

### Detection tiers

Hooks are Tier 1. When hooks aren't installed, `TranscriptPoller` reads the agent's JSONL transcript directory (Tier 2, polling every 5s) and `ProcessDiscovery` scans `ps` for known agent binary names (Tier 3, 60s). Tiers 2 and 3 cannot observe approvals or drive the pet's live state — they exist so the menu and approval card honestly represent "I know this agent is running, I just can't interact with it." When a Tier 1 event arrives for a session previously seen via Tier 2 or 3, the lower-tier entry is dropped in favor of the hook source.

## When this document lies

The per-CLI docs describe the hook surface as of the version of each agent we tested against. Upstream schemas change (especially Codex and Trae CLI, which are younger). Notchikko's hook script is authoritative — if what you see here disagrees with `Notchikko/Resources/notchikko-hook.py`, the script wins.
