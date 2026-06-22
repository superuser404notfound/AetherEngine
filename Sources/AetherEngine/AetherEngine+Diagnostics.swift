import Foundation
import Darwin.Mach
import AVFoundation

extension AetherEngine {

    // MARK: - Memory diagnostic

    /// Cancel any prior probe, then emit one EngineLog line every 30 s under `.engine`. Line shape is documented on `memoryProbeTask`.
    func startMemoryProbe() {
        memoryProbeTask?.cancel()
        let sessionStart = Date()
        memoryProbeTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if Task.isCancelled { return }
                guard let self = self else { return }
                let elapsed = Int(Date().timeIntervalSince(sessionStart))
                let rssMB = Self.residentMemoryMB()
                let cueCount = self.subtitleCues.count

                // AVPlayer buffer probe: if ahead > preferredForwardBufferDuration, suspect linear-growth memory leak.
                var bufferAheadSec = 0.0
                var bufferBehindSec = 0.0
                if let avPlayer = self.currentAVPlayer,
                   let item = avPlayer.currentItem {
                    let now = item.currentTime().seconds
                    for value in item.loadedTimeRanges {
                        let range = value.timeRangeValue
                        let start = range.start.seconds
                        let end = (range.start + range.duration).seconds
                        if end > now { bufferAheadSec += end - max(start, now) }
                        if start < now { bufferBehindSec += min(end, now) - start }
                    }
                }

                // Zero on SW path or pre-start; 30 s cadence makes non-atomic field drift irrelevant.
                let stats = self.nativeVideoSession?.diagnosticStats()
                let avioMB = (stats?.avioBytesFetched ?? 0) / 1024 / 1024
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

                let line = "[AetherEngine] memprobe t=\(elapsed)s "
                    + "rss=\(rssMB)MB "
                    + vmStr
                    + mallocStr
                    + "avioFetchedMB=\(avioMB) "
                    + "cacheCount=\(cacheCount) cacheMB=\(cacheMB) "
                    + "packetsWritten=\(packetsWritten) "
                    + "audioFifo=\(audioFifo) "
                    + "abFifoKB=\(abFifoKB) abSwrKB=\(abSwrKB) abTotKB=\(abTotKB) "
                    + "muxBytesMB=\(muxBytesMB) muxCuts=\(muxCuts) "
                    + "srvConns=\(srvConns) srvBytesMB=\(srvBytesMB) srvSfMB=\(srvSfMB) "
                    + "pktAlive=\(pktAlive) pktTotal=\(pktTotal) "
                    + "subCues=\(cueCount) "
                    + "audioTracks=\(self.audioTracks.count) "
                    + "subTracks=\(self.subtitleTracks.count) "
                    + "subActive=\(self.isSubtitleActive) "
                    + "avBufAhead=\(String(format: "%.1f", bufferAheadSec))s "
                    + "avBufBehind=\(String(format: "%.1f", bufferBehindSec))s"

                EngineLog.emit(line, category: .engine)
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

    // MARK: - Live telemetry bridge

    /// Single write-through point: sampler never reaches into `EngineDiagnostics` directly.
    func applyLiveTelemetry(_ snapshot: LiveTelemetry) {
        diagnostics.liveTelemetry = snapshot
    }


    /// `Demuxer.avioBytesFetched` via HLSVideoEngine. Used by `LiveTelemetrySampler` for instant + average bitrate. 0 on SW path or pre-start.
    var demuxerBytesFetched: Int64 {
        nativeVideoSession?.demuxerBytesFetched ?? 0
    }

    /// Resident bytes in the loopback HLS segment cache. nil when no native session is active.
    var cachedBytes: Int64? {
        guard let bytes = nativeVideoSession?.segmentCacheTotalBytes else { return nil }
        return Int64(bytes)
    }

    /// Freshly stat-ed on-disk footprint of the segment cache. nil when no native session is active. Used by `aetherctl live --report-cache-bytes`.
    public var segmentCacheDiskBytes: Int64? {
        nativeVideoSession?.segmentCacheDiskBytes
    }

    /// Frames the SW host enqueued into AVSampleBufferDisplayLayer. Zero on native path or pre-start.
    var softwareHostFramesEnqueued: Int {
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

    /// Last A/V gate gap in source-clock ms. 0 before the first audio gate opens.
    var lastAVGapMs: Double {
        nativeVideoSession?.lastAVGapMs ?? 0
    }
}
