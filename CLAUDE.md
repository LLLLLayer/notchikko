# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Notchikko is a macOS app that displays an animated pixel crab ("Clawd") hanging from the MacBook notch. It acts as a visual indicator of Claude Code (and other AI CLI) activity, showing different SVG animations as the agent reads, writes, builds, etc. Runs as an accessory app (no dock icon) with a menu bar status item.

## Build & Run

Standard Xcode project — zero external dependencies. Targets macOS 14.0+, Swift 5. Bundle ID: `com.notchikko.app`.

```bash
xcodebuild -scheme Notchikko -configuration Debug build
```

No tests or linting configured. SourceKit frequently reports false-positive "Cannot find type" errors — always verify with `xcodebuild` before investigating.

## Architecture

Event-driven pipeline:

```
CLI hook → notchikko-hook.sh → Unix socket → ClaudeCodeAdapter → SessionManager → NotchikkoState → ThemeProvider → NotchikkoView
```

### App Entry

`NotchikkoApp.swift` is the `@main` entry — a minimal SwiftUI `App` that delegates everything to `AppDelegate` via `@NSApplicationDelegateAdaptor`. `AppDelegate` is the real orchestrator: it creates and wires all modules (SocketServer, ClaudeCodeAdapter, SessionManager, NotchPanel, ApprovalManager, MenuBarManager, etc.) via callback closures. `MenuBarManager` owns the status-bar menu (session list, screen switching, settings, quit). `Views/NotchContentView.swift` is the SwiftUI root view embedded in the NotchPanel.

### Core Modules

- **IPC** — `SocketServer` listens on `/tmp/notchikko.sock`. `HookInstaller` registers hooks in CLI config files (JSON for Claude Code/Codex, YAML for Trae CLI). For approval requests, keeps socket fd open in `pendingResponses` dict until app writes back. Bind failure triggers automatic unlink + retry.

- **Agent** — `AgentBridge` protocol. `ClaudeCodeAdapter` converts `HookEvent` → `AgentEvent` via AsyncStream. Performs **synthetic session injection** — auto-yields `.sessionStart` on first event from unknown session ID. `SubagentStart`/`SubagentStop` events are silently dropped (return `nil` from `convert()`) to avoid affecting main pet state. AppDelegate creates a single adapter and consumes its stream directly.

- **Session** — `SessionManager` (@Observable) tracks multiple sessions, maps tools to visual states, manages idle/sleep timers (60s/120s). Supports pinned session binding with auto-switch: after task completion (Stop event), celebrates 3s then auto-unpins and switches to next active session. Sessions store terminal PID, tty path, prompt text, and bypass mode flag. Max 32 concurrent sessions with LRU eviction.

- **Terminal** — `TerminalJumper` activates the terminal window for a session. `KnownTerminal` enum maps bundle IDs to display names and focus strategies for 13 supported terminals. Three focus strategies: `appleScriptTty` (iTerm2, Terminal.app — locates tab by tty), `appleScriptCwd` (Ghostty — locates surface by cwd), `generic` (all others — activate app only). Process tree batch-cached (single `ps -eo pid=,ppid=`, 5s TTL). CWD matching uses 3-level deepest-first candidates with symlink-resolved path normalization. Cross-Space window discovery via `CGWindowList` fallback.

- **Theme** — `ThemeProvider` resolves SVGs by state with per-state URL caching (cleared on state exit, so re-entry picks new random variant; window rebuild reuses same SVG). Built-in "clawd" theme from bundle; custom themes from `~/.notchikko/themes/{id}/` with `theme.json` manifest. External SVGs sanitized via `SVGSanitizer` (strips `<script>`, event handlers, `javascript:` URLs).

- **Notchikko (core)** — `NotchikkoState` enum defines 11 states with revealAmount and soundKey. `NotchikkoView` wraps WKWebView, loads SVG via `loadSVG(for: NotchikkoState)`. SVG transitions use JS-injected crossfade (0.3s opacity transition) — first load uses full HTML, subsequent loads inject via `evaluateJavaScript`. Rapid state changes clean up all prior layers before adding new one (prevents DOM accumulation).

- **Window** — `NotchPanel` (borderless NSPanel) positioned via `NotchGeometry` relative to hardware notch. `DragController` handles drag with 5pt threshold, hit area padded +20px. Cross-screen drag rebuilds the window on the target screen; same-screen drag animates back with `disableFrameConstraint` flag to prevent notch constraint interference during animation.

- **Drag State Freeze** — `SessionManager.beginDrag()` sets `isDragging` flag, cancels all timers, freezes all state changes. `endDrag()` computes correct state from active session's current phase (not a stale snapshot). `refreshNotchWindow()` is blocked during drag to prevent panel duplication.

- **Approval** — Separate stacked `NSPanel` windows (each offset 8px). `ApprovalManager` manages pending requests with 300s stale timer. Only Bash/Edit/Write/NotebookEdit require approval (gated by `approvalCardEnabled` preference, default on). Hook script checks `permission_mode` from CLI stdin. Buttons: Deny / Allow Once / Allow All (session-scoped, in-memory via `autoApprovedSessions` set). Notification events (Elicitation/AskUserQuestion) also show info cards with jump button. All cards have close button. `removeAllApprovalPanels()` clears entire stack.

- **Preferences** — `PreferencesStore` (@Observable) auto-saves on `didSet` with 100ms debounce. Only `petScale` and `themeId` changes trigger window rebuild notification. Settings bindings do NOT call `save()` explicitly — `didSet` handles it, preventing unwanted SVG re-randomization.

- **i18n** — All UI strings use `String(localized:)` (SwiftUI) or `NSLocalizedString()` (AppKit). Translations in `Resources/{en,zh-Hans}.lproj/Localizable.strings`.

### Hook Script

`notchikko-hook.sh [source]` — Bash wrapper around inline Python3. Reads stdin JSON from CLI, maps events to status, sends to socket. The `source` arg ("claude-code", "trae-cli", etc.) selects the JSON parser — Trae CLI uses a different schema (`event_type` + nested body) that gets normalized to the same socket format. For PreToolUse on modification tools (Bash/Edit/Write/NotebookEdit), generates UUID `request_id` and blocks waiting for approval response (5 min timeout, defaults to allow). Also walks the process tree (up to 15 levels) to detect the parent terminal PID and tty.

### SVG / Themes

Built-in SVGs live in `Resources/themes/clawd/{state}/{state}-default.svg` (e.g. `idle/idle-default.svg`, `building/building-default.svg`). Xcode flattens subdirectories at build time — `ThemeProvider.builtinSVG(for:)` scans the resource bundle for files matching the `{state.rawValue}-` prefix. Each state directory can hold multiple SVG variants — ThemeProvider picks one at random on each transition.

Custom theme packs go in `~/.notchikko/themes/{id}/` with a `theme.json` manifest. Resolution order: custom theme directory → single `{state}.svg` flat file → built-in fallback. External theme SVGs are sanitized via `SVGSanitizer` (strips `<script>`, event handlers, `javascript:` URLs).

`theme.json` manifest supports optional fields: `sounds` (state→filename mapping), `eyeTracking`, `reactions` (click/drag SVGs), `viewBox`, `workingTiers` (multi-session animations). All optional and backward compatible.

### Sound System

`SoundManager` plays audio on state transitions with 2-second per-state cooldown. Three-tier resolution: user custom sounds (`~/Application Support/notchikko/sounds/`) → theme sounds (`themes/{id}/sounds/`, using manifest `sounds` mapping then directory scan) → built-in sounds (bundle `.wav`). Soundable states: happy, error, approving, session-start. Volume: continuous float 0.0–1.0 via PreferencesStore.

### State Transitions

No priority-based gating — `transition(to:)` always accepts the new state (only blocked by `isDragging`). Note: `NotchikkoState.priority` exists but is unused — vestigial from an earlier design. Tool→State mapping: Read/Grep/Glob→reading, Edit/Write/NotebookEdit→typing, Bash→building, others→typing. Non-tool phases: processing→thinking (LLM generating), compacting→sweeping (context compaction). Error states auto-return to idle after 5s; happy (task complete) triggers 3s celebration then auto-switches session. Notification events (Elicitation/AskUserQuestion) set approving state indefinitely until next event. Approving state is interruptible by any event (like idle/sleeping).

### Key Patterns

- **@Observable** for SwiftUI reactivity (SessionManager, PreferencesStore, ApprovalManager)
- **AsyncStream** for event listening from SocketServer
- **Callback closures** wired in AppDelegate for cross-module communication (onApprovalRequest, onTerminalPidUpdate, onTerminalTtyUpdate, onPermissionModeUpdate, onClick, onDragStart/End, etc.)
- **`CLIHookConfig.metadata(for:)`** — single source of truth for agent icon/name mapping (no duplicated switch statements)
- SVG files are pre-oriented (hanging upside-down) — no code flipping
- `NotchikkoView.updateEyePosition(dx:dy:)` does JS-based eye tracking via `#eyes-js` and `#body-js` SVG element IDs
- Click on Clawd → jump to the active session's terminal window (via TerminalJumper); right-click → context menu
- All source files are in `Notchikko/` subdirectories; `docs/internal/competitive-analysis/` contains reference implementations — not part of build
