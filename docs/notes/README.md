# Investigation notes

These pages are investigation notes and regression evidence: how a defect was reproduced, the fixtures (test media files) that pin it, and the numbers that showed the fix.

They are for maintainers and reporters and are not published on the website. The current behaviour lives in the published docs, which link here where a note backs a rule.

| Note | What it covers |
| --- | --- |
| [avi-mpeg4-cache-repro.md](avi-mpeg4-cache-repro.md) | AVI with MPEG-4 ASP B-frames: software packet-cache timing, synthetic reproduction and scope |
| [partial-composition-regression.md](partial-composition-regression.md) | H.264 MP4 whose composition offsets stop part way: judder after a seek, the repair and its limits |
| [wmv-cache-coverage.md](wmv-cache-coverage.md) | WMV1 / WMV2 software packet-cache coverage with a one-timestamp lookahead |
| [live-video-progress.md](live-video-progress.md) | Live MPEG-TS replay and decoded-output gaps (#747) |
