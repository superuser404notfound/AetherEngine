import Foundation

/// Route that owns buffering for the current session. Only `loopbackFMP4` uses Aether's
/// session-scoped `SegmentCache`; native remote HLS remains AVPlayer/server managed.
public enum SessionCacheRoute: String, Sendable, Equatable {
    case none
    case loopbackFMP4 = "loopback_fmp4"
    case nativeRemoteHLS = "native_remote_hls"
}

/// Whether the active route can apply Aether's session-cache byte policy.
public enum SessionCacheCapability: String, Sendable, Equatable {
    case inactive
    case active
    case unsupported
}

/// Why a session cache directory was closed. Values describe lifecycle, not persistence: every
/// successful close deletes the entire UUID directory and no later session reuses it.
public enum SessionCacheCleanupReason: String, Sendable, Equatable {
    case sessionStopped = "session_stopped"
    case sourceChanged = "source_changed"
    case loadFailed = "load_failed"
}

public enum SessionCacheCleanupResult: String, Sendable, Equatable {
    case notRun = "not_run"
    case succeeded
    case failed
}

/// Typed, credential-free disk failure for the current session cache.
public enum SessionCacheFailureReason: String, Sendable, Equatable {
    case sessionDirectoryCreationFailed = "session_directory_creation_failed"
    case writeFailed = "write_failed"
    case adoptFailed = "adopt_failed"
    case staleSweepFailed = "stale_sweep_failed"
    case cleanupFailed = "cleanup_failed"
}

/// Route-aware snapshot of Aether's ephemeral fMP4 segment cache.
///
/// `baseEffectiveBudgetBytes` is the caller request after the tmp-volume safety clamp.
/// `playbackSafeFloorBytes` is the actual resident hard window that cannot be evicted without
/// risking AVPlayer starvation. `effectiveBudgetBytes` is the larger of those two values, so a
/// high-bitrate hard window is reported honestly rather than silently violating the requested cap.
public struct SessionCacheStatus: Sendable, Equatable {
    public let route: SessionCacheRoute
    public let capability: SessionCacheCapability
    public let requestedBudgetBytes: Int?
    public let volumeSafetyLimitBytes: Int?
    public let baseEffectiveBudgetBytes: Int
    public let playbackSafeFloorBytes: Int
    public let effectiveBudgetBytes: Int
    public let hardLimitBytes: Int?
    public let stagingBytes: Int
    public let freeDiskReserveBytes: Int
    public let rejectedDiskWrites: Int
    public var currentDiskBytes: Int { currentResidentBytes + stagingBytes }
    public let currentResidentBytes: Int
    public let currentForwardBytes: Int
    public let forwardWindowSegments: Int
    public let backwardWindowSegments: Int
    public let producerParked: Bool
    public let evictionCount: Int
    public let hardWindowFloorExceeded: Bool
    public let cleanupReason: SessionCacheCleanupReason?
    public let cleanupResult: SessionCacheCleanupResult
    public let lastFailure: SessionCacheFailureReason?

    public init(
        route: SessionCacheRoute,
        capability: SessionCacheCapability,
        requestedBudgetBytes: Int?,
        volumeSafetyLimitBytes: Int?,
        baseEffectiveBudgetBytes: Int,
        playbackSafeFloorBytes: Int,
        effectiveBudgetBytes: Int,
        currentResidentBytes: Int,
        currentForwardBytes: Int,
        forwardWindowSegments: Int,
        backwardWindowSegments: Int,
        producerParked: Bool,
        evictionCount: Int,
        hardWindowFloorExceeded: Bool,
        cleanupReason: SessionCacheCleanupReason?,
        cleanupResult: SessionCacheCleanupResult,
        lastFailure: SessionCacheFailureReason?,
        hardLimitBytes: Int? = nil,
        stagingBytes: Int = 0,
        freeDiskReserveBytes: Int = 0,
        rejectedDiskWrites: Int = 0
    ) {
        self.hardLimitBytes = hardLimitBytes
        self.stagingBytes = stagingBytes
        self.freeDiskReserveBytes = freeDiskReserveBytes
        self.rejectedDiskWrites = rejectedDiskWrites
        self.route = route
        self.capability = capability
        self.requestedBudgetBytes = requestedBudgetBytes
        self.volumeSafetyLimitBytes = volumeSafetyLimitBytes
        self.baseEffectiveBudgetBytes = baseEffectiveBudgetBytes
        self.playbackSafeFloorBytes = playbackSafeFloorBytes
        self.effectiveBudgetBytes = effectiveBudgetBytes
        self.currentResidentBytes = currentResidentBytes
        self.currentForwardBytes = currentForwardBytes
        self.forwardWindowSegments = forwardWindowSegments
        self.backwardWindowSegments = backwardWindowSegments
        self.producerParked = producerParked
        self.evictionCount = evictionCount
        self.hardWindowFloorExceeded = hardWindowFloorExceeded
        self.cleanupReason = cleanupReason
        self.cleanupResult = cleanupResult
        self.lastFailure = lastFailure
    }

    public static let inactive = SessionCacheStatus(
        route: .none, capability: .inactive, requestedBudgetBytes: nil,
        volumeSafetyLimitBytes: nil, baseEffectiveBudgetBytes: 0,
        playbackSafeFloorBytes: 0, effectiveBudgetBytes: 0, currentResidentBytes: 0,
        currentForwardBytes: 0, forwardWindowSegments: 0, backwardWindowSegments: 0,
        producerParked: false, evictionCount: 0, hardWindowFloorExceeded: false,
        cleanupReason: nil, cleanupResult: .notRun, lastFailure: nil
    )

    public static func nativeRemoteHLS(requestedBudgetBytes: Int?) -> SessionCacheStatus {
        SessionCacheStatus(
            route: .nativeRemoteHLS, capability: .unsupported,
            requestedBudgetBytes: requestedBudgetBytes, volumeSafetyLimitBytes: nil,
            baseEffectiveBudgetBytes: 0, playbackSafeFloorBytes: 0,
            effectiveBudgetBytes: 0, currentResidentBytes: 0, currentForwardBytes: 0,
            forwardWindowSegments: 0, backwardWindowSegments: 0, producerParked: false,
            evictionCount: 0, hardWindowFloorExceeded: false, cleanupReason: nil,
            cleanupResult: .notRun, lastFailure: nil
        )
    }
}

