# OpenAI Codex CLI

Codex's hook surface is a strict subset of Claude Code's. Notchikko treats Codex as "Claude Code with fewer events, no approval" — literally: the same `handle_standard` Python path, the same JSON schema expected on stdin, the same socket format.

## Hook contract (upstream)

Codex uses `~/.codex/hooks.json` with the same nested JSON shape Claude Code uses. The events Notchikko registers for are narrower because Codex (as of integration time) emits only the basics:

```
UserPromptSubmit, SessionStart, SessionEnd,
PreToolUse, PostToolUse,
Stop
```

No `PermissionRequest`. No `Elicitation` / `AskUserQuestion`. No `PreCompact` / `PostCompact`. No subagent lifecycle. No `StopFailure` / `PostToolUseFailure` granularity — errors surface as whatever the CLI prints.

### JSON shape

Codex sends the same field names Claude Code does — `session_id`, `cwd`, `hook_event_name`, `tool_name`, `tool_input`, `prompt`, `transcript_path`. This is deliberate on the CLI's part: it adopted Claude Code's schema to maximize hook reuse. The Python hook's `handle_standard` function cannot tell a Codex event apart from a Claude Code event except by the `source` argument baked into the registered command line.

### No blocking

None of Codex's hook events are documented as blocking. The hook fires, reads stdin, connects to the socket, and exits as fast as possible (2s socket timeout). Codex does not read stdout for a decision object — anything the hook prints is ignored.

## Config registration

Identical to Claude Code's install path except:

- File: `~/.codex/hooks.json` instead of `~/.claude/settings.json`.
- No `PermissionRequest` entry, so no 24h timeout override — every entry uses the short default.
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

- The pet's `source` label reads "OpenAI Codex" with the `📦` icon (from `CLIHookConfig.metadata(for: "codex")`).
- No approval cards ever appear from Codex — `PermissionRequest` isn't registered, so the `needs_blocking` branch in the hook never triggers.
- The session submenu shows no `PermissionRequest` count; the danmaku shows only tool names and prompt text.

## Token usage

Codex emits a `transcript_path` on `Stop` similar to Claude Code. If the transcript uses the same `type: "assistant"` + `message.usage` JSONL format, `extract_token_usage()` works identically. If Codex's transcript shape diverges, the tail-scan returns `None` and usage is simply omitted — no error.

## Transcript / process fallback

The lower-priority detection tiers do apply:

- `TranscriptPoller` watches `~/.codex/sessions/**/*.jsonl` on a 5s poll.
- `ProcessDiscovery` matches the binary name `codex` in `ps`.

These are silent stand-ins; if the user hasn't installed the Codex hook, Notchikko will still show "OpenAI Codex is running" in the menu, just without live tool-phase updates.

## Caveats

- **Schema drift is the biggest risk.** Codex's hook system has iterated faster than Claude Code's. If upstream renames `hook_event_name` or stops sending `session_id`, the `handle_standard` early-exits silently (fail-open). Symptom: pet looks dead while Codex is obviously running.
- **No approval UI.** `--dangerously-skip-permissions`-equivalent flags are the CLI's own concern — Notchikko cannot offer "Always allow" for Codex because there is no decision surface to return to.
- **Whether Codex supports the `matcher` field** varies by version. The current installer uses `"*"` defensively; newer Codex builds may ignore it, which is harmless.
