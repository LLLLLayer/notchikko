# Gemini CLI

Gemini CLI has a hook surface comparable to Claude Code's in *shape*, but uses **different event names** and **different tool names**. Rather than maintain a second event pipeline, the Python hook normalizes Gemini's payload into Claude-Code-compatible fields and reuses `handle_standard`.

## Hook contract (upstream)

Config file: `~/.gemini/settings.json`. Same nested JSON shape Claude Code uses — one entry per event, each with a `matcher` and a list of `command` hooks.

### Events Notchikko registers for

From the Gemini entry in `CLIHookConfig.supportedCLIs`:

```
SessionStart, SessionEnd,
BeforeAgent, BeforeTool, AfterTool, AfterAgent,
Notification, PreCompress
```

The naming convention is *Before/After* instead of *Pre/Post*. Gemini also uses `PreCompress` instead of `PreCompact`. `SessionStart` and `SessionEnd` align with Claude Code. There is **no** `PermissionRequest`, `Elicitation`, or subagent event.

### Event-name translation table

The Python hook (`GEMINI_EVENT_MAP`) rewrites incoming `hook_event_name` before handing the event to `handle_standard`:

| Gemini event | Normalized to |
|---|---|
| `BeforeAgent` | `UserPromptSubmit` |
| `BeforeTool` | `PreToolUse` |
| `AfterTool` | `PostToolUse` |
| `AfterAgent` | `Stop` |
| `SessionStart` | `SessionStart` |
| `SessionEnd` | `SessionEnd` |
| `Notification` | `Notification` |
| `PreCompress` | `PreCompact` |

Anything not in the map → `sys.exit(0)` silently (unknown events are treated as fail-open).

### Tool-name translation table

Gemini emits tool names in snake_case. Notchikko's state machine keys on PascalCase names borrowed from Claude Code (`Read`, `Edit`, `Bash`, etc.), so `GEMINI_TOOL_MAP` rewrites `tool_name` before downstream consumption:

| Gemini tool name | Normalized to |
|---|---|
| `read_file`, `read_many_files` | `Read` |
| `write_file` | `Write` |
| `replace` | `Edit` |
| `run_shell_command` | `Bash` |
| `glob`, `list_directory` | `Glob` |
| `grep_search`, `search_file_content` | `Grep` |
| `ask_user` | `AskUserQuestion` |
| `google_web_search` | `WebSearch` |
| `web_fetch` | `WebFetch` |

Tools not in the map pass through unchanged — the state machine falls back to the "typing" default for anything it doesn't recognize.

### JSON shape

After normalization, the hook sees `session_id`, `cwd`, `hook_event_name`, `tool_name`, `tool_input`, `prompt`, `transcript_path` — all the Claude Code fields. Gemini itself produces these under the same keys; it's only the *values* of `hook_event_name` and `tool_name` that needed rewriting.

### No blocking

Gemini does not currently expose an approval hook Notchikko can bind to. `PermissionRequest` is not registered, `needs_blocking` never triggers, and no approval card is shown for Gemini sessions.

## Config registration

Identical to Claude Code's registration, with three differences:

- File: `~/.gemini/settings.json`.
- Command argument: `gemini-cli`.
- No `PermissionRequest` timeout override; all entries use Gemini's default timeout.

Install entry example:

```jsonc
{
  "hooks": {
    "BeforeTool": [
      {"matcher": "*",
       "hooks": [{"type": "command",
                  "command": "/Users/you/.notchikko/hooks/notchikko-hook.sh gemini-cli"}]}
    ],
    "AfterAgent": [ /* same shape */ ]
  }
}
```

## How the normalize-then-reuse design works in practice

Walking through a single tool call for clarity:

1. User runs `gemini-cli … "summarize the repo"`.
2. Gemini fires `BeforeTool` with `{session_id, cwd, hook_event_name: "BeforeTool", tool_name: "read_file", tool_input: {...}, ...}`.
3. `notchikko-hook.sh gemini-cli` → `notchikko-hook.py gemini-cli`.
4. `normalize_gemini_cli(input_data)` rewrites in place: `hook_event_name` → `"PreToolUse"`, `tool_name` → `"Read"`.
5. Control falls through to `handle_standard`, which is the exact same code path Claude Code uses.
6. Event is forwarded over the socket as `{event: "PreToolUse", tool: "Read", source: "gemini-cli", ...}`.
7. `ClaudeCodeAdapter.convert()` emits `.toolUse(sessionId, "Read", .pre)`.
8. Pet transitions to `reading`.

From the pet's perspective Gemini is indistinguishable from Claude Code except for its `source` metadata (`💎` icon, display name "Gemini CLI"). The menu, danmaku, and state machine don't know they're watching a different CLI.

## Token usage

Gemini's `AfterAgent` is normalized to `Stop`. The `extract_token_usage()` helper runs on the transcript path as with Claude Code. If Gemini's transcript format isn't compatible with the "last `type: assistant` entry with `usage`" heuristic, tail-scanning returns `None` and no usage is emitted — no error, just a session without token totals in the menu.

## Caveats

- **Tool-name map is a patch, not a contract.** If Gemini adds a new tool or renames one, it falls through unmapped and the pet defaults to "typing". Not catastrophic, but the danmaku label will show the raw snake_case name until `GEMINI_TOOL_MAP` is updated.
- **No approval surface.** Gemini enforces its own confirmation prompts inline in the terminal. The pet sees `BeforeTool` and `AfterTool` but cannot intercept the decision.
- **Subagents invisible.** Gemini doesn't emit subagent lifecycle events, so any orchestration Gemini runs internally appears as if the main session did it.
- **`Notification` is the only "pet grabs attention" signal.** No `Elicitation` distinction — non-blocking cards for Gemini are strictly from `Notification` events, with a 15s auto-hide.
