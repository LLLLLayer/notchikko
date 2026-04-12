# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Notchikko is a macOS app that displays an animated pixel crab ("Clawd") hanging from the MacBook notch. It acts as a visual indicator of Claude Code (and other AI CLI) activity, showing different SVG animations as the agent reads, writes, builds, etc. Runs as an accessory app (no dock icon) with a menu bar status item.

## Build & Run

This is a standard Xcode project (no SPM, no CocoaPods — zero external dependencies).

```bash
# Open in Xcode
open Notchikko.xcodeproj

# Build from CLI
xcodebuild -project Notchikko.xcodeproj -scheme Notchikko -configuration Debug build

# Clean build
xcodebuild -project Notchikko.xcodeproj -scheme Notchikko clean build
```

There are no tests or linting configured.

## Architecture

The app follows an event-driven pipeline:

```
Claude Code hook → Unix socket → AgentBridge → SessionManager → NotchikkoState → NotchikkoView (SVG)
```

### Core Modules

- **IPC** — `SocketServer` listens on `/tmp/notchikko.sock` for JSON hook events. `HookInstaller` manages hook registration in `~/.claude/settings.json` and `~/.codex/config.json`, copying `notchikko-hook.sh` to `~/.notchikko/hooks/`. Multi-CLI support via `CLIHookConfig` structs — each CLI gets the same hook script injected into its own settings file. Detection checks for "notchikko" substring in serialized hook entries.

- **Agent** — `AgentBridge` protocol abstracts any AI agent. `ClaudeCodeAdapter` wraps SocketServer, converting raw `HookEvent` JSON into unified `AgentEvent` enums emitted via AsyncStream. Important: adapter performs **synthetic session injection** — on first sight of an unknown session ID, it auto-yields `.sessionStart` before the actual event, handling mid-session hook installation. `AgentRegistry` supports multiple adapters.

- **Session** — `SessionManager` is the main state machine. Tracks multiple active sessions by working directory, maps tool names to visual states, and auto-transitions to idle/sleeping after inactivity (60s idle, 120s sleep timers that reset on activity). Users can pin a session ID to override auto-tracking of the most recent session.

- **Notchikko (core)** — `NotchikkoState` enum defines visual states (sleeping, idle, thinking, reading, typing, building, sweeping, happy, error, dragging, approving) with priority levels. State transitions only occur if new state priority >= current, OR current is idle/sleeping. `NotchikkoView` is an NSView wrapping WKWebView that loads SVG animations from the bundle as HTML strings with `image-rendering: pixelated`. Eye tracking via JavaScript injection on `#eyes-js` and `#body-js` elements.

- **Window** — `NotchPanel` is a borderless, always-on-top NSPanel. `NotchGeometry` positions the panel relative to the hardware notch — detects notch via `screen.safeAreaInsets.top > 0`, derives width from `auxiliaryTopLeftArea`/`auxiliaryTopRightArea`. Panel top is anchored to the screen's physical top (not safe area) so content hides behind hardware notch. `DragController` handles drag-to-reposition with a 5pt threshold; captures `stateBeforeDrag` and restores it post-animation to prevent layout jitter.

- **Approval** — `ApprovalManager` shows approve/deny cards for tool approval requests. Requests carry a `request_id` UUID and keep the socket connection open (hook script waits up to 300s, defaults to "allow" on timeout). Response sent back via `SocketServer.respond(requestId:json:)` to the held file descriptor. Global hotkeys: ⌘Y approve, ⌘N deny. Only modified tools (Bash, Edit, Write, NotebookEdit) require approval.

- **Preferences** — `PreferencesStore` persists settings (petScale, soundVolume, approvalCardHideDelay, installedHooks) as JSON in `~/Library/Application Support/notchikko/preferences.json`. Changes debounce writes with 100ms delay; `petScale` changes trigger UI refresh.

- **Sound** — `SoundManager` plays WAV files on state transitions. Each `NotchikkoState` has a `soundKey` mapping. Approval decisions play "nod"/"shake" sounds. Supports custom sound import to `~/Library/Application Support/notchikko/sounds/`.

- **Terminal** — `TerminalJumper` uses Accessibility API to find and activate the terminal window matching a session's working directory (supports Terminal, iTerm, Warp, Kitty).

### IPC Protocol

Hook events are JSON objects sent over the Unix socket with this schema:
```json
{
  "session_id": "string",
  "cwd": "/path/to/working/dir",
  "event": "UserPromptSubmit | ToolUse | ToolResult | Stop | ...",
  "status": "string (optional)",
  "tool": "Read | Edit | Bash | Write | ... (optional)",
  "tool_input": { ... },
  "source": "claude-code | codex | ...",
  "request_id": "UUID (for approval requests only)"
}
```

### Tool-to-State Mapping

`SessionManager.stateForTool()` converts tool names to visual states:
- `Read`, `Grep`, `Glob` → `.reading`
- `Edit`, `Write`, `NotebookEdit` → `.typing`
- `Bash` → `.building`
- All others → `.typing` (default fallback)

### State Priority Levels

Higher-priority states override lower ones: dragging(100) > approving(95) > error(90) > ... > sleeping(10). Each state defines `svgName`, `revealAmount`, and `soundKey`.

### Key Patterns

- **@Observable** classes for SwiftUI reactivity (SessionManager, PreferencesStore, ApprovalManager)
- **AsyncStream** for continuous event listening from SocketServer
- **Callback closures** wired through init in `AppDelegate` for cross-module communication (drag, approval, menu actions)
- SVG files in `Resources/svg/` are pre-oriented — no code flipping. Named `clawd-{state}.svg` (e.g., `clawd-idle.svg`, `clawd-tool-bash.svg`)
- The `docs/internal/competitive-analysis/` directory contains reference implementations of similar apps (Claude Island, notchi) — not part of the build

### Entry Point

`AppDelegate` is the orchestrator — initializes all components on launch, creates the NotchPanel, starts the SocketServer, and wires up event handlers. `NotchikkoApp` (@main) is a minimal SwiftUI shell.
