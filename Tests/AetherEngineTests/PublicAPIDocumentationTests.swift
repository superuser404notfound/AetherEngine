import XCTest

/// The documentation gap that produced this test: the README's API tour enumerated the engine's
/// `@Published` properties and named neither `PassthroughSubject`, so a shipping downstream host read
/// the whole tour and came away without the live-retune contract (#374). It had no compile error to
/// find it with, because a subject nobody subscribes to is silent by construction. The same shape
/// hides every surface that requires a host ACTION rather than a host read.
///
/// So the rule is mechanical: a public surface a host consumes has to be NAMED somewhere in the
/// documentation. Naming is a low bar on purpose. This test cannot judge whether a paragraph is any
/// good, only whether one exists at all, and the failure it prevents is the silent one: a symbol
/// shipping with no prose anywhere, discovered by an adopter instead of by us.
///
/// Three surfaces are checked, and they are the three where a missing mention costs an adopter:
/// every public member of `AetherEngine` itself, every public type in the host-facing files, and
/// every `LoadOptions` field. Fields of value types are deliberately not required: a host that has
/// the type has its members from autocomplete, which is not true of an engine method nobody
/// mentioned or an option nobody listed.
final class PublicAPIDocumentationTests: XCTestCase {

    // MARK: - Where the sources and the docs are

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)            // Tests/AetherEngineTests/<this file>
            .deletingLastPathComponent()           // Tests/AetherEngineTests
            .deletingLastPathComponent()           // Tests
            .deletingLastPathComponent()           // repo root
    }

    /// Files whose public TYPES are part of the host-facing surface. The engine's own extensions are
    /// covered by the member rule below; this list is about the value types a host holds.
    private static let hostFacingTypeFiles = [
        "PlayerState.swift",
        "PlaybackErrorInfo.swift",
        "PlaybackClock.swift",
        "SeekEvent.swift",
        "StartupProgress.swift",
        "PresentationAxisMap.swift",
        "NativeVideoFrameTime.swift",
        "SoftwareVideoFrameTime.swift",
        "View/AetherPlayerView.swift",
        "IO/IOReader.swift",
        "IO/HLSIngest/HLSIngestError.swift",
        "Subtitles/ExternalSubtitleTrack.swift",
        "Subtitles/NativeSubtitleCueStore.swift",
        "Disc/DiscMetadata.swift",
        "Native/NativeLegibleDeselectPin.swift",
        "Native/SoftwarePiPSource.swift",
        "Audio/Tap/AudioTapTypes.swift",
        "Audio/AudioBridge.swift",
        "Diagnostics/EngineDiagnostics.swift",
        "Diagnostics/LiveTelemetry.swift",
        "Diagnostics/EngineLog.swift",
        "Network/EngineTLS.swift",
        "FrameExtractor/FrameExtractor.swift",
        "Recording/RecordingState.swift",
    ]

    /// Public, and deliberately undocumented as host API. Each entry is a claim that an adopter
    /// reading the docs is better off not meeting this symbol, so it carries its reason.
    private static let notHostAPI: [String: String] = [
        "setForceSoftwarePathForTesting": "test hook, aetherctl live --sw",
        "setForceAudioPipelineFailureForTesting": "test hook, aetherctl play --drop-audio",
        "setForceMasterPlaylistForTesting": "test hook, aetherctl live --force-master",
        "setSourceThrottleKbpsForTesting": "test hook, aetherctl --throttle-kbps",
        "setSoftwareBackgroundAudioOnlyForTesting": "test hook",
        "softwareVideoFramesEnqueuedForTesting": "test hook",
        "setLargeAllocationCensusEnabled": "allocation census, diagnostics only",
        "bind": "documented as bind(view:)",
        "unbind": "documented as unbind(view:)",
        "shouldYield": "FrameExtractor yield policy, internal tuning exposed for tests",
        "yieldMinForwardBufferSeconds": "FrameExtractor yield policy constant",
        "yieldMinForwardBufferSecondsDefault": "FrameExtractor yield policy constant",
        "yieldHealthyTicksRequired": "FrameExtractor yield policy constant",
        "runRemote": "AudioTapProbe, aetherctl audiotap --remote",
        "a53ClosedCaptionTrackID": "synthetic id for the CEA-608 track, surfaced through subtitleTracks",
        "sameLanguageRank": "documented with NativeSubtitleTrack",
        "audioTapFormat": "documented with the audio tap",
        "errorDescription": "LocalizedError conformance, not a surface of its own",
    ]

    private static let declarationPattern = try! NSRegularExpression(
        pattern: #"^\s*(?:@Published\s+)?public\s+(?:internal\(set\)\s+|private\(set\)\s+)?"#
              + #"(?:static\s+|final\s+|nonisolated\s+|nonisolated\(unsafe\)\s+)*"#
              + #"(let|var|func|struct|enum|class|protocol|typealias|actor|init|subscript)"#
              + #"\s+([A-Za-z_][A-Za-z0-9_]*)"#)

    // MARK: - Helpers

    private func read(_ relativePath: String) -> String? {
        try? String(contentsOf: Self.repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func documentationText() throws -> String {
        let docsDir = Self.repoRoot.appendingPathComponent("docs")
        guard let readme = read("README.md"),
              let entries = try? FileManager.default.contentsOfDirectory(atPath: docsDir.path) else {
            throw XCTSkip("running outside a source checkout; no docs to check against")
        }
        let markdown = entries.filter { $0.hasSuffix(".md") }.sorted().compactMap { read("docs/\($0)") }
        return ([readme] + markdown).joined(separator: "\n")
    }

    /// Declarations in `text`, as (kind, name). Comment lines are skipped so a `///` mentioning
    /// "public func" cannot invent a symbol.
    private func declarations(in text: String) -> [(kind: String, name: String)] {
        var found: [(String, String)] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//") else { continue }
            let ns = String(line) as NSString
            guard let m = Self.declarationPattern.firstMatch(
                in: String(line), range: NSRange(location: 0, length: ns.length)) else { continue }
            found.append((ns.substring(with: m.range(at: 1)), ns.substring(with: m.range(at: 2))))
        }
        return found
    }

    /// Whole-word containment. A coverage floor, not a precision instrument: it answers "does this
    /// name appear at all", which is exactly the question the #374 gap failed.
    private func documentation(_ docs: String, names name: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: "\\b\(NSRegularExpression.escapedPattern(for: name))\\b")
        else { return false }
        let ns = docs as NSString
        return re.firstMatch(in: docs, range: NSRange(location: 0, length: ns.length)) != nil
    }

    private func sourceFiles(matching predicate: (String) -> Bool) -> [String] {
        let root = Self.repoRoot.appendingPathComponent("Sources/AetherEngine")
        guard let walker = FileManager.default.enumerator(atPath: root.path) else { return [] }
        return walker.compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") && predicate($0) }.sorted()
    }

    // MARK: - The engine's own members

    func testEveryPublicEngineMemberIsNamedInTheDocumentation() throws {
        let docs = try documentationText()
        var undocumented: [String] = []

        for relative in sourceFiles(matching: { $0.hasPrefix("AetherEngine") }) {
            guard let text = read("Sources/AetherEngine/\(relative)") else { continue }
            for decl in declarations(in: text) where decl.kind != "init" {
                if Self.notHostAPI[decl.name] != nil { continue }
                if !documentation(docs, names: decl.name) {
                    undocumented.append("\(decl.name)  (\(relative))")
                }
            }
        }

        XCTAssertTrue(undocumented.isEmpty, """
            \(undocumented.count) public engine member(s) are named nowhere in README.md or docs/:

            \(undocumented.joined(separator: "\n"))

            Document them in docs/api.md (or the topic doc they belong to). If a symbol is public for
            the CLI or the test suite rather than for hosts, add it to `notHostAPI` above with the
            reason, which is a smaller claim than it looks: it says an adopter is better off never
            meeting it.
            """)
    }

    // MARK: - Host-facing types

    func testEveryHostFacingPublicTypeIsNamedInTheDocumentation() throws {
        let docs = try documentationText()
        var undocumented: [String] = []

        for relative in Self.hostFacingTypeFiles {
            guard let text = read("Sources/AetherEngine/\(relative)") else {
                XCTFail("host-facing file list names \(relative), which does not exist")
                continue
            }
            let typeKinds: Set<String> = ["struct", "enum", "class", "protocol", "typealias", "actor"]
            for decl in declarations(in: text) where typeKinds.contains(decl.kind) {
                if Self.notHostAPI[decl.name] != nil { continue }
                if !documentation(docs, names: decl.name) {
                    undocumented.append("\(decl.name)  (\(relative))")
                }
            }
        }

        XCTAssertTrue(undocumented.isEmpty, """
            \(undocumented.count) host-facing public type(s) are named nowhere in README.md or docs/:

            \(undocumented.joined(separator: "\n"))

            A type a host holds needs at least one sentence somewhere. docs/api.md has a value-types
            table for the ones that need no more than that.
            """)
    }

    // MARK: - The examples

    /// The samples in `Examples/` are documentation that happens to be Swift. Since they became the
    /// `ExampleSources` target, `swift build` compiles them, which is the stronger guard and the one
    /// that catches a member that changed shape rather than name.
    ///
    /// This stays because it answers a different question cheaply, and reads as a list rather than
    /// as a compiler error: which engine surfaces do the samples actually exercise, and is any of
    /// them gone. It also still covers `DemoPlayerMac`, which is its own package and is not built by
    /// the root `swift build`.
    func testExamplesOnlyCallEngineMembersThatExist() throws {
        let root = Self.repoRoot.appendingPathComponent("Examples")
        guard let walker = FileManager.default.enumerator(atPath: root.path) else {
            throw XCTSkip("running outside a source checkout; no Examples/ to check")
        }
        let examples = walker.compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") }.sorted()
        XCTAssertFalse(examples.isEmpty, "Examples/ has no Swift files; did the directory move?")

        var publicNames = Set<String>()
        for relative in sourceFiles(matching: { _ in true }) {
            guard let text = read("Sources/AetherEngine/\(relative)") else { continue }
            for decl in declarations(in: text) { publicNames.insert(decl.name) }
        }

        // `engine.member`, `player.member` and their `$published` form.
        let callPattern = try NSRegularExpression(
            pattern: #"\b(?:engine|player)\.\$?([A-Za-z_][A-Za-z0-9_]*)"#)
        var dead: [String] = []
        var referenced = 0

        for relative in examples {
            guard let text = read("Examples/\(relative)") else { continue }
            let ns = text as NSString
            for m in callPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let name = ns.substring(with: m.range(at: 1))
                referenced += 1
                if !publicNames.contains(name) { dead.append("\(name)  (Examples/\(relative))") }
            }
        }

        XCTAssertGreaterThan(referenced, 0, "no engine calls found in Examples/; the regex or the samples changed")
        XCTAssertTrue(Set(dead).isEmpty, """
            \(Set(dead).count) example call(s) name a member that is no longer public API:

            \(Set(dead).sorted().joined(separator: "\n"))

            A sample that does not compile is worse than no sample, because a reader trusts it.
            """)
    }

    // MARK: - LoadOptions

    func testEveryLoadOptionIsNamedInTheDocumentation() throws {
        let docs = try documentationText()
        guard let text = read("Sources/AetherEngine/PlayerState.swift") else {
            throw XCTSkip("running outside a source checkout")
        }

        // Only the fields inside `public struct LoadOptions`, up to its closing brace at column 0.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: { $0.hasPrefix("public struct LoadOptions") }) else {
            return XCTFail("LoadOptions is no longer declared as `public struct LoadOptions` in PlayerState.swift")
        }
        let end = lines[start...].dropFirst().firstIndex(where: { $0 == "}" }) ?? lines.endIndex
        let body = lines[start..<end].joined(separator: "\n")

        let options = declarations(in: body).filter { $0.kind == "var" }
        XCTAssertGreaterThan(options.count, 20, "the LoadOptions block stopped parsing; the fields moved")

        let undocumented = options.map(\.name).filter { !documentation(docs, names: $0) }
        XCTAssertTrue(undocumented.isEmpty, """
            \(undocumented.count) LoadOptions field(s) are named nowhere in README.md or docs/:

            \(undocumented.joined(separator: "\n"))

            The full table lives in docs/api.md > LoadOptions; a new option belongs in it in the same
            commit that adds it, since an option nobody documents is an option nobody sets.
            """)
    }
}
