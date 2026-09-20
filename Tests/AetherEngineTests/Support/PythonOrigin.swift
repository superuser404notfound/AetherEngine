// `Process` exists only on macOS, so without this gate the whole test target fails to COMPILE
// for iOS and tvOS, which a macOS `swift build` never shows.
#if os(macOS)

import Foundation

/// The one place this suite starts a Python origin and waits for it to be listening.
///
/// Before this there were two copies of the wait, in two files, and both had the same shape: a
/// `while Date() < deadline` loop around `FileHandle.availableData`. Two things are wrong with it,
/// and the second one is why a hang from here cannot be diagnosed afterwards.
///
/// **`availableData` blocks until a byte arrives**, so while the interpreter is still starting up
/// the loop sits inside the read and the deadline in its own condition is never evaluated. The
/// bound only ever applied to an origin that had already said something, which is the case that did
/// not need one. On a machine where a green run routinely has hundreds of test durations above
/// 60 s, a 10 s bound on a process launch is a coin toss anyway, and losing it fails the test with
/// the wrong reason attached: not "the origin never came up" but "the origin was slow".
///
/// **A blocking syscall is unreachable for a `.timeLimit` trait.** Cancellation in Swift is
/// cooperative, so a test parked in that read ignores it, the trait never reports, and the job dies
/// at its own `timeout-minutes` with the log of the killed run discarded. That is the 30 minute
/// shape with no test name in it, and the only trace it leaves is the Python interpreter in the
/// runner's orphan-process cleanup. The read therefore happens on a thread of its own, the caller
/// awaits it, and cancelling the caller kills the interpreter, which closes the pipe and ends the
/// thread.
///
/// The wait itself carries no deadline, per [`waitFor`](TestWaiting.swift): the hang catcher is the
/// suite's `.timeLimit` trait, which reports a hang AS one, with a name attached.
enum PythonOrigin {
    struct Launched {
        let process: Process
        let port: UInt16
        let workDir: URL
    }

    /// Writes `files` and `script` into a scratch directory, runs the script with the system
    /// Python, and waits for its `READY <port>` line. Returns nil if the interpreter exits, or
    /// closes its output, without ever announcing a port.
    static func launch(prefix: String, script: String, files: [String: String] = [:]) async
        -> Launched?
    {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)) != nil else { return nil }

        func abandon() -> Launched? {
            try? FileManager.default.removeItem(at: dir)
            return nil
        }

        do {
            for (name, body) in files {
                try body.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            try script.write(
                to: dir.appendingPathComponent("origin.py"), atomically: true, encoding: .utf8)
        } catch { return abandon() }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = [dir.appendingPathComponent("origin.py").path]
        proc.currentDirectoryURL = dir
        let stdout = Pipe()
        proc.standardOutput = stdout
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return abandon() }

        guard let port = await readyPort(of: proc, reading: stdout.fileHandleForReading) else {
            proc.terminate()
            return abandon()
        }
        return Launched(process: proc, port: port, workDir: dir)
    }

    /// Resolves once the origin announces its port, or once it is established that it never will.
    ///
    /// Both exits are covered on purpose. The reader thread sees the pipe close, which is the
    /// ordinary case of a script that throws on startup; `terminationHandler` covers a dead
    /// interpreter whose pipe the parent still holds open, where no EOF is coming.
    private static func readyPort(of process: Process, reading handle: FileHandle) async -> UInt16? {
        let once = ResumeOnce()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                once.attach(continuation)
                process.terminationHandler = { _ in once.resume(nil) }
                Thread.detachNewThread {
                    var pending = Data()
                    while true {
                        let chunk = handle.availableData
                        if chunk.isEmpty { break }
                        pending.append(chunk)
                        let text = String(decoding: pending, as: UTF8.self)
                        guard let line = text.split(separator: "\n")
                            .first(where: { $0.contains("READY") }) else { continue }
                        once.resume(line.split(separator: " ").last.flatMap {
                            UInt16($0.trimmingCharacters(in: .whitespaces))
                        })
                        return
                    }
                    once.resume(nil)
                }
            }
        } onCancel: {
            // The read is a blocking syscall and cannot be cancelled. Killing the interpreter
            // closes the pipe, which is what lets the thread and the wait end.
            process.terminate()
        }
    }

    /// The reader thread, the termination handler and a cancellation can all reach the end of the
    /// wait, and a continuation may only be resumed once.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<UInt16?, Never>?
        private var resumed = false

        func attach(_ continuation: CheckedContinuation<UInt16?, Never>) {
            lock.withLock { self.continuation = continuation }
        }

        func resume(_ value: UInt16?) {
            let pending: CheckedContinuation<UInt16?, Never>? = lock.withLock {
                guard !resumed, let continuation else { return nil }
                resumed = true
                self.continuation = nil
                return continuation
            }
            pending?.resume(returning: value)
        }
    }
}

#endif
