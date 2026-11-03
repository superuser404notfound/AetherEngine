import Testing
@testable import AetherEngine

@Suite("LoadOptions")
struct LoadOptionsTests {

    @Test("Default values match documented defaults")
    func defaultsMatchDocs() {
        let opts = LoadOptions()
        #expect(opts.omitCriteriaColorExtensions == false)
        #expect(opts.suppressDisplayCriteria == false)
        #expect(opts.httpHeaders.isEmpty)
        #expect(opts.keepDvh1TagWithoutDV == false)
        // Default matchContentEnabled MUST be true; flipping this would
        // silently regress HDR routing for non-tvOS callers that don't
        // query the AVDisplayManager flag.
        #expect(opts.matchContentEnabled == true)
        // Default panelIsInHDRMode MUST be false (conservative branch).
        #expect(opts.panelIsInHDRMode == false)
        #expect(opts.audioBridgeMode == .surroundCompat)
        #expect(opts.isLive == false)
        #expect(opts.audioOnly == false)
        // Dual-layer FEL composition is opt-in.
        #expect(opts.preferDualLayerDolbyVision == false)
        // The software host stays the Profile 7 FEL route unless a host asks for the AVPlayer-output one.
        #expect(opts.dualLayerRoute == .softwareHost)
        // #68: probe-budget overrides default to nil so the engine keeps the
        // built-in .playback budget (50 MB / 60 s) unless a caller opts in.
        #expect(opts.probesize == nil)
        #expect(opts.maxAnalyzeDuration == nil)
    }

    @Test("Equatable holds for identical inputs")
    func equatableForIdenticalInputs() {
        let a = LoadOptions(httpHeaders: ["Auth": "x"], matchContentEnabled: false)
        let b = LoadOptions(httpHeaders: ["Auth": "x"], matchContentEnabled: false)
        #expect(a == b)
    }

    @Test("Equatable distinguishes different inputs")
    func equatableDistinguishesDifferentInputs() {
        let a = LoadOptions(matchContentEnabled: true)
        let b = LoadOptions(matchContentEnabled: false)
        #expect(a != b)

        let c = LoadOptions(panelIsInHDRMode: true)
        let d = LoadOptions(panelIsInHDRMode: false)
        #expect(c != d)
    }

    @Test("audioBridgeMode is preserved through init")
    func audioBridgeModePreserved() {
        let surround = LoadOptions(audioBridgeMode: .surroundCompat)
        let lossless = LoadOptions(audioBridgeMode: .lossless)
        #expect(surround.audioBridgeMode == .surroundCompat)
        #expect(lossless.audioBridgeMode == .lossless)
        #expect(surround != lossless)
    }

    @Test("audioOnly defaults to false")
    func audioOnlyDefaultsFalse() {
        #expect(LoadOptions().audioOnly == false)
    }

    @Test("audioOnly is preserved and affects equality")
    func audioOnlyPreservedAndEquatable() {
        let video = LoadOptions(audioOnly: false)
        let audio = LoadOptions(audioOnly: true)
        #expect(audio.audioOnly == true)
        #expect(video != audio)
    }

    // MARK: - Probe budget (#68)

    @Test("probesize / maxAnalyzeDuration round-trip through init")
    func probeBudgetRoundTrips() {
        let opts = LoadOptions(probesize: 10, maxAnalyzeDuration: 20)
        #expect(opts.probesize == 10)
        #expect(opts.maxAnalyzeDuration == 20)
    }

    @Test("probe-budget fields affect equality")
    func probeBudgetEquatable() {
        #expect(LoadOptions() == LoadOptions())
        #expect(LoadOptions(probesize: 10) != LoadOptions())
        #expect(LoadOptions(maxAnalyzeDuration: 20) != LoadOptions())
        #expect(LoadOptions(probesize: 10) == LoadOptions(probesize: 10))
    }

    @Test("existing positional/labeled callers stay source-compatible")
    func sourceCompatibleWithExistingCallers() {
        // The two new params are appended at the end with nil defaults, so a
        // pre-#68 call site that omits them must still compile and leave the
        // probe budget unset.
        let opts = LoadOptions(httpHeaders: ["a": "b"])
        #expect(opts.probesize == nil)
        #expect(opts.maxAnalyzeDuration == nil)
    }
}
