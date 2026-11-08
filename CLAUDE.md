# CLAUDE.md

Guidance for Claude Code (local sessions and the GitHub review/triage bot) working in this repository.

## What this is

AetherEngine is a Swift package that plays video and audio on Apple platforms (iOS 18+, tvOS 18+,
macOS 15+, visionOS 1+). FFmpeg demuxes and, where needed, decodes; Apple's native stack displays.
Two first-party hosts consume it, [Sodalite](https://github.com/superuser404notfound/Sodalite)
(Jellyfin client, tvOS + iOS) and [AetherPlayer](https://github.com/superuser404notfound/AetherPlayer)
(macOS), plus third-party apps listed in the README. Hosts pin releases by commit SHA.

Read before changing anything non-trivial:

- `docs/architecture.md`: the playback pipelines and the **Source map** section (which file owns what).
- `docs/api.md`: the public surface and the host contracts.
- `docs/formats.md`: per-format behaviour, Dolby Vision / HDR, audio routes.
- `docs/cli.md`: `aetherctl`, the headless harness that runs the real engine on macOS.
- `CONTRIBUTING.md`: test conventions and the doc-coverage tests.

## Build and test

```bash
swift build
swift test > /tmp/t.log 2>&1; echo "EXIT=$?"
grep -E "Executed .* with [0-9]+ failures|Test run with" /tmp/t.log | tail -3
swift test --enable-all-traits --scratch-path .build-alltraits
```

`swift test` runs **two** runners, XCTest and swift-testing. The green swift-testing summary line
says nothing about the XCTest half, and an XCTest failure still ends the process with 1. Never judge
a run through a pipe (`| tail` returns tail's exit code); read the real exit code.

Five package traits (`TrueHDObjectAudio`, `DTSXObjectAudio`, `DualLayerDolbyVision`,
`DolbyVisionStillReshaping`, `DolbyVisionFelCurves`) are off by default. Code behind a trait must compile both ways; CI
builds and tests the default and the all-traits configuration, and builds tvOS + visionOS
simulators. The simulator has no hardware video decoders, so a `-12906` there is not a device finding.

To verify a playback change against real media, use `aetherctl` (`swift run aetherctl`, commands in
`docs/cli.md`), not only unit tests.

## Architecture in one paragraph

Native AVPlayer is the default route: the engine demuxes with FFmpeg and serves HLS (fMP4) from a
local loopback server, so HEVC / H.264 / hardware AV1 keep Dolby Vision, HDR and Atmos signalling.
AV1 without hardware decode, interlaced or MVC-carrying H.264, Dolby Vision Profile 7 FEL (when
requested and built in) and every codec the native route does not carry (VP9, VP8, MPEG-2, VC-1, ...)
go to the software host (dav1d / libavcodec into `AVSampleBufferDisplayLayer`).
Audio is stream-copied where Apple can play it and otherwise bridged (FLAC, or APAC for rendered
object audio). Audio-only sources have their own pipeline. Subtitles are emitted as cues; the host
draws them. The engine draws no UI.

## Rules that are load-bearing

- **Playback bugs are fixed in the engine, never by asking hosts to compensate.** A change that adds
  host-side compensation is the wrong direction.
- **Public API needs documentation in the same commit.** `PublicAPIDocumentationTests` fails for any
  public member not named in `README.md` or `docs/`; a symbol public only for the CLI or tests goes
  in its `notHostAPI` list with a reason. Numbers quoted in docs are pinned by
  `DocumentedConstantsTests`. Relative links are checked by `Scripts/check-doc-links.py`.
- **`CHANGELOG.md` gets an entry under `[Unreleased]`** for every user-visible change, in the style
  of the existing entries (bold one-line summary, then what was broken and what happens now).
- **Codec routing is "software unless native really carries it".** Two lists that do not cover each
  other are a hole, not a fallback. `AV_CODEC_ID_NONE` (an audio-only source) stays native.
- **`.ended` is terminal.** Seek and play are no-ops there by contract; replay is a reload. Do not
  soften this in the engine.
- **The engine is one instance per host session and gets reused.** Stale state between two loads
  almost always traces back to teardown (`stopInternal`).
- **Text subtitles arrive as ASS** (libavcodec converts SRT, WebVTT and teletext). Never write a
  per-format parser.
- **Matroska cues are not sync points**: `AVINDEX_KEYFRAME` lies for MKV; verify keyframes.
- **AVPlayer places segments by playlist**, not by fetch; a cold seek looks back a fixed 6 to 8 s.
- Every Dolby Vision RPU passes `DoviRpuGuard` before libdovi parses it.

## Conventions

- Conventional Commits (`feat(audio):`, `fix(demuxer):`, `chore(deps):`, `docs:`, `test:`, `ci:`).
- No em-dashes anywhere (code, comments, commits, docs). Use commas, periods or parentheses.
- Comments explain WHY, sparingly. Long comments exist where a measurement backs a decision; keep
  the measurement when touching such code.
- `internal` is not public contract and can change in any release.
- Tests: file named after the BEHAVIOUR, not the issue (the issue number goes in the test name);
  wait with `waitFor` from `Tests/AetherEngineTests/Support/TestWaiting.swift`, never with a sleep;
  blocking syscalls never on the test's own thread. Details in `CONTRIBUTING.md`.
- Releases (tag + GitHub Release + host pin bumps) are cut by the maintainer only.
