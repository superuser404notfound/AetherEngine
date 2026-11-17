import Foundation
import os
import AetherLibavformat
import AetherLibavutil

// The forward-only (sequential GET) half of AVIOReader: read, background download and its delegate.
extension AVIOReader {
    // MARK: - Streaming Read (sequential GET)

    func readStreaming(into buf: UnsafeMutablePointer<UInt8>, size: Int32) -> Int32 {
        let requestSize = Int(size)
        var totalRead = 0

        while totalRead < requestSize {
            streamLock.lock()
            let posInBuffer = Int(position - streamBytesRead)
            let available = streamBuffer.count - posInBuffer
            let ended = streamEnded
            streamLock.unlock()

            if available > 0 && posInBuffer >= 0 {
                let toCopy = min(available, requestSize - totalRead)

                streamLock.lock()
                streamBuffer.copyBytes(to: buf.advanced(by: totalRead), from: posInBuffer, count: toCopy)
                streamLock.unlock()

                position += Int64(toCopy)
                totalRead += toCopy

                streamLock.lock()
                let consumed = Int(position - streamBytesRead)
                if consumed > Self.streamTrimThreshold {
                    let trimAmount = consumed - Self.streamTrimThreshold
                    streamBuffer.dropFirst(trimAmount)
                    streamBytesRead += Int64(trimAmount)
                }
                var toResume: URLSessionDataTask?
                if streamingTaskSuspended, streamBuffer.count < streamLowWater {
                    streamingTaskSuspended = false
                    toResume = streamingTask
                }
                streamLock.unlock()
                toResume?.resume()
                if isLive { break }   // AE#1076, see readPersistent
            } else if ended {
                break
            } else {
                // Resume before waiting: a suspended task would never deliver.
                streamLock.lock()
                var toResume: URLSessionDataTask?
                if streamingTaskSuspended {
                    streamingTaskSuspended = false
                    toResume = streamingTask
                }
                streamLock.unlock()
                toResume?.resume()
                let timeout = streamDataReady.wait(timeout: .now() + .seconds(15))
                if timeout == .timedOut { break }
            }
        }

        if totalRead > 0 { return Int32(totalRead) }
        streamLock.lock()
        let refusedStatus = streamRefusedStatus
        streamLock.unlock()
        if refusedStatus != 0 {
            // The response header arrived after open()'s budget: still a refusal, not end-of-media.
            EngineLog.emit(
                "[AVIOReader] \(label) streaming GET refused status=\(refusedStatus) after open; reporting EIO",
                category: .demux)
            return FFmpegErr.eio
        }
        streamLock.lock()
        let ended = streamEnded
        let failed = streamFailed
        let cause = streamFailureCause
        let received = streamBytesRead + Int64(streamBuffer.count)
        let expected = streamExpectedBytes
        streamLock.unlock()
        // This path cannot be resumed at an offset, so a stalled-out wait, a transport error or a
        // body that ended short of its advisory length is a LOST source: report EIO so the pump
        // exits on a read error the session can surface. EOF here would read as end-of-media,
        // which the consumer deliberately never retries. Audit DMX-6: this held for the
        // sequential origin only, and a length-less source ended its film early on a Wi-Fi drop.
        if !ended || failed || (expected > 0 && received < expected) {
            EngineLog.emit(
                "[AVIOReader] \(label) stream \(!ended ? "stalled out" : failed ? "failed" : "ended short") at "
                + "\(received)\(expected > 0 ? "/\(expected)" : "") bytes"
                + (cause.map { " (\($0))" } ?? "") + "; reporting EIO",
                category: .demux
            )
            return FFmpegErr.eio
        }
        return FFmpegErr.eof
    }

    // MARK: - Streaming Download (background)

    func startStreamingDownload() {
        prefetchQueue.async { [weak self] in
            self?.streamDownloadSync()
        }
    }

    private func streamDownloadSync() {
        var request = URLRequest(engineURL: url)
        request.timeoutInterval = 0  // No timeout for live streams
        applyExtraHeaders(&request)

        // #377: this connection is open for the whole session, so it holds its slot for the whole
        // session, which is exactly what it costs the origin. Returned at network completion so a
        // lower-priority caller need not resume first. A streaming-mode source has no detour
        // or ranged probe to starve (they are all switched off on this path), so a held slot here
        // blocks nothing but a second reader on the same origin, which is the point.
        let streamTicket: OriginRequestBudget.Ticket?
        do {
            streamTicket = try requestTicket(
                for: request.url ?? url, label: "\(label) stream", timeout: Self.pumpSlotWaitSeconds)
        } catch {
            streamLock.lock()
            streamEnded = true
            streamLock.unlock()
            streamDataReady.signal()
            return
        }
        let lease = OriginRequestBudget.Lease(streamTicket)
        defer { lease.release() }

        let semaphore = DispatchSemaphore(value: 0)

        let delegate = StreamingDelegate(
            diagnosticContext: diagnosticContext,
            extraHeaders: headers(for: request.url),
            onResponse: { [weak self] response in
                // Advisory length for the EOF/EIO distinction; -1 (chunked / unknown) leaves the
                // clean-end path as the only EOF source.
                guard let self else { return }
                let expected = response.expectedContentLength
                guard expected > 0 else { return }
                self.streamLock.lock()
                self.streamExpectedBytes = expected
                self.streamLock.unlock()
            },
            onRefused: { [weak self] status, respondedBy in
                guard let self else { return }
                self.streamLock.lock()
                self.streamRefusedStatus = status
                self.streamLock.unlock()
                // #377: a metering origin is charged wherever a status is first read, and this was
                // the one path that read one without charging it. On a sequential origin this GET
                // is the session's only request (no ranged open, no probe, by construction), so its
                // 429 was seen by nobody: the budget kept offering that origin its full concurrency
                // and the revive arm had no stamp saying the source was metered rather than gone.
                if Self.isRateLimitStatus(status) {
                    self.noteOriginRefusal(status: status, respondedBy: respondedBy)
                }
                EngineLog.emit(
                    "[AVIOReader] \(self.label) streaming GET refused status=\(status); hanging up at the header",
                    category: .demux)
            }
        ) { [weak self] data in
            guard let self, !self.isClosed else { return }
            self.streamLock.lock()
            if self.streamFailed {
                self.streamLock.unlock()
                return
            }
            // Owned bytes: the chunk is retained until it is consumed, and a delivery that still
            // references the transport's dispatch_data would pin its buffer for that long.
            let firstDelivery = self.streamBuffer.isEmpty && self.streamBytesRead == 0
            self.streamBuffer.append(data.withUnsafeBytes { Data($0) })
            if firstDelivery { self.clearRecordedTransportFailure() }
            self.streamPeakBytes = max(self.streamPeakBytes, self.streamBuffer.count)
            var toCancel: URLSessionDataTask?
            if self.streamBuffer.count > self.streamHardCap {
                self.streamFailed = true
                self.streamFailureCause = .originIgnoresFlowControl
                toCancel = self.streamingTask
            }
            // Backpressure: park the transfer once the retained buffer
            // exceeds the high water mark; readStreaming resumes it when
            // the consumer drains below the low water mark (and before
            // any wait, so a far-forward seek can't deadlock against a
            // suspended producer).
            var toSuspend: URLSessionDataTask?
            if !self.streamingTaskSuspended, self.streamBuffer.count > self.streamHighWater {
                self.streamingTaskSuspended = true
                toSuspend = self.streamingTask
            }
            self.streamLock.unlock()
            if let toCancel {
                EngineLog.emit(
                    "[AVIOReader] \(self.label) streaming buffer passed \(self.streamHardCap / 1024)KB "
                    + "with the transfer suspended: the origin ignores flow control, so the source is "
                    + "ended here to keep memory bounded and the read will fail (audit DMX-7, DMX-107)",
                    category: .demux)
                toCancel.cancel()
            } else {
                toSuspend?.suspend()
            }
            self.addBytesFetched(data.count)
            self.streamDataReady.signal()
        } onComplete: { [weak self] error in
            lease.release()
            guard let self else {
                semaphore.signal()
                return
            }
            self.streamLock.lock()
            self.streamURLFailureCode = SourceNetworkDiagnostics.urlErrorCode(error)
            self.recordTransportFailure(error)
            if error != nil, !self.isClosed { self.streamFailed = true }
            self.streamEnded = true
            self.streamLock.unlock()
            self.streamDataReady.signal()
            semaphore.signal()
        }

        let streamSession = URLSession(
            configuration: Self.makeSessionConfig(longLived: true),
            delegate: delegate,
            delegateQueue: AVIOReader.makePlaybackDelegateQueue()
        )
        let task = streamSession.dataTask(with: request)

        // Register before resume so markClosed()/close() can cancel; re-check after.
        streamLock.lock()
        streamingSession = streamSession
        streamingTask = task
        streamLock.unlock()

        task.resume()
        if isClosed { task.cancel() }

        #if DEBUG
        EngineLog.emit("[AVIOReader] Streaming started: \(url.lastPathComponent)", category: .demux)
        #endif

        semaphore.wait()

        #if DEBUG
        EngineLog.emit("[AVIOReader] Streaming ended", category: .demux)
        #endif
        streamLock.lock()
        streamingSession = nil
        streamingTask = nil
        streamLock.unlock()
        streamSession.invalidateAndCancel()
    }
}

// MARK: - Streaming Delegate

private final class StreamingDelegate: NSObject, URLSessionDataDelegate {
    private let sourceTrace: SourceNetworkDiagnostics.Trace
    let onData: @Sendable (Data) -> Void
    let onComplete: @Sendable (Error?) -> Void
    /// Response hook (advisory Content-Length capture on the sequential-origin path).
    let onResponse: (@Sendable (URLResponse) -> Void)?
    /// The origin answered with a status instead of media (anything but 200/206). Called at the
    /// response header, before the hang-up, so the reader can fail the open typed. Carries the URL
    /// that answered, redirects followed: on a source that 302s to an edge target, the refusing
    /// host is not the one the request named (#377).
    let onRefused: (@Sendable (Int, URL?) -> Void)?
    /// Re-applied across cross-host redirects like every other delegate in this file;
    /// IPTV origins routinely 302 twice (portal -> panel -> archive host) and the final
    /// host must still see the caller's User-Agent / auth headers.
    let extraHeaders: [String: String]

    init(
        diagnosticContext: SourceNetworkDiagnostics.Context?,
        extraHeaders: [String: String] = [:],
        onResponse: (@Sendable (URLResponse) -> Void)? = nil,
        onRefused: (@Sendable (Int, URL?) -> Void)? = nil,
        onData: @escaping @Sendable (Data) -> Void,
        onComplete: @escaping @Sendable (Error?) -> Void
    ) {
        self.extraHeaders = extraHeaders
        self.sourceTrace = .init(role: .streaming, context: diagnosticContext)
        self.onResponse = onResponse
        self.onRefused = onRefused
        self.onData = onData
        self.onComplete = onComplete
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        sourceTrace.redirect(task: task, response: response, request: request)
        completionHandler(redirectPreservingHeaders(
            task: task, newRequest: request, extraHeaders: extraHeaders))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        EngineTLS.resolve(challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        sourceTrace.response(task: dataTask, response: response)
        // Redirects never reach here (willPerformHTTPRedirection follows them), so anything but
        // a 200/206 is the origin's verdict, not media: a 401/403 refusal, a 404, a 429, a 5xx.
        // Hang up at the header so the error page never enters the stream buffer, where FFmpeg
        // would probe it as container bytes and report "Invalid data found when processing
        // input" for what was a refusal (#378).
        if let http = response as? HTTPURLResponse, http.statusCode != 200, http.statusCode != 206 {
            onRefused?(http.statusCode, dataTask.currentRequest?.url ?? http.url)
            completionHandler(.cancel)
            return
        }
        onResponse?(response)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        onData(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        sourceTrace.completed(task: task, error: error)
        #if DEBUG
        if let error {
            EngineLog.emit("[AVIOReader] Stream error: \(error.localizedDescription)", category: .demux)
        }
        #endif
        onComplete(error)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        sourceTrace.metrics(task: task, metrics: metrics)
    }

}
