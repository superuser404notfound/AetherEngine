import Foundation
import Testing
@testable import AetherEngine

@Suite("FragmentSplitter ISOBMFF box split")
struct FragmentSplitterTests {

    private func u32be(_ v: UInt32) -> [UInt8] {
        [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
    }

    /// A standard 32-bit-size box: 4-byte big-endian size (incl. 8-byte header) + 4-char type + body.
    private func box(_ type: String, _ body: [UInt8]) -> [UInt8] {
        u32be(UInt32(8 + body.count)) + Array(type.utf8) + body
    }

    /// A 64-bit largesize box: size field == 1, then an 8-byte size (incl. 16-byte header) + body.
    private func largeBox(_ type: String, _ body: [UInt8]) -> [UInt8] {
        let size = UInt64(16 + body.count)
        var ls = [UInt8](repeating: 0, count: 8)
        for i in 0..<8 { ls[i] = UInt8((size >> (UInt64(7 - i) * 8)) & 0xff) }
        return u32be(1) + Array(type.utf8) + ls + body
    }

    /// Run the splitter over a sequence of feed() chunks; return captured header(s) and concatenated fragment bytes.
    private func run(feeds: [[UInt8]]) -> (headers: [Data], fragment: Data) {
        var headers: [Data] = []
        var fragment = Data()
        let fs = FragmentSplitter(
            onHeaderComplete: { headers.append($0) },
            onFragmentBytes: { ptr, len in fragment.append(ptr, count: len) }
        )
        for feed in feeds where !feed.isEmpty {
            feed.withUnsafeBufferPointer { fs.feed($0.baseAddress!, count: feed.count) }
        }
        return (headers, fragment)
    }

    @Test("Clean ftyp+moov+moof+mdat: header fires once, fragment streams moof+mdat")
    func cleanStream() {
        let ftyp = box("ftyp", Array("isom".utf8) + [0, 0, 0, 1])
        let moov = box("moov", [UInt8](repeating: 0xAB, count: 20))
        let moof = box("moof", [UInt8](repeating: 0xCD, count: 12))
        let mdat = box("mdat", [UInt8](repeating: 0xEF, count: 40))
        let (headers, fragment) = run(feeds: [ftyp + moov + moof + mdat])
        #expect(headers.count == 1)
        #expect(Array(headers[0]) == ftyp + moov)
        #expect(Array(fragment) == moof + mdat)
    }

    @Test("Split feed one byte at a time reassembles identically")
    func splitFeed() {
        let ftyp = box("ftyp", Array("isom".utf8))
        let moov = box("moov", [UInt8](repeating: 0xAB, count: 17))
        let moof = box("moof", [UInt8](repeating: 0xCD, count: 9))
        let mdat = box("mdat", [UInt8](repeating: 0xEF, count: 33))
        let stream = ftyp + moov + moof + mdat
        let (headers, fragment) = run(feeds: stream.map { [$0] })
        #expect(headers.count == 1)
        #expect(Array(headers[0]) == ftyp + moov)
        #expect(Array(fragment) == moof + mdat)
    }

    @Test("largesize (size==1) moof is parsed via the 64-bit size and streamed whole")
    func largesizeMoof() {
        let ftyp = box("ftyp", Array("isom".utf8))
        let moov = box("moov", [UInt8](repeating: 1, count: 8))
        let moof = largeBox("moof", [UInt8](repeating: 0x7, count: 50))
        let mdat = box("mdat", [UInt8](repeating: 0x9, count: 10))
        let (headers, fragment) = run(feeds: [ftyp + moov + moof + mdat])
        #expect(headers.count == 1)
        #expect(Array(fragment) == moof + mdat)
    }

    @Test("largesize moof split one byte at a time reassembles identically")
    func largesizeMoofSplit() {
        let ftyp = box("ftyp", Array("isom".utf8))
        let moov = box("moov", [UInt8](repeating: 1, count: 8))
        let moof = largeBox("moof", [UInt8](repeating: 0x7, count: 40))
        let mdat = box("mdat", [UInt8](repeating: 0x9, count: 10))
        let stream = ftyp + moov + moof + mdat
        let (headers, fragment) = run(feeds: stream.map { [$0] })
        #expect(headers.count == 1)
        #expect(Array(fragment) == moof + mdat)
    }

    @Test("mfra, free and unknown boxes are discarded, not streamed")
    func discardsUnknownBoxes() {
        let ftyp = box("ftyp", Array("isom".utf8))
        let moov = box("moov", [UInt8](repeating: 2, count: 8))
        let moof = box("moof", [UInt8](repeating: 3, count: 8))
        let mdat = box("mdat", [UInt8](repeating: 4, count: 8))
        let mfra = box("mfra", [UInt8](repeating: 5, count: 16))
        let free = box("free", [UInt8](repeating: 6, count: 4))
        let (headers, fragment) = run(feeds: [ftyp + moov + moof + mdat + mfra + free])
        #expect(headers.count == 1)
        #expect(Array(fragment) == moof + mdat)
    }

    @Test("Header-only (ftyp+moov) fires onHeaderComplete with no fragment bytes")
    func headerOnly() {
        let ftyp = box("ftyp", Array("isom".utf8))
        let moov = box("moov", [UInt8](repeating: 0, count: 12))
        let (headers, fragment) = run(feeds: [ftyp + moov])
        #expect(headers.count == 1)
        #expect(Array(headers[0]) == ftyp + moov)
        #expect(fragment.isEmpty)
    }

    @Test("Multiple fragments after the header all stream in order")
    func multipleFragments() {
        let ftyp = box("ftyp", Array("isom".utf8))
        let moov = box("moov", [UInt8](repeating: 0, count: 8))
        let moof1 = box("moof", [UInt8](repeating: 0x11, count: 8))
        let mdat1 = box("mdat", [UInt8](repeating: 0x22, count: 16))
        let moof2 = box("moof", [UInt8](repeating: 0x33, count: 8))
        let mdat2 = box("mdat", [UInt8](repeating: 0x44, count: 24))
        let (headers, fragment) = run(feeds: [ftyp + moov, moof1 + mdat1, moof2 + mdat2])
        #expect(headers.count == 1)
        #expect(Array(fragment) == moof1 + mdat1 + moof2 + mdat2)
    }

    @Test("styp and sidx boxes are streamed as fragment bytes")
    func stypSidxStreamed() {
        let ftyp = box("ftyp", Array("isom".utf8))
        let moov = box("moov", [UInt8](repeating: 0, count: 8))
        let styp = box("styp", Array("msdh".utf8))
        let sidx = box("sidx", [UInt8](repeating: 0x5, count: 12))
        let moof = box("moof", [UInt8](repeating: 0x6, count: 8))
        let mdat = box("mdat", [UInt8](repeating: 0x7, count: 8))
        let (headers, fragment) = run(feeds: [ftyp + moov + styp + sidx + moof + mdat])
        #expect(headers.count == 1)
        #expect(Array(fragment) == styp + sidx + moof + mdat)
    }

    @Test("mdat with size==0 streams to end of input as fragment bytes")
    func mdatToEndOfFile() {
        let ftyp = box("ftyp", Array("isom".utf8))
        let moov = box("moov", [UInt8](repeating: 0, count: 8))
        let mdatHeader = u32be(0) + Array("mdat".utf8)
        let mdatBody = [UInt8](repeating: 0x9, count: 30)
        let (headers, fragment) = run(feeds: [ftyp + moov + mdatHeader + mdatBody])
        #expect(headers.count == 1)
        #expect(Array(fragment) == mdatHeader + mdatBody)
    }
}
