---
name: clawd-svg-creator
description: |
  Create animated pixel-art SVG characters for the Clawd mascot system.
  Use when: user asks to create/modify clawd SVGs, add new character poses,
  design pixel art animations, or work with the Notchikko hook state system.
  Covers: body templates (front/side), CSS keyframe animations, state-folder mapping,
  color palette, and common pitfalls.
---

# Clawd SVG Creator

Hand-craft animated pixel-art SVG characters for the Clawd companion system. Each SVG is a self-contained animated character using `<rect>` elements and CSS keyframes — NO raster images, NO frame-by-frame switching.

SVGs live in `Notchikko/Resources/themes/clawd/{state}/` — e.g. `idle/idle-peeking.svg`, `building/building-construction.svg`. ThemeProvider picks a random variant per state transition.

## Quick Start

```xml
<svg xmlns="http://www.w3.org/2000/svg" viewBox="-8 -16 32 18"
     preserveAspectRatio="xMidYMin meet" width="500" height="500">
  <defs><style>/* animations here */</style></defs>
  <g transform="scale(1, -1)">
    <!-- character here (Y-axis flipped: feet at top, head at bottom) -->
  </g>
</svg>
```

## CRITICAL Rules

1. **viewBox must be `-8 -16 32 18`** for all standard SVGs (use `32 10` height for peeking/clipped variants). This ensures consistent sizing and room for effects.
2. **Y-axis is flipped** via `scale(1, -1)`. The pig hangs from the top (feet up, head down). Higher Y values in source = closer to top of rendered output. This means:
   - y=15 = ground/shadow (rendered at top)
   - y=12-15 = legs (top of character visually)
   - y=6-12 = body (middle)
   - y=5-6 = head stripe (bottom of character visually)
   - **Props on "upper body" (near legs) use HIGH y values (y=10-12), NOT low y values (y=6-8)**
   - **Props on "lower body" (near head) use LOW y values (y=6-8)**
3. **Eyes are 1x1**, NOT 1x2. This matches the actual character design.
4. **Eye blink transform-origin**: ALWAYS use `transform-box: fill-box; transform-origin: center;` — NEVER use absolute px coordinates like `7.5px -8px`, which causes eyes to fly off during blink.
5. **Never use broad `sed` on SVG files**. A command like `sed 's/width="[0-9]*"/width="500"/'` will destroy ALL rect dimensions, not just the `<svg>` element. Always target specific lines or use precise patterns.
6. **Integer coordinates** for all body rects. Fractional values OK for small details (eye heights, highlights).
7. **All animations are CSS `@keyframes`**. No JavaScript, no SMIL `<animate>`.
8. **SVG render order = z-order**. Elements drawn later appear ON TOP. If a keyboard/prop is drawn before the body, the body will cover it. Always draw overlapping props AFTER the body rect.
9. **Only create/modify the files asked for**. Never batch-modify existing files unless explicitly requested.

## Body Templates

### Front-Facing Body

```xml
<!-- Head stripe (darker forehead, visually at bottom) -->
<rect x="2" y="5" width="11" height="1" fill="#C07050"/>
<!-- Main body -->
<rect x="2" y="6" width="11" height="6" fill="#DE886D"/>
<!-- Left arm -->
<rect x="0" y="9" width="2" height="2" fill="#DE886D"/>
<!-- Right arm -->
<rect x="13" y="9" width="2" height="2" fill="#DE886D"/>
<!-- Eyes (1x1!) -->
<rect x="5" y="8" width="1" height="1" fill="#000"/>
<rect x="10" y="8" width="1" height="1" fill="#000"/>
<!-- Legs (4 columns, height=3, visually at top) -->
<rect x="3" y="12" width="1" height="3" fill="#DE886D"/>
<rect x="5" y="12" width="1" height="3" fill="#DE886D"/>
<rect x="9" y="12" width="1" height="3" fill="#DE886D"/>
<rect x="11" y="12" width="1" height="3" fill="#DE886D"/>
<!-- Ground shadow -->
<rect x="3" y="15" width="9" height="1" fill="#000" opacity="0.4"/>
```

### Side-Facing Body (facing LEFT)

```xml
<!-- Ear -->
<rect x="13" y="5" width="2" height="1" fill="#DE886D"/>
<!-- Main body (ONE single block — do NOT split into 3 bands, it looks broken) -->
<rect x="2" y="6" width="13" height="7" fill="#DE886D"/>
<!-- Snout (extends left from body) -->
<rect x="0" y="9" width="2" height="3" fill="#DE886D"/>
<!-- Eyes -->
<rect x="4" y="9" width="1" height="1" fill="#000"/>
<rect x="9" y="9" width="1" height="1" fill="#000"/>
<!-- Legs -->
<rect x="3" y="13" width="1" height="2" fill="#DE886D"/>
<rect x="5" y="13" width="1" height="2" fill="#DE886D"/>
<rect x="11" y="13" width="1" height="2" fill="#DE886D"/>
<rect x="13" y="13" width="1" height="2" fill="#DE886D"/>
<!-- Shadow (wider) -->
<rect x="1" y="15" width="14" height="1" fill="#000" opacity="0.4"/>
```

### Sleeping/Sploot Pose

```xml
<!-- Flattened wide torso (melted flat) -->
<rect x="1" y="10" width="13" height="5" fill="#DE886D"/>
<!-- Arms spread flat -->
<rect x="-1" y="13" width="2" height="2" fill="#DE886D"/>
<rect x="14" y="13" width="2" height="2" fill="#DE886D"/>
<!-- Legs pointing UP (relaxed sploot) -->
<rect x="3" y="9" width="1" height="1" fill="#DE886D"/>
<rect x="5" y="9" width="1" height="1" fill="#DE886D"/>
<rect x="9" y="9" width="1" height="1" fill="#DE886D"/>
<rect x="11" y="9" width="1" height="1" fill="#DE886D"/>
<!-- Eyes shut (thin dashes) -->
<rect x="3.5" y="12.5" width="2" height="0.4" fill="#000"/>
<rect x="9.5" y="12.5" width="2" height="0.4" fill="#000"/>
```

### Typing/Keyboard Pose (reference: `typing/typing-programmer.svg`)

This is the gold-standard for keyboard/typing characters. Key layout:

```
Visually top-to-bottom (high Y to low Y in source):
  y=12-15  Legs (alternating kick-a / kick-b)
  y=10-12.5 Keyboard (3 rows + key flashes, rendered AFTER body)
  y=10-12  Arms (at keyboard edges, left x=0, right x=13)
  y=8      Eyes (peeking below keyboard)
  y=6-12   Body rect
  y=5-6    Head stripe
```

```xml
<!-- Legs (alternating kicks) -->
<g fill="#DE886D">
  <rect class="kick-a" x="3" y="12" width="1" height="3"/>
  <rect class="kick-b" x="5" y="12" width="1" height="3"/>
  <rect class="kick-a" x="9" y="12" width="1" height="3"/>
  <rect class="kick-b" x="11" y="12" width="1" height="3"/>
</g>

<!-- Body (draw BEFORE keyboard so keyboard renders on top) -->
<g class="breathe">
  <rect x="2" y="5" width="11" height="1" fill="#C07050"/>
  <rect x="2" y="6" width="11" height="6" fill="#DE886D"/>

  <!-- Arms at keyboard level -->
  <g class="arm-l"><rect x="0" y="10" width="2" height="2" fill="#DE886D"/></g>
  <g class="arm-r"><rect x="13" y="10" width="2" height="2" fill="#DE886D"/></g>

  <!-- Keyboard (AFTER body, same width, 3 rows) -->
  <g class="kb">
    <rect x="2" y="10" width="11" height="2.5" fill="#37474F" rx="0.2"/>
    <!-- Row 1: 12 keys at y=10.2 -->
    <!-- Row 2: 11 keys at y=10.9 -->
    <!-- Row 3 + space bar at y=11.6 -->
    <!-- Key flashes: 6 keys with staggered kf animation -->
  </g>

  <!-- Eyes peeking below keyboard -->
  <g class="blink">
    <rect x="5" y="8" width="1" height="1" fill="#000"/>
    <rect x="10" y="8" width="1" height="1" fill="#000"/>
  </g>
</g>
```

```css
/* Alternating leg kicks */
.kick-a { animation: kick-a 0.4s infinite ease-in-out; }
.kick-b { animation: kick-b 0.4s infinite ease-in-out; }
@keyframes kick-a { 0%,100%{transform:translateY(0)} 50%{transform:translateY(-0.5px)} }
@keyframes kick-b { 0%,100%{transform:translateY(-0.5px)} 50%{transform:translateY(0)} }

/* Keyboard bounce */
.kb { animation: kb 0.35s infinite ease-in-out; }
@keyframes kb { 0%,100%{transform:translateY(0)} 50%{transform:translateY(0.1px)} }

/* Arm typing rotation */
.arm-l { transform-origin: 1px 10px; animation: al 0.15s infinite alternate ease-in-out; }
.arm-r { transform-origin: 14px 10px; animation: ar 0.12s infinite alternate ease-in-out; }
@keyframes al { 0%{transform:rotate(-6deg)} 100%{transform:rotate(6deg)} }
@keyframes ar { 0%{transform:rotate(6deg)} 100%{transform:rotate(-6deg)} }

/* Key flash */
@keyframes kf { 0%,70%,100%{opacity:0} 35%{opacity:0.9} }
/* Apply with staggered timing: style="animation:kf .6s infinite;opacity:0" */
```

## Color Palette

| Element | Color | Notes |
|---|---|---|
| Body | `#DE886D` | Main pig body |
| Head stripe | `#C07050` | Darker forehead line |
| Eyes | `#000000` | Always 1x1 squares |
| Feet accent | `#C06848` | Optional darker feet |
| Hat gold | `#FBC02D` / `#F9A825` | Construction hat, gold details |
| Purple | `#5858A8` / `#3D3D8A` / `#2D2D6A` | Wizard hat, collars |
| Red | `#E53935` / `#C62828` | Caps, capes, hearts |
| Heart red | `#FF5252` | Love heart, alerts |
| Blue | `#1E3A8A` / `#6898D8` | Headphones, speech bubbles |
| Green | `#4CAF50` / `#78B848` | Shoes, bugs, code lines |
| Gray metal | `#78909C` / `#9E9E9E` | Tools, pipes, sockets |
| Dark mask | `#37474F` / `#263238` | Ninja, welder masks, keyboard bg |
| Keyboard keys | `#607D8B` (base) / `#90A4AE` (flash) | Key rects and flash highlight |
| White | `#FFFFFF` | Headband, chef hat, lab coat |
| Spark/gold | `#FFC107` / `#FFEB3B` | Sparks, stars, tape |
| Steam | `#B0BEC5` | Steam, dust, vapor |

## Animation Library

### Base Animations (use on almost every character)

```css
/* Breathing — subtle body scale pulse */
.breathe {
  transform-origin: 7.5px 10px;
  animation: breathe 3.2s infinite ease-in-out;
}
@keyframes breathe {
  0%, 100% { transform: scale(1, 1) translate(0, 0); }
  50% { transform: scale(1.02, 0.98) translate(0, 0.5px); }
}

/* Eye blink — ALWAYS use fill-box */
.blink {
  transform-box: fill-box;
  transform-origin: center;
  animation: blink 4s infinite;
}
@keyframes blink {
  0%, 10%, 100% { transform: scaleY(1); }
  5% { transform: scaleY(0.1); }
}
```

### Reusable Sparkle (pixel cross)

Define once in `<defs>`, reuse with `<use>`:

```xml
<!-- In <defs> -->
<g id="sp">
  <rect class="sp-c" x="-0.5" y="-0.5" width="1" height="1"/>
  <rect class="sp-o" x="-0.5" y="-1.5" width="1" height="1"/>
  <rect class="sp-o" x="-0.5" y="0.5" width="1" height="1"/>
  <rect class="sp-o" x="-1.5" y="-0.5" width="1" height="1"/>
  <rect class="sp-o" x="0.5" y="-0.5" width="1" height="1"/>
</g>

<!-- Usage -->
<use href="#sp" x="-4" y="8" fill="#FBC02D" style="--d:0s"/>
<use href="#sp" x="19" y="7" fill="#FFF59D" style="--d:.4s"/>
```

```css
.sp-c { opacity:0; animation: spc 1.5s infinite step-end; animation-delay: var(--d,0s); }
.sp-o { opacity:0; animation: spo 1.5s infinite step-end; animation-delay: var(--d,0s); }
@keyframes spc { 0%{opacity:0} 10%{opacity:1} 30%,100%{opacity:0} }
@keyframes spo { 0%{opacity:0} 20%{opacity:1} 40%,100%{opacity:0} }
```

### Floating Code Symbols

```xml
<text class="cf" x="-5" y="10" font-family="monospace" font-size="2"
      fill="#4CAF50" opacity="0" style="--d:0s;--dx:1px;--mx:0.5px">{</text>
```

```css
.cf { animation: cf 6s infinite ease-in-out; animation-delay: var(--d, 0s); }
@keyframes cf {
  0% { opacity:0; transform:translate(0,0); }
  12% { opacity:0.45; }
  50% { opacity:0.25; transform:translate(var(--dx,1px),-4px); }
  85%,100% { opacity:0; transform:translate(var(--mx,0.5px),-8px); }
}
```

### Notification Animations

Notification SVGs need STRONG attention-grabbing effects, not subtle. Include multiple of these:

```css
/* Badge pulse (scale in/out) */
.noti-badge {
  transform-box: fill-box; transform-origin: center;
  animation: noti-pulse 0.8s infinite ease-in-out;
}
@keyframes noti-pulse { 0%,100%{transform:scale(1)} 50%{transform:scale(1.3)} }

/* Expanding ring (radar-like) */
.noti-ring {
  transform-box: fill-box; transform-origin: center;
  animation: noti-ring 1.5s infinite ease-out;
}
@keyframes noti-ring { 0%{transform:scale(1);opacity:0.8} 100%{transform:scale(2.5);opacity:0} }

/* Exclamation blink */
.noti-blink { animation: noti-blink 0.6s infinite; }
@keyframes noti-blink { 0%,60%,100%{opacity:1} 30%{opacity:0.2} }

/* Alert body shake */
.alert-shake {
  transform-origin: 7.5px 10px;
  animation: alert-shake 0.3s infinite ease-in-out;
}
@keyframes alert-shake { 0%,100%{transform:rotate(0)} 25%{transform:rotate(2deg)} 75%{transform:rotate(-2deg)} }
```

Notification badge element (red circle with "!" mark):
```xml
<g>
  <rect class="noti-ring" x="12" y="3" width="3" height="3" rx="1"
        fill="none" stroke="#FF5252" stroke-width="0.3"/>
  <rect class="noti-badge" x="12.5" y="3.5" width="2" height="2" rx="1" fill="#FF5252"/>
  <rect class="noti-blink" x="13.2" y="3.8" width="0.6" height="0.8" fill="#FFF"/>
  <rect class="noti-blink" x="13.2" y="4.9" width="0.6" height="0.4" fill="#FFF"/>
</g>
```

### Work Animations (for building/typing states)

**Key principle**: Work animations should be BOLD and VISIBLE. Tool swings should be ±40-80°, not ±10°. Add particle effects (sparks, steam, bubbles). Sync body bounce with tool rhythm.

### Particle Patterns

```css
/* Floating particle (hearts, music notes, Zzz, bubbles) */
@keyframes float-up {
  0%   { opacity: 0; transform: translate(0, 0) scale(0.5); }
  10%  { opacity: 1; }
  100% { transform: translate(Xpx, -8px) scale(1); opacity: 0; }
}

/* Spark burst (welding, hammer impact) */
@keyframes spark {
  0%, 49%   { opacity: 0; transform: translate(0, 0) scale(0); }
  50%       { opacity: 1; transform: translate(0, 0) scale(1); }
  70%       { opacity: 0; transform: translate(Xpx, Ypx) scale(0); }
  71%, 100% { opacity: 0; }
}
```

## Hook Event → State → SVG Folder Mapping

| Hook Event | NotchikkoState | SVG Folder | Description |
|---|---|---|---|
| SessionStart | idle | idle/ | CLI ready, waiting for input |
| SessionEnd | sleeping | sleeping/ | Session closed |
| UserPromptSubmit | thinking | thinking/ | User sent a prompt |
| PreToolUse (Read/Grep/Glob) | reading | reading/ | Reading/searching files |
| PreToolUse (Edit/Write) | typing | typing/ | Editing/writing files |
| PreToolUse (Bash) | building | building/ | Running shell commands |
| PreToolUse (other) | typing | typing/ | Other tool usage |
| PostToolUse | thinking | thinking/ | Tool succeeded, back to thinking |
| PostToolUseFailure | error | error/ | Tool failed |
| PreCompact | sweeping | sweeping/ | Compacting context |
| Stop | happy | happy/ | Task completed successfully |
| Notification | approving | approving/ | Needs user attention |

## State → Folder Design Guide

| State | Folder | Character Should Feel | Animation Keys |
|---|---|---|---|
| idle | idle/ | Relaxed, patient, maybe bored | Weight shift, slow blink, occasional scratch |
| sleeping | sleeping/ | Dormant, knocked out | Sploot pose, Zzz particles, very slow breath |
| thinking | thinking/ | Contemplative, processing | Thought bubble, hand on chin, eyes up |
| reading | reading/ | Scanning, focused | Eyes scan L→R, hold book/magnifier, still body |
| typing | typing/ | Creating, rhythmic | Rapid hand motion, ink/keys, code output |
| building | building/ | Actively working HARD | Big tool swings ±40-80°, sparks, sweat, body bounce |
| sweeping | sweeping/ | Cleaning up, tidying | Broom, dust puffs, packing boxes, debris |
| happy | happy/ | Celebrating victory | Confetti, sparkles, big bounce, arms raised |
| error | error/ | Alert, danger | Red "!" flash, defensive stance, fast sway |
| approving | approving/ | Grabbing attention | Pulse, bounce, badge, shake, ring expand |
| dragging | dragging/ | Being moved by user | Dizzy, happy, panic poses |

## Workflow: Creating a New Character

1. **Pick the state** — which folder does this character belong to?
2. **Choose pose** — front-facing, side-facing, or sploot?
3. **Draw the body** — use the template above, add accessories
4. **Layer accessories** — hats, tools, props (SVG order = z-order, later = on top)
5. **Add base animations** — breathing + blink (almost always)
6. **Add character animations** — tool swings, particles, eye behavior
7. **Match the state mood** — refer to the Design Guide table above
8. **Verify Y positions** — remember flipped Y! Upper body props = high Y values, head area = low Y values
9. **Verify z-order** — props that should appear in front of the body must be drawn AFTER the body rect
10. **Save to** `Notchikko/Resources/themes/clawd/{state}/{state}-{name}.svg` (e.g. `building/building-blacksmith.svg`)
11. **Test in browser** — open the SVG directly, verify no clipping or eye drift

## Common Pitfalls

| Problem | Cause | Fix |
|---|---|---|
| Eyes fly off during blink | Absolute px transform-origin | Use `transform-box: fill-box; transform-origin: center` |
| Side body looks broken | Body split into 3 horizontal bands | Use ONE rect for main body + small snout rect |
| Effects clipped at edges | viewBox too small | Use standard `-8 -16 32 18` |
| All rects become huge after sed | `sed 's/width="N"/width="500"/'` matches ALL rects | Never use broad sed on SVG files |
| Animation too subtle | Tool swing only ±10° | Use ±40-80° for work tools, add particles |
| Character size inconsistent | Different viewBox values | ALL SVGs must share the same viewBox |
| Keyboard/prop on face | Y position too low (e.g. y=6-9) | Upper body props use HIGH y (y=10-12), because Y is flipped |
| Keyboard hidden behind body | Keyboard drawn before body in SVG | Draw keyboard AFTER body rect (later = on top) |
| Notification SVG not attention-grabbing | Only subtle animations | Add noti-badge pulse + ring expand + body shake + blink |
| Eyes hidden by accessories | Hat/mask covers eye area with no gap | Ensure eyes are visible — add gaps or position eyes outside accessory |
