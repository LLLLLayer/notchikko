# Notchikko Theme Authoring Guide

Create custom pixel art themes for Clawd, the crab that hangs from your MacBook notch.

## Theme Structure

A theme is a folder containing a `theme.json` manifest and SVG animation files:

```
my-theme/
  theme.json
  sleeping.svg
  idle.svg
  prompt.svg
  tool-edit.svg
  tool-bash.svg
  compact.svg
  stop.svg
  error.svg
  drag.svg
```

## theme.json

```json
{
  "name": "My Custom Theme",
  "author": "Your Name",
  "version": "1.0",
  "animations": {
    "sleeping":  "sleeping",
    "idle":      "idle",
    "thinking":  "prompt",
    "reading":   "tool-edit",
    "typing":    "tool-edit",
    "building":  "tool-bash",
    "sweeping":  "compact",
    "happy":     "stop",
    "error":     "error",
    "dragging":  "drag",
    "approving": "idle"
  }
}
```

### Fields

| Field | Required | Description |
|---|---|---|
| `name` | Yes | Display name shown in settings |
| `author` | No | Theme author |
| `version` | No | Theme version |
| `animations` | No | State-to-SVG mapping (keys = state names, values = SVG filenames without `.svg`) |

### State Names

| State | Trigger | Description |
|---|---|---|
| `sleeping` | No active sessions | Crab is asleep, barely visible |
| `idle` | SessionStart / Stop | Crab is awake, waiting |
| `thinking` | UserPromptSubmit | Crab is thinking/processing |
| `reading` | PreToolUse: Read/Grep/Glob | Crab is reading files |
| `typing` | PreToolUse: Edit/Write | Crab is writing code |
| `building` | PreToolUse: Bash | Crab is running commands |
| `sweeping` | PreCompact | Crab is cleaning up context |
| `happy` | Stop (task complete) | Crab celebrates |
| `error` | StopFailure / PostToolUseFailure | Crab shows error |
| `dragging` | User drags the crab | Crab being dragged |
| `approving` | PreToolUse approval pending | Crab waiting for user approval |

If `animations` is omitted or a state is missing, the built-in Clawd SVG is used as fallback.

## SVG Requirements

- **Pixel art style**: Use `image-rendering: pixelated` in your SVGs
- **Self-contained**: Each SVG should include its own CSS animations
- **Orientation**: SVGs are rendered as-is — design them hanging upside-down from the notch (head at bottom, legs at top)
- **Size**: SVGs are rendered at 80x80px by default (scalable via settings)
- **Transparent background**: No background color — the SVG floats over the desktop

### Optional: Eye Tracking

To support eye tracking, add elements with these IDs:
- `id="eyes-js"` — will receive `transform: translate(dx, dy)` based on mouse position
- `id="body-js"` — will receive `transform: translate(dx*0.3, dy*0.3)` for subtle body sway

## Installation

### Via Settings Panel

1. Open Notchikko Settings → Display
2. Click "Import Theme..."
3. Select your theme folder
4. Choose the theme from the dropdown

### Manual

Copy your theme folder to `~/.notchikko/themes/`:

```bash
cp -r my-theme ~/.notchikko/themes/
```

Then select it in Settings → Display → Theme.

## Example: Minimal Theme

A theme only needs `theme.json` and at least one SVG. Missing states fall back to built-in Clawd:

```
minimal-theme/
  theme.json    → { "name": "Minimal", "animations": { "idle": "my-idle" } }
  my-idle.svg   → Your custom idle animation
```
