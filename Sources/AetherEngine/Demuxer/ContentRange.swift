import Foundation

/// A `Content-Range: bytes first-last/total` value, parsed one way for every reader (audit DMX-R202).
///
/// The unit is case-insensitive (RFC 9110 14.1), and a value is only accepted when it is coherent:
/// `first <= last`, and a numeric `total` lies past `last`. A `*` total is kept as nil, because some
/// callers can live without a size and others reject it. What a caller does with a range it can read
/// but dislikes (a start elsewhere, a missing total) stays at the call site.
struct ContentRange: Equatable, Sendable {
    let start: Int64
    let end: Int64
    /// Nil for `*`, an origin that will not say how large the resource is.
    let total: Int64?

    var length: Int64 { end - start + 1 }

    init?(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > 6, trimmed.prefix(5).lowercased() == "bytes",
              trimmed[trimmed.index(trimmed.startIndex, offsetBy: 5)] == " " else { return nil }
        let body = trimmed.dropFirst(6)
        let parts = body.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let span = parts[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard span.count == 2,
              let start = Int64(span[0].trimmingCharacters(in: .whitespaces)),
              let end = Int64(span[1].trimmingCharacters(in: .whitespaces)),
              start >= 0, end >= start, end - start < Int64.max else { return nil }
        let totalText = parts[1].trimmingCharacters(in: .whitespaces)
        if totalText == "*" {
            total = nil
        } else {
            guard let parsed = Int64(totalText), parsed > end else { return nil }
            total = parsed
        }
        self.start = start
        self.end = end
    }
}
