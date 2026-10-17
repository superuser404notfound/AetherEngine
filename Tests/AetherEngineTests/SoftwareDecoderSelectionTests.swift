import Testing
import AetherLibavcodec
@testable import AetherEngine

@Suite("SoftwarePlaybackHost decoder selection")
struct SoftwareDecoderSelectionTests {

    @MainActor
    @Test("P7 FEL with default options keeps the base layer on HardwareVideoDecoder: dual-layer is opt-in")
    func felDefaultIsOptIn() {
        let host = SoftwarePlaybackHost()
        host.elType = "FEL"
        #expect(host.dolbyVisionHandling == .automatic)
        #expect(host.preferDualLayerDolbyVision == false)

        let decoder = host.selectVideoDecoder(
            codecID: AV_CODEC_ID_HEVC,
            canHardwareDecode: true,
            dvProfile: 7
        )
        #expect(decoder is HardwareVideoDecoder)
    }

    #if DualLayerDolbyVision
    @MainActor
    @Test("P7 FEL opted in selects DualLayerVideoDecoder")
    func felOptedInSelectsDualLayer() {
        let host = SoftwarePlaybackHost()
        host.elType = "FEL"
        host.preferDualLayerDolbyVision = true
        #expect(host.dolbyVisionHandling == .automatic)

        let decoder = host.selectVideoDecoder(
            codecID: AV_CODEC_ID_HEVC,
            canHardwareDecode: true,
            dvProfile: 7
        )
        #expect(decoder is DualLayerVideoDecoder)
    }
    #else
    @MainActor
    @Test("P7 FEL opted in keeps HardwareVideoDecoder in a build without the DualLayerDolbyVision trait")
    func felOptedInWithoutTraitKeepsBaseLayer() {
        let host = SoftwarePlaybackHost()
        host.elType = "FEL"
        host.preferDualLayerDolbyVision = true

        let decoder = host.selectVideoDecoder(
            codecID: AV_CODEC_ID_HEVC,
            canHardwareDecode: true,
            dvProfile: 7
        )
        #expect(decoder is HardwareVideoDecoder)
        #expect(!SoftwarePlaybackHost.shouldUseDualLayerDecoder(
            dvProfile: 7, elType: "FEL", preferDualLayerDolbyVision: true, dolbyVisionHandling: .automatic
        ))
    }
    #endif

    @MainActor
    @Test("P7 MEL selects HardwareVideoDecoder across all option combinations")
    func melSelectsHardwareDecoder() {
        let handlings: [DolbyVisionHandling] = [.automatic, .baseLayerOnly]
        for handling in handlings {
            for prefer in [true, false] {
                let host = SoftwarePlaybackHost()
                host.elType = "MEL"
                host.dolbyVisionHandling = handling
                host.preferDualLayerDolbyVision = prefer

                let decoder = host.selectVideoDecoder(
                    codecID: AV_CODEC_ID_HEVC,
                    canHardwareDecode: true,
                    dvProfile: 7
                )
                #expect(
                    decoder is HardwareVideoDecoder,
                    "MEL with handling=\(handling) prefer=\(prefer) must pick HardwareVideoDecoder"
                )
            }
        }
    }

    @MainActor
    @Test("P7 FEL with baseLayerOnly selects HardwareVideoDecoder")
    func felBaseLayerOnlySelectsHardwareDecoder() {
        let host = SoftwarePlaybackHost()
        host.elType = "FEL"
        host.dolbyVisionHandling = .baseLayerOnly
        host.preferDualLayerDolbyVision = true

        let decoder = host.selectVideoDecoder(
            codecID: AV_CODEC_ID_HEVC,
            canHardwareDecode: true,
            dvProfile: 7
        )
        #expect(decoder is HardwareVideoDecoder)
    }

    @MainActor
    @Test("P7 FEL with preferDualLayerDolbyVision=false selects HardwareVideoDecoder")
    func felPreferFalseSelectsHardwareDecoder() {
        let host = SoftwarePlaybackHost()
        host.elType = "FEL"
        host.dolbyVisionHandling = .automatic
        host.preferDualLayerDolbyVision = false

        let decoder = host.selectVideoDecoder(
            codecID: AV_CODEC_ID_HEVC,
            canHardwareDecode: true,
            dvProfile: 7
        )
        #expect(decoder is HardwareVideoDecoder)
    }

    @MainActor
    @Test("P7 without elType (nil) selects HardwareVideoDecoder")
    func nilElTypeSelectsHardwareDecoder() {
        let host = SoftwarePlaybackHost()
        #expect(host.elType == nil)

        let decoder = host.selectVideoDecoder(
            codecID: AV_CODEC_ID_HEVC,
            canHardwareDecode: true,
            dvProfile: 7
        )
        #expect(decoder is HardwareVideoDecoder)
    }

    @MainActor
    @Test("P8 or other DV profiles select HardwareVideoDecoder regardless of FEL settings")
    func p8SelectsHardwareDecoder() {
        let host = SoftwarePlaybackHost()
        host.elType = "FEL"
        host.preferDualLayerDolbyVision = true
        host.dolbyVisionHandling = .automatic

        let decoder = host.selectVideoDecoder(
            codecID: AV_CODEC_ID_HEVC,
            canHardwareDecode: true,
            dvProfile: 8
        )
        #expect(decoder is HardwareVideoDecoder)
    }

    @MainActor
    @Test("Non-HEVC or unsupported hardware decode falls back to SoftwareVideoDecoder")
    func nonHardwareFallback() {
        let host = SoftwarePlaybackHost()
        host.elType = "FEL"

        let av1Decoder = host.selectVideoDecoder(
            codecID: AV_CODEC_ID_AV1,
            canHardwareDecode: true,
            dvProfile: nil
        )
        #expect(av1Decoder is SoftwareVideoDecoder)

        let noHwDecoder = host.selectVideoDecoder(
            codecID: AV_CODEC_ID_HEVC,
            canHardwareDecode: false,
            dvProfile: 7
        )
        #expect(noHwDecoder is SoftwareVideoDecoder)
    }

    @Test("SoftwarePlaybackHost.shouldUseDualLayerDecoder static predicate matches table")
    func shouldUseDualLayerDecoderPredicate() {
        // Section 5.2 table: only dvProfile == 7 && elType == "FEL" && preferDualLayerDolbyVision && .automatic
        #expect(SoftwarePlaybackHost.shouldUseDualLayerDecoder(
            dvProfile: 7, elType: "FEL", preferDualLayerDolbyVision: true, dolbyVisionHandling: .automatic
        ) == DualLayerRouteDecision.isBuiltIn)
        #expect(!SoftwarePlaybackHost.shouldUseDualLayerDecoder(
            dvProfile: 7, elType: "FEL", preferDualLayerDolbyVision: true, dolbyVisionHandling: .baseLayerOnly
        ))
        #expect(!SoftwarePlaybackHost.shouldUseDualLayerDecoder(
            dvProfile: 7, elType: "FEL", preferDualLayerDolbyVision: false, dolbyVisionHandling: .automatic
        ))
        #expect(!SoftwarePlaybackHost.shouldUseDualLayerDecoder(
            dvProfile: 7, elType: "MEL", preferDualLayerDolbyVision: true, dolbyVisionHandling: .automatic
        ))
        #expect(!SoftwarePlaybackHost.shouldUseDualLayerDecoder(
            dvProfile: 7, elType: nil, preferDualLayerDolbyVision: true, dolbyVisionHandling: .automatic
        ))
        #expect(!SoftwarePlaybackHost.shouldUseDualLayerDecoder(
            dvProfile: 8, elType: "FEL", preferDualLayerDolbyVision: true, dolbyVisionHandling: .automatic
        ))
        #expect(!SoftwarePlaybackHost.shouldUseDualLayerDecoder(
            dvProfile: nil, elType: "FEL", preferDualLayerDolbyVision: true, dolbyVisionHandling: .automatic
        ))
    }
}
