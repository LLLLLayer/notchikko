# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Notchikko is a macOS app that displays an animated character ("Clawd") hanging from the MacBook notch. It acts as a visual indicator of Claude Code (and other AI agent) activity, showing different animations as the agent reads, writes, builds, etc. Runs as an accessory app (no dock icon) with a menu bar status item.

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

- **IPC** — `SocketServer` listens on `/tmp/notchikko.sock` for JSON hook events. `HookInstaller` manages hook registration in `~/.claude/settings.json` and `~/.codex/config.json`, copying `notchikko-hook.sh` to `~/.notchikko/hooks/`.

- **Agent** — `AgentBridge` protocol abstracts any AI agent. `ClaudeCodeAdapter` wraps SocketServer, converting raw `HookEvent` JSON into unified `AgentEvent` enums emitted via AsyncStream. `AgentRegistry` supports multiple adapters.

- **Session** — `SessionManager` is the main state machine. Tracks multiple active sessions by working directory, maps tool names to visual states (Read/Grep→reading, Edit/Write→typing, Bash→building), and auto-transitions to idle/sleeping after inactivity (60s/120s).

- **Notchikko (core)** — `NotchikkoState` enum defines visual states (sleeping, idle, thinking, reading, typing, building, sweeping, happy, error, dragging, approving) with priority levels. `NotchikkoView` is an NSView wrapping WKWebView that loads SVG animations from the bundle.

- **Window** — `NotchPanel` is a borderless, always-on-top NSPanel. `NotchGeometry` positions the panel relative to the hardware notch (or top of screen). `DragController` handles drag-to-reposition with a 5pt threshold.

- **Approval** — `ApprovalManager` shows approve/deny cards for tool approval requests received via the socket. Global hotkeys: ⌘Y approve, ⌘N deny. Sends JSON decision back through the socket connection.

- **Preferences** — `PreferencesStore` persists settings (petScale, soundVolume, approvalCardHideDelay, installedHooks) as JSON in `~/Library/Application Support/notchikko/preferences.json`.

- **Sound** — `SoundManager` plays WAV files on state transitions. Supports custom sound import to `~/Library/Application Support/notchikko/sounds/`.

- **Terminal** — `TerminalJumper` uses Accessibility API to find and activate the terminal window matching a session's working directory (supports Terminal, iTerm, Warp, Kitty).

### Key Patterns

- **@Observable** classes for SwiftUI reactivity (SessionManager, PreferencesStore, ApprovalManager)
- **AsyncStream** for continuous event listening from SocketServer
- **Callback closures** wired through init for cross-module communication (drag, approval, menu actions)
- **Priority-based state transitions** — higher-priority states (dragging=100, approving=95) override lower ones

### Entry Point

`AppDelegate` is the orchestrator — initializes all components on launch, creates the NotchPanel, starts the SocketServer, and wires up event handlers. `NotchikkoApp` (@main) is a minimal SwiftUI shell.
