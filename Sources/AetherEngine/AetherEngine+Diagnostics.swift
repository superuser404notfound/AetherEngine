import Foundation
import Darwin.Mach
import AVFoundation

extension AetherEngine {

    /// Reads presentation evidence from the active local video pipeline, without waiting for a frame.
    /// Native readiness can briefly fall during item swaps. Software metrics count non-dropped frames
    /// cumulatively and do not prove a picture survived a flush. Hosts may latch a true for startup,
    /// but must not treat a false as a request to restore a poster or as evidence of lost playback.
    /// Unavailable metrics (including visionOS 1.0), cancellation and a superseded session return false.
    public func hasRenderedVideoFrame() async -> Bool {
        await hasRenderedVideoFrame(readSoftwareMetrics: { await $0.loadRenderMetrics() })
    }

    // Keep the asynchronous read injectable so a replacement load can be tested while it is pending.
    func hasRenderedVideoFrame(
        readSoftwareMetrics: @MainActor (SoftwarePlaybackHost) async -> SampleBufferRenderer.RenderMetrics?
    ) async -> Bool {
        guard !Task.isCancelled else { return false }
        switch playbackBackend {
        case .native:
            // A reused layer may still hold the outgoing item's picture until the next load mounts.
            return hasFirstFrameReadyForDisplay && nativePlayerLayer?.isReadyForDisplay == true
        case .software:
            guard let host = softwareHost else { return false }
            let generation = loadGeneration
            guard let metrics = await readSoftwareMetrics(host),
                  !Task.isCancelled, loadGeneration == generation,
                  playbackBackend == .software, softwareHost === host else { return false }
            // Each software host owns one renderer for its lifetime, so host identity also fences
            // the surface whose asynchronous counters answered.
            return metrics.total > metrics.dropped
        case .none, .audio, .aether:
            return false
        }
    }

    /// #220 diagnostic opt-in: appends a live large-block census (blocks >= 1 MB, bucketed by
    /// size class) to the 30 s memprobe line. A flat `mallocBlocks` with a rising `mallocMB`
    /// identifies "one large buffer is growing" but not which one; the census names the size
    /// class so the search does not depend on having guessed the site.
    ///
    /// Off by default and intended for triage builds only: the walk holds every malloc zone
    /// through `force_lock`, which briefly blocks allocating threads.
    ///
    /// Enabling also arms a jump trigger on its own queue (see `MallocBlockCensusTrigger`). The 30 s
    /// memprobe cannot catch a failure that completes inside one sample, which is what every kill on
    /// #220 turned out to be, so the counter is polled at `triggerPollHz` and the zone walk runs once
    /// it climbs `triggerThresholdMB` above its running high-water. Pass `triggerPollHz: 0` for the
    /// plain 30 s census with no watcher.
    ///
    /// `triggerCaptureCap` bounds how many of those walks are logged (`0` = uncapped). The default of
    /// twelve keeps a runaway from turning the log into a slideshow, but a session that climbs at a
    /// steady mux rate spends one capture per threshold climbed and reaches the cap minutes before
    /// the kill (AE#445, where the decisive final step survived only in the 30 s grid). Lift it when
    /// the shape being hunted is a steady climb rather than a single step.
    public nonisolated static func setLargeAllocationCensusEnabled(
        _ enabled: Bool,
        triggerThresholdMB: Int = 64,
        triggerPollHz: Double = 8,
        triggerCaptureCap: Int = 12   // MallocBlockCensus.defaultTriggerCaptureCap, spelled out because that type is internal
    ) {
        MallocBlockCensus.isEnabled = enabled
        // AE#445: the same switch, because they answer halves of one question. The malloc census
        // covers the heap; the region census covers everything phys_footprint counts that malloc
        // never sees, which is where three rounds of that issue ran out of instrument.
        VMRegionCensus.isEnabled = enabled
        if !enabled { VMRegionCensus.clearBaseline() }
        if enabled {
            MallocBlockCensus.startTriggerWatch(thresholdMB: triggerThresholdMB, pollHz: triggerPollHz,
                                                captureCap: triggerCaptureCap)
        } else {
            MallocBlockCensus.stopTriggerWatch()
        }
    }

    // MARK: - Buffer probe

    /// Seconds of AVPlayer buffer ahead of the current playhead (sum of loadedTimeRanges beyond now). 0 on SW path / pre-start.
    /// Surfaced in the 30 s memprobe and the #65 VOD shift-publish diagnostic so a stale cross-epoch buffer is visible.
    ///
    /// AE#422: async, because it hops off the main actor. Its one caller emits from inside a producer
    /// restart, which is a state where the media server may not answer, and a figure that only ever
    /// appears in a log line must not be able to block the app to produce itself.
    func avPlayerBufferAheadSeconds() async -> Double {
        guard let avPlayer = currentAVPlayer, let item = avPlayer.currentItem else { return 0 }
        return await AVFoundationOffMain.read(item, on: NativeAVPlayerHost.offMainReadQueue) { item in
            let now = item.currentTime().seconds
            var ahead = 0.0
            for value in item.loadedTimeRanges {
                let range = value.timeRangeValue
                let start = range.start.seconds
                let end = (range.start + range.duration).seconds
                if end > now { ahead += end - max(start, now) }
            }
            return ahead
        }
    }

    /// AE#418: the item's loaded ranges on the item axis. Where AVPlayer HOLDS what it fetched is the
    /// only on-device account of where it placed a segment, and the axis is a statement about exactly
    /// that. Off-main for the same reason as the buffer probe (AE#422).
    func avPlayerLoadedRanges() async -> [(Double, Double)] {
        guard let avPlayer = currentAVPlayer, let item = avPlayer.currentItem else { return [] }
        return await AVFoundationOffMain.read(item, on: NativeAVPlayerHost.offMainReadQueue) { item in
            item.loadedTimeRanges.map { value in
                let r = value.timeRangeValue
                return (r.start.seconds, (r.start + r.duration).seconds)
            }
        }
    }

    /// AE#509: the item's own account of itself, in the three fields a host dumps when a live join
    /// fetches a whole window and presents none of it.
    ///
    /// The engine publishes `item time + playlistShiftSeconds`, so on a live source whose axis is
    /// hours into an encoder clock the session clock and the ITEM clock are thousands of seconds
    /// apart in a perfectly healthy session. A diagnostic that prints only the published clock
    /// therefore cannot be read against a reporter's `AVPlayerItem.currentTime()` at all: the two
    /// disagree by the shift by construction, which is the same disagreement a wedged session is
    /// being accused of. Print both or neither.
    ///
    /// Off-main for the same reason as the buffer probe (AE#422).
    public struct NativeItemReading: Sendable {
        /// `AVPlayerItem.currentTime().seconds`, on the ITEM axis. NaN before the item resolves.
        public let playhead: Double
        /// `AVPlayerItem.loadedTimeRanges.count`. Zero is "nothing has been PLACED", which no buffer
        /// depth can say: `isPlaybackBufferEmpty` is false on an item that fetched and placed
        /// nothing (AE#418, a fetch is not a placement).
        public let loadedRangeCount: Int
        /// `AVPlayerItem.status.rawValue`: 0 unknown, 1 readyToPlay, 2 failed.
        public let status: Int
    }

    /// The reading above, or nil when no native item is mounted (software path, pre-load, torn down).
    public func nativeItemReading() async -> NativeItemReading? {
        guard let avPlayer = currentAVPlayer, let item = avPlayer.currentItem else { return nil }
        return await AVFoundationOffMain.read(item, on: NativeAVPlayerHost.offMainReadQueue) { item in
            NativeItemReading(playhead: item.currentTime().seconds,
                              loadedRangeCount: item.loadedTimeRanges.count,
                              status: item.status.rawValue)
        }
    }

    /// AE#418 round 3: check a just-published VOD axis against AVPlayer's own account of the placement
    /// it describes, and let the session correct it when the base it composed onto was never carried.
    ///
    /// Polled rather than awaited on an edge, because the publish happens when the segment is FETCHED
    /// and the ranges only move once AVPlayer has taken the bytes.
    ///
    /// Round 4: the first sample is the BASELINE, taken before AVPlayer can have the bytes, and every
    /// later sample is read against it. Only a run that overlaps nothing in the baseline is this
    /// placement's; the run that was already there answers a different question, and its own start
    /// moves while it is asked, because AVPlayer backfills below a run after it opens. Reading the
    /// first range that happened to hold the playhead is what let a stale run be reported as a
    /// confirmation, one to two frames at a time, until the accumulated difference exceeded the check
    /// itself.
    /// Samples taken once the request behind the placement has been answered.
    static let placementVerificationAttempts = 6
    /// How long to keep waiting while it has NOT been. A deep re-aim makes the producer scan seconds
    /// of source before its first segment lands, and an empty buffer says nothing about a placement
    /// whose bytes have not gone out yet. The #93 slow-serve window reaches 25 to 50 s in the worst
    /// case, so the wait outlasts the sampling rate: the first samples are 250 ms apart, and once the
    /// answer is overdue they drop to one a second for the rest of it.
    static let placementVerificationWaitSeconds = 30.0
    static let placementVerificationIntervalMS = 250
    static let placementVerificationSlowIntervalMS = 1000

    /// AE#481: how long after a seek the landing's run is read for. The reading needs a run that
    /// HOLDS the target, so it has to outlast the landing itself; three seconds covers a landing that
    /// buffers on a shaped link (measured: the run holding the landing was there within 1.5 s on every
    /// arm at 600 kbps / 300 ms) without keeping a sampler alive into the next seek.
    static let landingAxisWaitSeconds = 3.0

    /// AE#481: read what the run holding a seek landing carries, and correct the axis when the timeline
    /// disagrees with the composition it inherited. Silent in every session whose landing stays inside
    /// the run it was already playing, which is what a fast link produces.
    func verifyAxisAtSeekLanding(session: HLSVideoEngine, landingItemSeconds: Double) {
        landingAxisTask?.cancel()
        landingAxisTask = Task { @MainActor [weak self, weak session] in
            var waited = 0.0
            while waited < Self.landingAxisWaitSeconds {
                try? await Task.sleep(for: .milliseconds(Self.placementVerificationIntervalMS))
                waited += Double(Self.placementVerificationIntervalMS) / 1000
                guard !Task.isCancelled, let self, let session else { return }
                let ranges = await self.avPlayerLoadedRanges()
                guard !Task.isCancelled else { return }
                // A publication is the end of it: the axis it wrote is the one every later reading
                // composes onto, and sampling on would re-read what this just published.
                if session.applyLandingAxisReading(
                    landingItemSeconds: landingItemSeconds, ranges: ranges) { return }
            }
        }
    }

    func verifyPlacementAgainstLoadedRanges(session: HLSVideoEngine) {
        placementVerificationTask?.cancel()
        guard session.hasPlacementAwaitingMeasurement else { return }
        placementVerificationTask = Task { @MainActor [weak self, weak session] in
            var samplesSinceAnswered = 0
            var lastRanges: [(Double, Double)] = []
            var waited = 0.0
            while waited < Self.placementVerificationWaitSeconds {
                let intervalMS = samplesSinceAnswered > 0 || waited < 2.0
                    ? Self.placementVerificationIntervalMS
                    : Self.placementVerificationSlowIntervalMS
                waited += Double(intervalMS) / 1000
                try? await Task.sleep(for: .milliseconds(intervalMS))
                guard !Task.isCancelled, let self, let session else { return }
                let ranges = await self.avPlayerLoadedRanges()
                guard !Task.isCancelled, let pending = session.pendingPlacement else { return }
                lastRanges = ranges
                // AE#418 round 7: the run that opens where this placement's segment begins is its own,
                // through the axis the timeline carried or, on a timeline AVPlayer rebuilt, through no
                // axis at all. Asked as "which run is new here", a later seek's run answers for it
                // (measured against the picture: 21 s of error, and 41.667 s on the wide fixture).
                if let run = HLSVideoEngine.placementRunStart(
                    ranges: ranges, predictedSeam: pending.seam, rawSeam: pending.rawSeam) {
                    session.reconcileAxisWithObservedPlacement(
                        observedItemStart: run.start, itemClock: self.nativeClockSeconds,
                        source: run.source)
                    return
                }
                switch session.pendingPlacementDelivery {
                case .some(false):
                    // The response failed, so these bytes are never arriving.
                    samplesSinceAnswered = Self.placementVerificationAttempts
                case .some(true):
                    samplesSinceAnswered += 1
                case .none:
                    break
                }
                if samplesSinceAnswered >= Self.placementVerificationAttempts { break }
            }
            guard !Task.isCancelled, let session, let pending = session.pendingPlacement else { return }
            session.resolveUnreadablePlacement(
                heldInBuffer: HLSVideoEngine.placementIsHeld(ranges: lastRanges, seam: pending.seam),
                answered: session.pendingPlacementDelivery != nil)
        }
    }

    // MARK: - Memory diagnostic

    /// Cancel any prior probe, then emit one EngineLog line every 30 s under `.engine`. Line shape is documented on `memoryProbeTask`.
    func startMemoryProbe() {
        memoryProbeTask?.cancel()
        let sessionStart = Date()
        // #243: the disc pull path's byte tally is session-scoped like `elapsed`, so it can be read
        // as a rate off two probe lines.
        HTTPDiscIOReader.resetLifetimeFetchedBytes()
        // #134: currentTime()/loadedTimeRanges are sync XPC reads; hop them off the main actor.
        let probeReadQueue = DispatchQueue(label: "engine.memprobe.avfread", qos: .utility)
        let cpuSampler = ThreadCPUSampler()
        _ = cpuSampler.sample()
        memoryProbeTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if Task.isCancelled { return }
                guard let self = self else { return }

                // AVPlayer buffer probe: if ahead > preferredForwardBufferDuration, suspect linear-growth memory leak.
                var bufferAheadSec = 0.0
                var bufferBehindSec = 0.0
                if let avPlayer = self.currentAVPlayer,
                   let item = avPlayer.currentItem {
                    (bufferAheadSec, bufferBehindSec) = await AVFoundationOffMain.read(item, on: probeReadQueue) { item in
                        let now = item.currentTime().seconds
                        var ahead = 0.0
                        var behind = 0.0
                        for value in item.loadedTimeRanges {
                            let range = value.timeRangeValue
                            let start = range.start.seconds
                            let end = (range.start + range.duration).seconds
                            if end > now { ahead += end - max(start, now) }
                            if start < now { behind += min(end, now) - start }
                        }
                        return (ahead, behind)
                    }
                    if Task.isCancelled { return }
                }
                let elapsed = Int(Date().timeIntervalSince(sessionStart))
                let rssMB = Self.residentMemoryMB()
                let cueCount = self.subtitleCues.count

                // Zero on SW path or pre-start; 30 s cadence makes non-atomic field drift irrelevant.
                let stats = self.nativeVideoSession?.diagnosticStats()
                let avioMB = (stats?.avioBytesFetched ?? 0) / 1024 / 1024
                let discFetchedMB = HTTPDiscIOReader.lifetimeFetchedBytes / 1024 / 1024
                let cacheMB = (stats?.segmentCacheBytes ?? 0) / 1024 / 1024
                let cacheCount = stats?.segmentCacheCount ?? 0
                let packetsWritten = stats?.producerPacketsWritten ?? 0
                let audioFifo = stats?.audioFifoSamples ?? 0
                let abFifoKB = (stats?.audioBridgeFifoBytes ?? 0) / 1024
                let abSwrKB = (stats?.audioBridgeSwrBytes ?? 0) / 1024
                let abTotKB = (stats?.audioBridgeTotalBytes ?? 0) / 1024
                let muxBytesMB = (stats?.muxerLifetimeFragmentBytes ?? 0) / 1024 / 1024
                let muxCuts = stats?.muxerFragmentCuts ?? 0
                let srvConns = stats?.serverConnectionCount ?? 0
                let srvBytesMB = (stats?.serverLifetimeBytesSent ?? 0) / 1024 / 1024
                let srvSfMB = (stats?.serverSendfileBytesSent ?? 0) / 1024 / 1024
                let pktAlive = stats?.packetsAlive ?? 0
                let pktTotal = stats?.packetsTotalAllocs ?? 0

                // VM buckets: internal=heap, external=mmap/dyld, compressed=kernel-compressed, iosurfaces=decoded video frames.
                let vmStr: String
                if let vm = Self.vmBreakdownMB() {
                    vmStr = "vmInt=\(vm.internalMB)MB "
                        + "vmExt=\(vm.externalMB)MB "
                        + "vmCmp=\(vm.compressedMB)MB "
                        + "vmIOS=\(vm.iosurfaceMB)MB "
                        + "physFP=\(vm.physFootprintMB)MB "
                } else {
                    vmStr = ""
                }

                let mallocStr: String
                if let m = Self.mallocZoneSummary() {
                    mallocStr = "mallocBlocks=\(m.blocksInUse) mallocMB=\(m.sizeInUseMB) "
                } else {
                    mallocStr = ""
                }

                // #220: the two readers of a subtitled VOD session, separately attributable.
                // `ahead` far above winHighWater (16 MB VOD / 64 MB live) with `parked=0` is
                // backpressure that never engaged; the pump's own window is the control. A live
                // reader plateauing between the two marks is healthy: that is the join burst,
                // absorbed once and held.
                //
                // Both paths, not just software. On a direct-play source the native path runs
                // the HLS loopback, so `HLSVideoEngine` demuxes from the origin through an
                // AVIOReader of its own and only the remuxed segments reach AVPlayer. Its
                // producer parks whenever the forward buffer is full, which is exactly the
                // shape that lets a connection ignoring the suspend keep filling the window,
                // and the #174 field crash it was built against (HTTPS origin, boringssl in
                // the stack) was on this path. Reporting software-only hid that.
                let pumpWin = self.pumpIOWindow
                let prefetchWin = self.subtitleForwardPrefetchDemuxer?.ioWindowDiagnostics
                let readerStr = Self.readerWindowFragment(
                    pump: pumpWin, prefetch: prefetchWin,
                    pumpFetchedBytes: self.softwareHost?.demuxerBytesFetched
                        ?? self.nativeVideoSession?.demuxerBytesFetched,
                    prefetchFetchedBytes: self.subtitleForwardPrefetchDemuxer?.avioBytesFetched)

                // #303: the software path's own read-ahead, and what the display did with it.
                // `avBufAhead` covers the AVPlayer path only, and `frameAhead` is the native
                // producer-shift fold that reads 0 here whatever the buffer is doing, so a software
                // session used to leave a trace with no cushion figure in it at all.
                let swStr = Self.softwareReadAheadFragment(
                    cushionSeconds: self.softwareHost?.displayCushionSeconds,
                    metrics: await self.softwareHost?.loadRenderMetrics())

                let line = "[AetherEngine] memprobe t=\(elapsed)s "
                    + "rss=\(rssMB)MB "
                    + vmStr
                    + mallocStr
                    // #220: empty unless the host opted in. A flat mallocBlocks with a rising
                    // mallocMB says one large buffer is growing but not which; this names the
                    // size class. `peak` is the watcher's high-water, which survives a step the
                    // 30 s cadence never sampled.
                    + MallocBlockCensus.probeFragment()
                    + (MallocBlockCensus.isEnabled ? "peakMB=\(MallocBlockCensus.peakSizeInUseMB) " : "")
                    // AE#445: which VM region the footprint grew in, by tag and by delta against
                    // the first tick. `physFP` rising while every bucket above it is flat is the
                    // state this issue kept ending in, and it means the growth is somewhere none of
                    // them look, not that there is nothing to find.
                    + VMRegionCensus.probeFragment()
                    + "avioFetchedMB=\(avioMB) "
                    // #243: only the disc pull path fills this, and only then is it printed. On a
                    // remote ISO every reader fork pulls through HTTPDiscIOReader, which
                    // `avioFetchedMB` does not see at all, so without it the one path doing the
                    // reading is the one path with no counter.
                    + (discFetchedMB > 0 ? "discFetchedMB=\(discFetchedMB) " : "")
                    + "cacheCount=\(cacheCount) cacheMB=\(cacheMB) "
                    + "packetsWritten=\(packetsWritten) "
                    + "audioFifo=\(audioFifo) "
                    + "abFifoKB=\(abFifoKB) abSwrKB=\(abSwrKB) abTotKB=\(abTotKB) "
                    + "muxBytesMB=\(muxBytesMB) muxCuts=\(muxCuts) "
                    + "srvConns=\(srvConns) srvBytesMB=\(srvBytesMB) srvSfMB=\(srvSfMB) "
                    + "pktAlive=\(pktAlive) pktTotal=\(pktTotal) "
                    + "subCues=\(cueCount) "
                    + readerStr
                    // #220: the lead is the live tell. It is visible minutes before a kill and
                    // separates "reads fast while building its lead" from "the lead never settles".
                    + SubtitlePrefetchTelemetry.probeFragment(playhead: self.sourceTime)
                    + "swFrames=\(self.softwareHostFramesEnqueued) "
                    + swStr
                    + "audioTracks=\(self.audioTracks.count) "
                    + "subTracks=\(self.subtitleTracks.count) "
                    + "subActive=\(self.isSubtitleActive) "
                    + "avBufAhead=\(String(format: "%.1f", bufferAheadSec))s "
                    + "avBufBehind=\(String(format: "%.1f", bufferBehindSec))s "
                    // Shift coherence: prodShift is the producer edge, hostShift the shift the clock folds
                    // with, and frameAhead their difference. Since #260 a VOD restart records a seam instead
                    // of collapsing the history, so a non-zero frameAhead now means the producer has moved to
                    // a new epoch while AVPlayer still presents the previous one, which is a real state and
                    // not a defect on its own; seams counts the epochs still on record.
                    + "frameAhead=\(String(format: "%.2f", self.frameAhead))s "
                    + "prodShift=\(String(format: "%.2f", self.activeProducerShiftSeconds))s "
                    + "hostShift=\(String(format: "%.2f", self.playlistShiftSeconds))s "
                    + "seams=\(self.presentationAxis.seams.count)"

                EngineLog.emit(line, category: .engine)
                if let cpu = cpuSampler.sample() {
                    EngineLog.emit("[AetherEngine] cpuprobe t=\(elapsed)s " + cpu.logFragment(), category: .engine)
                }

                // #250: the steady-state cadence for the subtitle-resolution statement. It rides
                // the memprobe rather than the 2 Hz drain tick because it states a span, and a
                // span restated four times a second per channel buries the transitions that carry
                // the information. Silent when no subtitle drain target is active.
                self.emitSubtitleResolutionStatements(reason: .tick)
            }
        }
    }

    /// Cancel any prior sampler, then start a fresh 1 Hz LiveTelemetrySampler. Mirrors `startMemoryProbe` lifecycle.
    func startLiveTelemetrySampler() {
        liveTelemetrySampler?.stop()
        let sampler = LiveTelemetrySampler(engine: self)
        liveTelemetrySampler = sampler
        sampler.start()
    }

    /// Resident memory via `mach_task_basic_info`, in MB. Returns 0 on error. Allocation-free; safe from any thread.
    static func residentMemoryMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Int(info.resident_size / 1024 / 1024)
    }

    /// VM breakdown via `task_vm_info`: internal=heap/malloc, external=mmap/dyld, compressed=kernel-compressed, iosurfaces=HEVC frame pool.
    /// Surfaced in the 30 s memprobe so investigations can see which bucket moved.
    static func vmBreakdownMB() -> (internalMB: Int,
                                    externalMB: Int,
                                    compressedMB: Int,
                                    iosurfaceMB: Int,
                                    physFootprintMB: Int)? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return (
            internalMB: Int(info.internal / 1024 / 1024),
            externalMB: Int(info.external / 1024 / 1024),
            compressedMB: Int(info.compressed / 1024 / 1024),
            iosurfaceMB: Int(info.device / 1024 / 1024),
            physFootprintMB: Int(info.phys_footprint / 1024 / 1024)
        )
    }

    /// `malloc_zone_statistics(nil, ...)` summed across all zones. Rising block count = allocation leak; flat count + rising size = single large buffer growing.
    static func mallocZoneSummary() -> (blocksInUse: Int, sizeInUseMB: Int)? {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return (blocksInUse: Int(stats.blocks_in_use),
                sizeInUseMB: Int(stats.size_in_use / 1024 / 1024))
    }

    /// #220: one memprobe fragment per live `AVIOReader` window. `win` is the whole buffer,
    /// `ahead` the undrained forward extent that `appendPersistentData` gates the backpressure
    /// end on. `ahead` far above winHighWater (16 MB VOD / 64 MB live) while `parked=0` means the backpressure
    /// never engaged, which is a different defect from a transport overshoot past an end that
    /// fired (#310: the end replaced the suspend, so the overshoot is bounded by one
    /// delivery's in-flight amount rather than by whatever a suspended task lets through).
    ///
    /// #240: `FetchedMB` per reader is the link attribution. The aggregate `avioFetchedMB` cannot
    /// answer "who took the bandwidth", and the reporter of #240 had to infer a second reader from
    /// connection-start lines that carried no identity. Two counters side by side answer it directly:
    /// a session whose `prefFetchedMB` tracks `pumpFetchedMB` is reading the stream twice.
    nonisolated static func readerWindowFragment(
        pump: (windowBytes: Int, aheadBytes: Int, parked: Bool)?,
        prefetch: (windowBytes: Int, aheadBytes: Int, parked: Bool)?,
        pumpFetchedBytes: Int64? = nil,
        prefetchFetchedBytes: Int64? = nil
    ) -> String {
        func fragment(
            _ prefix: String,
            _ w: (windowBytes: Int, aheadBytes: Int, parked: Bool)?,
            _ fetched: Int64?
        ) -> String {
            guard let w else { return "" }
            return "\(prefix)WinMB=\(w.windowBytes / 1024 / 1024) "
                + "\(prefix)AheadMB=\(w.aheadBytes / 1024 / 1024) "
                + "\(prefix)Parked=\(w.parked ? 1 : 0) "
                + (fetched.map { "\(prefix)FetchedMB=\($0 / 1024 / 1024) " } ?? "")
        }
        return fragment("pump", pump, pumpFetchedBytes)
            + fragment("pref", prefetch, prefetchFetchedBytes)
    }

    /// #303: the software path's read-ahead, and the display's own account of what it did with it.
    /// Empty on a native session, so the line does not carry three fields that can only read zero
    /// there. Each half is independently optional: the cushion exists as soon as a frame has been
    /// enqueued, while the metrics need an OS and a queue target that can answer for them.
    nonisolated static func softwareReadAheadFragment(
        cushionSeconds: Double?,
        metrics: SampleBufferRenderer.RenderMetrics?
    ) -> String {
        var out = ""
        if let cushionSeconds {
            out += "swAhead=\(String(format: "%.2f", cushionSeconds))s "
        }
        if let metrics {
            out += "swDropped=\(metrics.dropped)/\(metrics.total) "
            if metrics.corrupted > 0 { out += "swCorrupt=\(metrics.corrupted) " }
            out += "swDelay=\(String(format: "%.2f", metrics.accumulatedDelay))s "
        }
        return out
    }

    // MARK: - Live telemetry bridge

    /// Lifecycle callbacks can arrive after stop or a new load. Only cleanup may publish after
    /// the owning session has detached; the token still prevents it crossing into its successor.
    func acceptSessionCacheStatus(_ status: SessionCacheStatus, token: UInt64) {
        guard token == sessionCacheStatusToken else { return }
        guard status.cleanupResult != .notRun || nativeVideoSession != nil else { return }
        diagnostics.sessionCacheStatus = status
    }

    /// Read the cache ledger off-main. An old tick must never overwrite a new session or cleanup.
    func refreshSessionCacheStatus() async {
        guard let session = nativeVideoSession else { return }
        let token = sessionCacheStatusToken
        let generation = loadGeneration
        let status = await BlockingWork.detached(priority: .utility) { session.sessionCacheStatus() }.value
        guard !Task.isCancelled, sessionCacheStatusToken == token, loadGeneration == generation,
              nativeVideoSession === session else { return }
        diagnostics.sessionCacheStatus = status
    }

    /// Single write-through point: sampler never reaches into `EngineDiagnostics` directly.
    func applyLiveTelemetry(_ snapshot: LiveTelemetry) {
        diagnostics.liveTelemetry = snapshot
    }


    /// Lifetime bytes the session's playback reader pulled from the source. Feeds the sampler's
    /// instant + average bitrate and `LiveTelemetry.demuxerBytesFetched`. 0 before a reader exists.
    ///
    /// #306: software first, native second, the same precedence the memprobe has always read the pump
    /// with. A software session owns no `HLSVideoEngine`, so the native-only form returned 0 for the
    /// whole session and every byte-derived figure a host can show (bitrate, throughput, transferred)
    /// read zero on the one path that carries the exotic content.
    var demuxerBytesFetched: Int64 {
        Self.pumpBytesFetched(software: softwareHost?.demuxerBytesFetched,
                              native: nativeVideoSession?.demuxerBytesFetched)
    }

    /// AE#514: the played-media ledger of whichever path owns the pump, same precedence as the byte
    /// counter above. nil before a pipeline exists and on the paths with no pump to feed one.
    var playedMediaLedger: PlayedMediaLedger? {
        softwareHost?.playedMediaLedger ?? nativeVideoSession?.playedMediaLedger
    }

    /// #306: the precedence itself, as a function, so the ordering is assertable without a live
    /// session on either path. Software first: only one of the two exists per session, and a
    /// software session's counter is the one that used to be dropped.
    nonisolated static func pumpBytesFetched(software: Int64?, native: Int64?) -> Int64 {
        software ?? native ?? 0
    }

    /// The playback pump reader's sliding-window snapshot, from whichever path owns the reader.
    /// nil for sources with no `AVIOReader` (disc, custom provider) and before the reader exists.
    /// Named for the pump to keep it apart from the subtitle side reader, which has a window of its own.
    var pumpIOWindow: (windowBytes: Int, aheadBytes: Int, parked: Bool)? {
        softwareHost?.ioWindowDiagnostics ?? nativeVideoSession?.demuxer?.ioWindowDiagnostics
    }

    /// Compressed resident bytes: software packet spool or native loopback segment cache.
    var cachedBytes: Int64? {
        if let bytes = softwareHost?.cachedVODBytes { return bytes }
        guard let bytes = nativeVideoSession?.segmentCacheTotalBytes else { return nil }
        return Int64(bytes)
    }

    /// Short metadata lock only; never reads the packet store from the main actor.
    var softwarePacketCacheSnapshot: SoftwarePacketReadAhead.Snapshot? {
        softwareHost?.vodPacketCacheSnapshot
    }

    /// Freshly stat-ed on-disk footprint of the segment cache. nil when no native session is active. Used by `aetherctl live --report-cache-bytes`.
    public var segmentCacheDiskBytes: Int64? {
        nativeVideoSession?.segmentCacheDiskBytes
    }

    /// Frames the SW host enqueued into AVSampleBufferDisplayLayer. Zero on native path or pre-start.
    ///
    /// #288: the software-path answer to "is there a picture, or is this audio into a black view".
    /// `AVPlayerItemVideoOutput.hasNewPixelBuffer` answers it on the native path, but a software
    /// session has no AVPlayer at all, so a host watchdog built on that probe alone reads every
    /// dav1d/libavcodec session as picture-less and kills healthy playback. Pair it with
    /// `currentAVPlayer == nil` to pick the backend, then watch this counter for movement.
    ///
    /// Monotonic within a session only: it belongs to the current SW host, and a `load()` that
    /// builds a new one restarts it at zero. A watchdog measuring deltas must treat a decrease as
    /// a new session, not as a stall.
    public var softwareHostFramesEnqueued: Int {
        softwareHost?.framesEnqueued ?? 0
    }

    /// Producer restart count for the current session. Zero on SW path or pre-start.
    var producerRestartCount: Int {
        nativeVideoSession?.producerRestartCount ?? 0
    }

    var muxedBytesLifetime: Int64 {
        Int64(nativeVideoSession?.muxedBytesLifetime ?? 0)
    }

    var serverBytesSentLifetime: Int64 {
        Int64(nativeVideoSession?.serverLifetimeBytesSent ?? 0)
    }

    var serverRequestCount: Int {
        nativeVideoSession?.serverRequestCount ?? 0
    }

    /// AudioBridge FIFO + swr-delay bytes. Zero when bridge is not active (stream-copy path or video-only source).
    var audioBridgeLiveBytes: Int {
        nativeVideoSession?.audioBridgeLiveBytes ?? 0
    }

    /// What the object renderer is doing, for `LiveTelemetry.objectAudio`; nil off `objectAudioRendering`.
    var objectAudioActivity: ObjectAudioActivity? { nativeVideoSession?.objectAudioActivity }

    /// Cumulative encoded-audio bytes the bridge has emitted this session. Zero when bridge is not active
    /// (stream-copy path or video-only source). The telemetry sampler diffs it into a live bridge output bitrate.
    var audioBridgeOutputBytesLifetime: Int64 {
        nativeVideoSession?.audioBridgeOutputBytesLifetime ?? 0
    }

    /// Last A/V gate gap in source-clock ms. 0 before the first audio gate opens.
    var lastAVGapMs: Double {
        nativeVideoSession?.lastAVGapMs ?? 0
    }
}
