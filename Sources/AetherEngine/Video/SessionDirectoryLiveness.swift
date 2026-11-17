import Darwin
import Foundation

/// AE#451: the liveness half of the `aether-segments/` stale-session sweep. A session directory's
/// creation date is its session's START time, so age alone cannot tell a session an hour in from one
/// that crashed an hour ago; an flock(2) held on `<dir>/session.lock` for the owner's lifetime can.
///
/// flock and not fcntl: flock locks belong to the open file description, so a second owner in the
/// SAME process fails to take it too. fcntl locks are per-process and a process never blocks itself.
/// The kernel drops the lock when the process dies, so a crashed session leaves an unheld marker and
/// sweeps as before.
///
/// Audit SEG-105: shared by `SegmentCache` and the software DVR ring, which lives under the same base
/// directory and was swept an hour into a DVR session because its directory carried no marker.
enum SessionDirectoryLiveness {
    static let markerName = "session.lock"

    /// What one bounded sweep did, shared by the segment cache and the software packet spool.
    struct SweepResult: Sendable, Equatable {
        let inspectedCount: Int
        let removedCount: Int
        let failureCount: Int
    }

    /// The held marker's descriptor, or -1 when open or flock failed (such a directory is swept by
    /// age, the pre-AE#451 behaviour rather than a new failure).
    static func acquire(sessionDir: URL, logPrefix: String) -> Int32 {
        let path = sessionDir.appendingPathComponent(markerName).path
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            EngineLog.emit("\(logPrefix) live marker open failed at \(path): errno=\(errno)",
                           category: .session)
            return -1
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            EngineLog.emit("\(logPrefix) live marker lock failed at \(path): errno=\(errno)",
                           category: .session)
            Darwin.close(fd)
            return -1
        }
        return fd
    }

    /// Whether some open file description still holds `entry`'s marker. A missing marker answers
    /// false: it is a directory from a build without one, and the age check decides it as before.
    static func isLive(_ entry: URL) -> Bool {
        let path = entry.appendingPathComponent(markerName).path
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return true
    }

    /// A new session directory's marker, created exclusively: an existing name (a planted file or a
    /// symlink) fails the open instead of being followed. The caller keeps the descriptor for the
    /// session's life.
    static func acquireExclusive(sessionDir: URL) throws -> Int32 {
        let path = sessionDir.appendingPathComponent(markerName).path
        let fd = open(path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            Darwin.close(fd)
            throw error
        }
        return fd
    }

    /// Age a crash remnant must reach before a sweep may take it. The held marker is the proof of
    /// abandonment; the age only keeps a sweep off a directory a sibling is still creating.
    static let staleAge: TimeInterval = 3600

    /// Bounded crash-remnant cleanup for the session directories under `base`, shared by the segment
    /// cache and the software packet spool (audit NAT-201, NAT-R203). Only direct-child directories
    /// that `isCandidate` accepts count against `maxEntries` and are considered, so unrelated
    /// entries in a shared temporary directory cannot starve the sweep. A directory is removed only
    /// when it is `staleAge` old by creation date AND its marker can be locked here: the lock is
    /// held through the removal, and the directory's identity is rechecked after it, so a replaced
    /// directory or marker symlink is never followed.
    static func sweepStale(
        base: URL, currentSession: String?, now: Date = Date(),
        maxEntries: Int, maxRemovals: Int,
        isCandidate: (String) -> Bool = { _ in true },
        logPrefix: String
    ) -> SweepResult {
        guard maxEntries > 0, maxRemovals > 0 else {
            return SweepResult(inspectedCount: 0, removedCount: 0, failureCount: 0)
        }
        var failures = 0
        guard let entries = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
            errorHandler: { _, _ in failures += 1; return false }
        ) else {
            return SweepResult(inspectedCount: 0, removedCount: 0, failureCount: max(1, failures))
        }
        let cutoff = now.addingTimeInterval(-staleAge).timeIntervalSince1970
        var inspected = 0
        var removed = 0
        while inspected < maxEntries, let entry = entries.nextObject() as? URL {
            let name = entry.lastPathComponent
            guard name != currentSession, isCandidate(name) else { continue }
            inspected += 1
            guard removed < maxRemovals else { continue }
            var info = stat()
            guard lstat(entry.path, &info) == 0 else { failures += 1; continue }
            let created = Double(info.st_birthtimespec.tv_sec) + Double(info.st_birthtimespec.tv_nsec) / 1e9
            guard info.st_mode & S_IFMT == S_IFDIR, created < cutoff else { continue }
            let dirFD = open(entry.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard dirFD >= 0 else { failures += 1; continue }
            defer { Darwin.close(dirFD) }
            // O_CREAT also leases a root abandoned between mkdir and marker creation, or from a build without one.
            let markerFD = openat(dirFD, markerName, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard markerFD >= 0 else { failures += 1; continue }
            defer { Darwin.close(markerFD) }
            guard flock(markerFD, LOCK_EX | LOCK_NB) == 0 else {
                if errno != EWOULDBLOCK && errno != EAGAIN { failures += 1 }
                EngineLog.emit("\(logPrefix) sweep spared live session dir \(name)", category: .session,
                               level: .verbose)
                continue
            }
            var held = stat()
            var named = stat()
            guard fstat(dirFD, &held) == 0, lstat(entry.path, &named) == 0,
                  named.st_mode & S_IFMT == S_IFDIR,
                  held.st_dev == named.st_dev, held.st_ino == named.st_ino else {
                failures += 1
                continue
            }
            do {
                try FileManager.default.removeItem(at: entry)
                removed += 1
            } catch { failures += 1 }
        }
        return SweepResult(inspectedCount: inspected, removedCount: removed, failureCount: failures)
    }
}
