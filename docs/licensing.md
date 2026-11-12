# Licensing

What you have to do to ship AetherEngine and its dependencies in an app, App Store included.

## Short version

| Part | License | How it reaches your app | What you do |
| --- | --- | --- | --- |
| AetherEngine | [LGPL-3.0 with an App Store / DRM exception](../LICENSE) | Statically linked (SPM default) | Point to the exact tag you built against; publish your changes to the engine under LGPL |
| FFmpeg | LGPL-2.1-or-later | Dynamic frameworks from [FFmpegBuild](https://github.com/superuser404notfound/FFmpegBuild) | Embed them dynamically, ship the license texts, link the build's source |
| libdovi | MIT (dual MIT OR Apache-2.0, used as MIT) | Static library from [LibDovi](https://github.com/superuser404notfound/LibDovi) | Show quietvoid's copyright notice |
| LibTrueHD | MIT, plus Apache-2.0 parts | Static library, only with the `TrueHDObjectAudio` trait | Ship the Apache-2.0 text and LibTrueHD's `NOTICE` |
| DTS:X decoding | Part of FFmpeg | Nothing extra | Nothing beyond FFmpeg |
| SMBClient | MIT | Only if you link `AetherEngineSMB` | Show its notice |
| Anime4K | MIT | Compiled in (the line-art scaler's kernels) | Show bloc97's notice |

## AetherEngine

[LGPL-3.0 with Apple Store / DRM Exception](../LICENSE). The exception explicitly allows distribution through app stores (Apple App Store, TestFlight, and so on) whose terms would otherwise conflict with LGPL sections 4 to 6. Changes to the engine itself must still be released under the LGPL.

The exception covers AetherEngine's own code. It does not extend to its dependencies.

This is what lets any app, closed source included, ship AetherEngine through the App Store while the engine stays open. ([Sodalite](https://sodalite.superuser404.de) itself is open source under GPL-3.0 with the same store exception.)

## FFmpeg

FFmpeg reaches your app through [FFmpegBuild](https://github.com/superuser404notfound/FFmpegBuild) as dynamically linked frameworks under plain LGPL-2.1-or-later, with no GPL components. Dynamic linking keeps the relink requirement satisfiable for closed-source App Store apps.

The components and their licenses: FFmpeg LGPL-2.1+ (libavcodec, libavformat, libavutil, libswresample, libswscale, libavfilter), dav1d BSD-2-Clause, zimg WTFPL, libzvbi LGPL-2.0+ (its `ure.c` MIT). FFmpegBuild's README lists them in detail, with the concrete steps for adopters (embed dynamically, ship the license texts, link the build's source). Its [LICENSES/](https://github.com/superuser404notfound/FFmpegBuild/tree/main/LICENSES) folder is the set to reproduce, one file per component.

## libdovi

libdovi reaches your app through [LibDovi](https://github.com/superuser404notfound/LibDovi) as a static library. It is the compiled `dolby_vision` crate from [dovi_tool](https://github.com/quietvoid/dovi_tool), Copyright (c) quietvoid and contributors, dual-licensed MIT OR Apache-2.0 and used here under the MIT option.

MIT requires the copyright notice to travel with the binary, and it is **quietvoid's notice** that belongs on your acknowledgements screen. The MIT text in LibDovi's own `LICENSE` covers only the packaging and build scripts; both parts are in that one file.

## LibTrueHD

[LibTrueHD](https://github.com/superuser404notfound/LibTrueHD) reaches your app as a static library and decodes TrueHD for `objectAudioRendering`.

- Its C API, framer and packaging are MIT (Copyright Quick104, who wrote it for Silo as SiloObjectAudio, and Vincent Herbst).
- It compiles in the `truehd` and `oamd` crates from [truehdd](https://github.com/truehdd/truehdd), Copyright Rainbaby and the truehdd contributors, under the Apache License 2.0. That license requires its text and LibTrueHD's `NOTICE` to travel with the binary. Apache-2.0 combines with the engine's LGPL-3.0.
- It comes in only through the `TrueHDObjectAudio` trait, which is off by default ([Optional components](installation.md#optional-components)). With the trait on, it is linked whether or not a host turns the option on.

## DTS:X

DTS:X is decoded by FFmpeg's own `dca` decoder in the FFmpeg frameworks above. FFmpegBuild carries a patch that decodes the height channels of DTS:X's standard presentation (#798), so the `DTSXObjectAudio` trait adds no library and no license of its own.

History: earlier releases linked LibDTSX instead. Its `dca` crate is a port of FFmpeg's decoder combined with Apache-2.0 code, and therefore LGPL-3.0-or-later, which an App Store app cannot meet without an exception.

## SMBClient

[SMBClient](https://github.com/kishikawakatsumi/SMBClient) (MIT) reaches your app only if you link the `AetherEngineSMB` product. Linking `AetherEngine` alone pulls in none of its symbols, even though SwiftPM still lists the package in `Package.resolved` (that file describes the resolved graph, not what the linker kept).

## Anime4K

The line-art scaler (`LoadOptions.upscaleScaler = .lineArt`) runs [Anime4K](https://github.com/bloc97/Anime4K)'s Upscale CNN x2 (S), Copyright (c) 2019-2021 bloc97, MIT. Its weights are compiled into the engine as Metal source (`Sources/AetherEngine/Video/Metal/LineArtShaderSource.swift`, which carries the full notice), whether or not a host uses the option. MIT requires the copyright notice to travel with the binary, so **bloc97's notice** belongs on your acknowledgements screen.

## Linking the engine statically

An SPM library product links statically by default, and for the engine that is the intended setup on the App Store path.

- **Object code:** LGPL-3.0 section 4(d)(0) would otherwise ask for your app's object code in a relinkable form. The exception's fourth bullet explicitly names end-user re-linking, so that part does not apply.
- **Source:** the exception does not waive the source side. Point at the exact tag you built against, not the repository root. If you patched the engine, publish the patched source under the LGPL. No separate written offer is needed while that pointer works.
- **Dependencies** keep their own terms either way. That is why the FFmpeg frameworks must stay dynamically embedded in `YourApp.app/Frameworks/` instead of being merged into the app binary.

### Make sure the engine's FFmpeg is the one that answers

Being dynamic does not guarantee being used. The engine calls `avcodec_*` as ordinary external symbols, so a second FFmpeg elsewhere in the app can serve them instead:

- a static archive pulled in with `-force_load` becomes a definition inside your executable and beats every dylib;
- a dependency that exports the same symbols wins on link order alone (libVLC does, and CocoaPods sorts a pod ahead of a vendored framework).

**Link AetherEngine's frameworks first.** `nm -m <executable> | grep _avcodec_find_encoder` shows who currently wins. The engine's own startup line says the same from the inside ([guide.md › Which FFmpeg answered](guide.md#which-ffmpeg-answered)).
