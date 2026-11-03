import Foundation
import Testing
@testable import AetherEngine

/// AE#920: the engine calls APIs on Apple's required-reason list, so it ships its own privacy manifest
/// and an app embedding it does not have to find and declare those calls (ITMS-91053).
@Suite("The engine's resource bundle carries its privacy manifest (#920)")
struct Issue920PrivacyManifestTests {

    @Test("the manifest declares boot time, disk space and file timestamp, and no tracking") @MainActor
    func manifestDeclaresTheEngineCalls() throws {
        // Beside the resource the engine itself loads, i.e. in AetherEngine's bundle (a bare
        // `Bundle.module` here would be the test target's).
        let url = AtmosOutputActivator.silentAtmosStream
            .deletingLastPathComponent().appendingPathComponent("PrivacyInfo.xcprivacy")
        let plist = try #require(
            PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])

        #expect(plist["NSPrivacyTracking"] as? Bool == false)
        #expect((plist["NSPrivacyCollectedDataTypes"] as? [Any])?.isEmpty == true)

        let entries = plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]] ?? []
        let reasons = Dictionary(uniqueKeysWithValues: entries.compactMap { entry -> (String, [String])? in
            guard let type = entry["NSPrivacyAccessedAPIType"] as? String else { return nil }
            return (type, entry["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? [])
        })
        #expect(reasons["NSPrivacyAccessedAPICategorySystemBootTime"] == ["35F9.1"])
        #expect(reasons["NSPrivacyAccessedAPICategoryDiskSpace"] == ["E174.1"])
        #expect(reasons["NSPrivacyAccessedAPICategoryFileTimestamp"] == ["C617.1", "3B52.1"])
    }
}
