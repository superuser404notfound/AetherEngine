import Foundation
import Testing
@testable import AetherEngine

/// The engine logs whole URLs so a report can be diagnosed from host, path and query. Media servers put
/// the access token in that same query, and `EngineLog` emits with `.public` privacy into OSLog plus
/// whatever handler the host installed, so an unredacted line is a live credential in a Console.app
/// capture, a sysdiagnose, and every in-app log a host builds on the handler.
/// Serialized: the secret-registry tests mutate process-global redaction state.
@Suite("EngineLog credential stripping", .serialized)
struct LogRedactionTests {

    private let token = "9f2c1ab34de5470fa1b6c8d90e7f2a11"

    @Test("a media-server stream URL loses its api_key and keeps what diagnoses the report")
    func streamURLQuery() {
        let line = LogRedaction.redact(
            "[AetherEngine] load url=https://media.example.org/Videos/abc123/stream.mkv" +
            "?api_key=\(token)&Static=true&MediaSourceId=abc123 source-format=mkv"
        )
        #expect(!line.contains(token))
        #expect(line.contains("api_key=<redacted>"))
        #expect(line.contains("media.example.org/Videos/abc123/stream.mkv"))
        #expect(line.contains("Static=true"))
        #expect(line.contains("MediaSourceId=abc123"))
        #expect(line.hasSuffix("source-format=mkv"))
    }

    @Test("the generic credential parameter names are covered", arguments: [
        "api_key", "ApiKey", "access_token", "token", "password", "secret", "signature",
        "X-Emby-Token", "X-MediaBrowser-Token",
    ])
    func genericKeyNames(key: String) {
        let line = LogRedaction.redact("[x] https://s/a?\(key)=\(token)&keep=1")
        #expect(!line.contains(token))
        #expect(line == "[x] https://s/a?\(key)=<redacted>&keep=1")
    }

    @Test("the quoted header form is stripped inside its quotes")
    func quotedHeaderForm() {
        let line = LogRedaction.redact(#"Authorization: MediaBrowser Client="Host", Token="\#(token)", Device="TV""#)
        #expect(!line.contains(token))
        #expect(line.contains(#"Token="<redacted>""#))
        #expect(line.contains(#"Client="Host""#))
        #expect(line.contains(#"Device="TV""#))
    }

    @Test("the colon-separated header form is stripped")
    func colonSeparatedHeader() {
        let line = LogRedaction.redact("[http] X-Emby-Token: \(token) sent")
        #expect(line == "[http] X-Emby-Token: <redacted> sent")
    }

    @Test("a session cookie is stripped up to the attribute separator")
    func cookieForm() {
        let line = LogRedaction.redact("[net] connect.sid=s%3Aabc.def+ghi; Path=/; HttpOnly")
        #expect(!line.contains("s%3Aabc.def"))
        #expect(line == "[net] connect.sid=<redacted>; Path=/; HttpOnly")
    }

    @Test("a colon after the value ends it, so the error text survives")
    func colonTerminatesTheValue() {
        let line = LogRedaction.redact("[Image] fetch failed https://s/i?ApiKey=\(token): timeout")
        #expect(line.hasSuffix(": timeout"))
        #expect(line.contains("ApiKey=<redacted>"))
    }

    /// The broad `token` and `secret` keys must not fire mid-identifier, or the per-second counters the
    /// engine exists to report start reading as redactions.
    @Test("a key substring inside another identifier is left alone", arguments: [
        "[session] hasToken=true refreshTokenAt=120s",
        "[SWDiag] enq=48 layerDrop=0 delay=0.02 cushion=1.8",
        "[LiveDirect] eligible: route=hls tuner=file",
        "[HLSVideoEngine] serving on http://127.0.0.1:52341/master.m3u8 (dvModeAvailable=true)",
        "[DisplayCriteria] refreshRate=23.976 videoRange=HLG",
    ])
    func doesNotFireMidIdentifier(line: String) {
        #expect(LogRedaction.redact(line) == line)
    }

    @Test("an empty value and a bare mention are left alone")
    func nothingToStrip() {
        #expect(LogRedaction.redact("[auth] api_key= (missing)") == "[auth] api_key= (missing)")
        #expect(LogRedaction.redact("no token was supplied") == "no token was supplied")
    }

    @Test("several credentials in one line are all stripped")
    func multiplePerLine() {
        let line = LogRedaction.redact("a=1&api_key=\(token)&b=2&access_token=\(token)&c=3")
        #expect(!line.contains(token))
        #expect(line == "a=1&api_key=<redacted>&b=2&access_token=<redacted>&c=3")
    }

    // MARK: - Credentials that no key name points at

    /// Reported privately against 6.70.0. Several debrid and proxy add-ons in the Stremio ecosystem
    /// carry the account token in a PATH segment, as base64url-encoded JSON, with no parameter name
    /// anywhere near it, so every matcher above walks straight past it.
    ///
    /// Adding names cannot reach this one, and the decoded payload is why: its keys are `stores`, `c`
    /// and `t`. Matching key names inside the decoded JSON would still miss it. The encoding itself is
    /// the only thing that marks the segment as a carrier, so that is what this matches on.
    @Test("a credential encoded into a path segment goes, although nothing in the line names it")
    func encodedPathSegment() {
        // {"stores":[{"c":"tb","t":"9f2c1ab34de5470fa1b6c8d90e7f2a11abcd"}]}
        let segment = "eyJzdG9yZXMiOlt7ImMiOiJ0YiIsInQiOiI5ZjJjMWFiMzRkZTU0NzBmYTFiNmM4ZDkwZTdmMmExMWFiY2QifV19"
        let line = LogRedaction.redact(
            "[AetherEngine] load url=https://proxy.example.org/stremio/torz/\(segment)" +
            "/_/strem/tt0111161/tb/9a3f/0/Some.Film.2009.mkv source-format=mkv"
        )
        #expect(!line.contains(segment))
        #expect(!line.contains("ImMiOiJ0YiIsInQi"))
        #expect(line.contains("/stremio/torz/<redacted>/_/strem/"))
        #expect(line.contains("proxy.example.org"))
        #expect(line.contains("Some.Film.2009.mkv"))
        #expect(line.hasSuffix("source-format=mkv"))
    }

    /// The same shape without a key name, in the other place a URL hides one. `config=` is not a
    /// credential parameter and never will be, so the value has to answer for itself.
    @Test("an encoded blob in a query value goes even though its parameter is not a credential name")
    func encodedQueryValue() {
        let segment = "eyJzdG9yZXMiOlt7ImMiOiJ0YiIsInQiOiI5ZjJjMWFiMzRkZTU0NzBmYTFiNmM4ZDkwZTdmMmExMWFiY2QifV19"
        let line = LogRedaction.redact("[x] https://s/a?config=\(segment)&Static=true")
        #expect(!line.contains(segment))
        #expect(line == "[x] https://s/a?config=<redacted>&Static=true")
    }

    /// A bearer token is the other nameless carrier: `Authorization` is not a credential key, `Bearer`
    /// is a scheme, and the secret is the signature at the end. All three parts go, since a JWT missing
    /// only its header is still a JWT to anyone who knows the algorithm.
    @Test("a bearer JSON web token goes whole, signature included")
    func bearerJSONWebToken() {
        let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
            + ".eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4ifQ"
            + ".dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXkw"
        let line = LogRedaction.redact("[http] GET /Items Authorization: Bearer \(jwt)")
        #expect(!line.contains("dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXkw"))
        #expect(!line.contains("eyJzdWIiOiIxMjM0NTY3ODkw"))
        #expect(line == "[http] GET /Items Authorization: Bearer <redacted>")
    }

    /// The other nameless carrier, found by comparing this file against the copy Sodalite kept: a URL
    /// can put the credential in its authority, where no key precedes it either. `load url=` logs
    /// `absoluteString`, so a share opened as `smb://user:pw@host` or a server behind basic auth walked
    /// straight into all three sinks. The user name stays: a log that cannot say which account failed
    /// is worth less, and the name is not the secret.
    @Test("a password in the authority goes, and the account name it identifies stays", arguments: [
        "smb://media-ro:\(#"hunter2secretpw"#)@nas.local/Films/A.mkv",
        "https://media-ro:\(#"hunter2secretpw"#)@jf.example.org/Videos/abc/stream.mkv",
    ])
    func userInfoInTheAuthority(url: String) {
        let line = LogRedaction.redact("[AetherEngine] load url=\(url) source-format=mkv")
        #expect(!line.contains("hunter2secretpw"))
        #expect(line.contains("media-ro:<redacted>@"))
        #expect(line.hasSuffix("source-format=mkv"))
    }

    /// The gate has to be the encoding, not a resemblance to it. An episode file that happens to start
    /// with the same two letters, an item id, a hash: all of these are what a playback report is
    /// actually diagnosed from, and none of them may be swallowed.
    @Test("an ordinary segment that merely looks encoded is left alone", arguments: [
        "[AetherEngine] load url=https://s/Videos/Eyewitness.S01E04.mkv source-format=mkv",
        "[AetherEngine] load url=https://s/Videos/eyewitness-report-2011.mkv source-format=mkv",
        "[AetherEngine] load url=https://s/Videos/a1b2c3d4e5f60718293a4b5c6d7e8f90/stream.mkv?Static=true",
        "[hls.server] GET /master.m3u8 -> 200",
    ])
    func ordinarySegmentsSurvive(line: String) {
        #expect(LogRedaction.redact(line) == line)
    }

    @Test("an Xtream Codes path loses its password and keeps the account name", arguments: [
        ("http://h:8080/live/john/S3cretPass/12345.m3u8", "http://h:8080/live/john/<redacted>/12345.m3u8"),
        ("http://h:8080/movie/john/S3cretPass/678.mkv", "http://h:8080/movie/john/<redacted>/678.mkv"),
        ("http://h:8080/series/john/S3cretPass/901.mkv", "http://h:8080/series/john/<redacted>/901.mkv"),
        ("http://h:8080/timeshift/john/S3cretPass/60/2026-09-24:20-00/12345.ts",
         "http://h:8080/timeshift/john/<redacted>/60/2026-09-24:20-00/12345.ts"),
        ("http://h:8080/hls/a1b2c3d4e5/12345_3.ts", "http://h:8080/hls/<redacted>/12345_3.ts"),
        ("http://h:8080/hlsr/a1b2c3d4e5/john/S3cretPass/12345/1/7.ts", "http://h:8080/hlsr/<redacted>/12345/1/7.ts"),
    ])
    func xtreamPath(url: String, expected: String) {
        let line = LogRedaction.redact("[AetherEngine] load url=\(url) source-format=hls")
        #expect(line == "[AetherEngine] load url=\(expected) source-format=hls")
    }

    @Test("an ordinary path under the same prefixes is left alone", arguments: [
        "https://origin.example/live/master.m3u8",
        "https://origin.example/live/channel1/index.m3u8",
        "https://origin.example/movie/trailer.mp4",
        "https://origin.example/live/ch1/index.m3u8?x=1",
        "https://jellyfin.example/LiveTv/LiveStreamFiles/abc/stream.ts",
    ])
    func ordinaryPrefixedPathsSurvive(url: String) {
        #expect(LogRedaction.redact("[x] url=\(url) ok") == "[x] url=\(url) ok")
    }

    @Test("a URL logged percent-encoded inside another URL's query loses its token (audit NET-1)")
    func percentEncodedNestedURL() {
        // The exact shape the pre-NET-1 origin relay logged on every request.
        let origin = "https://jf.example.com/Videos/abc/master.m3u8?MediaSourceId=x&api_key=\(token)&Tag=7"
        let encoded = origin.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let lines = [
            "[HLSLocalServer] GET /deadbeef/aether-origin-relay?origin=\(encoded) HTTP/1.1 fd=12",
            "[NativeAVPlayerHost] #3 load url=http://127.0.0.1:50123/deadbeef/aether-origin-relay?origin=\(encoded)",
        ]
        for line in lines {
            let out = LogRedaction.redact(line)
            #expect(!out.contains(token), "leaked: \(out)")
            #expect(out.contains("api%5Fkey%3D<redacted>%26Tag%3D7"), "\(out)")
            #expect(out.contains("MediaSourceId%3Dx"), "diagnostic context went with it: \(out)")
        }
        let tail = LogRedaction.redact("GET /x?origin=\(encoded) HTTP/1.1 fd=12")
        #expect(tail.hasSuffix(" HTTP/1.1 fd=12"))
    }

    @Test("a doubly encoded token is stripped too")
    func doublyEncodedNestedURL() {
        let once = "https://s/a?b=1&X-Emby-Token=\(token)&keep=1"
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let twice = once.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let out = LogRedaction.redact("[x] outer?u=\(twice)&z=2")
        #expect(!out.contains(token), "leaked: \(out)")
        #expect(out.contains("<redacted>%2526keep%253D1&z=2"), "\(out)")
    }

    @Test("an encoded separator inside a plain query value stays part of the value")
    func encodedAmpersandInPlainValue() {
        // At depth 0 a `%26` is data in the value, not the `&` that ends it, so the whole value goes.
        let out = LogRedaction.redact("[x] https://s/a?api_key=abc%26def&keep=1")
        #expect(out == "[x] https://s/a?api_key=<redacted>&keep=1")
    }

    @Test("an escape that decodes to a letter is no boundary, and prose with percent signs is left alone")
    func encodedBoundaryRules() {
        // `%73` is `s`, so this reads `hasToken=` and must stay, like its plain form.
        let letter = "[x] ha%73Token=visible"
        #expect(LogRedaction.redact(letter) == letter)
        let prose = "[x] buffer 100% full, 5%token budget, 12%3 left"
        #expect(LogRedaction.redact(prose) == prose)
        #expect(LogRedaction.redact("[x] a%2Ftoken%3Asecretvalue done") == "[x] a%2Ftoken%3A<redacted> done")
    }

    @Test("a registered secret goes wherever it sits, raw or percent-encoded, until unregistered")
    func registeredSecret() {
        #expect(EngineLog.registerSecret("p@ss w0rd"))
        let raw = LogRedaction.redact("[x] http://h:8080/john/p%40ss%20w0rd/123 alt=p@ss w0rd.")
        #expect(raw == "[x] http://h:8080/john/<redacted>/123 alt=<redacted>.")
        EngineLog.unregisterSecret("p@ss w0rd")
        #expect(LogRedaction.redact("[x] alt=p@ss w0rd") == "[x] alt=p@ss w0rd")
    }

    @Test("a value too short to match literally is refused")
    func shortSecretRefused() {
        #expect(!EngineLog.registerSecret("abc"))
        #expect(LogRedaction.redact("[x] abc") == "[x] abc")
    }

    /// Audit SUB-109: `registerSecret` was a set, so the second owner of a value unregistering it
    /// (logout of one of two profiles sharing a password) unmasked it for the first.
    @Test("a secret registered twice stays redacted until both registrations are gone")
    func registrationsAreCounted() {
        let secret = "sh4redPassw0rd"
        #expect(EngineLog.registerSecret(secret))
        #expect(EngineLog.registerSecret(secret))
        EngineLog.unregisterSecret(secret)
        #expect(LogRedaction.redact("[x] pw=\(secret)x") == "[x] pw=<redacted>x")
        EngineLog.unregisterSecret(secret)
        #expect(LogRedaction.redact("[x] v=\(secret)x") == "[x] v=\(secret)x")
    }

    // MARK: - Nameless shapes inside a percent-encoded URL (audit SUB-104)

    /// An IPTV proxy or a debrid wrapper carries the upstream URL percent-encoded in its own query.
    /// The key forms of that were covered by NET-1; the shapes that need no key only matched raw.
    @Test("a nameless credential inside a percent-encoded URL goes", arguments: [
        ("url=http://proxy/x?u=http%3A%2F%2Fiptv.example%2Flive%2Falice%2FSECRETpass%2F1234.ts",
         "url=http://proxy/x?u=http%3A%2F%2Fiptv.example%2Flive%2Falice%2F<redacted>%2F1234.ts"),
        ("u=http%3A%2F%2Faddon%2FeyJzdG9yZXMiOlsiYSJdLCJjIjoiU0VDUkVUeHl6IiwidCI6InQifQ%2Fmanifest.json",
         "u=http%3A%2F%2Faddon%2F<redacted>%2Fmanifest.json"),
        ("u=smb%3A%2F%2Fbob%3ASECRETpw%40nas%2Fshare", "u=smb%3A%2F%2Fbob%3A<redacted>%40nas%2Fshare"),
        ("http://addon/v1-eyJzdG9yZXMiOlsiYSJdLCJjIjoiU0VDUkVUeHl6IiwidCI6InQifQ/manifest.json",
         "http://addon/v1-<redacted>/manifest.json"),
    ])
    func namelessShapesThroughEscapes(input: String, expected: String) {
        #expect(LogRedaction.redact(input) == expected)
    }

    @Test("the same shapes encoded twice go too", arguments: [
        "http://iptv.example/live/alice/SECRETpass/1234.ts",
        "http://addon/eyJzdG9yZXMiOlsiYSJdLCJjIjoiU0VDUkVUeHl6IiwidCI6InQifQ/manifest.json",
        "smb://bob:SECRETpw@nas/share",
    ])
    func namelessShapesEncodedTwice(upstream: String) {
        let once = upstream.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let twice = once.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let out = LogRedaction.redact("[NativeAVPlayerHost] #1 load url=https://mfp.example/p?d=\(twice) startPos=nil")
        for secret in ["SECRETpass", "SECRETpw", "U0VDUkVUeHl6"] { #expect(!out.contains(secret), "\(out)") }
        #expect(out.contains("<redacted>"))
        #expect(out.hasSuffix(" startPos=nil"))
    }

    /// NET-114: `"\(error)"` of a URLError prints the failing URL twice through its userInfo.
    @Test("an interpolated URLError loses the encoded upstream credential of its failing URL")
    func urlErrorDescription() {
        let upstream = "http://iptv/live/alice/SECRETpass/1.ts"
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let failing = "http://127.0.0.1:1/live/playlist.m3u8?u=\(upstream)"
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut,
                            userInfo: [NSURLErrorFailingURLStringErrorKey: failing,
                                       NSURLErrorFailingURLErrorKey: URL(string: failing)!])
        let out = LogRedaction.redact("[HLSVODIngest] carriage probe inconclusive: \(error)")
        #expect(!out.contains("SECRETpass"), "\(out)")
    }

    @Test("an error summary names the URL error code and host, never the failing URL")
    func errorSummaryDropsTheURL() throws {
        let failing = try #require(URL(string: "http://iptv.example:8080/get.php?username=u&password=Pa:ss"))
        let urlError = URLError(.timedOut, userInfo: [NSURLErrorFailingURLErrorKey: failing,
                                                      NSURLErrorFailingURLStringErrorKey: failing.absoluteString])
        let summary = EngineLog.summary(of: urlError)
        #expect(summary == "NSURLError \(NSURLErrorTimedOut) from iptv.example")
        #expect(EngineLog.summary(of: HLSIngestError.playlistUnreachable(status: 403))
                == "playlistUnreachable(403)")
    }

    @Test("an escape-heavy line with nothing secret in it comes back unchanged", arguments: [
        "[ffmpeg] Opening 'https://s/Videos/My%20Movie%20(2009)/stream.mkv' for reading",
        "[x] url=https://s/Shows/Show%20Name/Season%2001/Show%20Name%20-%20S01E01.mkv ok",
        "[x] path=%2Fmedia%2Flive%2Fchannel1%2Findex.m3u8 ok",
        "[HLSLocalServer] GET /0123/aether-origin-relay?ref=eW91IGNhbm5vdCByZWFkIHRoaXM_3kJ-qZ HTTP/1.1 fd=9",
    ])
    func escapesWithoutSecretsSurvive(line: String) {
        #expect(LogRedaction.redact(line) == line)
    }

    // MARK: - Query values that hold a terminator (audit SUB-108)

    @Test("a query password holding : ; , ) or > goes whole", arguments: [":", ";", ",", ")", ">"])
    func queryPasswordWithPunctuation(mark: String) {
        let out = LogRedaction.redact("https://h/get.php?username=u&password=SECRET\(mark)tail123&type=m3u")
        #expect(out == "https://h/get.php?username=u&password=<redacted>&type=m3u")
    }

    @Test("punctuation that prose puts after a value still ends it")
    func proseAfterAValue() {
        #expect(LogRedaction.redact("[x] fetch failed (api_key=abc), retrying")
                == "[x] fetch failed (api_key=<redacted>), retrying")
        #expect(LogRedaction.redact("[x] seen <token=abc>") == "[x] seen <token=<redacted>>")
    }

    // MARK: - Credential names outside Jellyfin and Xtream (audit SUB-109)

    @Test("the other backends' credential names are covered", arguments: [
        ("Authorization: Bearer SECRETopaque12345", "Authorization: Bearer <redacted>"),
        ("Authorization: Basic dmluY2VudDpzZWNyZXQxMjM0", "Authorization: Basic <redacted>"),
        ("Cookie: PHPSESSID=SECRETsess123; other=1", "Cookie: <redacted>"),
        ("Set-Cookie: session=SECRETsess123; Path=/", "Set-Cookie: <redacted>; Path=/"),
        ("X-Api-Key: SECRETkey123", "X-Api-Key: <redacted>"),
        ("https://h/a?api-key=SECRETkey123&x=1", "https://h/a?api-key=<redacted>&x=1"),
        (#"{"api_key":"SECRETjson123"}"#, #"{"api_key":"<redacted>"}"#),
        (#"["X-Emby-Token": "SECRETjson123"]"#, #"["X-Emby-Token": "<redacted>"]"#),
        ("https://h/p.php?user=u&pwd=SECRETkey123", "https://h/p.php?user=u&pwd=<redacted>"),
        ("https://h/p.php?user=u&passwd=SECRETkey123", "https://h/p.php?user=u&passwd=<redacted>"),
        ("authToken=SECRETrt123 done", "authToken=<redacted> done"),
        ("refreshToken=SECRETrt123 done", "refreshToken=<redacted> done"),
        ("sessionToken=SECRETrt123 done", "sessionToken=<redacted> done"),
        ("auth_token=SECRETrt123 done", "auth_token=<redacted> done"),
        ("https://h/a?sessionid=SECRETsid123&session_id=SECRETsid456", "https://h/a?sessionid=<redacted>&session_id=<redacted>"),
    ])
    func otherBackendNames(input: String, expected: String) {
        #expect(LogRedaction.redact(input) == expected)
    }

    @Test("prose around the new names is left alone", arguments: [
        "[http] 401 with WWW-Authenticate: Bearer realm=\"fixture\"",
        "[auth] a bearer token was sent",
        "[auth] basic auth failed",
        "[x] X-Playback-Session-Id: 5A0C2D7E-1234",
        "[x] no cookie was set",
    ])
    func proseAroundNewNames(line: String) {
        #expect(LogRedaction.redact(line) == line)
    }

    /// Audit OPS-106: aetherctl printed the source URL in its own banner, outside the funnel, so the
    /// first line of a pasted transcript undid the redaction of every engine line below it.
    @Test("a line a tool prints itself gets the funnel's redaction")
    func redactedForATool() {
        #expect(EngineLog.redacted("aetherctl probe: http://h:8080/live/john/S3cretPass/1.ts?api_key=\(token)")
                == "aetherctl probe: http://h:8080/live/john/<redacted>/1.ts?api_key=<redacted>")
    }

    /// The point of putting this in EngineLog rather than in each host: the handler a host installs
    /// must never see the raw token, whether or not that host scrubs its own log.
    @Test("the host handler receives the redacted line")
    func handlerSeesRedactedLine() {
        let box = EngineLogCapture()
        defer { box.end() }

        EngineLog.emit("[test-496a] load url=https://s/v?api_key=\(token)&Static=true", category: .engine)

        // #496: the handler is a process-wide singleton, so every line any concurrently running
        // suite emits lands in this box too. Assert on THIS test's line, not on the box.
        let captured = box.lines.filter { $0.contains("[test-496a]") }
        #expect(captured.count == 1)
        #expect(captured.first?.contains("api_key=<redacted>") == true)
        #expect(captured.first?.contains(token) == false)
        #expect(captured.first?.contains("Static=true") == true)
    }

    // MARK: - Remaining credential shapes (audit SUB-205, SUB-206)

    @Test("a camelCase credential name is matched, an identifier without an assignment is not", arguments: [
        ("apiToken=SECRETab12 done", "apiToken=<redacted> done"),
        ("userToken: SECRETab12", "userToken: <redacted>"),
        ("plexToken=SECRETab12&x=1", "plexToken=<redacted>&x=1"),
        ("dbPassword=SECRETab12 ok", "dbPassword=<redacted> ok"),
        ("[session] hasToken=true refreshTokenAt=120s", "[session] hasToken=true refreshTokenAt=120s"),
    ])
    func camelCaseNames(input: String, expected: String) {
        #expect(LogRedaction.redact(input) == expected)
    }

    @Test("every pair of a request Cookie header goes, a Set-Cookie keeps its attributes")
    func cookieHeaderPairs() {
        #expect(LogRedaction.redact("Cookie: lang=en; PHPSESSID=SECRETabc") == "Cookie: <redacted>")
        #expect(LogRedaction.redact("Set-Cookie: session=SECRETabc; Path=/") == "Set-Cookie: <redacted>; Path=/")
    }

    @Test("a Swift optional and an escaped quote do not leave the tail of the value")
    func optionalAndEscapedQuote() {
        #expect(LogRedaction.redact(#"api_key: Optional("SECRETabc")"#) == #"api_key: Optional("<redacted>")"#)
        #expect(LogRedaction.redact(#"{"password":"ab\"cd","x":1}"#) == #"{"password":"<redacted>","x":1}"#)
    }

    @Test("a short Basic credential after the Authorization name is redacted, prose is not")
    func shortBasicCredential() {
        #expect(LogRedaction.redact("Authorization: Basic dTpwYXNz") == "Authorization: Basic <redacted>")
        #expect(LogRedaction.redact("falling back to basic realm") == "falling back to basic realm")
    }

    @Test("a raw @ inside the password stays inside the redacted span")
    func atSignInPassword() {
        #expect(LogRedaction.redact("smb://user:p@ss@host/share") == "smb://user:<redacted>@host/share")
        #expect(LogRedaction.redact("see http://a.test and foo@bar") == "see http://a.test and foo@bar")
    }

    /// The scan used to start at every `e` after a `-` and run to the end of the line, quadratic on
    /// `e-e-e-...`. The JSON prefilter rejects those starts before any scan; checked directly, since a
    /// wall-clock bound flaked under the parallel suite.
    @Test("a long run of e- starts is rejected before any scan")
    func repeatedEncodedStarts() {
        let run = Array(("https://h/" + String(repeating: "e-", count: 32 * 1024)).utf8)
        let starts = run.indices.filter { run[$0] == UInt8(ascii: "e") }
        #expect(starts.allSatisfy { !LogRedaction.startsLikeJSON(run, at: $0) })
        #expect(LogRedaction.startsLikeJSON(Array("eyJzdG9y".utf8), at: 0))
        let line = String(decoding: run, as: UTF8.self)
        #expect(LogRedaction.redact(line) == line)
        let blob = "http://addon/v1-eyJzdG9yZXMiOlsiYSJdLCJjIjoiU0VDUkVUeHl6IiwidCI6InQifQ/manifest.json"
        #expect(!LogRedaction.redact(blob).contains("eyJzdG9yZXM"))
    }

    /// `.verbose` never reaches the handler; it still goes to OSLog, which is why redaction sits on the
    /// shared funnel and not on the `.info` branch alone.
    @Test("a verbose line is withheld from the handler")
    func verboseSkipsTheHandler() {
        let box = EngineLogCapture()
        defer { box.end() }

        EngineLog.emit("[test-496b] per-segment trace api_key=\(token)", category: .session, level: .verbose)

        // #496: same singleton, same rule. The bare `box.lines.isEmpty` failed a full run once on
        // an unrelated AVIOReader line from a parallel suite, which says nothing about `.verbose`.
        #expect(box.lines.filter { $0.contains("[test-496b]") }.isEmpty)
    }
}
