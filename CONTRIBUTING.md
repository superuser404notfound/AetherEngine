# Contributing to AetherEngine

Thanks for your interest. AetherEngine is the video playback engine behind [Sodalite](https://github.com/superuser404notfound/Sodalite) (tvOS, iOS), [AetherPlayer](https://github.com/superuser404notfound/AetherPlayer) (macOS) and the apps in the README's [Used by](README.md#used-by) list. Most of the interesting work here is format- and platform-specific, so a good bug report or a focused PR with a clear test plan is worth a lot.

## Reporting bugs and requesting capabilities

Open an issue using one of the [templates](.github/ISSUE_TEMPLATE). For a playback bug, the most useful things you can provide are:

- the source media details: container, video codec and profile, audio codec, HDR / Dolby Vision profile,
- any AVPlayer / CoreMedia / VideoToolbox error codes.

`ffprobe` output and a sample file make triage dramatically faster.

If the problem is in a host app's UI rather than the engine, report it on that app's tracker instead (the issue chooser links both).

## Building and testing

AetherEngine is a Swift package. It builds for iOS 18+, tvOS 18+, macOS 15+, and visionOS 1+.

```bash
swift build
swift test > /tmp/t.log 2>&1; echo "EXIT=$?"
swift test --enable-all-traits --scratch-path .build-alltraits
```

`swift test` runs two test runners, XCTest and swift-testing. The green swift-testing summary says nothing about the XCTest half, so judge a run by its exit code, never through a pipe (`| tail` returns tail's exit code). The second command builds and tests the five optional components (package traits), as CI does.

To check a playback change against real media, not only unit tests, run `swift run aetherctl` ([docs/cli.md](docs/cli.md)). `Scripts/fetch-fixtures.sh` generates a small set of synthetic test clips for it.

For iterative work, open `Package.swift` in Xcode 27+ and pick the `AetherEngine` scheme. `FFmpegBuild` is a transitive dependency that supplies the bundled FFmpeg / dav1d binaries; you do not build it yourself.

The `aetherctl` command-line target is macOS-only (it uses `Foundation.Process`) and is excluded from the iOS / tvOS library build.

## Writing tests

The suite is large (several thousand tests) and cheap (a few minutes), so any behaviour can have a test. Four rules keep it easy to navigate and reliable on a busy CI machine:

1. **Name a test file after the behaviour, not after the issue.** The issue number goes in the test's name and its comment.
2. **Wait with `waitFor` from `Support/TestWaiting.swift`.** Never sleep, and never write a private copy.
3. **Park work on a real thread** (`Thread.detachNewThread`), never on `DispatchQueue.global().async`.
4. **Keep blocking calls off the test's own thread.** Put `read`, `accept` or `waitUntilExit` on its own thread and `await` the result.

Why each one:

1. Files named `Issue<N>…Tests.swift` hide coverage: nobody can see whether a behaviour is already tested. That is how seek ended up spread over sixteen files and live over thirty-two. Do not rename old files just for this; put a new test where its topic already lives.
2. A step the test needs before it can measure anything gets no deadline of its own. Any finite bound can be overrun on an oversubscribed machine, and then the bound, not the code, decides the result. Hangs are caught by a `.timeLimit` trait instead, which reports a hang as a hang, with a name.
3. A full parallel run blocks every worker of the global dispatch pool. Measured with 192 workers blocked, the global queue had not started a block after 35 seconds, while a detached thread ran in 3 milliseconds.
4. Swift cancellation is cooperative (a task stops only where it checks for cancellation), so a test parked in a blocking syscall never sees the `.timeLimit` trait. The job then dies at its own `timeout-minutes` and the log, test name included, is lost. Measured on this suite: a launch helper parked in `FileHandle.availableData` ran past a one minute limit for more than ten, and the only trace was the subprocess in the runner's orphan-process cleanup. Give the cancellation handler whatever ends the call (close the handle, kill the subprocess). `Support/PythonOrigin.swift` is the worked example.

CI enforces the mechanical parts with `Scripts/check-test-hygiene.py`: no `try? await Task.sleep` and no `DispatchQueue.global().async` (or `asyncAfter`) under `Tests/`, and no `.timeLimit` under three minutes (a green run has hundreds of tests above 60 s and trivial ones near 100 s; use `.minutes(3)`). A line that is a real exception says why, with `// hygiene: allow <reason>` on it.

## Where playback bugs get fixed

A bug that reproduces in a host app but traces back to decoding, demuxing, the audio bridge, or display routing gets fixed **in the engine**, not worked around in the host. If a change starts adding host-side compensation for engine behavior, that is a signal the fix belongs here instead. PRs that move logic in the right direction are very welcome.

## Pull requests

- Keep each PR focused on one change.
- Fill in the test plan: the device, OS, and exact media you tested against. Engine behavior varies by all three, so "tested on Apple TV 4K, tvOS 26, DV Profile 8.1 MKV" tells a reviewer far more than "works for me."
- Update `CHANGELOG.md` and the documentation in the same commit (see below; the checks there fail a PR that skips it).
- Follow [Conventional Commits](https://www.conventionalcommits.org/) (`feat(audio):`, `fix(muxer):`, `chore(deps):`, and so on).
- Treat `internal` types and properties as private; they are not part of the public contract and can change in any release.
- Every pull request that is not a draft gets an automated first-pass review (Claude, rules in [.github/claude/review.md](.github/claude/review.md)) when it opens and after each push. It reads the code and does not run it; it is advisory, and a human still reviews and merges. New issues get automatic labels and, when information is missing, one comment asking for it.

## Documentation, and the tests that hold it to the code

Update the docs in the same commit as the code. A contract that needs a host action and has no sentence in the docs gets missed. Where things go:

- [docs/api.md](docs/api.md): the public surface an adopter reads.
- [docs/formats.md](docs/formats.md) and the architecture pages ([overview](docs/architecture.md), [native path](docs/architecture-native.md), [software path](docs/architecture-software.md)): the depth behind it.
- [docs/measurements.md](docs/measurements.md): the dated measurements behind the rules.
- [docs/notes/](docs/notes/README.md): investigation notes and regression evidence that are not published on the website.

These checks hold you to that:

- **`PublicAPIDocumentationTests`.** Every public member of the engine, every host-facing public type and every `LoadOptions` field has to be NAMED somewhere in `README.md` or `docs/`. The test cannot judge a paragraph, only catch a symbol with no prose anywhere. A symbol that is public for the CLI or the test suite rather than for hosts goes in the test's `notHostAPI` list with its reason.
- **`DocumentedConstantsTests`.** Numbers the documentation quotes ("2 GiB cap", "128 kbps per channel", "the 60 s lead window") are pinned to the constants that own them, and a failure names the sentence to fix. Add a number to the docs, add its pin in the same commit.
- **The `ExampleSources` target.** The samples in `Examples/` are compiled by `swift build`, so one that stops matching the API breaks the build instead of misleading a reader. They are never a product.
- **`Scripts/check-doc-links.py`** (the `docs links` CI job, a second to run by hand). Every relative link in the published docs must point at a file that exists, and every `#anchor` at a heading that produces it. The docs site drops each file's leading H1, so do not link to a document's own H1 anchor: it works on GitHub and 404s on the site.
- **`Scripts/check-source-map.py`** (same CI job). Every Swift file under `Sources/` has to be named in [`docs/source-map.md`](docs/source-map.md), so a new file gets its one-line row in the same commit.

New public API therefore belongs in `docs/api.md` in the commit that adds it. Behaviour a host has to answer (a subject to subscribe to, a state that is terminal, a stream that ends with its session) belongs in that file's contracts section, not only in a doc comment.

**Changelog.** Every user-visible change gets an entry under `[Unreleased]` in `CHANGELOG.md`, in the style of the existing ones: a bold one-line summary, then what was broken and what happens now.

## Releases and host pins

Maintainers cut releases as tags plus a GitHub Release with notes. Host apps pin a release by its commit SHA and move to a new release after it is published. You do not need to touch the host repos in your PR.

### Device check for native subtitle renditions

Required on a device before tagging a release. What it covers is in [formats.md › Native subtitle renditions](docs/formats.md#native-subtitle-renditions-webvtt-for-pip-airplay-and-external-display).

- Selecting a rendition displays it in the PiP window and survives seeks (including seeks that restart the producer).
- Inline host ASS rendering unchanged: rich styling intact, tap-fed cues appear instantly on selection.
- No double subtitles while inline; no rendition is auto-selected on session start.
- Timing: no constant offset between audio and subtitle cues, before and after seeks.
- SDR / HDR10 picture behavior unchanged with `prepareNativeSubtitles = true` (the renditions only add master tags + subtitle endpoints).
- HDR on an SDR panel still plays (media-direct, no renditions there by design).
- Memory bounded by total cue count across all tracks.

## License

AetherEngine is [LGPL-3.0 with an Apple Store / DRM exception](LICENSE). By contributing you agree your contributions are licensed under the same terms. Modifications to the engine itself remain under LGPL; the exception covers store distribution of the engine and of modified versions.
