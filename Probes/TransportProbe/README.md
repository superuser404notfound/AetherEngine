# Transport probe (AE#377)

**Outcome.** The answer was yes, and the transport shipped in 6.75.0 as
`LoadOptions.heldSourceConnection` (`HeldSourceConnection`: the engine's own HTTP/1.1 over a
`URLSessionStreamTask`). On the reporter's Apple TV 4K (3rd generation, tvOS 26.6), against the
origin from the issue, arm B held the stream for 600 s with reads stopped and bought nothing while it
waited ("backpressure held"), and all 1,180 canaries to the origin and to a neutral host were served
during the hold, so the dormant flow did not starve the process's networking (#310). AE#377 was
closed on 9 September 2026. How a host uses the option and what it gives up:
[api.md › heldSourceConnection](../../docs/api.md#heldsourceconnection). The probe stays for the next
origin that behaves this way.

A measurement, not a test. It answers whether the media read path can move off URLSession data
tasks onto `URLSessionStreamTask`, and it is meant to be run against the origin that produced the
failure rather than against a loopback server.

Nothing here imports AetherEngine. The question is a property of the transport; routing it through
the reader under suspicion would answer a different one.

## Why it is a test bundle, a package, and also an Xcode project

tvOS has no command line, so an executable cannot run on the device that has the failure. An XCTest
bundle can. The same code runs under `swift test` on macOS, where the earlier loopback attempt
failed to tell the arms apart, which is the reason the device run exists at all.

It is a separate package because the engine's package scheme carries `aetherctl`, which uses
`Foundation.Process` and cannot build for tvOS. The device that has the failure could not otherwise
build the harness meant to measure it.

The package alone still cannot reach an Apple TV. A SwiftPM test target is tool-hosted, and
tool-hosted testing does not exist on device destinations:

```
Cannot test target "TransportProbe" on "<device>": Tool-hosted testing is unavailable on device
destinations. Select a host application for the test target, or use a simulator destination instead.
```

So `Device/` carries an Xcode project with the host application that message asks for. It compiles
the same files from `Tests/TransportProbe/`, nothing is duplicated, and the generated project is
committed so a device run needs Xcode and nothing else. The host app earns its place twice beyond
existing: it disables the screen saver, because an Apple TV that sleeps during a fifteen minute arm
suspends the process and takes the held connection with it, which would read as the origin cutting
it; and it prints the resolved target on the television, so a run whose configuration never arrived
is visible before it reports as a skipped, green, empty suite.

## Run it

The configuration lives in `Tests/TransportProbe/ProbeTarget.swift`, in every case. Put the source
URL there first.

That file is the whole configuration, and it is a source file rather than an environment variable on
purpose: **no environment channel reaches a test process on a tvOS destination, simulator included.**
`TEST_RUNNER_`-prefixed settings are forwarded to UI-test runner apps, not to a unit-test bundle, and
a plain environment is not carried into a simulated process either. A tvOS run with the variables set
takes the defaults and reports green, which is measured rather than assumed: the first such run
skipped the entire suite in silence. Environment variables work on macOS and only there.

**Apple TV.** From `Device/`:

```bash
xcodebuild test -project TransportProbe.xcodeproj -scheme TransportProbe \
  -destination 'platform=tvOS,id=<device-udid>' \
  -test-timeouts-enabled NO \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=<your team id>
```

Device UDIDs: `xcrun devicectl list devices`. In Xcode, open `Device/TransportProbe.xcodeproj`, pick
the Apple TV, and run the test action; setting the team in the target editor does the same thing.

If a team cannot register `de.superuser404.transportprobe.host` and `.tests`, add
`PROBE_BUNDLE_PREFIX=com.example.probe` to that command. One knob covers both targets. Overriding
`PRODUCT_BUNDLE_IDENTIFIER` instead would hand the app and the test bundle the same identifier and
the install fails in a way that does not name the cause.

**tvOS simulator.** Same project, simulator destination. Worth one pass to see the output before the
device run, but the simulator does not reproduce #220, so arm C will correctly report that the run
does not count.

```bash
xcodebuild test -project TransportProbe.xcodeproj -scheme TransportProbe \
  -destination 'platform=tvOS Simulator,name=Apple TV 4K' -test-timeouts-enabled NO
```

**macOS.** The package, where the environment does work and keeps a shakedown to one line:

```bash
AE_PROBE_URL='…' swift test
```

With no URL in either place the whole suite is disabled and reports as skipped, which is what lets
CI compile it without reaching the network.

## Proving the probe before trusting it

`window-origin.py` is a local origin with this issue's shape: ranges, an endless body, and a refusal
window on a compressed clock. It is not the measurement, it is how the harness was checked before it
was handed over, and it is the fastest way to see what a good run looks like.

```bash
python3 window-origin.py 8477 40 20     # serve 40 s, refuse 20 s
AE_PROBE_URL=http://127.0.0.1:8477/big.bin AE_PROBE_WINDOW_SECONDS=110 \
  AE_PROBE_HOLD_SECONDS=8 AE_PROBE_WARMUP_MB=4 AE_PROBE_MBPS=8 \
  AE_PROBE_CANARY_URL=http://127.0.0.1:8477/neutral swift test
```

That one line is macOS only. To point a simulator or a device at the local origin, put the same
values in `ProbeTarget.swift`; the host app allows plain http for exactly this reason, so an http
origin produces a measurement instead of an App Transport Security error that reads like a finding.

Loopback makes arm B inconclusive by construction (250 ms of loopback is gigabytes), which is the
harness telling the truth about itself.

One arm at a time, if sitting through the set is not wanted. The trailing `()` is not optional:
without it xcodebuild matches nothing, runs zero tests and reports green.

```bash
xcodebuild test -scheme TransportProbe-Package -destination '…' \
  '-only-testing:TransportProbe/TransportProbe/heldAcrossWindow()'
```

Names: `resolve()`, `streamBackpressure()`, `dataTaskSuspendControl()`, `heldAcrossWindow()`.

## The arms

They are serialized and run in order. About 20 minutes for the set. Each arm waits for the origin
to serve before it starts, so a run that begins inside a refusal measures the transport instead of
the timing.

**Refusal windows are not periodic.** They recur, seven of them inside one episode, but a 45 minute
arm D against the same source met none at all and its 135 canaries were served without exception.
Whatever gates the refusal is not a clock and cannot currently be provoked, so arm D is a waiting
game: `windowSeconds` is how long it is prepared to wait, not a period it has to exceed.

| arm | duration | question |
| --- | --- | --- |
| A resolve | seconds | which edge answers, http/1.1 or h2, does it range |
| B stream hold | ~2 min | does a stream task stop the sender when reads stop |
| C data task + suspend | ~2 min | positive control: it must NOT stop the sender (#220) |
| D held across the window | `windowSeconds`, 15 min by default | does a held connection cross a refusal window, if one arrives |

**Arm C is the one that validates the run.** #220 measured 911 MB arriving after a `suspend()`. If
arm C reports a small "delivered DURING hold" and a flat footprint, this harness is not reproducing
the known failure and arm B's healthy result means nothing. That is exactly how the macOS loopback
attempt ended.

**Arm D can end the plan on its own.** If the held stream gaps at the same moment its canary flips
to 429, the origin cuts held connections too, no transport change helps, and nobody should write it.
An arm that ends without a canary flip decides nothing either way, and says so, because it never met
the case. It costs roughly 5 GB an hour at 20 Mbps, which is the price of waiting for one.

## Knobs

Every knob exists in both places: a field in `ProbeTarget.swift` (0 or empty means "default") and an
environment variable that overrides it on macOS. On tvOS the field is the only channel.

| field / variable | default | what it is |
| --- | --- | --- |
| `sourceURL` / `AE_PROBE_URL` | none, required | the source URL, redirects followed once like the reader does |
| `holdSeconds` / `AE_PROBE_HOLD_SECONDS` | 60 | how long arms B and C issue no reads |
| `windowSeconds` / `AE_PROBE_WINDOW_SECONDS` | 900 | how long arm D runs |
| `megabitsPerSecond` / `AE_PROBE_MBPS` | 65 | arm D's consumption rate, i.e. the bitrate being emulated |
| `warmupMegabytes` / `AE_PROBE_WARMUP_MB` | 16 | bytes consumed before the hold, matching `winHighWater` on VOD |
| `neutralCanaryURL` / `AE_PROBE_CANARY_URL` | captive.apple.com | a non-origin host, so a refusal can be told from #310's starvation. `none` disables it |
| `abortMegabytes` / `AE_PROBE_ABORT_MB` | 400 | footprint growth that ends an arm early. Unbounded delivery is the finding; a jetsam kill while proving it is not |

## What it will not tell you

The origin's own books. Every witness here is client side, so "the sender was stopped" is inferred
from a flat footprint plus a post-hold drain no larger than the wire could have carried in 250 ms.
That inference is stated as the arm's verdict line rather than left to the reader.

## Reading the output

Each arm prints a `paste this` block. The three lines that carry the decision:

- arm C `delivered DURING hold` large and footprint climbing: the harness reproduces #220, so the
  run counts.
- arm B footprint flat, first read after the hold instant and small, stream continues: demand-driven
  reads give real backpressure and a held connection survives a viewer pause.
- arm D canary at 429 while the stream shows no stall: a held connection is exempt from the window,
  which is the whole reason to consider the change.

Canary lines are condensed per run of identical outcomes, so a fifteen minute arm reads as a handful
of lines with the flip visible in the middle.
