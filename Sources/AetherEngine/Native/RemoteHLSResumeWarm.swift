import Foundation

/// AE#1122: ask a transcoding origin for the resume segment before AVPlayer asks for anything.
///
/// With a start position on an fMP4 playlist, AVPlayer requests the init (`EXT-X-MAP`) first and the
/// segment at the start position second. A Jellyfin transcode builds the init from a job it starts at
/// position 0, so the segment request that follows lands far from that job, which is killed and
/// started again at the resume point. Two ffmpeg spin-ups in a row, and the first one alone sits right
/// on AVPlayer's ~3 s map timeout (`-12889 'No response for map'`). Measured by the reporter on Jellyfin
/// 12.4, resumed at 691 s: init 2.9 to 3.75 s, then the segment another 3.5 to 4.1 s.
///
/// Asking for the segment first starts the job where playback will begin. Once that segment answers,
/// the init it was cut after is on disk too, and AVPlayer's own two requests are served from there
/// (0.16 s for the init in the same measurement). Only the response head is awaited: Jellyfin answers a
/// segment once the file is finished, and the body is AVPlayer's to fetch.
///
/// It runs only inside the #316 stand-in, which has already fetched the variant playlist it needs and
/// serves it to AVPlayer itself (`RemoteHLSMasterRewrite.servedVariantURI`). The warm fires when the
/// player asks for that variant and the answer waits for it (`Gate`), for one reason: Jellyfin names a
/// transcode job after the media path, the User-Agent, the DeviceId and the PlaySessionId. A warm sent
/// with URLSession's own agent started a second job that AVPlayer (`AppleCoreMedia`) never touched,
/// measured against Jellyfin 12.2. The variant request is the first place the player's real agent is
/// known, and on AirPlay it is the receiver's, which is the one that then asks for the segments.
enum RemoteHLSResumeWarm {

    /// How long the variant answer waits for the resume segment before it goes out anyway.
    /// The reporter's segment answered in 2.9 to 4.1 s. A server still spinning up after this keeps
    /// spinning up for AVPlayer, which then finds a job already running at the right place.
    static let waitSeconds: TimeInterval = 8

    struct Target: Equatable {
        let index: Int
        let url: URL
    }

    /// The segment AVPlayer's mount seek will ask for, or nil when asking for it first gains nothing.
    ///
    /// - A start at the head needs no warm: the init request already starts the job at segment 0.
    /// - Without `EXT-X-MAP` there is no init request to land first, so the order cannot go wrong.
    /// - A byte-ranged segment is a slice of a finished file, and nothing is transcoded for it.
    /// - More than one variant means AVPlayer picks which one plays, and warming a variant it then
    ///   skips would start a second job on the server instead of saving one.
    ///
    /// The mount seek is exact (`toleranceBefore: .zero`), so the segment is the one whose span holds
    /// the position, start inclusive.
    static func target(startPosition: Double?,
                       playlist: HLSMediaPlaylist,
                       playlistURL: URL,
                       variantCount: Int) -> Target? {
        guard let startPosition, startPosition.isFinite, startPosition > 0,
              playlist.hasEndList, playlist.hasMap, variantCount == 1 else { return nil }
        var segmentStart = 0.0
        for (index, segment) in playlist.segments.enumerated() {
            let segmentEnd = segmentStart + segment.duration
            if startPosition < segmentEnd {
                guard index > 0, segment.byteRange == nil,
                      let url = HLSPlaylistParser.resolve(uri: segment.uri, against: playlistURL)
                else { return nil }
                return Target(index: index, url: url)
            }
            segmentStart = segmentEnd
        }
        return nil
    }

    enum Outcome: Equatable {
        case answered(status: Int, seconds: Double)
        case failed(String, seconds: Double)
    }

    /// GET the segment, wait for its response head, then drop the body. Never throws: a warm that fails
    /// leaves the session exactly where it would have been without one.
    static func warm(_ target: Target,
                     headers: [String: String],
                     waitSeconds: TimeInterval = waitSeconds) async -> Outcome {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = waitSeconds
        config.timeoutIntervalForResource = waitSeconds
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(
            configuration: config, delegate: EngineTLS.sessionDelegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(engineURL: target.url)
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        let started = Date()
        do {
            let (bytes, response) = try await session.bytes(for: request)
            bytes.task.cancel()
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return .answered(status: status, seconds: Date().timeIntervalSince(started))
        } catch {
            return .failed("\(error.localizedDescription)", seconds: Date().timeIntervalSince(started))
        }
    }
}

extension RemoteHLSResumeWarm {

    /// Runs the warm once, on the first variant request, and holds every variant answer until it is
    /// done or `waitSeconds` passed. Called from the loopback server's connection threads, which are
    /// plain threads that may block.
    final class Gate: @unchecked Sendable {
        let target: Target
        private let headers: [String: String]
        private let waitSeconds: TimeInterval
        private let startPosition: Double
        private let lock = NSLock()
        private let done = DispatchGroup()
        private var task: Task<Void, Never>?
        private var cancelled = false

        init(target: Target, headers: [String: String], startPosition: Double,
             waitSeconds: TimeInterval = RemoteHLSResumeWarm.waitSeconds) {
            self.target = target
            self.headers = headers
            self.startPosition = startPosition
            self.waitSeconds = waitSeconds
        }

        /// Blocks until the resume segment answered, failed, or the wait ran out. `userAgent` is the
        /// player's own, from the variant request; the host's headers ride along as they would on
        /// AVPlayer's request.
        func passThrough(userAgent: String?) {
            lock.lock()
            if task == nil, !cancelled {
                var headers = self.headers
                if let userAgent, !userAgent.isEmpty {
                    // URLRequest matches field names case-insensitively, so a host's "user-agent"
                    // left next to ours would win or lose on dictionary order.
                    headers = headers.filter { $0.key.caseInsensitiveCompare("User-Agent") != .orderedSame }
                    headers["User-Agent"] = userAgent
                }
                let target = self.target, waitSeconds = self.waitSeconds, position = startPosition
                done.enter()
                // Awaits URLSession only, nothing that blocks, so a plain task is enough.
                task = Task { [done] in
                    let outcome = await RemoteHLSResumeWarm.warm(
                        target, headers: headers, waitSeconds: waitSeconds)
                    RemoteHLSResumeWarm.log(outcome, target: target, startPosition: position)
                    done.leave()
                }
            }
            lock.unlock()
            _ = done.wait(timeout: .now() + waitSeconds + 0.5)
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let task = self.task
            lock.unlock()
            task?.cancel()
        }
    }

    static func log(_ outcome: Outcome, target: Target, startPosition: Double) {
        let position = String(format: "%.1f", startPosition)
        switch outcome {
        case .answered(let status, let seconds):
            EngineLog.emit(
                "[AetherEngine] AE#1122: resume segment \(target.index) (start \(position) s) answered "
                + "HTTP \(status) after \(String(format: "%.2f", seconds)) s; the variant goes out now, "
                + "so the player asks for the init after the job runs at the resume point", category: .engine)
        case .failed(let reason, let seconds):
            EngineLog.emit(
                "[AetherEngine] AE#1122: resume segment \(target.index) (start \(position) s) did not "
                + "answer (\(reason), \(String(format: "%.2f", seconds)) s); the variant goes out as before",
                category: .engine)
        }
    }
}
