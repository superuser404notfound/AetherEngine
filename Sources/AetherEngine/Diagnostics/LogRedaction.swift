import Foundation

/// Strips credentials out of a diagnostic line before `EngineLog` emits it.
///
/// The engine logs whole URLs on purpose (`[AetherEngine] load url=`, `[NativeAVPlayerHost] load
/// url=`, `asset.url=`): host, path and query are what a playback report is diagnosed from. But media
/// servers routinely put the access token in that query, Jellyfin's `api_key=` being the case this was
/// written for, so those lines carry a live credential into `os.Logger` (a Console.app capture, a
/// sysdiagnose) and into whatever handler the host installed for its own in-app log.
///
/// A credential does not always arrive next to a name, and that half was reported from the field: some
/// debrid and proxy add-ons carry the account token in a PATH segment, as base64url-encoded JSON, where
/// nothing in the URL names it. The list of names cannot be extended to reach that one, because the
/// names live inside the payload, so the encoding itself has to be the signal (`encodedPayloadRange`).
///
/// IPTV panels speaking the Xtream Codes API put the account's password in the path with no name and
/// no encoding at all (`/live/{user}/{password}/{id}.ts`), so the layout is the only signal there
/// (`xtreamPathSecretRange`). Its short form (`/{user}/{password}/{id}`) has no layout to go by, and
/// neither does a provider shape nobody has reported yet; for those the host names the value itself
/// through `EngineLog.registerSecret(_:)`, which is matched literally (`registeredSecretRange`).
///
/// That makes it the engine's problem rather than each host's: the engine composes the line, it reaches
/// three sinks a host does not control, and a host-side scrub only ever covers the one sink it owns.
///
/// Redacts at the `EngineLog` funnel, never at the call sites, so a URL logged by code added later is
/// covered without its author knowing this type exists. Over-redaction is the safe failure here;
/// under-redaction ships a credential. The value goes whole rather than truncated to a prefix: a prefix
/// still narrows a brute-force and answers no question a playback bug asks.
enum LogRedaction {

    static let placeholder = "<redacted>"

    /// Generic credential parameter and header names; the engine is not tied to one server product.
    /// Held as lowercase ASCII bytes and matched longest first, so `x-mediabrowser-token` wins over its
    /// `token` suffix. `token` alone is deliberately broad and only fires on a boundary, so identifiers
    /// such as `hasToken` and `refreshTokenAt` are left alone. Audit SUB-109 added the names other
    /// backends use as whole keys (`api-key` covers `X-Api-Key` through the `-` boundary, `cookie` covers
    /// `Set-Cookie`); bare `pass`, `key`, `auth` and `sid` stay out, because prose carries them.
    private static let keys: [[UInt8]] = [
        "x-mediabrowser-token", "x-emby-token", "access_token", "accesstoken", "refreshtoken",
        "sessiontoken", "auth_token", "authtoken", "connect.sid", "session_id", "sessionid",
        "signature", "password", "api_key", "api-key", "apikey", "passwd", "secret", "cookie",
        "token", "pwd",
    ].map { Array($0.utf8) }

    private static let placeholderBytes = Array(placeholder.utf8)

    /// Works on UTF-8 bytes, not Characters, and allocates the output only once something actually
    /// matches. That is not premature: a Character-level pass building a lowercased String per position
    /// cost enough on this hot path to shift the request timing in `ServedFromMemoryProgressTests`,
    /// which is how the first version of this file was caught. `emit` is called from the demuxer and the
    /// segment producer, so anything per-line here is per-line everywhere.
    static func redact(_ line: String) -> String {
        let bytes = Array(line.utf8)
        let secrets = registeredSecrets
        guard let view = DecodedView(bytes) else { return streamingRedact(line, bytes, secrets) }

        // Audit SUB-104: a URL carried percent-encoded inside another URL's query hides every shape
        // that needs no key (`%2F` is not a `/`, `%40` is not an `@`, `%2F` ends in a base64 letter).
        // The nameless matchers therefore also run over the decoded view, and each hit maps back to
        // whole escapes. The key matcher stays raw-only: its depth-aware terminators are the NET-1
        // rule, and the view is produced once and never decoded again.
        var spans: [Range<Int>] = []
        var i = 0
        while i < bytes.count {
            guard let value = match(in: bytes, at: i, secrets: secrets, keys: true) else {
                i += 1
                continue
            }
            spans.append(value)
            i = value.upperBound
        }
        let decoded = view.decoded
        var j = 0
        while j < decoded.count {
            guard let value = match(in: decoded, at: j, secrets: secrets, keys: false) else {
                j += 1
                continue
            }
            spans.append(view.rawStart[value.lowerBound] ..< view.rawStart[value.upperBound])
            j = value.upperBound
        }
        guard !spans.isEmpty else { return line }

        spans.sort { $0.lowerBound < $1.lowerBound }
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var copiedUpTo = 0
        var current = spans[0]
        for span in spans.dropFirst() {
            if span.lowerBound <= current.upperBound {
                current = current.lowerBound ..< max(current.upperBound, span.upperBound)
                continue
            }
            out.append(contentsOf: bytes[copiedUpTo ..< current.lowerBound])
            out.append(contentsOf: placeholderBytes)
            copiedUpTo = current.upperBound
            current = span
        }
        out.append(contentsOf: bytes[copiedUpTo ..< current.lowerBound])
        out.append(contentsOf: placeholderBytes)
        out.append(contentsOf: bytes[current.upperBound...])
        return String(decoding: out, as: UTF8.self)
    }

    /// A line without a percent escape, which is nearly every line: one pass, and the output is
    /// allocated only once something matches.
    private static func streamingRedact(_ line: String, _ bytes: [UInt8], _ secrets: [[UInt8]]) -> String {
        var out: [UInt8]?
        var copiedUpTo = 0
        var i = 0

        while i < bytes.count {
            guard let value = match(in: bytes, at: i, secrets: secrets, keys: true) else {
                i += 1
                continue
            }
            if out == nil {
                out = []
                out?.reserveCapacity(bytes.count)
            }
            out?.append(contentsOf: bytes[copiedUpTo ..< value.lowerBound])
            out?.append(contentsOf: placeholderBytes)
            copiedUpTo = value.upperBound
            i = value.upperBound
        }

        guard var out else { return line }
        out.append(contentsOf: bytes[copiedUpTo...])
        return String(decoding: out, as: UTF8.self)
    }

    /// Several shapes, because a credential does not always arrive next to a name. The key matcher
    /// covers `api_key=…`, `X-Emby-Token: …` and the cookie; the scheme matcher covers
    /// `Authorization: Bearer …` / `Basic …`; the payload matcher covers an encoded blob that no name
    /// points at, which is how a path segment carries one; the userinfo matcher covers
    /// `smb://user:secret@host`, where it sits in the authority; the path matcher covers the Xtream
    /// layout; a registered secret is found wherever it sits.
    @inline(__always)
    private static func match(in bytes: [UInt8], at index: Int, secrets: [[UInt8]], keys: Bool)
        -> Range<Int>?
    {
        if let secret = registeredSecretRange(in: bytes, at: index, secrets: secrets) { return secret }
        if keys, let value = matchedKeyLength(in: bytes, at: index)
            .flatMap({ valueRange(in: bytes, keyStart: index, keyEnd: index + $0) }) {
            return value
        }
        return authorizationSchemeRange(in: bytes, at: index)
            ?? encodedPayloadRange(in: bytes, at: index)
            ?? userInfoSecretRange(in: bytes, at: index)
            ?? xtreamPathSecretRange(in: bytes, at: index)
    }

    /// Every logical character of a line once, escapes followed through `%25` layers by
    /// `logicalByte`, with the raw offset each one starts at, so a range found in `decoded` maps back
    /// to whole escapes. Nil for a line without a valid escape, which keeps the streaming pass.
    private struct DecodedView {
        let decoded: [UInt8]
        /// `decoded.count + 1` entries; the last is the raw length.
        let rawStart: [Int]

        init?(_ bytes: [UInt8]) {
            guard bytes.withUnsafeBufferPointer({ memchr($0.baseAddress, 0x25, $0.count) }) != nil
            else { return nil }
            var k = 0
            var found = false
            while k + 2 < bytes.count {
                if bytes[k] == LogRedaction.percent, LogRedaction.hexValue(bytes[k + 1]) != nil,
                   LogRedaction.hexValue(bytes[k + 2]) != nil {
                    found = true
                    break
                }
                k += 1
            }
            guard found else { return nil }
            var decoded: [UInt8] = []
            decoded.reserveCapacity(bytes.count)
            var rawStart: [Int] = []
            rawStart.reserveCapacity(bytes.count + 1)
            var i = 0
            while i < bytes.count {
                let char = LogRedaction.logicalByte(in: bytes, at: i)
                decoded.append(char.byte)
                rawStart.append(i)
                i += char.width
            }
            rawStart.append(bytes.count)
            self.decoded = decoded
            self.rawStart = rawStart
        }
    }

    /// Raw length of the key starting here, or nil. The key must start on a boundary, else `token`
    /// would fire inside `hasToken`. A separator such as the `-` in `X-Emby-Token` or the `_` in
    /// `api_key` is a boundary; an ASCII letter or digit is not, unless it closes a percent escape
    /// whose decoded character is a separator.
    ///
    /// Audit NET-1: the key is read through `logicalByte`, so a URL logged inside another URL's query
    /// (`%26api%5Fkey%3D…`, or `%2526api%255Fkey%253D…` encoded twice) is matched like the plain form.
    private static func matchedKeyLength(in bytes: [UInt8], at index: Int) -> Int? {
        let first = logicalByte(in: bytes, at: index)
        guard keyInitials[Int(lowercased(first.byte))] else { return nil }
        if precededByWordCharacter(bytes, at: index), !startsCamelCaseWord(bytes, at: index) { return nil }
        for key in keys {
            var j = index
            var matched = true
            for keyByte in key {
                guard j < bytes.count else { matched = false; break }
                let char = logicalByte(in: bytes, at: j)
                guard lowercased(char.byte) == keyByte else { matched = false; break }
                j += char.width
            }
            if matched { return j - index }
        }
        return nil
    }

    /// Audit SUB-205: `apiToken`, `userToken`, `plexToken` start their key at a lower-to-upper step.
    /// `hasToken` and `refreshTokenAt` stay literal because `valueRange` still wants an `=` or `:` after.
    private static func startsCamelCaseWord(_ bytes: [UInt8], at index: Int) -> Bool {
        guard index > 0 else { return false }
        let here = bytes[index], before = bytes[index - 1]
        guard here >= UInt8(ascii: "A") && here <= UInt8(ascii: "Z"),
              before >= UInt8(ascii: "a") && before <= UInt8(ascii: "z") else { return false }
        // The lowercase word in front: `hasToken` and `isSecret` are flags, not credentials.
        var start = index
        while start > 0, bytes[start - 1] >= UInt8(ascii: "a"), bytes[start - 1] <= UInt8(ascii: "z") { start -= 1 }
        let word = String(decoding: bytes[start ..< index], as: UTF8.self)
        return !camelCaseFlagPrefixes.contains(word)
    }

    private static let camelCaseFlagPrefixes: Set<String> = [
        "has", "have", "had", "is", "was", "are", "needs", "need", "can", "should", "will", "does", "did",
    ]

    /// A table rather than a `Set`: this is asked at every position of every line, and hashing the
    /// byte cost more than the rest of an escape-free line's pass put together (measured).
    private static let keyInitials: [Bool] = {
        var table = [Bool](repeating: false, count: 256)
        for key in keys { table[Int(key[0])] = true }
        return table
    }()

    /// The span holding the secret, given the index just past the key. Covers the query form
    /// (`api_key=abc&next=1`), both header forms (`Token="abc"`, `X-Emby-Token: abc`) and the cookie
    /// form (`connect.sid=abc; Path=/`). Nil when there is no assignment or the value is empty, so
    /// `api_key=` and a bare mention in prose are left alone.
    ///
    /// Characters are read through `logicalByte`. A terminator ends the value only when it sits under
    /// no more encoding layers than the `=` did: inside a plain query `%26` is part of the value, inside
    /// an encoded one it is the `&` that ends it. With no escape in sight this is the byte scan it was.
    private static func valueRange(in bytes: [UInt8], keyStart: Int, keyEnd: Int) -> Range<Int>? {
        var i = keyEnd
        // Audit SUB-109: a JSON member or a dictionary description closes the key's quote before its
        // separator (`{"api_key":"…"}`, `["X-Emby-Token": "…"]`).
        if keyStart > 0, bytes[keyStart - 1] == UInt8(ascii: "\"") || bytes[keyStart - 1] == UInt8(ascii: "'"),
           i < bytes.count, bytes[i] == bytes[keyStart - 1] {
            i += 1
        }
        while i < bytes.count, case let char = logicalByte(in: bytes, at: i), char.byte == space {
            i += char.width
        }
        guard i < bytes.count else { return nil }
        let separator = logicalByte(in: bytes, at: i)
        guard separator.byte == UInt8(ascii: "=") || separator.byte == UInt8(ascii: ":") else {
            return nil
        }
        let isHeaderSeparator = separator.byte == UInt8(ascii: ":")
        let depth = separator.depth
        i += separator.width

        // Only a header separator may be followed by spaces. After `=` the value starts immediately:
        // a URL query and a cookie never space it out, and skipping here would let prose such as
        // "api_key= (missing)" read as a credential and swallow the rest of the line.
        var afterSpaces = i
        while afterSpaces < bytes.count, case let char = logicalByte(in: bytes, at: afterSpaces),
              char.byte == space {
            afterSpaces += char.width
        }
        // Audit SUB-205: `api_key: Optional("abc")` is how a Swift value prints.
        let optionalPrefix = Array("Optional(".utf8)
        if afterSpaces + optionalPrefix.count < bytes.count,
           Array(bytes[afterSpaces ..< afterSpaces + optionalPrefix.count]) == optionalPrefix {
            afterSpaces += optionalPrefix.count
        }
        var quote: UInt8?
        if afterSpaces < bytes.count, case let char = logicalByte(in: bytes, at: afterSpaces),
           char.depth <= depth, char.byte == UInt8(ascii: "\"") || char.byte == UInt8(ascii: "'") {
            quote = char.byte
            i = afterSpaces + char.width
        } else if isHeaderSeparator {
            i = afterSpaces
        }
        let start = i
        // Audit SUB-205: a request `Cookie:` header holds several pairs and every one is a credential,
        // so its value runs to the end of the line. `Set-Cookie:` carries one cookie and then attributes.
        let wholeLine = isHeaderSeparator && quote == nil
            && isRequestCookieKey(bytes, keyStart: keyStart, keyEnd: keyEnd)

        while i < bytes.count {
            let char = logicalByte(in: bytes, at: i)
            if char.depth <= depth {
                if quote != nil, char.byte == UInt8(ascii: "\\") {
                    // An escaped quote (or backslash) belongs to the value.
                    let next = i + char.width
                    if next < bytes.count { i = next + logicalByte(in: bytes, at: next).width } else { i = next }
                    continue
                }
                if let quote, char.byte == quote { break }
                if wholeLine {
                    if char.byte == 0x0A || char.byte == 0x0D { break }
                } else if quote == nil, isValueTerminator(char.byte),
                   endsValue(char, at: i, in: bytes, afterHeaderSeparator: isHeaderSeparator) {
                    break
                }
            }
            i += char.width
        }
        return start < i ? start ..< i : nil
    }

    private static func isRequestCookieKey(_ bytes: [UInt8], keyStart: Int, keyEnd: Int) -> Bool {
        guard keyEnd - keyStart == 6 else { return false }
        let cookie = Array("cookie".utf8)
        for (offset, byte) in cookie.enumerated() where lowercased(bytes[keyStart + offset]) != byte { return false }
        if keyStart >= 4, Array(bytes[keyStart - 4 ..< keyStart]).map(lowercased) == Array("set-".utf8) { return false }
        return true
    }

    /// Audit SUB-108: `: ; , ) >` are legal unescaped inside a query value, and a user-chosen
    /// password holds them, so after `=` one of them ends the value only where prose follows it (a
    /// terminator, a blank or the end of the line): `…&api_key=abc: timeout` and
    /// `connect.sid=abc; Path=/` still give their text back, `password=Pa:ss,word&…` goes whole. The
    /// header form keeps the wide set, since a header value is not a query value.
    private static func endsValue(_ char: (byte: UInt8, width: Int, depth: Int), at index: Int,
                                  in bytes: [UInt8], afterHeaderSeparator: Bool) -> Bool {
        guard !afterHeaderSeparator, isSoftTerminator(char.byte) else { return true }
        let next = index + char.width
        guard next < bytes.count else { return true }
        return isValueTerminator(logicalByte(in: bytes, at: next).byte)
    }

    // MARK: Percent escapes

    fileprivate static let percent = UInt8(ascii: "%")
    private static let space = UInt8(ascii: " ")

    /// A value encoded more often than this is not one a URL builder produces by accident.
    private static let maximumEncodingDepth = 4

    /// One character as a URL decoder would see it: a raw byte, or a `%XX` escape, followed through
    /// `%25` when the value was encoded more than once. `depth` is the number of layers (0 = raw).
    fileprivate static func logicalByte(in bytes: [UInt8], at index: Int)
        -> (byte: UInt8, width: Int, depth: Int)
    {
        let raw = bytes[index]
        guard raw == percent, index + 2 < bytes.count,
              let hi = hexValue(bytes[index + 1]), let lo = hexValue(bytes[index + 2]) else {
            return (raw, 1, 0)
        }
        var value = hi << 4 | lo
        var width = 3
        var depth = 1
        while value == percent, depth < maximumEncodingDepth, index + width + 1 < bytes.count,
              let nextHi = hexValue(bytes[index + width]), let nextLo = hexValue(bytes[index + width + 1]) {
            value = nextHi << 4 | nextLo
            width += 2
            depth += 1
        }
        return (value, width, depth)
    }

    /// Whether the character in front of `index` is a letter or digit, reading a percent escape that
    /// ends there (`%26`, `%2526`) as the character it decodes to.
    private static func precededByWordCharacter(_ bytes: [UInt8], at index: Int) -> Bool {
        guard index > 0, isLetterOrDigit(bytes[index - 1]) else { return false }
        guard index >= 3, let hi = hexValue(bytes[index - 2]), let lo = hexValue(bytes[index - 1]) else {
            return true
        }
        var k = index - 3
        var layers = 1
        while bytes[k] != percent {
            guard layers < maximumEncodingDepth, k >= 2,
                  bytes[k - 1] == UInt8(ascii: "2"), bytes[k] == UInt8(ascii: "5") else { return true }
            k -= 2
            layers += 1
        }
        return isLetterOrDigit(hi << 4 | lo)
    }

    fileprivate static func hexValue(_ b: UInt8) -> UInt8? {
        switch b {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return b - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return b - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return b - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    /// The secret inside a URL's userinfo, given an index that may start `://`. `smb://user:pw@host`
    /// and `https://user:pw@host` put the credential in the authority, where no key precedes it, so the
    /// key matcher cannot see it and `load url=` logs `absoluteString` whole. The user name is left
    /// readable: it identifies the account a line is about, and a diagnostic log that cannot say which
    /// account failed is worth less. Nil unless an `@` really terminates an authority, so prose such as
    /// "see http://a.test and foo@bar" is untouched: the scan stops at the first character that cannot
    /// appear in userinfo.
    private static func userInfoSecretRange(in bytes: [UInt8], at index: Int) -> Range<Int>? {
        guard index + 3 <= bytes.count,
              bytes[index] == UInt8(ascii: ":"),
              bytes[index + 1] == UInt8(ascii: "/"),
              bytes[index + 2] == UInt8(ascii: "/") else { return nil }
        let start = index + 3
        var i = start
        var colon: Int?
        var lastAt: Int?
        // Audit SUB-205: the last `@` of the authority ends the userinfo, so a password that holds a
        // raw `@` goes whole. A conforming URL percent-encodes it, a hand-built one does not.
        while i < bytes.count, !isAuthorityTerminator(bytes[i]) {
            if bytes[i] == UInt8(ascii: "@") { lastAt = i }
            if bytes[i] == UInt8(ascii: ":"), colon == nil, lastAt == nil { colon = i }
            i += 1
        }
        guard let at = lastAt else { return nil }
        i = at
        // With a colon the password is everything after it; without one the whole userinfo is the
        // secret (a bare token in the authority), and then the user name cannot be spared.
        let secretStart = colon.map { $0 + 1 } ?? start
        return secretStart < i ? secretStart ..< i : nil
    }

    // MARK: Registered secrets

    /// Shortest value `register` accepts. A literal match has no context to go by, so a one- or
    /// two-byte value would black out every occurrence of that text in every line.
    static let minimumSecretLength = 4

    private static let secretsLock = NSLock()
    nonisolated(unsafe) private static var _secrets: [String: (bytes: [UInt8], registrations: Int)] = [:]

    /// Snapshot taken once per line, so a register racing a redact sees the old set or the new one,
    /// never half of it. Sorted longest first, so a secret that contains another goes whole.
    private static var registeredSecrets: [[UInt8]] {
        secretsLock.lock(); defer { secretsLock.unlock() }
        return _secrets.isEmpty ? [] : _secrets.values.map(\.bytes).sorted { $0.count > $1.count }
    }

    /// Registers the value and its percent-encoded form, which is how it appears inside a URL path or
    /// query when it holds a character a URL cannot carry raw. Returns false for a value too short to
    /// match literally.
    ///
    /// Counted (audit SUB-109): two owners of the same value, two profiles sharing a password or two
    /// live servers, each unregister their own registration, and the value stays redacted until the
    /// last one has.
    @discardableResult
    static func register(_ secret: String) -> Bool {
        let forms = literalForms(of: secret)
        guard !forms.isEmpty else { return false }
        secretsLock.lock(); defer { secretsLock.unlock() }
        for form in forms {
            _secrets[form] = (Array(form.utf8), (_secrets[form]?.registrations ?? 0) + 1)
        }
        return true
    }

    static func unregister(_ secret: String) {
        let forms = literalForms(of: secret)
        secretsLock.lock(); defer { secretsLock.unlock() }
        for form in forms {
            guard let entry = _secrets[form] else { continue }
            _secrets[form] = entry.registrations > 1 ? (entry.bytes, entry.registrations - 1) : nil
        }
    }

    /// Whether `secret` is currently redacted as a registered literal.
    static func isRegistered(_ secret: String) -> Bool {
        secretsLock.lock(); defer { secretsLock.unlock() }
        return _secrets[secret] != nil
    }

    private static func literalForms(of secret: String) -> Set<String> {
        guard secret.utf8.count >= minimumSecretLength else { return [] }
        var forms: Set<String> = [secret]
        if let encoded = secret.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) { forms.insert(encoded) }
        if let encoded = secret.addingPercentEncoding(withAllowedCharacters: .alphanumerics) { forms.insert(encoded) }
        return forms
    }

    /// The span of a registered secret starting here, or nil. Exact bytes, no boundary rule: the host
    /// said this value must never be logged, so it goes even inside a longer word.
    private static func registeredSecretRange(in bytes: [UInt8], at index: Int, secrets: [[UInt8]]) -> Range<Int>? {
        for secret in secrets where index + secret.count <= bytes.count && bytes[index] == secret[0] {
            var matched = true
            for offset in 1 ..< secret.count where bytes[index + offset] != secret[offset] {
                matched = false
                break
            }
            if matched { return index ..< index + secret.count }
        }
        return nil
    }

    // MARK: Xtream Codes paths

    /// Path prefixes of the Xtream Codes stream layout, each paired with the zero-based positions of
    /// the segments after it that hold a credential. `/live/`, `/movie/`, `/series/` and `/timeshift/`
    /// carry `{user}/{password}/...`; the HLS redirect targets carry a session token first, and
    /// `/hlsr/` then repeats `{user}/{password}` behind it.
    private static let xtreamLayouts: [(prefix: [UInt8], secretSegments: [Int])] = [
        ("/live/", [1]), ("/movie/", [1]), ("/series/", [1]), ("/timeshift/", [1]),
        ("/hls/", [0]), ("/hlsr/", [0, 2]),
    ].map { (Array($0.0.utf8), $0.1) }

    /// The span from the first credential segment through the last one, given an index that may
    /// start one of `xtreamLayouts`' prefixes, or nil. The user name in front of the password is left
    /// readable for the same reason as in `userInfoSecretRange`; on `/hlsr/` it sits between the token
    /// and the password and goes with them, since one line yields one span.
    ///
    /// A credential segment only counts when a further path segment follows it, because that is what
    /// the layout guarantees and what an ordinary HLS path lacks: `/live/master.m3u8` and
    /// `/live/channel1/index.m3u8` stay whole. Over-redacting some other three-deep `/live/` path is
    /// the accepted cost.
    private static func xtreamPathSecretRange(in bytes: [UInt8], at index: Int) -> Range<Int>? {
        guard bytes[index] == UInt8(ascii: "/") else { return nil }
        for layout in xtreamLayouts where hasPrefix(layout.prefix, in: bytes, at: index) {
            var segments: [Range<Int>] = []
            var i = index + layout.prefix.count
            let needed = layout.secretSegments.max()! + 2
            while segments.count < needed {
                let start = i
                while i < bytes.count, bytes[i] != UInt8(ascii: "/"), !isPathTerminator(bytes[i]) { i += 1 }
                guard i > start else { break }
                segments.append(start ..< i)
                guard i < bytes.count, bytes[i] == UInt8(ascii: "/") else { break }
                i += 1
            }
            guard segments.count >= needed else { continue }
            return segments[layout.secretSegments.min()!].lowerBound ..< segments[layout.secretSegments.max()!].upperBound
        }
        return nil
    }

    private static func hasPrefix(_ prefix: [UInt8], in bytes: [UInt8], at index: Int) -> Bool {
        guard index + prefix.count <= bytes.count else { return false }
        for offset in 0 ..< prefix.count where bytes[index + offset] != prefix[offset] { return false }
        return true
    }

    /// Ends a URL path: the query, the fragment, or whatever the log line puts after the URL.
    private static func isPathTerminator(_ b: UInt8) -> Bool {
        switch b {
        case UInt8(ascii: "?"), UInt8(ascii: "#"), UInt8(ascii: "\""), UInt8(ascii: "'"),
             UInt8(ascii: ","), UInt8(ascii: ")"), UInt8(ascii: ">"), UInt8(ascii: " "), 0x09, 0x0A, 0x0D:
            return true
        default:
            return false
        }
    }

    /// Ends an authority component. `@` is deliberately absent: it is what the scan is looking for.
    private static func isAuthorityTerminator(_ b: UInt8) -> Bool {
        switch b {
        case UInt8(ascii: "/"), UInt8(ascii: "?"), UInt8(ascii: "#"), UInt8(ascii: "\""),
             UInt8(ascii: "'"), UInt8(ascii: ","), UInt8(ascii: ")"), UInt8(ascii: ">"),
             UInt8(ascii: " "), 0x09, 0x0A, 0x0D:
            return true
        default:
            return false
        }
    }

    /// Shortest encoded run worth decoding. `{"a":"b"}` is nine bytes, so twelve characters; anything
    /// shorter cannot be a JSON object and a credential blob is far longer than either.
    private static let minimumEncodedLength = 12

    /// The span of an encoded payload starting here, or nil.
    ///
    /// A path segment or a query value holding base64url-encoded JSON carries structure the URL never
    /// declares. No name precedes it, so `matchedKeyLength` cannot see it, and the list of names cannot
    /// be extended to reach it either: the names are INSIDE the payload and belong to whoever wrote it.
    /// The case this was reported for decodes to the keys `stores`, `c` and `t`, so even matching known
    /// names against the decoded JSON would walk past it. The encoding is the only honest signal, and an
    /// opaque blob answers no question a playback report asks, so the whole run goes.
    ///
    /// Gated hard before it allocates, because this runs per line on the demuxer and segment-producer
    /// paths: base64url of `{` always starts `e` and of `[` always `W`, so one byte comparison rejects
    /// very nearly every position, and only a run that survives that is ever decoded.
    private static func encodedPayloadRange(in bytes: [UInt8], at index: Int) -> Range<Int>? {
        guard bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "W") else { return nil }
        // A letter or digit in front means the run started earlier. A `-` or `_` does not: a blob
        // glued to a version prefix (`/v1-eyJ…`) is still a blob (audit SUB-104).
        if index > 0, isLetterOrDigit(bytes[index - 1]) { return nil }

        // Audit SUB-206: every `e` after a `-` is a start, so a run like `e-e-e-` would otherwise be scanned
        // and decoded from each one to its end. Two bytes of JSON syntax reject almost all of them before
        // anything is scanned, and a run past the cap is not a credential blob.
        guard startsLikeJSON(bytes, at: index) else { return nil }
        var end = index
        let scanLimit = min(bytes.count, index + maximumEncodedLength + 1)
        while end < scanLimit, isBase64URL(bytes[end]) { end += 1 }
        guard end - index >= minimumEncodedLength, end - index <= maximumEncodedLength,
              decodesToJSON(bytes[index ..< end]) else { return nil }

        // A JSON web token is three of these joined by dots, and the signature at the end is the part
        // worth stealing, so the whole token goes rather than the header that happened to match. A
        // header alone proves nothing: `{"alg":"HS256","typ":"JWT"}` is reconstructable by anyone.
        var extended = end
        while extended < bytes.count, bytes[extended] == UInt8(ascii: ".") {
            var run = extended + 1
            while run < bytes.count, isBase64URL(bytes[run]) { run += 1 }
            guard run > extended + 1 else { break }
            extended = run
        }
        return index ..< extended
    }

    private static let maximumEncodedLength = 16 * 1024

    /// Whether the first two decoded bytes of the run read as the opening of a JSON object or array.
    static func startsLikeJSON(_ bytes: [UInt8], at index: Int) -> Bool {
        func sextet(_ b: UInt8) -> UInt8? {
            switch b {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"): return b - UInt8(ascii: "A")
            case UInt8(ascii: "a")...UInt8(ascii: "z"): return b - UInt8(ascii: "a") + 26
            case UInt8(ascii: "0")...UInt8(ascii: "9"): return b - UInt8(ascii: "0") + 52
            case UInt8(ascii: "-"), UInt8(ascii: "+"): return 62
            case UInt8(ascii: "_"), UInt8(ascii: "/"): return 63
            default: return nil
            }
        }
        guard index + 2 < bytes.count, let a = sextet(bytes[index]), let b = sextet(bytes[index + 1]),
              let c = sextet(bytes[index + 2]) else { return false }
        let first = a << 2 | b >> 4
        let second = (b & 0x0f) << 4 | c >> 2
        let whitespace = second == 0x20 || second == 0x09 || second == 0x0a || second == 0x0d
        switch first {
        case UInt8(ascii: "{"):
            return whitespace || second == UInt8(ascii: "\"") || second == UInt8(ascii: "}")
        case UInt8(ascii: "["):
            return whitespace || second == UInt8(ascii: "\"") || second == UInt8(ascii: "[")
                || second == UInt8(ascii: "{") || second == UInt8(ascii: "]") || second == UInt8(ascii: "-")
                || (second >= UInt8(ascii: "0") && second <= UInt8(ascii: "9"))
                || second == UInt8(ascii: "t") || second == UInt8(ascii: "f") || second == UInt8(ascii: "n")
        default:
            return false
        }
    }

    /// Whether the run decodes as base64url into a JSON object or array. `JSONSerialization` without
    /// `.fragmentsAllowed` is the test rather than a resemblance check: a bare number or string would
    /// otherwise let ordinary text through as a payload, and an episode file named `Eyewitness…` gets
    /// as far as the decode and no further.
    private static func decodesToJSON(_ run: ArraySlice<UInt8>) -> Bool {
        var encoded = String(decoding: run, as: UTF8.self)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    private static func isBase64URL(_ b: UInt8) -> Bool {
        isLetterOrDigit(b) || b == UInt8(ascii: "-") || b == UInt8(ascii: "_")
    }

    // MARK: Authorization schemes

    private static let authorizationSchemes: [[UInt8]] = ["bearer", "basic"].map { Array($0.utf8) }

    /// A credential after an `Authorization` scheme shorter than this is prose ("bearer token",
    /// "basic realm"), not a credential. Sodalite's copy uses the same floor.
    private static let minimumSchemeCredentialLength = 16

    /// The credential after `Bearer ` or `Basic `, or nil (audit SUB-109). The scheme has no `=` or
    /// `:` of its own, so the key matcher cannot see it, and `Authorization` is not a key: the
    /// Jellyfin form of that header carries readable fields around its token.
    private static func authorizationSchemeRange(in bytes: [UInt8], at index: Int) -> Range<Int>? {
        let first = lowercased(bytes[index])
        guard first == UInt8(ascii: "b") else { return nil }
        if index > 0, isLetterOrDigit(bytes[index - 1]) { return nil }
        for scheme in authorizationSchemes where index + scheme.count < bytes.count {
            var matched = true
            for offset in 1 ..< scheme.count where lowercased(bytes[index + offset]) != scheme[offset] {
                matched = false
                break
            }
            guard matched else { continue }
            var i = index + scheme.count
            guard isBlank(bytes[i]) else { continue }
            while i < bytes.count, isBlank(bytes[i]) { i += 1 }
            let start = i
            while i < bytes.count, isToken68(bytes[i]) { i += 1 }
            if i - start >= minimumSchemeCredentialLength { return start ..< i }
            // Audit SUB-205: base64 of a short `user:pass` is under the floor, but after the
            // `Authorization` name it is a credential, not prose.
            if i - start >= minimumNamedSchemeCredentialLength, followsAuthorizationName(bytes, schemeStart: index) {
                return start ..< i
            }
        }
        return nil
    }

    private static let minimumNamedSchemeCredentialLength = 6

    private static func followsAuthorizationName(_ bytes: [UInt8], schemeStart: Int) -> Bool {
        var k = schemeStart
        while k > 0, isBlank(bytes[k - 1]) || bytes[k - 1] == UInt8(ascii: ":") || bytes[k - 1] == UInt8(ascii: "=")
                || bytes[k - 1] == UInt8(ascii: "\"") || bytes[k - 1] == UInt8(ascii: "'") { k -= 1 }
        let name = Array("authorization".utf8)
        guard k >= name.count else { return false }
        for (offset, byte) in name.enumerated() where lowercased(bytes[k - name.count + offset]) != byte {
            return false
        }
        return true
    }

    private static func isToken68(_ b: UInt8) -> Bool {
        isBase64URL(b) || b == UInt8(ascii: ".") || b == UInt8(ascii: "~") || b == UInt8(ascii: "+")
            || b == UInt8(ascii: "/") || b == UInt8(ascii: "=")
    }

    private static func isBlank(_ b: UInt8) -> Bool {
        b == space || b == 0x09
    }

    /// Audit SUB-108: the terminators that are also legal inside a query value.
    private static func isSoftTerminator(_ b: UInt8) -> Bool {
        b == UInt8(ascii: ":") || b == UInt8(ascii: ";") || b == UInt8(ascii: ",")
            || b == UInt8(ascii: ")") || b == UInt8(ascii: ">")
    }

    /// `:` counts, so `…&api_key=abc: timeout` gives the token back and keeps the error text, though
    /// after `=` only where prose follows it (`endsValue`).
    private static func isValueTerminator(_ b: UInt8) -> Bool {
        switch b {
        case UInt8(ascii: "&"), UInt8(ascii: ";"), UInt8(ascii: ","), UInt8(ascii: ")"),
             UInt8(ascii: ">"), UInt8(ascii: ":"), UInt8(ascii: "\""), UInt8(ascii: "'"),
             UInt8(ascii: " "), 0x09, 0x0A, 0x0D:
            return true
        default:
            return false
        }
    }

    private static func isLetterOrDigit(_ b: UInt8) -> Bool {
        (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z"))
            || (b >= UInt8(ascii: "A") && b <= UInt8(ascii: "Z"))
            || (b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9"))
    }

    private static func lowercased(_ b: UInt8) -> UInt8 {
        (b >= UInt8(ascii: "A") && b <= UInt8(ascii: "Z")) ? b + 32 : b
    }
}
