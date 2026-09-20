# Contributing to AetherEngine

Thanks for your interest. AetherEngine is the video playback engine behind [Sodalite](https://github.com/superuser404notfound/Sodalite) (tvOS) and [AetherPlayer](https://github.com/superuser404notfound/AetherPlayer) (macOS). Most of the interesting work here is format- and platform-specific, so a good bug report or a focused PR with a clear test plan is worth a lot.

## Reporting bugs and requesting capabilities

Open an issue using one of the [templates](.github/ISSUE_TEMPLATE). For playback bugs, the source media details (container, video codec and profile, audio codec, HDR / Dolby Vision profile) and any AVPlayer / CoreMedia / VideoToolbox error codes are the single most useful thing you can provide. `ffprobe` output and a sample file make triage dramatically faster.

If the problem is in a host app's UI rather than the engine, report it on that app's tracker instead (the issue chooser links both).

## Building and testing

AetherEngine is a Swift package. It builds for iOS 18+, tvOS 18+, macOS 15+, and visionOS 1+.

```bash
swift build
swift test
```

For iterative work, open `Package.swift` in Xcode 26+ and pick the `AetherEngine` scheme. `FFmpegBuild` is a transitive dependency that supplies the bundled FFmpeg / dav1d binaries; you do not build it yourself.

The `aetherctl` command-line target is macOS-only (it uses `Foundation.Process`) and is excluded from the iOS / tvOS library build.

## Writing tests

The suite is large (3000 tests over 460 files) and cheap (the whole run is about a minute), so the
question is never whether a behaviour deserves a test. Two conventions keep it from growing in the
one direction that costs something, which is width.

**A test file is named after the BEHAVIOUR, not after the issue that revealed it.** The issue number
belongs in the test's name and in the comment that explains what it cost, where it is read by
whoever hits the same thing again. Files named `Issue<N>…Tests.swift` made growth purely additive:
a new report got a new file, because nobody could see from the outside whether the behaviour was
already covered. That is how seek ended up spread over sixteen files, live over thirty-two, and how
two pairs of files ended up testing the same concept under two issue numbers. Existing files are
not worth renaming on their own; put a new test where the topic already lives.

**Wait with `waitFor` from `Support/TestWaiting.swift`, never with a sleep or a private copy.** It
carries two rules that cost three rounds of red CI to learn. A step that HAS to happen before the
test can measure anything gets no deadline of its own, because any finite bound can be overrun by
an oversubscribed machine, and the bound then decides what the test reports; the hang catcher is a
`.timeLimit` trait, which reports a hang as one, with a name. And anything a test parks on its own
gets a real thread (`Thread.detachNewThread`), never `DispatchQueue.global().async`: measured with
192 pool workers blocked, which is what a full parallel run of this suite produces, the queue had
not started the block after 35 seconds while a detached thread ran in 3 milliseconds.

**A blocking syscall in a test is unreachable for the `.timeLimit` trait, so it may not sit on the
test's own thread.** Cancellation in Swift is cooperative: a test parked in `read`, `accept` or
`waitUntilExit` never observes it, the trait never reports, and the job dies at its own
`timeout-minutes` with the log of the killed run discarded, so not even the test's name survives.
Measured on this suite: a launch helper parked in `FileHandle.availableData` ran past a one minute
limit for more than ten, and the only trace was the subprocess in the runner's orphan-process
cleanup. Put the blocking call on its own thread, `await` its result, and give the cancellation
handler whatever ends it (closing the handle, killing the subprocess).
`Support/PythonOrigin.swift` is the worked example.

## Where playback bugs get fixed

A bug that reproduces in a host app but traces back to decoding, demuxing, the audio bridge, or display routing gets fixed **in the engine**, not worked around in the host. If a change starts adding host-side compensation for engine behavior, that is a signal the fix belongs here instead. PRs that move logic in the right direction are very welcome.

## Pull requests

- Keep each PR focused on one change.
- Fill in the test plan: the device, OS, and exact media you tested against. Engine behavior varies by all three, so "tested on Apple TV 4K, tvOS 26, DV Profile 8.1 MKV" tells a reviewer far more than "works for me."
- Update `CHANGELOG.md`, and the documentation in the same commit (see below; three tests enforce parts of this, so a PR that skips it fails rather than merges).
- Follow [Conventional Commits](https://www.conventionalcommits.org/) (`feat(audio):`, `fix(muxer):`, `chore(deps):`, and so on).
- Treat `internal` types and properties as private; they are not part of the public contract and can change in any release.

## Documentation, and the tests that hold it to the code

[docs/api.md](docs/api.md) is the public surface an adopter reads; [docs/formats.md](docs/formats.md) and [docs/architecture.md](docs/architecture.md) are the depth behind it. Documentation here is not a courtesy pass after the fact: a downstream app once read the whole API tour and came away without a contract that needed a host action, because the tour listed properties and the contract was a `PassthroughSubject` nobody had written a sentence about. Three tests exist so that particular failure cannot repeat quietly, and knowing them beforehand is cheaper than meeting them in CI.

- **`PublicAPIDocumentationTests`.** Every public member of the engine, every host-facing public type and every `LoadOptions` field has to be NAMED somewhere in `README.md` or `docs/`. Naming is a low bar on purpose: the test cannot judge a paragraph, only catch a symbol with no prose anywhere. A symbol that is public for the CLI or the test suite rather than for hosts goes in the test's `notHostAPI` list with its reason.
- **`DocumentedConstantsTests`.** Numbers the documentation quotes ("2 GiB cap", "128 kbps per channel", "the 60 s lead window") are pinned to the constants that own them, and a failure names the sentence to fix. Add a number to the docs, add its pin in the same commit. This is what caught a paragraph claiming a 15 s margin over a window the code clears by 30 s.
- **The `ExampleSources` target.** The samples in `Examples/` are compiled by `swift build`, so one that stops matching the API breaks the build instead of misleading a reader. They are never a product, so nothing reaches a consumer.
- **`Scripts/check-doc-links.py`**, run by the `docs links` CI job and by hand in a second. Every relative link in the published docs has to point at a file that exists, and every `#anchor` at a heading that produces it. The docs site validates the same anchors, but it builds in another repo after the push, so a bad anchor used to ship first and be found second: `formats.md#dolby-vision` against a heading that slugs to `#dolby-vision-signaling` broke the site build for two releases. Note that the site drops each file's leading H1 (Starlight renders the title from frontmatter), so linking a document's own H1 anchor works on GitHub and 404s on the site; the checker holds you to the stricter of the two.

New public API therefore belongs in `docs/api.md` in the commit that adds it, and behaviour a host has to answer (a subject to subscribe to, a state that is terminal, a stream that ends with its session) belongs in that file's contracts section rather than only in a doc comment.

## Releases and host pins

Maintainers cut releases as annotated tags plus a GitHub Release with notes. Host apps pin AetherEngine by commit SHA, so after a change merges the host repos bump their pins to the new commit. You do not need to touch the host repos in your PR.

## License

AetherEngine is [LGPL-3.0 with an Apple Store / DRM exception](LICENSE). By contributing you agree your contributions are licensed under the same terms. Modifications to the engine itself remain under LGPL; the exception clause only covers distribution of unmodified builds through application stores.
