---
name: release-guide
description: "Sparkle auto-update and release workflow — the full pipeline from version bump to published update. MUST use this skill when: bumping version numbers, archiving/exporting the app, notarizing, generating appcast, creating GitHub releases, troubleshooting Sparkle, or changing any file in App/UpdateManager.swift or Info.plist Sparkle keys (SUFeedURL, SUPublicEDKey, etc.). Also use when the user mentions release, update, appcast, Sparkle, notarize, code signing, or version bump."
allowed-tools: Read Grep Glob Edit Write Bash
paths: "Notchikko/App/UpdateManager.swift,Notchikko/Info.plist,Notchikko.xcodeproj/project.pbxproj"
---

# Sparkle Auto-Update & Release

## Architecture

```
Info.plist (SUFeedURL, SUPublicEDKey, intervals)
     │
UpdateManager                     ← App/UpdateManager.swift
  │  wraps SPUStandardUpdaterController
  │  start() called in AppDelegate.applicationDidFinishLaunching
  │  checkForUpdates() wired to MenuBarManager callback
  ▼
Sparkle Framework (SPM: 2.9.x)
  │  background check every SUScheduledCheckInterval (86400s = 24h)
  │  fetches appcast.xml → verifies EdDSA signature → downloads zip
  │  SUAutomaticallyUpdate=YES → installs on quit
  ▼
GitHub Releases
  └── appcast.xml + Notchikko-{version}.zip
```

Menu entry: status bar → "Check for Updates…" (between Settings and Quit).

---

## One-Time Setup: EdDSA Key Pair

```bash
# Find the Sparkle tools in DerivedData SPM artifacts
SPARKLE_BIN=$(find ~/Library/Developer/Xcode/DerivedData/Notchikko-*/SourcePackages/artifacts \
  -path "*/Sparkle/bin" -type d 2>/dev/null | head -1)

# Generate key pair (private key → Keychain, public key → stdout)
"$SPARKLE_BIN/generate_keys"
```

Copy the printed public key into `Notchikko/Info.plist`:
```xml
<key>SUPublicEDKey</key>
<string>PASTE_BASE64_PUBLIC_KEY_HERE</string>
```

### Key Management

- Private key is stored in macOS Keychain under service `https://sparkle-project.org`
- **NEVER** export with `generate_keys -p` to a file or pipe — use Keychain Access.app for secure export
- Changing machines: export from Keychain Access → import on new machine → verify with `generate_keys`
- If private key is lost: generate new pair, ship one release signed with both old+new keys (Sparkle supports key rotation via `sparkle:edSignature` on the enclosure)

---

## Release Workflow

### Step 1: Version Bump

Both values in `project.pbxproj` target build settings (Debug + Release):

| Key | Purpose | Rule |
|---|---|---|
| `MARKETING_VERSION` | Display version (e.g. `1.1`) | Semantic versioning |
| `CURRENT_PROJECT_VERSION` | Build number (e.g. `2`) | **Must strictly increment every release** — Sparkle uses this to detect updates |

### Step 2: Archive & Export

```bash
# Archive
xcodebuild archive -scheme Notchikko \
  -archivePath ./build/Notchikko.xcarchive

# Export with Developer ID signing
xcodebuild -exportArchive \
  -archivePath ./build/Notchikko.xcarchive \
  -exportOptionsPlist ExportOptions.plist \
  -exportPath ./build/export
```

`ExportOptions.plist`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>Q2T8TN4ZW6</string>
</dict>
</plist>
```

### Step 3: Notarize

```bash
# First time only: store credentials in Keychain (interactive prompt, password never on disk)
xcrun notarytool store-credentials "notchikko-notarize" \
  --apple-id YOUR_APPLE_ID --team-id Q2T8TN4ZW6

# Create zip for notarization (ditto preserves symlinks)
ditto -c -k --sequesterRsrc --keepParent \
  ./build/export/Notchikko.app ./build/Notchikko.zip

# Submit (uses Keychain profile — no password on command line)
xcrun notarytool submit ./build/Notchikko.zip \
  --keychain-profile "notchikko-notarize" --wait

# Staple the ticket to the .app (not the zip)
xcrun stapler staple ./build/export/Notchikko.app
```

> **Security**: Always use `--keychain-profile`, never `--password`. The latter exposes credentials in shell history and process list.

### Step 4: Package for Distribution

```bash
# Re-zip AFTER stapling (the stapled ticket must be in the distributed archive)
ditto -c -k --sequesterRsrc --keepParent \
  ./build/export/Notchikko.app ./build/Notchikko-1.1.zip
```

### Step 5: Generate Appcast

```bash
# Keep previous version zips in the same directory for delta generation
# generate_appcast reads the EdDSA private key from Keychain automatically
"$SPARKLE_BIN/generate_appcast" ./build/

# Output: ./build/appcast.xml (+ delta files like Notchikko1.0-1.1.delta)
```

Options:
- `--download-url-prefix URL` — prepend URL to enclosure filenames (for GitHub Releases hosting)
- `--maximum-deltas N` — limit delta files per version (default: all previous)

### Step 6: Publish

```bash
gh release create v1.1 \
  ./build/Notchikko-1.1.zip \
  ./build/appcast.xml \
  --title "v1.1" \
  --notes "Release notes"
```

The appcast URL in Info.plist points to:
```
https://github.com/LLLLLayer/notchikko/releases/latest/download/appcast.xml
```

GitHub's `/latest/download/` redirects to the most recent release's assets.

---

## Info.plist Sparkle Keys

| Key | Value | Purpose |
|---|---|---|
| `SUFeedURL` | GitHub Releases appcast URL | Where to fetch update metadata |
| `SUPublicEDKey` | Base64 Ed25519 public key | Verify update signatures |
| `SUEnableAutomaticChecks` | `true` | Skip first-launch opt-in prompt |
| `SUAutomaticallyUpdate` | `true` | Download + install on quit silently |
| `SUScheduledCheckInterval` | `86400` | Check every 24 hours |

These are in `Notchikko/Info.plist` and merged with auto-generated keys at build time (`GENERATE_INFOPLIST_FILE = YES` + `INFOPLIST_FILE` coexist).

---

## Code Integration Points

| Component | File | Role |
|---|---|---|
| `UpdateManager` | `App/UpdateManager.swift` | Wraps `SPUStandardUpdaterController`, `start()` + `checkForUpdates()` |
| `AppDelegate` | `App/AppDelegate.swift` | Creates `UpdateManager`, calls `start()`, wires `onCheckForUpdates` |
| `MenuBarManager` | `App/MenuBarManager.swift` | "Check for Updates…" menu item → `onCheckForUpdates` callback |
| Info.plist | `Notchikko/Info.plist` | Sparkle configuration (feed URL, public key, intervals) |
| pbxproj | `Notchikko.xcodeproj/project.pbxproj` | SPM dependency (`Sparkle 2.9.0+`), `INFOPLIST_FILE` build setting |

---

## Security Checklist

- [ ] `SUPublicEDKey` is a real key (not the placeholder)
- [ ] Notarization uses `--keychain-profile` (never `--password` on command line)
- [ ] Private key only in macOS Keychain (never in git, env vars, or plain files)
- [ ] Archive is signed with Developer ID (not Development)
- [ ] Staple BEFORE final zip (so ticket is embedded in distributed archive)
- [ ] Appcast served over HTTPS (GitHub Releases = automatic)
- [ ] `CURRENT_PROJECT_VERSION` incremented (Sparkle ignores marketing version)

---

## Troubleshooting

### "Sparkle updater failed to start"
- Check `SUPublicEDKey` is valid base64 in Info.plist
- Verify `SUFeedURL` is a reachable HTTPS URL
- Check Console.app for Sparkle-specific logs

### Update available but not installing
- Verify `CURRENT_PROJECT_VERSION` in new build > current build
- Check that the zip is signed with the same Developer ID as the running app
- Verify EdDSA signature: `"$SPARKLE_BIN/sign_update" Notchikko.zip` and compare with appcast

### Delta updates not generated
- Keep previous version zips in the same directory as new zip when running `generate_appcast`
- Delta generation requires both old and new .app bundles extractable from their zips

### Build warning: "Copy Bundle Resources contains Info.plist"
- Already handled: `PBXFileSystemSynchronizedBuildFileExceptionSet` excludes `Info.plist` from resources
- If warning reappears after pbxproj changes, re-add the exception set entry

---

## Accessory App Considerations

Notchikko runs as `.accessory` (no dock icon). Sparkle 2.2+ handles this:
- Scheduled update alerts do NOT steal focus from other apps
- `SUAutomaticallyUpdate = YES` means most updates are invisible (download in background, install on quit)
- If user doesn't quit for a week, Sparkle shows a gentle reminder
- Manual "Check for Updates…" brings up standard Sparkle dialog as a floating panel
