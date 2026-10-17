// Tests/AetherEngineTests/IFrameRenditionEligibilityTests.swift
import Testing
@testable import AetherEngine

struct IFrameRenditionEligibilityTests {
    private func inputs(_ change: (inout IFrameRenditionEligibility.Inputs) -> Void = { _ in })
        -> IFrameRenditionEligibility.Inputs {
        var i = IFrameRenditionEligibility.Inputs(
            requested: true, isLive: false, planBoundariesClaimRandomAccess: true,
            sequentialOrigin: false, heldSourceConnection: false, originIsSerial: false,
            isDiscSource: false, secondReaderAvailable: true)
        change(&i)
        return i
    }

    @Test("every requirement met is a candidate")
    func allMet() {
        #expect(IFrameRenditionEligibility.candidate(inputs()) == .served)
    }

    @Test("each failed requirement names its own reason",
          arguments: ["notRequested", "live", "planNotKeyframeAligned", "sequentialOrigin",
                      "heldSourceConnection", "serialOrigin", "discSource", "noSecondReader",
                      "dolbyVisionStillsNotBuiltIn"])
    func eachReason(reason: String) throws {
        let expected = try #require(IFrameRenditionEligibility.AbsentReason(rawValue: reason))
        let verdict = IFrameRenditionEligibility.candidate(inputs { i in
            switch expected {
            case .notRequested: i.requested = false
            case .live: i.isLive = true
            case .planNotKeyframeAligned: i.planBoundariesClaimRandomAccess = false
            case .sequentialOrigin: i.sequentialOrigin = true
            case .heldSourceConnection: i.heldSourceConnection = true
            case .serialOrigin: i.originIsSerial = true
            case .discSource: i.isDiscSource = true
            case .noSecondReader: i.secondReaderAvailable = false
            case .dolbyVisionStillsNotBuiltIn: i.stillsUnavailable = true
            case .mediaPlaylistRouting: break
            }
        })
        #expect(verdict == .absent(expected))
    }

    @Test("not requested wins over every other reason, so an unflagged session logs nothing odd")
    func notRequestedFirst() {
        let v = IFrameRenditionEligibility.candidate(inputs { $0.requested = false; $0.isLive = true })
        #expect(v == .absent(.notRequested))
    }

    @Test("a candidate without a master is absent for routing")
    func mediaRouting() {
        #expect(IFrameRenditionEligibility.resolve(candidate: .served, servingMaster: false)
                == .absent(.mediaPlaylistRouting))
        #expect(IFrameRenditionEligibility.resolve(candidate: .served, servingMaster: true) == .served)
        #expect(IFrameRenditionEligibility.resolve(candidate: .absent(.live), servingMaster: true)
                == .absent(.live))
    }
}
