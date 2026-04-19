# OpenAI Codex CLI

Codex's hook surface is a strict subset of Claude Code's. Notchikko treats Codex as "Claude Code with fewer events, no approval" — literally: the same `handle_standard` Python path, the same JSON schema expected on stdin, the same socket format.

## Hook contract (upstream)

Codex uses `~/.codex/hooks.json` (or `<repo>/.codex/hooks.json`; both are loaded and merged) with the same nested JSON shape Claude Code uses. Per Codex's [upstream docs](https://developers.openai.com/codex/hooks), the events Codex emits are:

```
SessionStart,
UserPromptSubmit,
PreToolUse, PostToolUse,
Stop
```

**There is no `SessionEnd` upstream.** Notchikko's installer currently registers `SessionEnd` anyway (see `CLIHookConfig` for `"codex"`); Codex silently ignores unknown events, so this is harmless but wasted config.

No `PermissionRequest`. No `Elicitation` / `AskUserQuestion`. No `PreCompact` / `PostCompact`. No subagent lifecycle. No `StopFailure` / `PostToolUseFailure` granularity — errors surface as whatever the CLI prints.

### Bash-only tool interception (critical caveat)

Per upstream docs and tracking issues ([codex#16732](https://github.com/openai/codex/issues/16732), [codex#14754](https://github.com/openai/codex/issues/14754)), **`PreToolUse` / `PostToolUse` currently only fire for the `Bash` tool**. Edits, writes, MCP calls, web searches, and every other tool class run without triggering a hook. From Notchikko's perspective:

- Tool-phase Notchikko transitions (`reading` / `typing` / `building`) only fire when Codex runs shell commands.
- Any Codex session that's mostly file I/O will look idle to Notchikko until the next non-tool lifecycle event (`UserPromptSubmit` / `Stop`).
- Expect this to change as Codex's hook surface grows; nothing in Notchikko needs to be rewritten when it does (the `handle_standard` path already accepts any tool name).

### JSON shape

Codex sends the Claude-Code-compatible core fields — `session_id`, `cwd`, `hook_event_name`, `tool_name`, `tool_input`, `transcript_path` — plus two Codex-specific ones:

- `model` — the model ID in use for this turn.
- `turn_id` — scopes the event to a conversation turn (present on turn-scoped events; absent on session-scoped ones).

`prompt` is sent on `UserPromptSubmit` as with Claude Code. Notchikko ignores `model` / `turn_id` today; they're surfaced only in the raw socket payload.

### Blocking semantics

Codex's `PreToolUse` **is** blocking and does read stdout. Per upstream it accepts:

```json
{"hookSpecificOutput": {
  "hookEventName": "PreToolUse",
  "permissionDecision": "deny",
  "permissionDecisionReason": "..."
}}
```

Notice this is the `permissionDecision` shape (same as Claude Code's `PreToolUse`), **not** the `decision.behavior` shape used by Claude Code's `PermissionRequest`. Codex has no `PermissionRequest` event at all.

Notchikko does **not** use this path: `notchikko-hook.py` sets `needs_blocking = (hook_event == "PermissionRequest" and ...)`, which is never true for Codex. So from Codex's point of view the hook connects, dumps the event to the socket with a 2s client timeout, and exits without printing anything — Codex allows the tool to proceed. This is a deliberate policy choice (we only want blocking approval cards for the richer Claude Code contract), not a limitation of the CLI.

`PostToolUse` supports `{decision: "block", stopReason: "..."}` to replace the tool result with feedback text (the command has already run — this doesn't undo it, only injects context). Notchikko doesn't use that either.

## Config registration

Identical to Claude Code's install path except:

- File: `~/.codex/hooks.json` instead of `~/.claude/settings.json`.
- No `PermissionRequest` entry, so no 24h timeout override — every entry uses Codex's default timeout.
- Command argument is `codex`, so the Python script's `source` = `"codex"`.

Example fragment:

```jsonc
{
  "hooks": {
    "PreToolUse": [
      {"matcher": "*",
       "hooks": [{"type": "command",
                  "command": "/Users/you/.notchikko/hooks/notchikko-hook.sh codex"}]}
    ],
    "Stop": [ /* same shape */ ]
  }
}
```

## Notchikko's per-event handling

Because the schema is Claude-Code-compatible, every event routes through the same `STATUS_MAP` and the same `AgentEvent` conversion. The visible differences are:

- Notchikko's `source` label reads "OpenAI Codex" with the `📦` icon (from `CLIHookConfig.metadata(for: "codex")`).
- No approval cards ever appear from Codex — `PermissionRequest` isn't an event Codex emits, so the `needs_blocking` branch in the hook never triggers.
- The danmaku shows only tool names and prompt text; because only Bash fires tool hooks, danmaku frequency is much lower than for Claude Code sessions.

## Token usage

Codex emits a `transcript_path` on `Stop` similar to Claude Code. If the transcript uses the same `type: "assistant"` + `message.usage` JSONL format, `extract_token_usage()` works identically. If Codex's transcript shape diverges, the tail-scan returns `None` and usage is simply omitted — no error.

## Transcript / process fallback

The lower-priority detection tiers do apply:

- `TranscriptPoller` watches `~/.codex/sessions/**/*.jsonl` on a 5s poll.
- `ProcessDiscovery` matches the binary name `codex` in `ps`.

These are silent stand-ins; if the user hasn't installed the Codex hook, Notchikko will still show "OpenAI Codex is running" in the menu, just without live tool-phase updates.

## Caveats

- **Bash-only hook coverage.** Biggest practical caveat. File edits, MCP calls, web searches — none of them fire a hook, so Notchikko only reacts to shell commands. Users who don't understand this will think Notchikko is broken against a Codex workload that's mostly edits.
- **Large-file hook silent failure.** On Linux / Windows, Codex editing a file over ~100 KB (or ~1500–2000 lines) can exceed OS argv limits and the hook never runs at all ([codex#18067](https://github.com/openai/codex/issues/18067)). macOS has a higher limit but isn't immune.
- **Schema drift is the biggest other risk.** Codex's hook system has iterated faster than Claude Code's. If upstream renames `hook_event_name` or stops sending `session_id`, the `handle_standard` early-exits silently (fail-open). Symptom: Notchikko looks dead while Codex is obviously running.
- **Blocking is available upstream but Notchikko doesn't use it.** Codex's `PreToolUse` can deny Bash commands via `permissionDecision: "deny"` on stdout. Notchikko chooses not to — blocking approval UX is reserved for Claude Code's `PermissionRequest`. A future release could add it.
- **`matcher` field uses regex.** Per upstream, Codex matchers are regex strings (e.g. `"Bash"`, `"Edit|Write"`, `"startup|resume"`). Notchikko's installer writes `"*"`, which is not a valid regex quantifier; in practice Codex treats it as a fail-closed / match-all depending on version. If a future release tightens regex validation, the installer will need to switch to `".*"` or `""`.
