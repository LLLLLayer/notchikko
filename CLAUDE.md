# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Notchikko is a macOS app that displays an animated pixel crab ("Clawd") hanging from the MacBook notch. It acts as a visual indicator of Claude Code (and other AI CLI) activity, showing different SVG animations as the agent reads, writes, builds, etc. Runs as an accessory app (no dock icon) with a menu bar status item.

## Build & Run

Standard Xcode project — zero external dependencies. Targets macOS 14.0+, Swift 5.

```bash
xcodebuild -scheme Notchikko -configuration Debug build
```

No tests or linting configured. SourceKit frequently reports false-positive "Cannot find type" errors — always verify with `xcodebuild` before investigating.

## Architecture

Event-driven pipeline:

```
CLI hook → notchikko-hook.sh → Unix socket → ClaudeCodeAdapter → SessionManager → NotchikkoState → ThemeProvider → NotchikkoView
```

### Core Modules

- **IPC** — `SocketServer` listens on `/tmp/notchikko.sock`. `HookInstaller` registers hooks in `~/.claude/settings.json` (nested format: `{"hooks":[{"type":"command","command":"..."}]}`). Supports 16 hook events. For approval requests, keeps socket fd open in `pendingResponses` dict until app writes back.

- **Agent** — `AgentBridge` protocol. `ClaudeCodeAdapter` converts `HookEvent` → `AgentEvent` via AsyncStream. Performs **synthetic session injection** — auto-yields `.sessionStart` on first event from unknown session ID. AppDelegate creates a single adapter and consumes its stream directly (no registry layer).

- **Session** — `SessionManager` (@Observable) tracks multiple sessions, maps tools to visual states, manages idle/sleep timers (60s/120s). Supports pinned session binding with auto-switch: after task completion (Stop event), celebrates 3s then auto-unpins and switches to next active session. Sessions store terminal PID, tty path, and prompt text for subtitle display. Max 32 concurrent sessions with LRU eviction.

- **Terminal** — `TerminalJumper` activates the terminal window for a session. `KnownTerminal` enum maps bundle IDs to display names and focus strategies for 13 supported terminals. Three focus strategies: `appleScriptTty` (iTerm2, Terminal.app — locates tab by tty), `appleScriptCwd` (Ghostty — locates surface by cwd), `generic` (all others — activate app only).

- **Theme** — `ThemeProvider` resolves SVGs by state. Built-in "clawd" theme from bundle; custom themes from `~/.notchikko/themes/{id}/` with `theme.json` manifest mapping state names to SVG filenames. Falls back to built-in for missing SVGs.

- **Notchikko (core)** — `NotchikkoState` enum defines 11 states with priority, svgName, revealAmount, soundKey. `NotchikkoView` wraps WKWebView, loads SVG via `loadSVG(for: NotchikkoState)` which resolves through `ThemeProvider.svgURL(for:)`. SVG transitions use JS-injected crossfade (0.3s opacity transition) — first load uses full HTML, subsequent loads inject via `evaluateJavaScript`. Note: `svgName` property exists on `NotchikkoState` but is currently unused; ThemeProvider matches built-in SVGs by `{state.rawValue}-` filename prefix.

- **Window** — `NotchPanel` (borderless NSPanel) positioned via `NotchGeometry` relative to hardware notch. `DragController` handles drag with 5pt threshold, hit area padded +20px. Cross-screen drag rebuilds the window on the target screen; same-screen drag animates back to home position.

- **Approval** — Separate `NSPanel` window (independent of pet panel — doesn't move during drag). `ApprovalManager` manages pending requests. Only Bash/Edit/Write/NotebookEdit require approval. Hook script checks `skipDangerousModePermissionPrompt` to skip when bypass mode is on. "Auto Approve" button writes `skipDangerousModePermissionPrompt: true` to `~/.claude/settings.json`.

- **Preferences** — `PreferencesStore` (@Observable) auto-saves on `didSet` with 100ms debounce. Only `petScale` and `themeId` changes trigger window rebuild notification.

- **i18n** — All UI strings use `String(localized:)` (SwiftUI) or `NSLocalizedString()` (AppKit). Translations in `Resources/{en,zh-Hans}.lproj/Localizable.strings`.

### Hook Script

`notchikko-hook.sh [source]` — Bash wrapper around inline Python3. Reads stdin JSON from CLI, maps events to status, sends to socket. The `source` arg ("claude-code", "trae-cli", etc.) selects the JSON parser — Trae CLI uses a different schema (`event_type` + nested body) that gets normalized to the same socket format. For PreToolUse on modification tools (Bash/Edit/Write/NotebookEdit), generates UUID `request_id` and blocks waiting for approval response (5 min timeout, defaults to allow). Also walks the process tree (up to 15 levels) to detect the parent terminal PID and tty.

### SVG / Themes

Built-in SVGs live in `Resources/themes/clawd/{state}/{state}-default.svg` (e.g. `idle/idle-default.svg`, `building/building-default.svg`). Xcode flattens subdirectories at build time — `ThemeProvider.builtinSVG(for:)` scans the resource bundle for files matching the `{state.rawValue}-` prefix. Each state directory can hold multiple SVG variants — ThemeProvider picks one at random on each transition.

Custom theme packs go in `~/.notchikko/themes/{id}/` with a `theme.json` manifest. Resolution order: custom theme directory → single `{state}.svg` flat file → built-in fallback.

### State Transitions & Priority

States have numeric priorities: sleeping(10), idle(20), thinking(50), sweeping(53), reading(55), typing(60), building(70), happy(80), error(90), approving(95), dragging(100). `SessionManager.transition(to:)` only moves to a higher-priority state unless current state is idle/sleeping. Tool→State mapping: Read/Grep/Glob→reading, Edit/Write/NotebookEdit→typing, Bash→building, others→typing. Error states auto-return to idle after 5s; happy (task complete) triggers 3s celebration then auto-switches session.

### Global Hotkeys

⌘Y = approve, ⌘N = deny (only active when an approval is pending). Registered as local NSEvent monitor in AppDelegate.

### Key Patterns

- **@Observable** for SwiftUI reactivity (SessionManager, PreferencesStore, ApprovalManager)
- **AsyncStream** for event listening from SocketServer
- **Callback closures** wired in AppDelegate for cross-module communication (onApprovalRequest, onTerminalPidUpdate, onTerminalTtyUpdate, onClick, onDragStart/End, etc.)
- SVG files are pre-oriented (hanging upside-down) — no code flipping
- `NotchikkoView.updateEyePosition(dx:dy:)` does JS-based eye tracking via `#eyes-js` and `#body-js` SVG element IDs
- Click on Clawd → jump to the active session's terminal window (via TerminalJumper); right-click → context menu
- All source files are in `Notchikko/` subdirectories; `docs/internal/competitive-analysis/` contains reference implementations — not part of build
