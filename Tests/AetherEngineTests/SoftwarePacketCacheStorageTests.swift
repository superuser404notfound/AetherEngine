import Foundation
import Testing
@testable import AetherEngine

@Suite("Software VOD storage selection", .serialized, .offCooperativePool)
struct SoftwarePacketCacheStorageTests {
    @Test("Explicit disk selection retains a disk claim and real packet history")
    func diskKeepsBudgetAndHistory() throws {
        // A ledger of its own: on the shared one, the sessions other tests run in parallel claim the
        // free space too, and on a boot volume with 22 GB free that left this claim at 0 and the
        // store nil. What the shared ledger does is pinned in its own tests.
        let (store, bytes, claim) = try #require(try SoftwarePlaybackHost.makePacketStore(
            storage: .disk, forwardSegments: 2700, claims: RetentionClaims()))
        defer { try? store.close(); claim?.release() }
        #expect(store is SoftwarePacketDiskFIFO)
        #expect(bytes > 0)
        #expect(claim?.bytes == bytes)
        let data = Data(repeating: 0x37, count: 1024)
        let cursor = try store.append(data)
        #expect(try store.pop() == data)
        try store.restore(to: cursor)
        #expect(try store.pop() == data)
        #expect(store.retainsConsumedPackets)
    }

    @Test("Explicit memory keeps upstream bounds and takes no disk claim")
    func memoryRemainsAvailable() throws {
        let (store, bytes, claim) = try #require(try SoftwarePlaybackHost.makePacketStore(
            storage: .memory, forwardSegments: 2700))
        defer { try? store.close() }
        #expect(store is SoftwarePacketMemoryFIFO)
        #expect(bytes == 96 << 20)
        #expect(claim == nil)
        let payload = Data([1, 2, 3])
        _ = try store.append(payload)
        #expect(try store.pop() == payload)
        #expect(store.retainsConsumedPackets)
    }

    @Test("Automatic preserves upstream platform selection")
    func automaticPlatformPolicy() throws {
        let (store, _, claim) = try #require(try SoftwarePlaybackHost.makePacketStore(
            storage: .automatic, forwardSegments: 10, claims: RetentionClaims()))
        defer { try? store.close(); claim?.release() }
        #if os(tvOS)
        #expect(store is SoftwarePacketMemoryFIFO)
        #else
        #expect(store is SoftwarePacketDiskFIFO)
        #endif
    }

    @Test("A disk construction failure releases its claim and never substitutes memory")
    func diskFailureReleasesClaim() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([0]).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let claims = RetentionClaims()
        #expect(throws: (any Error).self) {
            _ = try SoftwarePlaybackHost.makePacketStore(
                storage: .disk, forwardSegments: 10, directory: root, claims: claims)
        }
        let next = claims.claim(volumeAvailableBytes: 1 << 30) { _ in 1 }
        defer { next.release() }
        #expect(next.heldBackBytes == 0)
    }

    @Test("Storage survives option copies and remains an explicitly reported reload correction")
    func correctionContract() {
        let original = LoadOptions(softwarePacketCacheStorage: .disk)
        var proposed = original
        proposed.softwarePacketCacheStorage = .memory
        #expect(original.softwarePacketCacheStorage == .disk)
        #expect(SessionOptionCorrection.refusedFields(from: original, to: proposed).isEmpty)
        #expect(SessionOptionCorrection.changedFields(from: original, to: proposed) == ["softwarePacketCacheStorage"])
        #expect(LoadOptions().softwarePacketCacheStorage == .automatic)
    }
}
