import AVFoundation
import Testing
@testable import AetherEngine

/// AE#834: the Atmos output activator exists for HDMI sinks. On an AirPlay route to a HomePod pair its
/// second player restarted beside the programme on every resume, and the programme stayed silent.
@Suite("The Atmos output activator runs only on an HDMI route (#834)")
struct Issue834AtmosActivatorRouteTests {

    @Test("an all-HDMI route takes the activator")
    func hdmiRouteTakesIt() {
        #expect(AtmosOutputActivator.routeTakesActivator(outputPortTypes: ["HDMIOutput"]))
    }

    @Test("AirPlay, Bluetooth and mixed routes do not")
    func otherRoutesDoNot() {
        #expect(!AtmosOutputActivator.routeTakesActivator(outputPortTypes: ["AirPlay"]))
        #expect(!AtmosOutputActivator.routeTakesActivator(outputPortTypes: ["BluetoothA2DPOutput"]))
        #expect(!AtmosOutputActivator.routeTakesActivator(outputPortTypes: ["HDMIOutput", "AirPlay"]))
    }

    @Test("a route in transition, with no outputs, does not")
    func emptyRouteDoesNot() {
        #expect(!AtmosOutputActivator.routeTakesActivator(outputPortTypes: []))
    }

    @Test("the software host's transport as the activator reads it")
    func softwareTransportTruthTable() {
        #expect(AetherEngine.softwareAtmosOutputPlaying(.playing) == true)
        #expect(AetherEngine.softwareAtmosOutputPlaying(.seeking) == true)
        #expect(AetherEngine.softwareAtmosOutputPlaying(.loading) == true)
        #expect(AetherEngine.softwareAtmosOutputPlaying(.paused) == false)
        #expect(AetherEngine.softwareAtmosOutputPlaying(.idle) == nil)
        #expect(AetherEngine.softwareAtmosOutputPlaying(.ended) == nil)
        #expect(AetherEngine.softwareAtmosOutputPlaying(.error("failed")) == nil)
    }

    // The session's own value, pinned where there is no session: the test below only builds for iOS
    // and tvOS, so a macOS run passed with the constant spelled "HDMI" while every HDMI route on an
    // Apple TV reported "HDMIOutput" and none took the activator.
    @Test("the spelled-out port type is the one tvOS reports for HDMI")
    func portTypeIsHDMIOutput() {
        #expect(AtmosOutputActivator.hdmiPortType == "HDMIOutput")
        #expect(!AtmosOutputActivator.routeTakesActivator(outputPortTypes: ["HDMI"]))
    }

    #if os(iOS) || os(tvOS)
    @Test("the spelled-out port type is the session's own")
    func portTypeMatchesTheSession() {
        #expect(AtmosOutputActivator.hdmiPortType == AVAudioSession.Port.HDMI.rawValue)
        #expect(AVAudioSession.Port.airPlay.rawValue == "AirPlay")
    }
    #endif
}
