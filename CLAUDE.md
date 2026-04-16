# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Notchikko is a macOS app that displays an animated pixel crab ("Clawd") hanging from the MacBook notch. It acts as a visual indicator of Claude Code (and other AI CLI) activity, showing different SVG animations as the agent reads, writes, builds, etc. Runs as an accessory app (no dock icon) with a menu bar status item.

## Build & Run

Standard Xcode project. Targets macOS 14.0+, Swift 5. Bundle ID: `com.notchikko.app`. Single external dependency: [Sparkle](https://github.com/sparkle-project/Sparkle) (SPM) for auto-update.

```bash
xcodebuild -scheme Notchikko -configuration Debug build
```

No tests or linting configured. SourceKit frequently reports false-positive "Cannot find type" errors — always verify with `xcodebuild` before investigating.

### Debugging

- App logs: `~/Library/Logs/Notchikko/notchikko-YYYY-MM-DD.log` (3-day retention)
- Unix socket: `/tmp/notchikko.sock`
- Hook script (installed copy): `~/.notchikko/hooks/notchikko-hook.sh`
- Hook script (bundle source): `Notchikko/Resources/notchikko-hook.sh`
- Test hook manually: `echo '{"session_id":"test","event":"tool_use","tool_name":"Read"}' | ~/.notchikko/hooks/notchikko-hook.sh claude-code`

## Architecture

Event-driven pipeline:

```
CLI hook → notchikko-hook.sh → Unix socket → ClaudeCodeAdapter → SessionManager → NotchikkoState → ThemeProvider → NotchikkoView
```

### App Entry

`NotchikkoApp.swift` is the `@main` entry — a minimal SwiftUI `App` that delegates everything to `AppDelegate` via `@NSApplicationDelegateAdaptor`. `AppDelegate` is the real orchestrator: it creates and wires all modules (SocketServer, ClaudeCodeAdapter, SessionManager, NotchPanel, ApprovalManager, MenuBarManager, etc.) via callback closures. `MenuBarManager` owns the status-bar menu (session list, screen switching, settings, quit). `Views/NotchContentView.swift` is the SwiftUI root view embedded in the NotchPanel.

### Core Modules

- **IPC** — `SocketServer` listens on `/tmp/notchikko.sock`. `HookInstaller` registers hooks in CLI config files (JSON for Claude Code/Codex/Gemini CLI, YAML for Trae CLI). Hook entries include `matcher: "*"` for tool matching; PermissionRequest entries add `timeout: 86400` (24h). `closePending()` cleans up orphaned fds on stale timer expiry. For approval requests, keeps socket fd open in `pendingResponses` dict until app writes back. Bind failure triggers automatic unlink + retry.

- **Agent** — `AgentBridge` protocol. `ClaudeCodeAdapter` converts `HookEvent` → `AgentEvent` via AsyncStream. Performs **synthetic session injection** — auto-yields `.sessionStart` on first event from unknown session ID. `SubagentStart`/`SubagentStop` events are silently dropped (return `nil` from `convert()`) to avoid affecting main pet state. Thread-safe: `knownSessions` and `subagentDepth` are protected by `NSLock` because `onEvent` runs on a concurrent queue. AppDelegate creates a single adapter and consumes its stream directly.

- **Session** — `SessionManager` (@Observable) tracks multiple sessions, maps tools to visual states, manages idle/sleep timers (60s/120s via `resetTimers()`) plus separate return timers (5s for errors, 3s for task-complete auto-switch — `resetTimers()` cancels all three). `activeSessionId` prioritizes: pinned → working phase (processing/runningTool/compacting) → most recent idle. Supports pinned session binding with auto-switch: after task completion (Stop event), celebrates 3s then auto-unpins and switches to next active session. Sessions store terminal PID, tty path, prompt text, bypass mode flag, and token usage. Max 32 concurrent sessions with LRU eviction. `removeSession()` for manual session close from menu. `sessionCleanupTasks` dict tracks delayed removal Tasks to prevent leaks.

- **Terminal** — `TerminalJumper` activates the terminal window for a session. `KnownTerminal` enum maps bundle IDs to display names and focus strategies for 13 supported terminals. Five focus strategies: `appleScriptTty` (iTerm2, Terminal.app — locates tab by tty), `appleScriptCwd` (Ghostty — locates surface by cwd), `ideExtension` (VS Code/VS Code Insiders/Cursor/Windsurf — HTTP POST to bundled extension which matches `terminal.processId` against PID chain), `kittyCLI` (Kitty — `kitty @ focus-window --match pid:X`, runs on background queue to avoid blocking main thread), `generic` (all others — activate app only). Process tree batch-cached (single `ps -eo pid=,ppid=`, 5s TTL, **read before waitUntilExit** to avoid pipe deadlock). `onTerminalMatched` callback caches first successful match to `SessionInfo.matchedTerminal` for menu/card display. CWD matching uses 3-level deepest-first candidates with symlink-resolved path normalization; guards against empty strings (`String.contains("")` always true). Cross-Space window discovery via `CGWindowList` fallback. Click on Clawd jumps to session in any state (idle/sleeping/happy/etc.), falling back to the most recent session if no active session exists.

- **IDE Extension** — `IDEExtensionInstaller` manages a VS Code extension (`notchikko-terminal-focus`) that enables precise terminal tab focusing. The extension runs an HTTP server on ports 23456-23460 (one per VS Code window) with `POST /focus-tab` (receives PID chain, matches `terminal.processId`, calls `terminal.show()`) and `GET /health` (returns version for status detection). Extension source files are bundled as `vscode-ext.js`/`vscode-ext-package.json` (Xcode-safe names) and copied with standard names during install to `~/.vscode/extensions/notchikko.notchikko-terminal-focus/`. Settings UI shows four-state status: not installed / installed (not running) / running / update available. **Important**: the hook script (`~/.notchikko/hooks/notchikko-hook.sh`) is a separate copy from the bundle — app updates do NOT auto-sync it. Users must reinstall hooks from Settings → Integration after updates that change the hook script.

- **Theme** — `ThemeProvider` resolves SVGs by state with per-state URL caching (cleared on state exit, so re-entry picks new random variant; window rebuild reuses same SVG). Built-in "clawd" theme from bundle; custom themes from `~/.notchikko/themes/{id}/` with `theme.json` manifest. External SVGs sanitized via `SVGSanitizer` (strips `<script>`, event handlers, `javascript:` URLs).

- **Notchikko (core)** — `NotchikkoState` enum defines 11 states with revealAmount and soundKey. `NotchikkoView` wraps WKWebView, loads SVG via `loadSVG(for: NotchikkoState)`. SVG files > 1MB are rejected (custom theme guard). SVG transitions use JS-injected crossfade (0.3s opacity transition) — first load uses full HTML, subsequent loads inject via `evaluateJavaScript` with error logging. Rapid state changes clean up all prior layers before adding new one (prevents DOM accumulation).

- **Window** — `NotchPanel` (borderless NSPanel) positioned via `NotchGeometry` relative to hardware notch. `NotchGeometry` accepts `NotchDetectionMode` (auto/forceOn/forceOff) — on non-notch screens with forceOn, simulates notch by placing panel top at `screenFrame.maxY - notchHeight` instead of screen edge. `NotchPanel.treatAsNotched` controls `constrainFrameRect` behavior (must match `NotchGeometry.hasPhysicalNotch`). `DragController` handles drag with 5pt threshold, hit area padded +20px. Cross-screen drag rebuilds the window on the target screen; same-screen drag animates back with `disableFrameConstraint` flag to prevent notch constraint interference during animation.

- **Drag State Freeze** — `SessionManager.beginDrag()` sets `isDragging` flag, cancels all timers, freezes all state changes. `endDrag()` computes correct state from active session's current phase (not a stale snapshot). `refreshNotchWindow()` is blocked during drag to prevent panel duplication. Similarly, `isApproving` locks state to `.approving` while blocking approval cards are visible; `endApproval()` restores the correct state when all cards are dismissed.

- **Approval** — Separate stacked `NSPanel` windows that slide out from behind the pet (overlap 15px, level mainMenu+2 so visually behind the pet panel). `ApprovalManager` manages pending requests with 24h stale timer (matching hook timeout). Approval cards only appear for `PermissionRequest` hook events (not PreToolUse — PreToolUse fires for all tools regardless of permission settings). Four buttons: Deny / Allow Once / Always Allow / Auto Approve. "Always Allow" and "Auto Approve" both send `bypass: true` in the socket response; the hook outputs `setMode: bypassPermissions` via `updatedPermissions` in a single round-trip (no flag files). `autoApprovedSessions` set for app-side fast-path. AskUserQuestion arriving via PermissionRequest shows interactive option buttons (`onAnswer` callback sends `{answers: {question: selectedOption}}`); via PreToolUse shows non-blocking notification card (1s debounce — delays card to let PermissionRequest replace it if it arrives within ~0.5s). Cards auto-hide after 15s (configurable), hover on pet restores hidden cards via `NotchHitTestView` tracking area. `onSessionEvent` only clears notification cards; `dismissStaleApprovals()` auto-closes blocking cards when new prompt/stop/sessionEnd arrives. `isApproving` flag on SessionManager locks state to `.approving` until all blocking cards are dismissed (like `isDragging`). Session submenu: Pin / Jump / Close.

- **Preferences** — `PreferencesStore` (@Observable) auto-saves on `didSet` with 100ms debounce. `petScale`, `themeId`, and `notchDetectionMode` changes trigger window rebuild notification. Settings bindings do NOT call `save()` explicitly — `didSet` handles it, preventing unwanted SVG re-randomization.

- **Danmaku** — `DanmakuView` renders scrolling tool/context labels (pixel-style tags) behind Clawd using SwiftUI `Canvas` + `TimelineView` at 30fps. Items drift right-to-left with fade-in/fade-out. Fed by `SessionManager` tool events.

- **Logging** — `FileLogger` singleton writes to `~/Library/Logs/Notchikko/notchikko-YYYY-MM-DD.log` with 3-day retention. Useful for debugging hook/socket/session issues without Xcode attached.

- **Session Detection (three-tier fallback)** — Every session is tagged with a `detection` level: `.hook` (full support) > `.transcript` (JSONL polling, read-only) > `.process` (ps-based placeholder). Hook is authoritative; the other two only fill gaps when hooks aren't installed. Upgrades flow one-way (process → transcript → hook). `SessionManager.hookSessionIds` is the single source of truth; `AppDelegate` mirrors it onto `TranscriptPoller.hookSessionIds` and `ProcessDiscovery.hookSessionIds` so they skip hook-managed sessions. Transcript/process sessions do NOT support approval or terminal jump.

- **TranscriptPoller** (`IPC/TranscriptPoller.swift`) — Polls `~/.claude/projects/**/*.jsonl` and `~/.codex/sessions/**/*.jsonl` every 5s, only files modified within the last 5min. Tracks `fileOffsets` to read incrementally. Emits synthetic `AgentEvent`s into `SessionManager.handleEvent`. When a hook session arrives for the same id, `mergeWithHookSession()` drops it from its known-set so hook takes over.

- **ProcessDiscovery** (`IPC/ProcessDiscovery.swift`) — Scans `ps` every 60s for known agent process names (`claude`, `codex`, `gemini`, `traecli`, `coco`). Creates `discovered-{source}-{pid}` placeholder sessions; emits sessionEnd when the pid disappears. Lowest-priority detection tier — visible in menu/card so the user knows the agent is running even without hooks.

- **HotkeyManager** (`App/HotkeyManager.swift`) — Carbon `RegisterEventHotKey`-based global shortcuts for approval cards: Cmd+Y (Allow Once), Cmd+Shift+Y (Always Allow), Cmd+N (Deny), Cmd+Shift+N (Auto Approve). No Accessibility permission needed. Only activated while a blocking approval card is visible (`AppDelegate.updateHotkeyState()` toggles on `ApprovalManager` changes) to avoid stealing Cmd+Y/N globally. Uses a `nonisolated(unsafe) static var instance` to bridge the C callback back to Swift — `activate()` is idempotent via `isActive` guard.

- **Update** — `UpdateManager` wraps Sparkle's `SPUStandardUpdaterController`. Auto-checks on launch (24h interval), manual check via menu. Configured in `Info.plist`: `SUFeedURL` points to GitHub release appcast, `SUPublicEDKey` for EdDSA signature verification. See the `release-guide` skill for the full release pipeline (version bump → archive → notarize → appcast → GitHub release).

- **i18n** — All UI strings use `String(localized:)` (SwiftUI) or `NSLocalizedString()` (AppKit). Translations in `Resources/{en,zh-Hans}.lproj/Localizable.strings`.

### Hook Script

`notchikko-hook.sh [source]` — Bash wrapper around inline Python3. **Never insert debug code with double quotes into the inline `python3 -c "..."` block** — f-strings break the outer bash quotes and brick all hook calls. Reads stdin JSON from CLI, maps events to status, sends to socket. The `source` arg ("claude-code", "codex", "gemini-cli", "trae-cli") selects the JSON parser — Trae CLI uses a different schema (`event_type` + nested body), Gemini CLI uses different event names (`BeforeAgent`→`UserPromptSubmit`, `BeforeTool`→`PreToolUse`, etc.) + snake_case tool names mapped via `GEMINI_TOOL_MAP`. **Only `PermissionRequest` events block** (not PreToolUse — PreToolUse fires for all tools regardless of permission settings). For PermissionRequest on approval tools (Bash/Edit/Write/NotebookEdit) or AskUserQuestion, generates UUID `request_id` and blocks waiting for response. Response format varies: approval tools get `{decision: {behavior: "allow|deny"}}`, AskUserQuestion gets `{decision: {behavior: "allow", updatedInput: {questions, answers}}}`. If app sends `bypass: true`, hook adds `updatedPermissions: [{type: "setMode", mode: "bypassPermissions", destination: "session"}]`. On Stop events, reads `transcript_path` tail to extract token usage (`input_tokens`, `output_tokens`, `cache_read`, `cache_creation`). Walks the process tree (up to 15 levels) via `detect_terminal_info()` to collect both the terminal PID and full PID chain (used by VS Code extension for terminal tab matching).

### SVG / Themes

Built-in SVGs live in `Resources/themes/clawd/{state}/{state}-{variant}.svg` (e.g. `idle/idle-coffee.svg`, `building/building-chef.svg`). Xcode flattens subdirectories at build time — `ThemeProvider.builtinSVG(for:)` scans the resource bundle for files matching the `{state.rawValue}-` prefix. Each state directory can hold multiple SVG variants — ThemeProvider picks one at random on each transition.

Custom theme packs go in `~/.notchikko/themes/{id}/` with a `theme.json` manifest. Resolution order: custom theme directory → single `{state}.svg` flat file → built-in fallback. External theme SVGs are sanitized via `SVGSanitizer` (strips `<script>`, event handlers, `javascript:` URLs).

`theme.json` manifest supports optional fields: `sounds` (state→filename mapping), `eyeTracking`, `reactions` (click/drag SVGs), `viewBox`, `workingTiers` (multi-session animations). All optional and backward compatible.

### Sound System

`SoundManager` (`@MainActor`) plays audio on state transitions with 2-second per-state cooldown. Three-tier resolution: user custom sounds (`~/Application Support/notchikko/sounds/`) → theme sounds (`themes/{id}/sounds/`, using manifest `sounds` mapping then directory scan) → built-in sounds (bundle `.wav`). Soundable states: happy, error, approving, session-start. Volume: continuous float 0.0–1.0 via PreferencesStore.

### State Transitions

No priority-based gating — `transition(to:)` always accepts the new state (blocked by `isDragging` or `isApproving`). Note: `NotchikkoState.priority` exists but is unused — vestigial from an earlier design. Tool→State mapping: Read/Grep/Glob→reading, Edit/Write/NotebookEdit→typing, Bash→building, others→typing. Non-tool phases: processing→thinking (LLM generating), compacting→sweeping (context compaction). Error states auto-return to idle after 5s; happy (task complete) triggers 3s celebration then auto-switches session. Notification events (Elicitation/AskUserQuestion) set approving state indefinitely until next event. Approving state is interruptible by any event (like idle/sleeping).

### Key Patterns

- **@Observable** for SwiftUI reactivity (SessionManager, PreferencesStore, ApprovalManager)
- **AsyncStream** for event listening from SocketServer
- **Callback closures** wired in AppDelegate for cross-module communication (onApprovalRequest, onTerminalPidUpdate, onTerminalTtyUpdate, onPermissionModeUpdate, onClick, onDragStart/End, etc.)
- **`CLIHookConfig.metadata(for:)`** — single source of truth for agent icon/name mapping (no duplicated switch statements)
- SVG files are pre-oriented (hanging upside-down) — no code flipping
- `NotchikkoView.updateEyePosition(dx:dy:)` does JS-based eye tracking via `#eyes-js` and `#body-js` SVG element IDs
- Click on Clawd → jump to session's terminal (active or most recent, works in any state); right-click → context menu
- All source files are in `Notchikko/` subdirectories (Agent/, App/, Approval/, IPC/, Notchikko/, Preferences/, Session/, Sound/, Terminal/, Theme/, Views/, Window/); `docs/internal/competitive-analysis/` contains reference implementations — not part of build

### Common Pitfalls

- **SourceKit lies** — "Cannot find type X" errors in the IDE are often phantom. Always run `xcodebuild -scheme Notchikko -configuration Debug build` to confirm real errors before fixing.
- **Hook script is inline Python in bash** — `python3 -c "..."` wrapping means **double quotes in injected code break the shell**. Never add f-strings or debug logging with `"` directly. Use a separate .py file for testing.
- **Hook script is a copy** — `~/.notchikko/hooks/notchikko-hook.sh` is copied from the bundle at install time. Editing `Notchikko/Resources/notchikko-hook.sh` requires reinstalling hooks to take effect.
- **PreToolUse vs PermissionRequest** — PreToolUse fires for ALL tool calls (even pre-approved ones); PermissionRequest only fires when Claude Code needs user confirmation. Only block on PermissionRequest, never PreToolUse.
- **Xcode flattens resource subdirectories** — SVGs in `Resources/themes/clawd/{state}/` end up in a flat bundle directory. ThemeProvider finds them by filename prefix (`{state}-`), not by directory.
- **`didSet` auto-saves preferences** — never call `save()` manually on PreferencesStore bindings; double-saving causes SVG re-randomization and unnecessary window rebuilds.
- **Drag freezes everything** — while `isDragging` is true, state transitions, timers, and window refreshes are all blocked. `endDrag()` must be called in the animation completion handler (not before), otherwise state changes during fly-back cause the panel to jump on notch screens.
- **`resetTimers()` must cancel all three timers** — idleTimer, sleepTimer, AND returnTimer. Missing returnTimer causes error→idle override of working state.
- **Screen disconnect** — `refreshNotchWindow()` checks `NSScreen.screens.contains(currentScreen)` and falls back to `NSScreen.main`. Stale NSScreen references stay alive but aren't in the screens list.
- **AppleScript injection** — tty paths and cwd are user-controlled strings embedded in AppleScript. Always use `KnownTerminal.escapeAppleScript()` when interpolating into AppleScript string literals.
- **SVG entity-encoded event handlers** — attackers can bypass `onclick=` stripping with HTML entity encoding (`on&#99;lick=`). `SVGSanitizer` now handles both forms; keep both regex patterns in sync when modifying.
- **Adding a new CLI agent** — update three places: `CLIHookConfig` (metadata mapping), `HookInstaller` (config file registration with correct `settingsPath`), and the hook script (event name mapping if different from Claude Code's schema, e.g. Gemini's `GEMINI_EVENT_MAP` + `GEMINI_TOOL_MAP`). To also pick it up without a hook: add the binary name to `ProcessDiscovery.agentNames` and (if it writes JSONL transcripts) a directory to `TranscriptPoller`.
- **`hookSessionIds` is @MainActor-only** — `TranscriptPoller` and `ProcessDiscovery` read it from `Task.detached` blocks. Always assign/read via the main actor; never mutate from their scan tasks.
- **HotkeyManager scope** — only toggle via `AppDelegate.updateHotkeyState()`. Registering globally while no approval card is up would hijack Cmd+Y/N from every other app.
