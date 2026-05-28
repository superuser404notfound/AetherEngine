# DemoPlayerMac

Standalone macOS demonstrator for AetherEngine. Single window, drop a video file onto it, video plays. No menus, no transport bar, no settings — the entire UI surface is one `AetherPlayerSurface` plus a placeholder for the empty state.

Intended for two audiences:

- **Beta testers** who want to exercise the engine against their own media without setting up an Xcode project or writing a host app. Useful for repro on bug reports: "does the source play in DemoPlayerMac too?" decouples engine bugs from Sodalite-specific bugs.
- **Developers** evaluating AetherEngine who want to see playback working before integrating.

## Running it (Phase A: source build)

From this directory:

```bash
swift run
```

A window labelled *AetherEngine Demo* opens. Drag any video file onto it; playback starts immediately. The corner indicator shows whether the source landed on the native AVPlayer path (`native`) or the SW dav1d / libavcodec path (`sw`).

Controls:

| Action | Effect |
| --- | --- |
| Click on the video | Toggle play / pause |
| Space | Toggle play / pause |
| Escape | Stop and return to the drop zone |
| Drop a different file | Loads the new file (current one is stopped first by the engine) |

## Distribution build (Phase B)

[`Scripts/build-dmg.sh`](Scripts/build-dmg.sh) produces a notarized universal-binary `.dmg` ready to attach to a GitHub Release as a download. End users get a double-clickable `.app` with Gatekeeper acceptance and no "unidentified developer" warning.

One-time setup on the build machine:

1. Confirm the Developer ID Application certificate is installed:

   ```bash
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```

   The line shows `"Developer ID Application: Your Name (TEAMID)"`. That whole quoted string is your `DEVELOPER_ID`.

2. Store notarization credentials in the keychain so the script doesn't have to prompt every run. Generate an app-specific password at https://appleid.apple.com, then:

   ```bash
   xcrun notarytool store-credentials NOTARY_PROFILE \
     --apple-id you@example.com \
     --team-id YOURTEAM \
     --password xxxx-xxxx-xxxx-xxxx
   ```

   Pick whatever profile name you want; the script reads it from `$NOTARY_PROFILE`.

Then run the build:

```bash
DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="NOTARY_PROFILE" \
./Scripts/build-dmg.sh
```

The output lands in `build/AetherEngine-Demo-<version>.dmg`. Six phases run in sequence: universal release build, `.app` wrap with Info.plist + entitlements, code-sign with Hardened Runtime, notarize + staple the `.app`, package into `.dmg`, sign + notarize the `.dmg`. Takes 1–3 minutes mostly waiting on Apple's notary service.

Optional env overrides: `VERSION` (default `2.0.2`), `APP_NAME`, `BUNDLE_ID`. If `NOTARY_PROFILE` is unset the script still builds + signs but skips notarization — useful for local smoke tests; the output won't pass Gatekeeper on other machines.

## Why a separate `Package.swift`

`Examples/DemoPlayerMac/Package.swift` is its own package that depends on the parent AetherEngine via `path: "../.."`. Keeping it isolated avoids pulling a SwiftUI macOS app target into the main engine package (which would force every SPM consumer of `AetherEngine` to drag in `AppKit` / `SwiftUI` dependencies they don't need).

## Scope

The demonstrator deliberately stops where DrHurt's [issue #18](https://github.com/superuser404notfound/AetherEngine/issues/18) does: *"Just a super simple wrapper app, no menus, no nothing. One window → drop file on top → play."* Adding a transport bar, subtitle picker, audio track switcher, etc. is feature creep that would turn this into a "real" player and miss the point — those things belong in a host app like [Sodalite](https://github.com/superuser404notfound/Sodalite). The demonstrator's job is to prove the engine plays files; the host's job is to ship the experience around that.
