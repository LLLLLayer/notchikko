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

## One-Time Setup: Developer ID Application Certificate

Required before any signed + notarized release. A plain Xcode "Apple Development" cert **will not work** — export needs a distribution cert.

1. **Generate CSR** — Keychain Access.app → menu bar → `Certificate Assistant → Request a Certificate From a Certificate Authority…`
   - User Email: Apple ID email
   - Common Name: any label (e.g. `LLLLLayer Developer ID`)
   - CA Email: leave blank
   - Select **Saved to disk**
2. **Create cert** — https://developer.apple.com/account/resources/certificates → "+" → **Developer ID Application** → Profile Type **G2 Sub-CA (Xcode 11.4.1 or later)** → upload the CSR
3. **Install** — download the `.cer`, double-click to import into login Keychain. Verify:
   ```bash
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```
   Should print one line with your team ID `(Q2T8TN4ZW6)`.

CSR file is safe to delete after the cert is installed — the private key stays in Keychain.

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

**Commit this change** before shipping any release — installed clients verify the appcast `sparkle:edSignature` against the public key baked into their own Info.plist at build time, so dev builds running on the old placeholder key will reject every update.

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
# Archive (Release config required — Debug won't be accepted by notarization)
xcodebuild archive -scheme Notchikko -configuration Release \
  -archivePath ./build/Notchikko.xcarchive

# Export with Developer ID signing
xcodebuild -exportArchive \
  -archivePath ./build/Notchikko.xcarchive \
  -exportOptionsPlist ExportOptions.plist \
  -exportPath ./build/export

# Verify the exported .app is signed by Developer ID (not Apple Development)
codesign -dv --verbose=2 ./build/export/Notchikko.app 2>&1 | grep Authority
# Expect: "Authority=Developer ID Application: <Name> (Q2T8TN4ZW6)"
```

`ExportOptions.plist` (gitignored — contains teamID):
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
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
```

### Step 3: Notarize

```bash
# First time only: store credentials in Keychain (interactive prompt, password never on disk)
# Requires an App-Specific Password from appleid.apple.com → Sign-In and Security →
# App-Specific Passwords. Apple Developer accounts have 2FA enforced, so the regular
# Apple ID password cannot be used here.
xcrun notarytool store-credentials "notchikko-notarize" \
  --apple-id YOUR_APPLE_ID --team-id Q2T8TN4ZW6

# Create zip for notarization (ditto preserves symlinks)
ditto -c -k --sequesterRsrc --keepParent \
  ./build/export/Notchikko.app ./build/Notchikko-notarize.zip

# Submit (uses Keychain profile — no password on command line)
# Typical duration: 1–3 minutes. --wait blocks until Accepted/Rejected.
xcrun notarytool submit ./build/Notchikko-notarize.zip \
  --keychain-profile "notchikko-notarize" --wait

# Staple the ticket to the .app (NOT the zip). Then verify.
xcrun stapler staple ./build/export/Notchikko.app
xcrun stapler validate ./build/export/Notchikko.app
```

> **Security**: Always use `--keychain-profile`, never `--password`. The latter exposes credentials in shell history and process list. Never paste the App-Specific Password into chat / logs / commit messages either — treat it as a leaked credential if you do and regenerate immediately at appleid.apple.com.

### Step 4a: Package ZIP (for Sparkle auto-update)

```bash
# Re-zip AFTER stapling (the stapled ticket must be in the distributed archive)
rm ./build/Notchikko-notarize.zip
ditto -c -k --sequesterRsrc --keepParent \
  ./build/export/Notchikko.app ./build/Notchikko-1.1.zip
```

### Step 4b: Package DMG (for first-time download)

Two-product model: ZIP is Sparkle's auto-update payload, DMG is the human-facing download on the GitHub Releases page (drag-to-Applications is the macOS muscle-memory install).

```bash
# Staging folder = .app + /Applications symlink. hdiutil snapshots this as the DMG root,
# so when the user mounts the DMG they see both icons side by side.
mkdir -p ./build/dmg-staging
cp -R ./build/export/Notchikko.app ./build/dmg-staging/
ln -sf /Applications ./build/dmg-staging/Applications

# Compressed DMG (UDZO). -ov overwrites prior runs.
hdiutil create -volname "Notchikko 1.1" \
  -srcfolder ./build/dmg-staging \
  -ov -format UDZO \
  ./build/Notchikko-1.1.dmg

# Sign the DMG ITSELF — the stapled ticket on the .app inside is not enough;
# Gatekeeper inspects the DMG wrapper at mount time.
codesign --force --sign "Developer ID Application: Jie Yang (Q2T8TN4ZW6)" \
  ./build/Notchikko-1.1.dmg

# Notarize + staple the DMG (separate submission from the .app's earlier one).
xcrun notarytool submit ./build/Notchikko-1.1.dmg \
  --keychain-profile "notchikko-notarize" --wait

xcrun stapler staple ./build/Notchikko-1.1.dmg
xcrun stapler validate ./build/Notchikko-1.1.dmg

rm -rf ./build/dmg-staging
```

> **Critical — DON'T chain `stapler staple` behind a pipe.** `xcrun stapler staple ... | tail -3` masks staple failures (tail's exit code wins), so a failed staple silently proceeds to `gh release upload`, shipping an un-stapled DMG. Either run `stapler staple` standalone, set `-o pipefail`, or check `PIPESTATUS[0]` explicitly.

### Step 5: Generate Appcast

```bash
# Keep previous version zips in the same directory for delta generation.
# generate_appcast reads the EdDSA private key from Keychain automatically.
# --download-url-prefix rewrites enclosure URLs to point at the GitHub Releases
# asset paths — required, otherwise clients try to download by bare filename.
"$SPARKLE_BIN/generate_appcast" \
  --download-url-prefix "https://github.com/LLLLLayer/notchikko/releases/download/v1.1/" \
  ./build/

# Output: ./build/appcast.xml (+ delta files like Notchikko1.0-1.1.delta)
```

Options:
- `--maximum-deltas N` — limit delta files per version (default: all previous)
- First release only: no prior zip → no delta files generated, only a single `<item>` for the new version. Expected.

### Step 6: Publish

Upload all four assets together:
- `Notchikko-1.1.dmg` — first-time download (drag-to-Applications)
- `Notchikko-1.1.zip` — Sparkle full update payload
- `Notchikko{build}-{prevBuild}.delta` — Sparkle incremental update (e.g. `Notchikko2-1.delta`)
- `appcast.xml` — update metadata

```bash
# Write release notes to a file to avoid shell-escaping Chinese/Markdown headaches
gh release create v1.1 \
  ./build/Notchikko-1.1.dmg \
  ./build/Notchikko-1.1.zip \
  ./build/Notchikko2-1.delta \
  ./build/appcast.xml \
  --title "Notchikko v1.1" \
  --notes-file /tmp/notchikko-v1.1-notes.md
```

If you need to replace a single asset after the release is published (e.g. the DMG shipped un-stapled because `stapler staple` failed silently behind a pipe):

```bash
gh release upload v1.1 ./build/Notchikko-1.1.dmg --clobber
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
- [ ] DMG independently signed + notarized + stapled (Gatekeeper inspects the DMG wrapper on mount)
- [ ] Appcast served over HTTPS (GitHub Releases = automatic)
- [ ] `CURRENT_PROJECT_VERSION` incremented (Sparkle ignores marketing version)
- [ ] `stapler staple` not behind a pipe (exit code gets masked; see Troubleshooting)

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

### `stapler staple` Error 68 ("CloudKit's response is inconsistent")
- Apple's notarization ticket service occasionally returns a transient CloudKit failure — the notarization was Accepted, only the staple fetch hiccuped.
- Wait ~10 seconds and retry `xcrun stapler staple <path>`. Usually passes on the second try.
- Do NOT re-submit to `notarytool` — the ticket already exists, only the local fetch needs another attempt.

### DMG shipped un-stapled / missing notarization ticket
- Check the publish chain: any `xcrun stapler staple … | tail -N && gh release upload …` pattern masks the staple exit code (tail's 0 wins), so a failed staple silently proceeds to upload.
- Run `stapler staple` on its own line, or prefix with `set -o pipefail`, or check `PIPESTATUS[0]` after the pipe.
- Fix an already-published un-stapled asset: staple locally, then `gh release upload vX.Y ./build/Notchikko-X.Y.dmg --clobber`.

### Gatekeeper complains on DMG mount even though the .app inside is notarized
- The stapled ticket on the `.app` isn't visible until *after* mount. Gatekeeper inspects the DMG wrapper *at* mount time.
- Staple the DMG itself (step 4b). Without it, first-time downloaders see a "this file is from the internet" warning even though the enclosed app is clean.

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
