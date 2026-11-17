import Foundation
import Testing
@testable import AetherEngine

/// Audit DMX-R202: the five readers that parsed a Content-Range each had their own rules.
@Suite("Content-Range parsing", .timeLimit(.minutes(3)))
struct ContentRangeTests {
    @Test("the unit is case-insensitive and the fields are read the same everywhere")
    func parsesTheUsualForms() throws {
        let plain = try #require(ContentRange("bytes 100-199/1000"))
        #expect(plain.start == 100 && plain.end == 199 && plain.total == 1000 && plain.length == 100)
        #expect(ContentRange("Bytes 0-1/2")?.total == 2)
        #expect(ContentRange("  BYTES 0-0/*  ")?.total == nil)
        #expect(ContentRange("  BYTES 0-0/*  ") != nil)
    }

    @Test("an incoherent or unreadable value is refused", arguments: [
        "", "garbage", "bytes", "bytes 5-4/10", "bytes 0-9/9", "bytes -1-5/10", "bytes 0-/10", "bytes 0-1",
        "items 0-1/2", "bytes0-1/2", "bytes 0-9223372036854775807/*",
    ])
    func refusesJunk(value: String) {
        #expect(ContentRange(value) == nil)
    }

    @Test("every caller sees the same answer for a capitalised unit")
    func callersAgree() {
        #expect(AVIOReader.contentRangeSpan(response(206, "Bytes 0-1/10"))?.start == 0)
        #expect(HTTPDiscIOReader.parseContentRangeStart("Bytes 0-1/10") == 0)
        #expect(HTTPDiscIOReader.parseContentRangeTotal("Bytes 0-1/10") == 10)
        #expect(HLSByteRange.contentRangeStart("Bytes 0-1/10") == 0)
    }

    private func response(_ status: Int, _ range: String) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "http://h/x")!, statusCode: status, httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Range": range])!
    }
}
