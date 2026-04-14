---
name: theme-guide
description: "Notchikko theme and SVG system reference — how Clawd's visual states are resolved and rendered. MUST use this skill when: adding/modifying SVG animations, creating or editing themes, changing ThemeProvider logic, modifying NotchikkoView rendering, adjusting NotchikkoState visual properties (svgName, revealAmount), working with files in Theme/, Notchikko/NotchikkoView.swift, Notchikko/NotchikkoState.swift, Views/NotchContentView.swift, or Resources/themes/. Also use when the user mentions SVG, animation, theme, pixel art, eye tracking, or visual states."
allowed-tools: Read Grep Glob Edit Write
paths: "Notchikko/Theme/**,Notchikko/Notchikko/NotchikkoState.swift,Notchikko/Notchikko/NotchikkoView.swift,Notchikko/Views/NotchContentView.swift,Notchikko/Resources/themes/**"
---

# Notchikko Theme & SVG System

This skill covers the full visual pipeline: how states map to SVGs, how themes are resolved, how SVGs are rendered, and how to add new visual content.

## Built-in Theme Structure

SVGs are in `Resources/themes/clawd/`, organized by state subdirectories:

```
Resources/themes/clawd/
  sleeping/sleeping-default.svg
  idle/idle-default.svg
  thinking/thinking-default.svg
  reading/reading-default.svg
  typing/typing-default.svg
  building/building-default.svg
  sweeping/sweeping-default.svg
  happy/happy-default.svg
  error/error-default.svg
  dragging/dragging-default.svg
  approving/approving-default.svg
```

### File Naming Convention

**Files MUST be named `{state}-{variant}.svg`** (e.g., `idle-default.svg`, `idle-wink.svg`).

Why: Xcode's `PBXFileSystemSynchronizedRootGroup` flattens all resources into the bundle root at build time. The state prefix ensures global uniqueness across directories and enables prefix-based scanning at runtime.

### Adding SVG Variants

Drop additional SVGs into the state folder with the correct prefix. When the app transitions to that state, ThemeProvider randomly picks one from all available variants.

Example: adding `happy/happy-dance.svg` and `happy/happy-spin.svg` alongside `happy/happy-default.svg` means each task completion randomly shows one of three celebrations.

## ThemeProvider Resolution (Theme/ThemeProvider.swift)

### Built-in theme (`currentThemeId == "clawd"`)

```swift
builtinSVG(for: .idle)
  // Scans Bundle.main.resourceURL for files matching "idle-*.svg"
  // Returns a random match
```

### Custom theme (at `~/.notchikko/themes/{id}/`)

Resolution order:

1. **Directory mode**: `{themeDir}/{dirName}/` exists as directory → scan all `.svg` files inside → random pick
2. **Flat file mode** (backward compat): `{themeDir}/{dirName}.svg` exists → use it directly
3. **Built-in fallback**: neither found → fall back to `builtinSVG(for:)`

Where `dirName` comes from the theme's `theme.json` manifest `animations` mapping (if present), otherwise defaults to `state.rawValue`.

## Custom Theme Authoring

### Directory-based (recommended, supports random selection)

```
my-theme/
  theme.json
  sleeping/
    sleeping-1.svg
  idle/
    idle-1.svg
    idle-2.svg          ← multiple = random each transition
  thinking/
    thinking-1.svg
  ...
```

### Flat file (backward compatible)

```
my-theme/
  theme.json
  sleeping.svg
  idle.svg
  ...
```

### theme.json Manifest

```json
{
  "name": "My Custom Theme",
  "author": "Your Name",
  "version": "1.0",
  "animations": {
    "sleeping":  "sleeping",
    "idle":      "idle",
    "thinking":  "thinking",
    "reading":   "reading",
    "typing":    "typing",
    "building":  "building",
    "sweeping":  "sweeping",
    "happy":     "happy",
    "error":     "error",
    "dragging":  "dragging",
    "approving": "approving"
  }
}
```

- `name` (required): display name in settings picker
- `author`, `version`: optional metadata
- `animations`: maps state rawValue → directory name (or filename without `.svg` for flat mode). Omitted states fall back to built-in Clawd.

Model: `ThemeManifest` struct in `Theme/ThemeProvider.swift`.

### Installation

- Manual: `cp -r my-theme ~/.notchikko/themes/`
- Programmatic: `ThemeProvider.importTheme(from: URL)` copies folder to `~/.notchikko/themes/{folder-name}/`
- Select in Settings → Theme picker

## SVG Requirements

- **Pixel art style**: use `image-rendering: pixelated` in SVG CSS
- **Self-contained animations**: each SVG includes its own `<style>` block with CSS `@keyframes`
- **Orientation**: design hanging upside-down — head at bottom, legs/claws at top. No code flipping is applied.
- **Default size**: rendered at 80×80px (scaled by `PreferencesStore.petScale`: 0.6/1.0/1.5)
- **Transparent background**: no `<rect>` background — SVG floats over desktop

### Eye Tracking (optional)

Add elements with these IDs for mouse-following parallax:

```xml
<g id="eyes-js">...</g>   <!-- receives transform: translate(dx, dy) -->
<g id="body-js">...</g>   <!-- receives transform: translate(dx*0.3, dy*0.3) -->
```

Driven by `NotchikkoView.updateEyePosition(dx:dy:)` which injects JavaScript into WKWebView.

## All 11 Visual States

| State | rawValue | revealAmount | Priority | SVG Dir | Trigger |
|---|---|---|---|---|---|
| `sleeping` | `sleeping` | 0.05 | 10 | `sleeping/` | No activity 120s |
| `idle` | `idle` | 0.30 | 20 | `idle/` | SessionStart, idle 60s |
| `thinking` | `thinking` | 0.40 | 50 | `thinking/` | UserPromptSubmit |
| `reading` | `reading` | 0.40 | 55 | `reading/` | Read/Grep/Glob |
| `typing` | `typing` | 0.50 | 60 | `typing/` | Edit/Write/NotebookEdit |
| `building` | `building` | 0.50 | 70 | `building/` | Bash |
| `sweeping` | `sweeping` | 0.45 | 53 | `sweeping/` | PreCompact |
| `happy` | `happy` | 0.60 | 80 | `happy/` | Stop (task complete) |
| `error` | `error` | 0.50 | 90 | `error/` | Failure events |
| `approving` | `approving` | 0.80 | 95 | `approving/` | Approval pending |
| `dragging` | `dragging` | 1.00 | 100 | `dragging/` | User drags crab |

- `revealAmount`: how far crab peeks below the notch (0 = hidden, 1 = fully visible)
- `priority`: governs state transitions — only higher-priority states override current

## Rendering Pipeline

```
NotchikkoState change
  → NotchContentView (SwiftUI, observes SessionManager.currentState)
    → NotchikkoRepresentable (NSViewRepresentable bridge)
      → NotchikkoView.loadSVG(for: state)
        → ThemeProvider.svgURL(for: state)  // resolves SVG file
        → Read SVG string, wrap in HTML template
        → WKWebView.loadHTMLString()        // renders with pixelated scaling
```

The HTML wrapper sets `image-rendering: pixelated` and fills the view. `NotchikkoView` caches `currentSVG` by state rawValue and skips reload if the state hasn't changed (prevents re-randomizing on SwiftUI re-renders).

## Adding a New Visual State — Checklist

1. **`NotchikkoState`** (`Notchikko/NotchikkoState.swift`): add enum case with `svgName`, `revealAmount`, `soundKey`, `priority`
2. **Create SVG directory**: `Resources/themes/clawd/{state}/` with at least one `{state}-default.svg`
3. **`SessionManager`**: map the triggering event to the new state (in `handleEvent` or `stateForTool`)
4. If the state needs sound: add mapping in `SoundManager.defaultSoundMap` and `soundableStates`

## Key Files

| File | Role |
|---|---|
| `Resources/themes/clawd/{state}/` | Built-in SVG assets per state |
| `Theme/ThemeProvider.swift` | SVG URL resolution, theme import, manifest loading |
| `Notchikko/NotchikkoState.swift` | State enum: svgName, revealAmount, priority, soundKey |
| `Notchikko/NotchikkoView.swift` | WKWebView renderer, SVG loading, eye tracking JS |
| `Views/NotchContentView.swift` | SwiftUI ↔ NSViewRepresentable bridge |
| `Preferences/PreferencesStore.swift` | petScale, themeId settings |
| `Sound/SoundManager.swift` | State transition sound effects |
| `~/.notchikko/themes/{id}/` | Custom themes directory |
