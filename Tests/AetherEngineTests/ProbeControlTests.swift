import Foundation
import Testing
import AetherLibavcodec
import AetherLibavformat
@testable import AetherEngine

@Suite("Whole-probe limits, cancellation and caller ownership")
struct ProbeControlTests {
    // Integration tests are not time-budget tests: a loaded runner must not change their answer.
    private static let ample = ProbeLimits(
        maxInputBytes: 8 * 1024 * 1024, maxPackets: 128,
        maxPacketBytes: 2 * 1024 * 1024, timeBudget: 3600)
    private static let atmos = AtmosDetectionOptions(timeBudget: 3600)
    private static let hdr = HDR10PlusDetectionOptions(timeBudget: 3600)

    private static func control(
        _ limits: ProbeLimits? = ample,
        cancellation: ProbeCancellation? = nil
    ) throws -> ProbeControl {
        try ProbeControl(limits: limits, cancellation: cancellation, now: { 100 }, scheduleDeadline: false)
    }

    private static func read(_ reader: IOReader, size: Int32) -> Int32 {
        var buffer = [UInt8](repeating: 0, count: Int(size))
        return buffer.withUnsafeMutableBufferPointer { reader.read($0.baseAddress, size: size) }
    }

    private static func expectCancellation<T>(_ outcome: Result<T, any Error>) {
        switch outcome {
        case .success: Issue.record("A cancelled probe published a result")
        case .failure(let error): #expect(error is CancellationError)
        }
    }

    enum EntryPoint: CaseIterable, Equatable, Sendable {
        case base, details, atmos

        func probe(
            _ source: MediaSource,
            limits: ProbeLimits? = nil,
            cancellation: ProbeCancellation? = nil
        ) throws -> SourceProbe {
            switch self {
            case .base:
                return try AetherEngine.probe(source: source, limits: limits, cancellation: cancellation)
            case .details:
                return try AetherEngine.probe(
                    source: source, detecting: [.hdr10Plus, .atmos],
                    atmosDetection: ProbeControlTests.atmos, hdr10PlusDetection: ProbeControlTests.hdr,
                    limits: limits, cancellation: cancellation)
            case .atmos:
                return try AetherEngine.probeDetectingAtmos(
                    source: source, atmosDetection: ProbeControlTests.atmos,
                    limits: limits, cancellation: cancellation)
            }
        }

        func probe(
            _ url: URL,
            limits: ProbeLimits? = nil,
            cancellation: ProbeCancellation? = nil
        ) throws -> SourceProbe {
            switch self {
            case .base:
                return try AetherEngine.probe(url: url, limits: limits, cancellation: cancellation)
            case .details:
                return try AetherEngine.probe(
                    url: url, detecting: [.hdr10Plus, .atmos],
                    atmosDetection: ProbeControlTests.atmos, hdr10PlusDetection: ProbeControlTests.hdr,
                    limits: limits, cancellation: cancellation)
            case .atmos:
                return try AetherEngine.probeDetectingAtmos(
                    url: url, atmosDetection: ProbeControlTests.atmos,
                    limits: limits, cancellation: cancellation)
            }
        }
    }

    // MARK: Validation and monotonic deadlines

    @Test("Every invalid whole-probe limit fails before input", arguments: [
        ProbeLimits(maxInputBytes: -1),
        ProbeLimits(maxPackets: -1),
        ProbeLimits(maxPacketBytes: -1),
        ProbeLimits(timeBudget: -1),
        ProbeLimits(timeBudget: .infinity),
        ProbeLimits(timeBudget: -.infinity),
        ProbeLimits(timeBudget: .nan),
    ])
    func invalidLimits(_ limits: ProbeLimits) throws {
        #expect(throws: ProbeError.invalidLimits) { try Self.control(limits) }
        let reader = ProbeRecordingReader(data: try ProbeTestFixtures.hdr10Plus())
        let token = ProbeCancellation()
        #expect(throws: ProbeError.invalidLimits) {
            try AetherEngine.probe(source: .custom(reader), limits: limits, cancellation: token)
        }
        token.cancel()
        #expect(reader.reads.isEmpty)
        #expect(reader.seeks.isEmpty)
        #expect(reader.cancelCount == 0)
        #expect(reader.closeCount == 0)
    }

    @Test("Zero limits are valid, and the zero deadline is already expired")
    func zeroLimitsAreNotInvalid() throws {
        let control = try Self.control(.init(
            maxInputBytes: 0, maxPackets: 0, maxPacketBytes: 0, timeBudget: 0))
        defer { control.finish() }
        #expect(throws: ProbeError.timedOut) { try control.check() }
    }

    @Test("A huge finite deadline schedules safely and still expires on the injected clock")
    func hugeFiniteDeadlineDoesNotOverflowDispatchTime() throws {
        let clock = ProbeTestBox<TimeInterval>(0)
        let control = try ProbeControl(
            limits: .init(timeBudget: Double.greatestFiniteMagnitude), cancellation: nil,
            now: { clock.value }, scheduleDeadline: true)
        defer { control.finish() }
        // Keep scheduling enabled: disabling the watchdog would bypass the conversion regression.
        try control.check()
        #expect(!control.isStopped)
        clock.update { $0 = Double.greatestFiniteMagnitude }
        #expect(throws: ProbeError.timedOut) { try control.check() }
        #expect(throws: ProbeError.timedOut) { try control.complete() }
    }

    @Test("Without limits there is no implicit deadline, byte cap or packet cap")
    func absentLimitsAreUnbounded() throws {
        let clock = ProbeTestBox<TimeInterval>(0)
        let control = try ProbeControl(
            limits: nil, cancellation: nil, now: { clock.value }, scheduleDeadline: false)
        defer { control.finish() }
        #expect(try control.inputAllowance(Int32.max) == Int32.max)
        try control.consumedInput(Int32.max, requested: Int32.max)
        clock.update { $0 = 1_000_000 }
        #expect(try control.inputAllowance(Int32.max) == Int32.max)
        var packet = AVPacket()
        packet.size = Int32.max
        for _ in 0..<129 {
            try control.willReadPacket()
            try control.receivedPacket(&packet)
        }
        try control.complete()
    }

    @Test("A monotonic deadline fires exactly at the boundary and only interrupts once")
    func deadlineBoundary() throws {
        let clock = ProbeTestBox<TimeInterval>(10)
        let interrupts = ProbeTestBox(0)
        let control = try ProbeControl(
            limits: .init(timeBudget: 5), cancellation: nil,
            now: { clock.value }, scheduleDeadline: false)
        defer { control.finish() }
        control.interrupt { interrupts.update { $0 += 1 } }
        clock.update { $0 = 14.999 }
        try control.check()
        #expect(!control.isStopped)
        #expect(interrupts.value == 0)
        clock.update { $0 = 15 }
        #expect(throws: ProbeError.timedOut) { try control.check() }
        #expect(throws: ProbeError.timedOut) { try control.complete() }
        #expect(control.isStopped)
        #expect(interrupts.value == 1)
    }

    /// The origin request slot is the one wait the watchdog cannot interrupt: it fires at reads, and an
    /// `acquire` is already blocked when it does. So the slot wait is bounded by what is left of the
    /// deadline instead, and a probe that merely arrived while another request held the origin waits for
    /// it rather than failing on the spot.
    @Test("Remaining time bounds the one wait the watchdog cannot interrupt")
    func remainingTimeTracksTheDeadline() throws {
        let clock = ProbeTestBox<TimeInterval>(10)
        let control = try ProbeControl(
            limits: .init(timeBudget: 5), cancellation: nil,
            now: { clock.value }, scheduleDeadline: false)
        defer { control.finish() }
        #expect(control.remainingTime == 5)
        clock.update { $0 = 13 }
        #expect(control.remainingTime == 2)
        clock.update { $0 = 99 }
        #expect(control.remainingTime == 0)

        let uncapped = try ProbeControl(
            limits: nil, cancellation: ProbeCancellation(),
            now: { clock.value }, scheduleDeadline: false)
        defer { uncapped.finish() }
        #expect(uncapped.remainingTime == nil)
    }

    @Test("Completion checks time even without another read or watchdog tick")
    func completionChecksDeadline() throws {
        let clock = ProbeTestBox<TimeInterval>(10)
        let control = try ProbeControl(
            limits: .init(timeBudget: 5), cancellation: nil,
            now: { clock.value }, scheduleDeadline: false)
        defer { control.finish() }
        try control.check()
        clock.update { $0 = 15 }
        #expect(throws: ProbeError.timedOut) { try control.complete() }
    }

    @Test("A real positive HDR10+ finding cannot commit after the whole-probe deadline")
    func positiveDetailCannotCompletePastDeadline() throws {
        let clock = ProbeTestBox<TimeInterval>(0)
        let control = try ProbeControl(
            limits: .init(timeBudget: 1), cancellation: nil,
            now: { clock.value }, scheduleDeadline: false)
        let reader = ProbeRecordingReader(data: try ProbeTestFixtures.hdr10Plus())
        let demuxer = Demuxer()
        demuxer.probeControl = control
        defer { control.finish(); demuxer.close() }
        try demuxer.open(
            reader: ProbeIOReader(reader: reader, control: control),
            formatHint: "mp4", profile: .stillExtraction)
        let finding = AetherEngine.detectHDR10Plus(
            demuxer: demuxer, videoIndex: demuxer.videoStreamIndex, options: Self.hdr)
        try #require(finding.carriesHDR10Plus)
        let reads = reader.reads.count
        clock.update { $0 = 1 }
        #expect(throws: ProbeError.timedOut) { try control.complete() }
        #expect(reader.reads.count == reads)
        #expect(reader.closeCount == 0)
    }

    @Test("A read or seek finishing after the deadline cannot deliver a late success",
          arguments: ProbeParkedReader.Operation.allCases)
    func lateIOIsRejected(_ operation: ProbeParkedReader.Operation) throws {
        let clock = ProbeTestBox<TimeInterval>(0)
        let control = try ProbeControl(
            limits: .init(timeBudget: 1), cancellation: nil,
            now: { clock.value }, scheduleDeadline: false)
        defer { control.finish() }
        let expire: @Sendable () -> Void = { clock.update { $0 = 1 } }
        let reader = ProbeRecordingReader(
            data: Data([1, 2, 3]), afterRead: operation == .read ? expire : nil,
            afterSeek: operation == .seek ? expire : nil)
        let counted = ProbeIOReader(reader: reader, control: control)
        if operation == .read {
            #expect(Self.read(counted, size: 3) == -1)
            #expect(reader.bytesRead == 3)
        } else {
            #expect(counted.seek(offset: 0, whence: SEEK_SET) == -1)
            #expect(reader.seeks.count == 1)
        }
        #expect(throws: ProbeError.timedOut) { try control.complete() }
        #expect(reader.cancelCount == 1)
        #expect(reader.closeCount == 0)
    }

    @Test("The first whole-probe failure remains the typed cause")
    func firstFailureWins() throws {
        let control = try Self.control()
        defer { control.finish() }
        control.stop(ProbeError.inputLimit)
        control.stop(ProbeError.timedOut)
        #expect(throws: ProbeError.inputLimit) { try control.check() }
        #expect(throws: ProbeError.inputLimit) { try control.complete() }
    }

    // MARK: Byte and packet accounting seams

    @Test("Allowance clamps the request, charges actual bytes, and does not charge EOF or errors")
    func inputAccounting() throws {
        let control = try Self.control(.init(maxInputBytes: 10))
        defer { control.finish() }
        #expect(try control.inputAllowance(Int32.max) == 10)
        try control.consumedInput(3, requested: 10)
        #expect(try control.inputAllowance(100) == 7)
        try control.consumedInput(0, requested: 7)
        try control.consumedInput(-1, requested: 7)
        #expect(try control.inputAllowance(100) == 7)
        try control.consumedInput(7, requested: 7)
        try control.check()
        #expect(throws: ProbeError.inputLimit) { try control.inputAllowance(1) }
        #expect(throws: ProbeError.inputLimit) { try control.complete() }
    }

    @Test("The exact byte boundary can complete if no further input is needed")
    func exactInputBoundaryCanComplete() throws {
        let control = try Self.control(.init(maxInputBytes: 3))
        defer { control.finish() }
        #expect(try control.inputAllowance(20) == 3)
        try control.consumedInput(3, requested: 3)
        try control.complete()
    }

    @Test("Large valid byte limits do not narrow or overflow the reader's Int32 request")
    func largeInputLimit() throws {
        let control = try Self.control(.init(maxInputBytes: Int64.max))
        defer { control.finish() }
        #expect(try control.inputAllowance(Int32.max) == Int32.max)
        try control.consumedInput(Int32.max, requested: Int32.max)
        #expect(try control.inputAllowance(Int32.max) == Int32.max)
    }

    @Test("Seek rereads consume the same input budget, and a refused read never reaches the host")
    func rereadsAreCounted() throws {
        let control = try Self.control(.init(maxInputBytes: 7))
        defer { control.finish() }
        let reader = ProbeRecordingReader(data: Data([1, 2, 3, 4]))
        let counted = ProbeIOReader(reader: reader, control: control)
        #expect(Self.read(counted, size: 4) == 4)
        #expect(counted.seek(offset: 0, whence: SEEK_SET) == 0)
        #expect(counted.seek(offset: 0, whence: 0x10000) == 4)
        #expect(Self.read(counted, size: 4) == 3)
        #expect(Self.read(counted, size: 4) == -1)
        #expect(reader.reads.map(\.requested) == [4, 3])
        #expect(reader.reads.map(\.offset) == [0, 0])
        #expect(reader.bytesRead == 7)
        #expect(throws: ProbeError.inputLimit) { try control.complete() }
        let seekCount = reader.seeks.count
        #expect(counted.seek(offset: 0, whence: SEEK_SET) == -1)
        #expect(reader.seeks.count == seekCount)
        #expect(reader.cancelCount == 1)
    }

    @Test("A reader claiming more than its clamped request fails closed")
    func oversizedReaderResult() throws {
        final class LyingReader: IOReader, @unchecked Sendable {
            let discImageProbeEnabled = false
            let reader: ProbeRecordingReader

            init(reader: ProbeRecordingReader) { self.reader = reader }
            func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
                let count = reader.read(buffer, size: size)
                return count > 0 ? size + 1 : count
            }
            func seek(offset: Int64, whence: Int32) -> Int64 {
                reader.seek(offset: offset, whence: whence)
            }
            func cancel() { reader.cancel() }
            func close() { reader.close() }
        }
        let data = try ProbeTestFixtures.hdr10Plus()
        let control = try Self.control(.init(maxInputBytes: 3))
        defer { control.finish() }
        let counted = ProbeIOReader(
            reader: LyingReader(reader: ProbeRecordingReader(data: data)), control: control)
        #expect(Self.read(counted, size: 10) == -1)
        #expect(throws: ProbeError.invalidReaderResult) { try control.check() }
        #expect(throws: ProbeError.invalidReaderResult) { try control.complete() }
        let nativeReader = ProbeRecordingReader(data: data)
        #expect(throws: ProbeError.invalidReaderResult) {
            try AetherEngine.probe(
                source: .custom(LyingReader(reader: nativeReader), formatHint: "mp4"),
                limits: .init(maxInputBytes: 3, timeBudget: 3600))
        }
        #expect(nativeReader.reads.map(\.requested) == [3])
        #expect(nativeReader.bytesRead == 3)
        #expect(nativeReader.cancelCount == 1)
        #expect(nativeReader.closeCount == 0)
    }

    @Test("One packet budget covers every stream and later pass")
    func packetBudgetIsShared() throws {
        let control = try Self.control(.init(maxPackets: 2, maxPacketBytes: 4))
        defer { control.finish() }
        var packet = AVPacket()
        packet.size = 4
        for stream in [Int32(0), Int32(7)] {
            packet.stream_index = stream
            try control.willReadPacket()
            try control.receivedPacket(&packet)
        }
        try control.check()
        #expect(throws: ProbeError.packetLimit) { try control.willReadPacket() }
        #expect(throws: ProbeError.packetLimit) { try control.complete() }
    }

    @Test("A single oversize packet is rejected independently of packet count")
    func packetSizeBoundary() throws {
        let control = try Self.control(.init(maxPackets: 10, maxPacketBytes: 4))
        defer { control.finish() }
        var packet = AVPacket()
        packet.size = 4
        try control.willReadPacket()
        try control.receivedPacket(&packet)
        packet.size = 5
        try control.willReadPacket()
        #expect(throws: ProbeError.packetSizeLimit) { try control.receivedPacket(&packet) }
        #expect(throws: ProbeError.packetSizeLimit) { try control.complete() }
    }

    @Test("Zero packet and packet-size budgets are enforced separately")
    func zeroPacketBudgets() throws {
        let none = try Self.control(.init(maxPackets: 0))
        defer { none.finish() }
        #expect(throws: ProbeError.packetLimit) { try none.willReadPacket() }

        let emptyOnly = try Self.control(.init(maxPacketBytes: 0))
        defer { emptyOnly.finish() }
        var packet = AVPacket()
        try emptyOnly.willReadPacket()
        try emptyOnly.receivedPacket(&packet)
        packet.size = 1
        #expect(throws: ProbeError.packetSizeLimit) { try emptyOnly.receivedPacket(&packet) }
    }

    // MARK: Token lifecycle and races

    @Test("A precancelled token interrupts even when the reader is attached later")
    func cancellationBeforeRegistration() throws {
        let token = ProbeCancellation()
        token.cancel()
        let control = try Self.control(nil, cancellation: token)
        defer { control.finish() }
        let calls = ProbeTestBox(0)
        control.interrupt { calls.update { $0 += 1 } }
        token.cancel()
        #expect(token.isCancelled)
        #expect(calls.value == 1)
        #expect(throws: CancellationError.self) { try control.check() }
        #expect(throws: CancellationError.self) { try control.complete() }
    }

    @Test("A shared token interrupts active registrations but not finished ones")
    func tokenFanoutAndRemoval() throws {
        let token = ProbeCancellation()
        let first = try Self.control(nil, cancellation: token)
        let second = try Self.control(nil, cancellation: token)
        let third = try Self.control(nil, cancellation: token)
        defer { first.finish(); second.finish(); third.finish() }
        let calls = ProbeTestBox([0, 0, 0])
        first.interrupt { calls.update { $0[0] += 1 } }
        second.interrupt { calls.update { $0[1] += 1 } }
        third.interrupt { calls.update { $0[2] += 1 } }
        second.finish()
        second.finish()
        token.cancel()
        token.cancel()
        #expect(calls.value == [1, 0, 1])
        #expect(throws: CancellationError.self) { try first.complete() }
        #expect(throws: CancellationError.self) { try third.complete() }
    }

    @Test("Finishing drops callback captures before the caller reuses its reader")
    func finishReleasesCallback() throws {
        let token = ProbeCancellation()
        let control = try Self.control(nil, cancellation: token)
        defer { control.finish() }
        weak var released: ProbeTestBox<Int>?
        do {
            let capture = ProbeTestBox(0)
            released = capture
            control.interrupt { capture.update { $0 += 1 } }
        }
        #expect(released != nil)
        control.finish()
        #expect(released == nil)
        token.cancel()
        #expect(released == nil)
    }

    @Test("Cancellation after the result's commit cannot touch the caller's reader")
    func completionWinsAgainstLaterCancellation() throws {
        let token = ProbeCancellation()
        let calls = ProbeTestBox(0)
        let control = try Self.control(nil, cancellation: token)
        defer { control.finish() }
        control.interrupt { calls.update { $0 += 1 } }
        try control.complete()
        token.cancel()
        #expect(calls.value == 0)
        try control.check()
    }

    @Test("Cancellation callbacks may safely cancel the token reentrantly", .timeLimit(.minutes(3)))
    func reentrantCancellation() async throws {
        let token = ProbeCancellation()
        let calls = ProbeTestBox(0)
        let control = try Self.control(nil, cancellation: token)
        defer { control.finish() }
        control.interrupt {
            calls.update { $0 += 1 }
            token.cancel()
        }
        let job = ProbeTestJob { token.cancel() }
        _ = try await job.outcome().get()
        #expect(calls.value == 1)
    }

    @Test("Concurrent cancels deliver each callback once", .timeLimit(.minutes(3)))
    func racingCancellationIsOneShot() async throws {
        let token = ProbeCancellation()
        let gate = ProbeTestGate()
        let calls = ProbeTestBox(0)
        let control = try Self.control(nil, cancellation: token)
        defer { gate.open(); control.finish() }
        control.interrupt { calls.update { $0 += 1 } }
        let jobs = (0..<8).map { _ in
            ProbeTestJob { gate.wait(); token.cancel() }
        }
        gate.open()
        for job in jobs { _ = try await job.outcome().get() }
        #expect(calls.value == 1)
        #expect(throws: CancellationError.self) { try control.complete() }
    }

    @Test("Cancellation and completion have one winner", .timeLimit(.minutes(3)))
    func cancellationCompletionRace() async throws {
        for _ in 0..<16 {
            let token = ProbeCancellation()
            let gate = ProbeTestGate()
            let calls = ProbeTestBox(0)
            let control = try Self.control(nil, cancellation: token)
            defer { gate.open(); control.finish() }
            control.interrupt { calls.update { $0 += 1 } }
            let cancelling = ProbeTestJob { gate.wait(); token.cancel() }
            let completing = ProbeTestJob { gate.wait(); try control.complete() }
            gate.open()
            let outcome = try await completing.outcome()
            _ = try await cancelling.outcome().get()
            switch outcome {
            case .success: #expect(calls.value == 0)
            case .failure(let error):
                #expect(error is CancellationError)
                #expect(calls.value == 1)
            }
            control.finish()
            token.cancel()
            #expect(calls.value <= 1)
        }
    }

    @Test("Finish joins a callback already running on the cancelling thread", .timeLimit(.minutes(3)))
    func finishJoinsRunningCallback() async throws {
        let token = ProbeCancellation()
        let callbackGate = ProbeTestGate()
        let callbackExited = ProbeTestBox(false)
        let finishEntered = ProbeTestBox(false)
        let control = try Self.control(nil, cancellation: token)
        defer { callbackGate.open(); control.finish() }
        control.interrupt {
            callbackGate.wait()
            callbackExited.update { $0 = true }
        }
        let cancelling = ProbeTestJob { token.cancel() }
        try await waitFor { callbackGate.entered }
        let finishing = ProbeTestJob {
            finishEntered.update { $0 = true }
            control.finish()
            return callbackExited.value
        }
        try await waitFor { finishEntered.value }
        #expect(!finishing.isFinished)
        callbackGate.open()
        #expect(try await finishing.outcome().get())
        _ = try await cancelling.outcome().get()
        control.finish()
    }

    // MARK: Real custom and file probes

    @Test("All custom overloads reject precancellation without reading, seeking or closing",
          arguments: EntryPoint.allCases)
    func customPrecancelled(_ entry: EntryPoint) throws {
        let token = ProbeCancellation()
        token.cancel()
        let reader = ProbeRecordingReader(data: try ProbeTestFixtures.hdr10Plus(), discImageProbeEnabled: true)
        #expect(throws: CancellationError.self) {
            try entry.probe(.custom(reader, formatHint: "mp4"), cancellation: token)
        }
        #expect(reader.reads.isEmpty)
        #expect(reader.seeks.isEmpty)
        #expect(reader.cancelCount == 0)
        #expect(reader.closeCount == 0)
    }

    @Test("All URL overloads reject precancellation before trying to open a missing file",
          arguments: EntryPoint.allCases)
    func filePrecancelled(_ entry: EntryPoint) {
        let token = ProbeCancellation()
        token.cancel()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(".missing-probe-\(UUID().uuidString).mp4")
        #expect(throws: CancellationError.self) { try entry.probe(missing, cancellation: token) }
    }

    @Test("A zero whole-probe deadline does no input")
    func zeroDeadlineBeforeInput() throws {
        let reader = ProbeRecordingReader(data: try ProbeTestFixtures.hdr10Plus(), discImageProbeEnabled: true)
        #expect(throws: ProbeError.timedOut) {
            try AetherEngine.probe(source: .custom(reader), limits: .init(timeBudget: 0))
        }
        #expect(reader.reads.isEmpty)
        #expect(reader.seeks.isEmpty)
        #expect(reader.closeCount == 0)
    }

    @Test("Opening and stream analysis obey the input cap even with short host reads")
    func openInputLimit() throws {
        let reader = ProbeRecordingReader(data: try ProbeTestFixtures.hdr10Plus(), chunkSize: 7)
        var limits = Self.ample
        limits.maxInputBytes = 31
        #expect(throws: ProbeError.inputLimit) {
            try AetherEngine.probe(source: .custom(reader, formatHint: "mp4"), limits: limits)
        }
        #expect(reader.bytesRead == 31)
        #expect(reader.reads.last?.requested == 3)
        var remaining: Int64 = 31
        for read in reader.reads {
            #expect(Int64(read.requested) <= remaining)
            remaining -= Int64(read.returned)
        }
        #expect(reader.cancelCount == 1)
        #expect(reader.closeCount == 0)
    }

    @Test("Sparse ISO and UDF signature reads share the opening input cap", arguments: [3, 6, 8])
    func discSniffCountsTowardInput(_ cap: Int) throws {
        let reader = ProbeRecordingReader(
            data: Data(repeating: 0, count: 256 * 2048 + 2), discImageProbeEnabled: true)
        var limits = Self.ample
        limits.maxInputBytes = Int64(cap)
        #expect(throws: ProbeError.inputLimit) {
            try AetherEngine.probe(source: .custom(reader, formatHint: "mp4"), limits: limits)
        }
        #expect(reader.bytesRead == Int64(cap))
        #expect(reader.reads.first?.offset == 0x8001)
        #expect(reader.reads.first?.requested == Int32(min(cap, 5)))
        if cap > 5 {
            try #require(reader.reads.count >= 2)
            #expect(reader.reads[1].offset == 256 * 2048)
            #expect(reader.reads[1].requested == Int32(min(cap - 5, 2)))
        }
        if cap > 7 {
            #expect(reader.reads.last?.offset == 0)
            #expect(reader.reads.last?.requested == 1)
        }
        #expect(reader.closeCount == 0)
    }

    @Test("Disc parsing after a positive signature is charged below the adapter")
    func isoMetadataCountsTowardInput() {
        let reader = ProbeRecordingReader(
            data: ISO9660Fixture.make(files: [.init(name: "VTS_01_1.VOB", length: 2048)]),
            discImageProbeEnabled: true)
        var limits = Self.ample
        limits.maxInputBytes = 37
        #expect(throws: ProbeError.inputLimit) {
            try AetherEngine.probe(source: .custom(reader), limits: limits)
        }
        #expect(reader.reads.first?.returned == 5)
        #expect(reader.bytesRead == 37)
        #expect(reader.reads.dropFirst().contains { $0.offset == 16 * 2048 })
        #expect(reader.closeCount == 0)
    }

    @Test("Base probing needs no inspection packets and preserves ordinary metadata")
    func baseProbeWithZeroPacketBudgets() throws {
        let bytes = try ProbeTestFixtures.hdr10Plus()
        let baseline = try AetherEngine.probe(source: .custom(DataIOReader(data: bytes), formatHint: "mp4"))
        let reader = ProbeRecordingReader(data: bytes)
        var limits = Self.ample
        limits.maxPackets = 0
        limits.maxPacketBytes = 0
        let actual = try AetherEngine.probe(source: .custom(reader, formatHint: "mp4"), limits: limits)
        #expect(actual.videoCodecID == baseline.videoCodecID)
        #expect(actual.videoWidth == baseline.videoWidth)
        #expect(actual.videoHeight == baseline.videoHeight)
        #expect(actual.durationSeconds == baseline.durationSeconds)
        #expect(actual.videoFormat == baseline.videoFormat)
        #expect(!actual.carriesHDR10PlusMetadata)
        #expect(reader.bytesRead > 0)
        #expect(reader.cancelCount == 0)
        #expect(reader.closeCount == 0)
    }

    @Test("Bounded file and custom detail probes still find real HDR10+")
    func controlledPositiveResults() throws {
        let bytes = try ProbeTestFixtures.hdr10Plus()
        let custom = try AetherEngine.probe(
            source: .custom(ProbeRecordingReader(data: bytes), formatHint: "mp4"), detecting: .hdr10Plus,
            hdr10PlusDetection: Self.hdr, limits: Self.ample, cancellation: ProbeCancellation())
        let file = try ProbeTestFixtures.withFile(bytes) { url in
            try AetherEngine.probe(
                url: url, detecting: .hdr10Plus, hdr10PlusDetection: Self.hdr,
                limits: Self.ample, cancellation: ProbeCancellation())
        }
        #expect(custom.carriesHDR10PlusMetadata)
        #expect(file.carriesHDR10PlusMetadata)
        #expect(custom.videoFormat == .hdr10Plus)
        #expect(file.videoFormat == .hdr10Plus)
        #expect(file.videoWidth == custom.videoWidth)
    }

    @Test("Per-detail zero budgets remain soft stops, unlike whole-probe limits")
    func detailCapsRemainSoft() throws {
        var limits = Self.ample
        limits.maxPackets = 0
        let probe = try AetherEngine.probe(
            source: .custom(ProbeRecordingReader(data: try ProbeTestFixtures.combined()), formatHint: "mp4"),
            detecting: [.hdr10Plus, .atmos],
            atmosDetection: .init(maxPackets: 0, timeBudget: 3600),
            hdr10PlusDetection: .init(maxPackets: 0, timeBudget: 3600),
            limits: limits)
        #expect(!probe.carriesHDR10PlusMetadata)
        #expect(!probe.audioTracks.isEmpty)
        #expect(probe.audioTracks.allSatisfy { !$0.isAtmos })
    }

    @Test("Whole packet limits are thrown, never folded into an inconclusive detail",
          arguments: [false, true])
    func realPacketLimit(_ atmos: Bool) throws {
        let bytes = try (atmos ? ProbeTestFixtures.eac3() : ProbeTestFixtures.hdr10Plus())
        let reader = ProbeRecordingReader(data: bytes)
        var limits = Self.ample
        limits.maxPackets = 0
        #expect(throws: ProbeError.packetLimit) {
            try AetherEngine.probe(
                source: .custom(reader, formatHint: "mp4"), detecting: atmos ? .atmos : .hdr10Plus,
                atmosDetection: Self.atmos, hdr10PlusDetection: Self.hdr, limits: limits)
        }
        #expect(reader.cancelCount == 1)
        #expect(reader.closeCount == 0)
    }

    @Test("Whole individual-packet limits reject both scan and decode payloads",
          arguments: [false, true])
    func realPacketSizeLimit(_ atmos: Bool) throws {
        let bytes = try (atmos ? ProbeTestFixtures.eac3() : ProbeTestFixtures.hdr10Plus())
        var limits = Self.ample
        limits.maxPacketBytes = 0
        #expect(throws: ProbeError.packetSizeLimit) {
            try AetherEngine.probe(
                source: .custom(ProbeRecordingReader(data: bytes), formatHint: "mp4"),
                detecting: atmos ? .atmos : .hdr10Plus,
                atmosDetection: Self.atmos, hdr10PlusDetection: Self.hdr, limits: limits)
        }
    }

    @Test("A real HDR10+ packet fits at its size boundary but not one byte below it")
    func realPacketSizeBoundary() throws {
        let bytes = try ProbeTestFixtures.hdr10Plus()
        let budget = try ProbeTestFixtures.firstVideoBudget(bytes)
        var limits = Self.ample
        limits.maxPackets = budget.packets
        limits.maxPacketBytes = budget.bytes
        let probe = try AetherEngine.probe(
            source: .custom(ProbeRecordingReader(data: bytes), formatHint: "mp4"),
            detecting: .hdr10Plus, hdr10PlusDetection: Self.hdr, limits: limits)
        #expect(probe.carriesHDR10PlusMetadata)
        limits.maxPacketBytes -= 1
        #expect(throws: ProbeError.packetSizeLimit) {
            try AetherEngine.probe(
                source: .custom(ProbeRecordingReader(data: bytes), formatHint: "mp4"),
                detecting: .hdr10Plus, hdr10PlusDetection: Self.hdr, limits: limits)
        }
    }

    @Test("HDR then Atmos share a packet budget across the flushing seek; a partial positive is not returned")
    func sharedDetailBudgetRejectsPartialPositive() throws {
        let bytes = try ProbeTestFixtures.combined()
        let budget = try ProbeTestFixtures.firstVideoBudget(bytes)
        var limits = Self.ample
        limits.maxPackets = budget.packets
        let hdrOnly = try AetherEngine.probe(
            source: .custom(ProbeRecordingReader(data: bytes), formatHint: "mp4"),
            detecting: .hdr10Plus, hdr10PlusDetection: Self.hdr, limits: limits)
        #expect(hdrOnly.carriesHDR10PlusMetadata)
        #expect(!hdrOnly.audioTracks.isEmpty)
        #expect(hdrOnly.audioTracks.allSatisfy { !$0.isAtmos })
        #expect(throws: ProbeError.packetLimit) {
            try AetherEngine.probe(
                source: .custom(ProbeRecordingReader(data: bytes), formatHint: "mp4"),
                detecting: [.hdr10Plus, .atmos], atmosDetection: Self.atmos,
                hdr10PlusDetection: Self.hdr, limits: limits)
        }
        let sufficient = try AetherEngine.probe(
            source: .custom(ProbeRecordingReader(data: bytes), formatHint: "mp4"),
            detecting: [.hdr10Plus, .atmos], atmosDetection: Self.atmos,
            hdr10PlusDetection: Self.hdr, limits: Self.ample)
        #expect(sufficient.carriesHDR10PlusMetadata)
        #expect(sufficient.audioTracks.allSatisfy { !$0.isAtmos })
    }

    @Test("File overloads forward both input and packet limits", arguments: EntryPoint.allCases)
    func fileLimits(_ entry: EntryPoint) throws {
        try ProbeTestFixtures.withFile(ProbeTestFixtures.eac3()) { url in
            var limits = Self.ample
            limits.maxInputBytes = 1
            #expect(throws: ProbeError.inputLimit) { try entry.probe(url, limits: limits) }
            if entry != .base {
                limits = Self.ample
                limits.maxPackets = 0
                #expect(throws: ProbeError.packetLimit) { try entry.probe(url, limits: limits) }
            }
        }
    }

    @Test("A reader cancelling during read cannot publish the bytes it nevertheless returns",
          arguments: EntryPoint.allCases)
    func cancellationDuringSuccessfulRead(_ entry: EntryPoint) throws {
        let token = ProbeCancellation()
        let reader = ProbeRecordingReader(
            data: try ProbeTestFixtures.hdr10Plus(), afterRead: { token.cancel() })
        #expect(throws: CancellationError.self) {
            try entry.probe(.custom(reader, formatHint: "mp4"), cancellation: token)
        }
        #expect(reader.bytesRead > 0)
        #expect(reader.reads.count == 1)
        #expect(reader.cancelCount == 1)
        #expect(reader.closeCount == 0)
    }

    @Test("A reader cancelling from a successful seek cannot proceed to any read")
    func cancellationDuringSuccessfulSeek() throws {
        let token = ProbeCancellation()
        let reader = ProbeRecordingReader(
            data: try ProbeTestFixtures.hdr10Plus(), afterSeek: { token.cancel() })
        #expect(throws: CancellationError.self) {
            try AetherEngine.probe(source: .custom(reader, formatHint: "mp4"), cancellation: token)
        }
        #expect(reader.seeks.count == 1)
        #expect(reader.reads.isEmpty)
        #expect(reader.cancelCount == 1)
        #expect(reader.closeCount == 0)
    }

    @Test("Cancellation wakes a parked read or seek, but cannot complete before the host returns",
          .timeLimit(.minutes(3)), arguments: ProbeParkedReader.Operation.allCases)
    func cancellationInterruptsParkedIO(_ operation: ProbeParkedReader.Operation) async throws {
        let token = ProbeCancellation()
        let reader = ProbeParkedReader(operation: operation)
        defer { reader.release(); token.cancel() }
        let job = ProbeTestJob {
            try AetherEngine.probe(source: .custom(reader, formatHint: "mp4"), cancellation: token)
        }
        try await waitFor { reader.interrupted.entered }
        #expect(!job.isFinished)
        token.cancel()
        try await waitFor { reader.mayReturn.entered }
        #expect(reader.cancelCount == 1)
        #expect(!job.isFinished, "Cancellation requests interruption, not an early synthetic result")
        reader.mayReturn.open()
        Self.expectCancellation(try await job.outcome())
        token.cancel()
        #expect(reader.cancelCount == 1)
        #expect(reader.closeCount == 0)
    }

    @Test("A cancellation racing the reader's start remains latched before it parks",
          .timeLimit(.minutes(3)), arguments: ProbeParkedReader.Operation.allCases)
    func cancellationBeforeReaderParks(_ operation: ProbeParkedReader.Operation) async throws {
        let token = ProbeCancellation()
        let reader = ProbeParkedReader(operation: operation, pauseBeforeParking: true)
        let beforePark = try #require(reader.beforePark)
        defer { reader.release(); token.cancel() }
        let job = ProbeTestJob {
            try AetherEngine.probe(source: .custom(reader, formatHint: "mp4"), cancellation: token)
        }
        try await waitFor { beforePark.entered || job.isFinished }
        try #require(beforePark.entered)
        token.cancel()
        #expect(reader.cancelCount == 1)
        #expect(!reader.interrupted.entered)
        #expect(!job.isFinished)
        beforePark.open()
        try await waitFor { reader.mayReturn.entered || job.isFinished }
        try #require(reader.mayReturn.entered, "The reader must not lose cancellation before its wait starts")
        #expect(!job.isFinished)
        reader.mayReturn.open()
        Self.expectCancellation(try await job.outcome())
        #expect(reader.cancelCount == 1)
        #expect(reader.closeCount == 0)
    }

    @Test("A noninterrupting reader still owns the native call after cancel has been notified",
          .timeLimit(.minutes(3)), arguments: ProbeParkedReader.Operation.allCases)
    func cancellationCannotCompleteUninterruptibleIO(_ operation: ProbeParkedReader.Operation) async throws {
        let token = ProbeCancellation()
        let reader = ProbeParkedReader(operation: operation, interruptOnCancel: false)
        defer { reader.release(); token.cancel() }
        let job = ProbeTestJob {
            try AetherEngine.probe(source: .custom(reader, formatHint: "mp4"), cancellation: token)
        }
        try await waitFor { reader.interrupted.entered || job.isFinished }
        try #require(reader.interrupted.entered)
        token.cancel()
        #expect(reader.cancelCount == 1)
        #expect(!reader.interrupted.isOpen)
        #expect(!reader.mayReturn.entered)
        #expect(!job.isFinished, "Notification alone cannot free native state or return a result")
        reader.interrupted.open()
        try await waitFor { reader.mayReturn.entered || job.isFinished }
        try #require(reader.mayReturn.entered)
        #expect(!job.isFinished)
        reader.mayReturn.open()
        Self.expectCancellation(try await job.outcome())
        #expect(reader.closeCount == 0)
    }

    @Test("An injected deadline interrupts parked I/O without relying on a wall-clock timer",
          .timeLimit(.minutes(3)), arguments: ProbeParkedReader.Operation.allCases)
    func deadlineInterruptsParkedIO(_ operation: ProbeParkedReader.Operation) async throws {
        let clock = ProbeTestBox<TimeInterval>(0)
        let control = try ProbeControl(
            limits: .init(timeBudget: 1), cancellation: nil,
            now: { clock.value }, scheduleDeadline: false)
        let reader = ProbeParkedReader(operation: operation)
        let counted = ProbeIOReader(reader: reader, control: control)
        defer { reader.release(); control.finish() }
        let job = ProbeTestJob {
            operation == .read
                ? Int64(Self.read(counted, size: 8))
                : counted.seek(offset: 0, whence: SEEK_SET)
        }
        try await waitFor { reader.interrupted.entered }
        clock.update { $0 = 1 }
        #expect(throws: ProbeError.timedOut) { try control.check() }
        try await waitFor { reader.mayReturn.entered }
        #expect(!job.isFinished)
        reader.mayReturn.open()
        #expect(try await job.outcome().get() == -1)
        #expect(throws: ProbeError.timedOut) { try control.complete() }
        #expect(reader.cancelCount == 1)
        #expect(reader.closeCount == 0)
    }

    @Test("A native AVIO seek waits for the interrupted host callback to unwind",
          .timeLimit(.minutes(3)), arguments: [false, true])
    func nativeSeekInterruption(_ expireDeadline: Bool) async throws {
        let token = ProbeCancellation()
        let clock = ProbeTestBox<TimeInterval>(0)
        let control = try ProbeControl(
            limits: .init(timeBudget: 1), cancellation: token,
            now: { clock.value }, scheduleDeadline: false)
        let armed = ProbeTestBox(false)
        let interrupted = ProbeTestGate()
        let mayReturn = ProbeTestGate()
        defer { interrupted.open(); mayReturn.open() }
        let reader = ProbeRecordingReader(
            data: Data([1, 2, 3]),
            afterSeek: {
                if armed.value {
                    interrupted.wait()
                    mayReturn.wait()
                }
            },
            afterCancel: { interrupted.open() })
        let job = ProbeTestJob {
            let counted = ProbeIOReader(reader: reader, control: control)
            let bridge = CustomIOReaderBridge(reader: counted)
            defer { control.finish(); bridge.close() }
            try bridge.open()
            let context = try #require(bridge.context)
            // Bypass AVIO's in-buffer seek shortcut: this test needs a real host callback.
            context.pointee.direct = 1
            armed.update { $0 = true }
            return avio_seek(context, 1024 * 1024, SEEK_SET)
        }
        try await waitFor { interrupted.entered || job.isFinished }
        try #require(interrupted.entered)
        if expireDeadline {
            clock.update { $0 = 1 }
            #expect(throws: ProbeError.timedOut) { try control.check() }
        } else {
            token.cancel()
        }
        try await waitFor { mayReturn.entered || job.isFinished }
        try #require(mayReturn.entered)
        #expect(!job.isFinished, "The native avio_seek call still owns the parked callback")
        mayReturn.open()
        let nativeResult = try await job.outcome().get()
        #expect(nativeResult < 0)
        if expireDeadline {
            #expect(throws: ProbeError.timedOut) { try control.check() }
        } else {
            #expect(throws: CancellationError.self) { try control.check() }
        }
        let recordedSeeks = reader.seeks
        let requestedOffset = try #require(recordedSeeks.last?.offset)
        let expectedOffset: Int64 = 1_048_576
        #expect(requestedOffset == expectedOffset)
        #expect(reader.reads.isEmpty)
        #expect(reader.cancelCount == 1)
        #expect(reader.closeCount == 0)
    }

    @Test("A real demuxer refuses a flushing seek once its injected deadline expires")
    func demuxerSeekAfterDeadline() throws {
        let clock = ProbeTestBox<TimeInterval>(0)
        let control = try ProbeControl(
            limits: .init(timeBudget: 1), cancellation: nil,
            now: { clock.value }, scheduleDeadline: false)
        let reader = ProbeRecordingReader(data: try ProbeTestFixtures.hdr10Plus())
        let demuxer = Demuxer()
        demuxer.probeControl = control
        defer { control.finish(); demuxer.close() }
        try demuxer.open(
            reader: ProbeIOReader(reader: reader, control: control),
            formatHint: "mp4", profile: .stillExtraction)
        let reads = reader.reads.count
        let seeks = reader.seeks.count
        clock.update { $0 = 1 }
        #expect(!demuxer.seekBounded(to: 0, timeout: 3600))
        #expect(throws: ProbeError.timedOut) { try control.check() }
        #expect(reader.reads.count == reads)
        #expect(reader.seeks.count == seeks)
        #expect(reader.cancelCount == 1)
        #expect(reader.closeCount == 0)
    }

    @Test("Normal completion unregisters cancellation and leaves the same reader reusable")
    func successfulReaderReuse() throws {
        let oldToken = ProbeCancellation()
        let reader = ProbeRecordingReader(data: try ProbeTestFixtures.hdr10Plus())
        let first = try AetherEngine.probe(
            source: .custom(reader, formatHint: "mp4"), limits: Self.ample, cancellation: oldToken)
        oldToken.cancel()
        #expect(reader.cancelCount == 0)
        #expect(reader.closeCount == 0)
        let secondToken = ProbeCancellation()
        let second = try AetherEngine.probe(
            source: .custom(reader, formatHint: "mp4"), limits: Self.ample, cancellation: secondToken)
        secondToken.cancel()
        #expect(first.videoCodecID == second.videoCodecID)
        #expect(first.videoWidth == second.videoWidth)
        #expect(reader.cancelCount == 0)
        #expect(reader.closeCount == 0)
    }

    @Test("A stopped probe unregisters its token and does not poison a new probe on the caller's reader")
    func failedReaderReuse() throws {
        let token = ProbeCancellation()
        let reader = ProbeRecordingReader(data: try ProbeTestFixtures.hdr10Plus())
        var limits = Self.ample
        limits.maxInputBytes = 1
        #expect(throws: ProbeError.inputLimit) {
            try AetherEngine.probe(source: .custom(reader, formatHint: "mp4"), limits: limits, cancellation: token)
        }
        #expect(reader.cancelCount == 1)
        token.cancel()
        #expect(reader.cancelCount == 1)
        let recovered = try AetherEngine.probe(
            source: .custom(reader, formatHint: "mp4"), limits: Self.ample)
        #expect(recovered.videoWidth == 64)
        #expect(reader.closeCount == 0)
    }

    @Test("Native open errors also unregister cancellation and preserve caller ownership")
    func nativeErrorCleanup() {
        let token = ProbeCancellation()
        let reader = ProbeRecordingReader(data: Data([0, 0, 0, 0]))
        #expect(throws: (any Error).self) {
            try AetherEngine.probe(source: .custom(reader, formatHint: "mp4"), cancellation: token)
        }
        token.cancel()
        #expect(reader.cancelCount == 0)
        #expect(reader.closeCount == 0)
    }

    @Test("The counted wrapper's ordinary close and cancel never close or cancel the host")
    func wrapperDoesNotOwnReader() throws {
        let control = try Self.control()
        defer { control.finish() }
        let reader = ProbeRecordingReader(data: Data([42]))
        let counted = ProbeIOReader(reader: reader, control: control)
        counted.cancel()
        counted.close()
        #expect(reader.cancelCount == 0)
        #expect(reader.closeCount == 0)
        #expect(Self.read(counted, size: 1) == 1)
    }

    @Test("Controlled probes reject unsupported URL schemes without native protocol fallback")
    func unsupportedURL() throws {
        let url = try #require(URL(string: "ftp://127.0.0.1/probe.mp4"))
        #expect(throws: ProbeError.unsupportedURL) { try AetherEngine.probe(url: url, limits: Self.ample) }
        #expect(throws: ProbeError.unsupportedURL) {
            try AetherEngine.probe(url: url, cancellation: ProbeCancellation())
        }
    }

    // MARK: HTTP opening, with an isolated loopback origin and no URLProtocol global hooks

    @Test("Stopped HTTP probes retain their origin slot until the request callback finishes",
          .timeLimit(.minutes(3)), arguments: ProbeHTTPTestOrigin.Stage.allCases, [false, true])
    func stoppedHTTPWaitsForCompletion(_ stage: ProbeHTTPTestOrigin.Stage, deadline: Bool) async throws {
        let token = ProbeCancellation()
        let clock = ProbeTestBox<TimeInterval>(0)
        let control = try ProbeControl(
            limits: deadline ? .init(timeBudget: 1) : nil, cancellation: token,
            now: { clock.value }, scheduleDeadline: false)
        let callbacks = OperationQueue()
        callbacks.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: .ephemeral, delegate: nil, delegateQueue: callbacks)
        let origin = try ProbeHTTPTestOrigin(data: ProbeTestFixtures.hdr10Plus(), stage: stage) {
            // Delay only this reader's callbacks; never park a shared URLSession delegate queue.
            callbacks.isSuspended = true
            if deadline {
                clock.update { $0 = 1 }
                control.stop(ProbeError.timedOut)
            } else {
                token.cancel()
            }
        }
        defer {
            callbacks.isSuspended = false
            origin.stop()
            token.cancel()
            session.invalidateAndCancel()
        }
        let url = try #require(URL(string: "http://127.0.0.1:\(origin.port)/\(UUID().uuidString).mp4"))
        let reader = AVIOReader(
            url: url, chunkSize: 64 * 1024, prefetchEnabled: false,
            chunkRequestTimeout: 3600, chunkMaxRetries: 1,
            probeControl: control, probeRequestSession: session)
        control.interrupt { reader.markClosed() }
        let job = ProbeTestJob {
            defer {
                reader.markClosed()
                reader.finishProbeTransfers()
                reader.close()
                control.finish()
            }
            try reader.open()
            try control.check()
        }
        // Park first, drain second: in the body stage the size probe ahead of the parked request
        // drains too when its callbacks run late, and that drain is not the one under test.
        try await waitFor { origin.blocked.entered || job.isFinished || origin.failure != nil }
        try #require(origin.blocked.entered)
        try await waitFor { reader.isDrainingProbeRequestForTesting || job.isFinished }
        #expect(reader.isDrainingProbeRequestForTesting)
        #expect(!job.isFinished, "Cancellation is not completion while the task callback is still queued")
        #expect(OriginRequestBudget.shared.snapshot(for: url)?.inflight == 1)

        callbacks.isSuspended = false
        let outcome = try await job.outcome()
        if deadline {
            #expect(throws: ProbeError.timedOut) { try outcome.get() }
        } else {
            Self.expectCancellation(outcome)
        }
        #expect(!reader.isDrainingProbeRequestForTesting)
        #expect(OriginRequestBudget.shared.snapshot(for: url)?.inflight == 0)
        #expect(origin.failure == nil)
        origin.stop()
        try await waitFor { origin.isStopped }
    }

    @Test("HTTP cancellation ends a blocked header or body request without launching a fallback",
          .timeLimit(.minutes(3)), arguments: ProbeHTTPTestOrigin.Stage.allCases)
    func cancellationDuringHTTPOpen(_ stage: ProbeHTTPTestOrigin.Stage) async throws {
        let token = ProbeCancellation()
        let returned = ProbeTestBox(false)
        // Stop at the observed request on the origin thread, not after a test-executor hop
        // that could outlast the HTTP transport's own timeout on an overloaded runner.
        let origin = try ProbeHTTPTestOrigin(
            data: ProbeTestFixtures.hdr10Plus(), stage: stage, onBlocked: { token.cancel() })
        defer { origin.stop(); token.cancel() }
        let url = try #require(URL(string: "http://127.0.0.1:\(origin.port)/\(UUID().uuidString).mp4"))
        let job = ProbeTestJob {
            defer { returned.update { $0 = true } }
            return try AetherEngine.probe(url: url, cancellation: token)
        }
        try await waitFor { origin.blocked.entered || job.isFinished || origin.failure != nil }
        try #require(origin.blocked.entered)
        Self.expectCancellation(try await job.outcome())
        #expect(returned.value, "Observe the synchronous probe returning, not just the cancelled token")
        #expect(!origin.blocked.isOpen, "Neither origin headers/body nor an EOF released the probe")
        #expect(origin.failure == nil)
        let ranges: [String?] = stage == .headers ? ["bytes=0-"] : ["bytes=0-", "bytes=0-65535"]
        #expect(origin.requests.map(\.range) == ranges, "No HEAD, bounded fallback or retry after cancellation")
        #expect(origin.requests.allSatisfy { $0.method == "GET" })
        #expect(OriginRequestBudget.shared.snapshot(for: url)?.inflight == 0)
        origin.stop()
        try await waitFor { origin.isStopped }
    }

    @Test("An injected deadline interrupts blocked HTTP headers or body before any fallback",
          .timeLimit(.minutes(3)), arguments: ProbeHTTPTestOrigin.Stage.allCases)
    func deadlineDuringHTTPOpen(_ stage: ProbeHTTPTestOrigin.Stage) async throws {
        let clock = ProbeTestBox<TimeInterval>(0)
        let control = try ProbeControl(
            limits: .init(timeBudget: 1), cancellation: nil,
            now: { clock.value }, scheduleDeadline: false)
        let stopped = ProbeTestBox<Result<Void, any Error>?>(nil)
        let returned = ProbeTestBox(false)
        let origin = try ProbeHTTPTestOrigin(data: ProbeTestFixtures.hdr10Plus(), stage: stage) {
            clock.update { $0 = 1 }
            let result = Result { try control.check() }
            stopped.update { $0 = result }
        }
        defer { origin.stop() }
        let url = try #require(URL(string: "http://127.0.0.1:\(origin.port)/\(UUID().uuidString).mp4"))
        let job = ProbeTestJob {
            let reader = ProbeHTTPReader(url: url, headers: [:], control: control)
            let counted = ProbeIOReader(reader: reader, control: control)
            let demuxer = Demuxer()
            demuxer.probeControl = control
            defer {
                demuxer.close()
                reader.close()
                control.finish()
                returned.update { $0 = true }
            }
            do {
                try reader.open()
                try control.check()
                try demuxer.open(reader: counted, profile: .stillExtraction)
                demuxer.close()
                reader.close()
                try control.complete()
            } catch {
                try control.check()
                throw error
            }
        }
        try await waitFor { origin.blocked.entered || job.isFinished || origin.failure != nil }
        try #require(origin.blocked.entered)
        let outcome = try await job.outcome()
        #expect(throws: ProbeError.timedOut) { try outcome.get() }
        try await waitFor { stopped.value != nil }
        let expired = try #require(stopped.value)
        #expect(throws: ProbeError.timedOut) { try expired.get() }
        #expect(returned.value)
        #expect(!origin.blocked.isOpen)
        #expect(origin.failure == nil)
        let ranges: [String?] = stage == .headers ? ["bytes=0-"] : ["bytes=0-", "bytes=0-65535"]
        #expect(origin.requests.map(\.range) == ranges)
        #expect(origin.requests.allSatisfy { $0.method == "GET" })
        #expect(OriginRequestBudget.shared.snapshot(for: url)?.inflight == 0)
        origin.stop()
        try await waitFor { origin.isStopped }
    }

    @Test("Controlled HTTP fixture probes preserve detection and enforce delivered-byte limits",
          .timeLimit(.minutes(3)), arguments: [false, true])
    func controlledHTTPFixture(_ exhaustInput: Bool) async throws {
        let origin = try ProbeHTTPTestOrigin(data: ProbeTestFixtures.hdr10Plus())
        defer { origin.stop() }
        let url = try #require(URL(string: "http://127.0.0.1:\(origin.port)/\(UUID().uuidString).mp4"))
        var limits = Self.ample
        if exhaustInput { limits.maxInputBytes = 1 }
        let requestedLimits = limits
        let job = ProbeTestJob {
            try AetherEngine.probe(
                url: url, detecting: .hdr10Plus, hdr10PlusDetection: Self.hdr,
                limits: requestedLimits)
        }
        let outcome = try await job.outcome()
        if exhaustInput {
            #expect(throws: ProbeError.inputLimit) { try outcome.get() }
        } else {
            let probe = try outcome.get()
            #expect(probe.carriesHDR10PlusMetadata)
            #expect(probe.videoFormat == .hdr10Plus)
        }
        #expect(origin.failure == nil)
        #expect(origin.requests.map(\.range) == ["bytes=0-", "bytes=0-65535"],
                "The tiny fixture needs one size probe and one finite chunk, no speculative tail")
        #expect(OriginRequestBudget.shared.snapshot(for: url)?.inflight == 0)
        origin.stop()
        try await waitFor { origin.isStopped }
    }

    @Test("Precancelled HTTP probes issue no opening request", .timeLimit(.minutes(3)))
    func precancelledHTTPDoesNotOpen() async throws {
        let origin = try ProbeHTTPTestOrigin(data: ProbeTestFixtures.hdr10Plus())
        defer { origin.stop() }
        let token = ProbeCancellation()
        token.cancel()
        let url = try #require(URL(string: "http://127.0.0.1:\(origin.port)/\(UUID().uuidString).mp4"))
        let job = ProbeTestJob { try AetherEngine.probe(url: url, cancellation: token) }
        Self.expectCancellation(try await job.outcome())
        #expect(origin.requests.isEmpty)
        origin.stop()
        try await waitFor { origin.isStopped }
    }
}
