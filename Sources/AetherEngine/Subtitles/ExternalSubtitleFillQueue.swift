import Foundation

/// AE#984: runs the whole-file decodes of load-declared sidecars into their native stores, one at a
/// time, the picked track first. Both rendition paths use it: the loopback session
/// (`AetherEngine.startExternalNativeStoreFill`) and the `nativeRemoteHLS` stand-in
/// (`RemoteHLSSubtitleProvider`).
///
/// One at a time because a sidecar can be an extraction the server runs from the very file it is
/// transcoding for this session. The pick goes first because a select waits for its store before it
/// hands AVPlayer the rendition, so every job ahead of it is time the viewer waits for subtitles.
final class ExternalSubtitleFillQueue: @unchecked Sendable {
    typealias Job = AetherEngine.ExternalSubtitleFillJob

    /// Guards everything below. `start` runs off the main actor (the proxy's build), `prioritize` on it,
    /// and the decode task reports its end from wherever it finished.
    private let lock = NSLock()
    /// Every job `start` was given, so a failed store can be retried from the job that owned it.
    private var allJobs: [Job] = []
    private var queued: [Job] = []
    private var running: (job: Job, task: Task<Void, Never>, id: UInt64)?
    private var nextRunID: UInt64 = 0
    /// The store of the last pick. Its job runs before any other and takes over from a running job
    /// that does not serve it.
    private var pickedStore: NativeSubtitleCueStore?
    /// While set, only the picked store's job runs (`releaseHeld` lifts it).
    private var holdsUnpicked = false
    private var cancelled = true

    /// Replaces whatever ran before. Every store is marked pending at once, so a `.vtt` request that
    /// lands before its decode is answered "not yet" rather than held.
    func start(_ jobs: [Job], holdingUnpicked: Bool) {
        // A store this run fills again goes straight from pending to pending: marking it failed in
        // between would end a select that is waiting for it.
        let refilled = Set(jobs.flatMap(\.targets).map { ObjectIdentifier($0.store) })
        cancel(keepingPending: refilled)
        guard !jobs.isEmpty else { return }
        jobs.forEach { $0.markPending() }
        for target in jobs.flatMap(\.targets) {
            target.store.onRequestWhilePending = { [weak self, weak store = target.store] in
                guard let self, let store else { return }
                self.prioritizeRequested(store)
            }
        }
        lock.lock()
        cancelled = false
        allJobs = jobs
        queued = jobs
        pickedStore = nil
        holdsUnpicked = holdingUnpicked
        lock.unlock()
        runNext()
    }

    /// Stops the running decode and drops the rest. A store left unfinished is marked failed: nothing
    /// will fill it now, and a select waiting for it must hear that rather than wait for good.
    func cancel() { cancel(keepingPending: []) }

    private func cancel(keepingPending kept: Set<ObjectIdentifier>) {
        lock.lock()
        let wasRunning = !cancelled
        cancelled = true
        let stranded = allJobs
        allJobs = []
        queued = []
        let task = running?.task
        running = nil
        lock.unlock()
        task?.cancel()
        guard wasRunning else { return }
        for target in stranded.flatMap(\.targets) where !kept.contains(ObjectIdentifier(target.store)) {
            target.store.markExternalFillFailed()
        }
    }

    /// The host picked the track `store` backs. Its job moves to the front and takes over from a
    /// running job that serves only other tracks; that one goes back in right behind it, so its decode
    /// is the next to resume. A store that failed earlier (a 120 s idle timeout on a server still
    /// extracting) gets one more attempt.
    func prioritize(_ store: NativeSubtitleCueStore) {
        var preempted: Task<Void, Never>?
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        pickedStore = store
        if let index = queued.firstIndex(where: { Self.job($0, serves: store) }) {
            queued.insert(queued.remove(at: index), at: 0)
        } else if store.externalFillState == .failed,
                  running.map({ !Self.job($0.job, serves: store) }) ?? true,
                  let retry = retryJob(for: store) {
            retry.markPending()
            queued.insert(retry, at: 0)
            EngineLog.emit("[AetherEngine] AE#984: a sidecar was picked after its fill failed; "
                           + "fetching it once more", category: .engine)
        }
        if let current = running, !Self.job(current.job, serves: store),
           queued.first.map({ Self.job($0, serves: store) }) == true {
            preempted = current.task
            // Only what it has not finished: a container's per-target pass may have filled some.
            let rest = current.job.targets.filter { !$0.store.isFinished }
            if !rest.isEmpty {
                queued.insert(Job(url: current.job.url, headers: current.job.headers, targets: rest,
                                  formatHint: current.job.formatHint), at: 1)
            }
            running = nil
        }
        lock.unlock()
        preempted?.cancel()
        runNext()
    }

    /// A rendition request found `store` still decoding. That is a pick too, but one the host did not
    /// make, so it never overtakes a host pick whose sidecar is still on its way.
    private func prioritizeRequested(_ store: NativeSubtitleCueStore) {
        lock.lock()
        let hostPickPending = pickedStore.map { $0 !== store && !$0.isFinished
            && $0.externalFillState == .pending } ?? false
        lock.unlock()
        guard !hostPickPending else { return }
        prioritize(store)
    }

    /// Lets the jobs nobody picked run.
    func releaseHeld() {
        lock.lock()
        let wasHeld = holdsUnpicked
        holdsUnpicked = false
        lock.unlock()
        if wasHeld { runNext() }
    }

    /// Waits for every job that can run to finish. Jobs still held for a pick are not waited for.
    /// Only tests need this; the session reads each store's state instead.
    func awaitIdle() async {
        while let task = currentTask() {
            await task.value
        }
    }

    private func currentTask() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return running?.task
    }

    private static func job(_ job: Job, serves store: NativeSubtitleCueStore) -> Bool {
        job.targets.contains { $0.store === store }
    }

    /// The failed targets of the job that owned `store`, as one job, so a container is still read once.
    /// Called under `lock`.
    private func retryJob(for store: NativeSubtitleCueStore) -> Job? {
        guard let owner = allJobs.first(where: { Self.job($0, serves: store) }) else { return nil }
        let failed = owner.targets.filter { $0.store.externalFillState == .failed }
        guard !failed.isEmpty else { return nil }
        return Job(url: owner.url, headers: owner.headers, targets: failed, formatHint: owner.formatHint)
    }

    /// Starts the next job the queue allows, unless one is running. A job whose every store finished
    /// meanwhile (a preempted decode that completed anyway) is dropped instead of fetched again.
    private func runNext() {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled, running == nil else { return }
        queued.removeAll { $0.targets.allSatisfy { $0.store.isFinished } }
        let index = pickedStore.flatMap { store in queued.firstIndex { Self.job($0, serves: store) } }
            ?? (holdsUnpicked || queued.isEmpty ? nil : 0)
        guard let index else { return }
        let job = queued.remove(at: index)
        nextRunID &+= 1
        let id = nextRunID
        // Assigned under the same lock hold, so `ended` can never see the run before it exists.
        let task = BlockingWork.detached(priority: .utility) { [weak self] in
            await AetherEngine.runExternalSubtitleFill(job: job)
            self?.ended(id: id)
        }
        running = (job: job, task: task, id: id)
    }

    private func ended(id: UInt64) {
        lock.lock()
        if running?.id == id { running = nil }
        lock.unlock()
        runNext()
    }
}
