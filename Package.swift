// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "AetherEngine",
    platforms: [
        .iOS(.v18),
        .tvOS(.v18),
        .macOS(.v15),
        .visionOS(.v1),
    ],
    products: [
        .library(
            name: "AetherEngine",
            targets: ["AetherEngine"]
        ),
        .library(
            name: "AetherEngineSMB",
            targets: ["AetherEngineSMB"]
        ),
        // aetherctl is intentionally not exposed as a product. The target
        // uses Foundation.Process, which is unavailable on tvOS/iOS, so
        // exposing it would force SPM consumers to compile it on those
        // platforms. The target is preserved below so `swift build` on
        // macOS still produces the CLI for upstream development.
    ],
    // Four optional components, all off by default. A host that wants one enables its trait
    // (`.package(url:..., traits: [...])`, or the package's traits in Xcode); without it the code is not
    // compiled and the library behind it is not linked. These components may be subject to third-party
    // patent licensing; an integrator that enables one is responsible for its own licensing. Off, the
    // matching LoadOptions are accepted and change nothing: object audio keeps the channel bridge, a
    // Profile 7 source keeps the native route, and a Dolby Vision Profile 5 / 10.0 source yields no
    // scrub still or held picture. LibDovi, FFmpeg and everything else are unaffected.
    traits: [
        .trait(
            name: "TrueHDObjectAudio",
            description: "Link LibTrueHD and the object renderer, so objectAudioRendering can render TrueHD Atmos objects to APAC."
        ),
        .trait(
            name: "DTSXObjectAudio",
            description: "Link LibDTSX and the object renderer, so objectAudioRendering can render DTS:X heights and objects to APAC."
        ),
        .trait(
            name: "DualLayerDolbyVision",
            description: "Compile the Dolby Vision Profile 7 FEL dual-layer composer, so preferDualLayerDolbyVision can take that route."
        ),
        .trait(
            name: "DolbyVisionStillReshaping",
            description: "Compile the CPU reshaping that turns a Dolby Vision Profile 5 / 10.0 frame into a still (scrub thumbnails, I-frame stills, held pictures)."
        ),
        .default(enabledTraits: []),
    ],
    dependencies: [
        // Minimal FFmpeg build (avcodec, avformat, avutil, swresample only).
        // No network stack, we use custom AVIO + URLSession for HTTP streams.
        // Resolved over Git rather than a local path so consumers (and
        // Xcode Cloud) can build without a sibling FFmpegBuild checkout.
        // Pinned to the minor rather than `from:`: this package ships the
        // prebuilt decode stack, so a floating minor silently changes which
        // FFmpeg a released engine tag runs (2.3.0 -> 2.4.0 did exactly that
        // under 5.28.0), and a minor that raises a platform floor retroactively
        // breaks every tag that floats onto it (LibDovi 1.1.0, below). Patch
        // rebuilds still reach existing tags, which is where a pure rebuild
        // belongs; anything that adds slices or enables a component is a minor
        // and reaches consumers through an engine release.
        .package(url: "https://github.com/superuser404notfound/FFmpegBuild", .upToNextMinor(from: "3.7.1")),  // 3.7.1: the mp4 muxer no longer aborts the process when a fragment is flushed with a packet still queued in the interleaver behind the samples already written for its track (check_pkt had clamped them past it, so get_cluster_duration hit av_assert0(next_dts >= 0)); same n8.1.3 otherwise; 3.7.0: the mp4 muxer's dec3 box describes a DD+ track whose height channels and Atmos objects live in a dependent substream (Blu-ray style AC-3 core plus E-AC-3 dependent frame): chan_loc is derived from chanmap per TS 102 366 (upstream f10fdd6310, backported) and the TS 103 420 JOC extension is taken from the dependent substream too, so such a track is no longer described as a bare 5.1 bed and an Atmos receiver no longer reports multichannel PCM (#728); same n8.1.3 otherwise; 3.6.0: an MPEG-TS audio PID is identified by its payload when its label does not name the codec: the raw dts / truehd / loas demuxers are in, so the mpegts content probe can confirm DTS, TrueHD and LATM at all (without them the lenient mp3 probe named the track, whatever the label), and a PID labelled 0x03 (MPEG-1 audio) gets the same content probe as 0x04; a DTS-HD IPTV channel opened as mp3 and never produced a frame (#641); same n8.1.3 otherwise; 3.5.0: FFmpeg n8.1.3, 268 upstream commits over n8.1.2, of which six touch code this engine ships: VP9 kept `next_refs[]` referenced across `avcodec_flush_buffers()`, so a worker could reseed its references from the pre-flush set and the first inter frame after a seek decoded against released buffers (heap OOB read and write, and this engine decodes VP9 with frame threading and flushes on every reposition); the Dolby Vision RPU parser trims trailing zero padding again, which n8.1.2 had stopped doing, so a padded RPU no longer fails the ext-block size check and loses its dynamic metadata, and the RPU partition counts are bounded; a VC-1 picture ending on a one-bit skipped macroblock keeps that macroblock instead of falling into error concealment; the `dca_core` bsf clears the profile it has just stripped; and a container channel layout survives a failed decoder open during probing. Same dav1d 1.5.4, zimg 3.0.6 and libzvbi 0.2.45 (all current upstream), same component set, same six local patches, unchanged soname majors; 3.4.0: FFmpeg learns the `dav1` sample entry in both directions, the AV1 variant of `av01` that signals Dolby Vision, so a Profile 10.0 source can be read at all and can be remuxed with the tag its packaging requires; stock FFmpeg has it in neither of its two mp4 tag tables, so the read probes as "unknown codec" and the write fails EINVAL (#547); same n8.1.2 binaries as 3.3.0 otherwise, compiled against the Xcode 27 SDKs with unchanged deployment targets; 3.3.0: every slice a shipped app can embed carries its dSYM inside the xcframework, so Xcode copies it into `.xcarchive/dSYMs` and a crash inside FFmpeg symbolicates instead of staying a list of addresses (FFmpegBuild#4); same n8.1.2 binaries as 3.2.1 apart from their UUID, the libraries just compile with `-gline-tables-only` now and the debug map is harvested before the shipped binary is stripped; 3.2.1: vc1_parser seeds its parse context from extradata, so a seek landing on an entry point alone keeps its picture size instead of falling back to 0x0 or to a size read out of the following payload (#490, FFmpeg PR 24458); 3.2.0: the legacy Flash tail, video and audio together (flv1 / vp6 / vp6f / vp6a, nellymoser, adpcm_swf, speex, and FLV's pcm_s16be / pcm_u8 / pcm_alaw / pcm_mulaw), so a pre-2008 .flv plays with sound where before only H.264-in-FLV did; flashsv stays out, it needs zlib and would have been dropped silently; 3.1.0: native .wmv / .asf, the asf demuxer plus every WMA decoder (Standard, Pro, Lossless, Voice), which is the container half of the legacy Microsoft support 2.4.3 started (FFmpegBuild#3); 3.0.0: every target, product, framework bundle and install name carries an `Aether` prefix, so this build can sit in an app that already has an FFmpeg (FFmpegKit, MobileVLCKit, mpv); same n8.1.2 binaries as 2.5.0, only names changed; 2.5.0: libzvbi 0.2.45 for GHSA-86rm-g7qf-j2fh (OOB read/write + integer underflow, reachable through the libzvbi_teletext decoder), dav1d 1.5.4, zimg 3.0.6, and the concat demuxer removed (a script demuxer selectable by probing alone, which made any stream a potential file-open primitive); 2.4.3: the legacy Microsoft video decoders (msmpeg4v1/v2/v3, wmv1/wmv2/wmv3; FFmpegBuild#3); 2.4.2: pgssubdec missing-palette recovery, replaces the 2.1.1 Epoch-Continue retain (#142); 2.4.1: qtrle decoder; 2.4.0: visionOS (xros) device + simulator slices; 2.3.0: webvtt demuxer (standalone .vtt sidecars, plus the cue settings as packet side data); 2.2.0: matroska TTS warn-only per RFC 9559 (#145 rework); 2.1.3: sup demuxer (raw PGS sidecars); 2.1.2: matroska TrackTimestampScale clamp (#145, dropped in 2.2.0); 2.1.1: pgssubdec Epoch-Continue retain (#142); 2.1.0: yadif_videotoolbox + hwupload (Metal GPU deinterlace); 2.0.0: dynamic frameworks (LGPL), zvbi GPL excision
        // Pure-Swift SMB2 client (MIT) that speaks the protocol over
        // NWConnection. Replaces AMSMB2/libsmb2, which EPERMs on tvOS/iOS.
        // Pinned to the 0.3.x minor: SMBClient is pre-1.0 with an actively
        // moving API, so allow patch updates but not a minor bump.
        .package(url: "https://github.com/kishikawakatsumi/SMBClient", .upToNextMinor(from: "0.3.1")),
        // libdovi (Dolby Vision RPU parser/converter). Resolved over Git like
        // FFmpegBuild so consumers (and Xcode Cloud) build without a sibling
        // LibDovi checkout; the prebuilt xcframework needs no Rust at build time.
        // Pinned to the minor for the same reason as FFmpegBuild above, with a
        // worked example: 1.1.0 shipped a tvOS floor raise as a minor, SwiftPM
        // floated every `from: "1.0.x"` consumer onto it and then failed on the
        // floor instead of backing off, so all of 5.x stopped resolving.
        .package(url: "https://github.com/superuser404notfound/LibDovi", .upToNextMinor(from: "2.1.0")),  // 2.1.0: dolby_vision 3.4.0, header additive only (two new CMv4.0 metadata entry points, nothing removed); 2.0.0: visionOS (xros) device + simulator slices, declared tvOS floor corrected to 17.0 (was published as 1.1.0, withdrawn: a floor raise is breaking and broke every 5.x pin that floated onto it); 1.0.2: iOS slices + x86_64 (Intel Macs)
        // TrueHD decoder that also decodes the Atmos object presentation (beds, objects, OAMD) for
        // `objectAudioRendering` (#731). The Rust `truehd` crate (Apache-2.0) behind a C API, prebuilt
        // as an xcframework like LibDovi so consumers need no Rust. Pinned to the minor for the same reason.
        .package(url: "https://github.com/superuser404notfound/LibTrueHD", .upToNextMinor(from: "2.3.1")),  // 2.3.1: truehd_atmos_version_string() names the truehd commit actually built in (read from Cargo.lock, LibTrueHD#2), same decoder; 2.3.0: decodes about a third faster again (harletty's truehd speed work: blocks decoded in place, table-driven Huffman, vectorised prediction filters, whole-block matrices; truehdd#42 included), byte-identical output; 2.2.1: rust_eh_personality exported weak, so it coalesces with LibDovi's copy and a host with its own Objective-C and C++ stays within compact unwind's three personality routines (#752); same decoder; 2.2.0: decodes about 30% faster (the truehd crate with its block and PCM buffers sized to the samples they hold, truehdd#42, from a fork of upstream main until that is merged), byte-identical output; 2.1.0: x86_64 in the iOS simulator slice, so a generic iOS Simulator build of a host links; same decoder; 2.0.0: transferred from Silo-Server/SiloObjectAudio and renamed (product TrueHD), rebuilt from source; same decoder as SiloObjectAudio 1.0.0
        // DTS:X decoder for `objectAudioRendering`: lossless DTS-HD MA with the encoder's height and object
        // folds removed from the bed, the fixed heights, and the alternate presentations' objects placed in
        // the same room coordinates as LibTrueHD's. The Rust `dca` crate behind a C API, a port of FFmpeg's
        // LGPL-2.1-or-later dca decoder, so the built library is LGPL-3.0-or-later and ships as a dynamic
        // framework the app embeds, like FFmpegBuild's (#798). Pinned to the minor for the same reason.
        .package(url: "https://github.com/superuser404notfound/LibDTSX", .upToNextMinor(from: "2.0.0")),  // 2.0.0: DTSX.framework, dynamic, exporting only the C API, with dSYMs; NOTICE states the LGPL; same decoder, bit-identical output (#798); 1.0.1: rust_eh_personality weak (#752); dca 0.8.0 (harletty-bridge a717bae); the first two frames after a start or seek only prime the decoder
    ],
    targets: [
        .target(
            name: "AetherEngine",
            dependencies: [
                .product(name: "AetherFFmpegBuild", package: "FFmpegBuild"),
                .product(name: "Dovi", package: "LibDovi"),
                .product(name: "TrueHD", package: "LibTrueHD", condition: .when(traits: ["TrueHDObjectAudio"])),
                .product(name: "DTSX", package: "LibDTSX", condition: .when(traits: ["DTSXObjectAudio"])),
            ],
            // Silent E-AC-3 Atmos that `AtmosOutputActivator` loops beside an APAC track on tvOS.
            resources: [.copy("Resources/silent-atmos.mp4")],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AVKit"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("AudioToolbox"),
            ]
        ),
        .target(
            name: "AetherEngineSMB",
            dependencies: [
                "AetherEngine",
                .product(name: "SMBClient", package: "SMBClient"),
            ],
            path: "Sources/AetherEngineSMB"
        ),
        .executableTarget(
            name: "aetherctl",
            dependencies: ["AetherEngine", "AetherEngineSMB"],
            path: "Sources/aetherctl"
        ),
        // The samples in Examples/ are drop-in files rather than apps, so nothing used to
        // compile them and they could rot the way prose rots, except a reader trusts them
        // more. Compiling them as a target (never a product, so no consumer builds it)
        // makes `swift build` and CI the guard. DemoPlayerMac is its own package and
        // excluded here; it builds with `swift build --package-path Examples/DemoPlayerMac`.
        .target(
            name: "ExampleSources",
            dependencies: ["AetherEngine"],
            path: "Examples",
            exclude: ["README.md", "DemoPlayerMac"]
        ),
        .testTarget(
            name: "AetherEngineTests",
            dependencies: ["AetherEngine"],
            path: "Tests/AetherEngineTests"
        ),
        .testTarget(
            name: "AetherEngineSMBTests",
            dependencies: ["AetherEngineSMB"],
            path: "Tests/AetherEngineSMBTests"
        ),
    ]
)
