import Foundation

/// #95 follow-up: minimal HLS fetch for the remote-HLS tap. Reuses the standalone parser and
/// AES-128 decryptor; independent of HLSLiveIngestReader (which keeps its device-verified live
/// retry path). Best-effort: transient failures surface as thrown errors the reader treats as a
/// sleep-and-retry, never a playback stall.
final class AudioTapHLSFetcher: @unchecked Sendable {
    enum FetchError: Error, CustomStringConvertible, LocalizedError {
        case http(Int), invalidPlaylist(String), unresolvable

        var description: String {
            switch self {
            case .http(let status): "AudioTapHLSFetcher: HTTP \(status)"
            case .invalidPlaylist(let reason): "AudioTapHLSFetcher: invalid playlist (\(reason))"
            case .unresolvable: "AudioTapHLSFetcher: unresolvable URI"
            }
        }

        var errorDescription: String? { description }
    }

    private let session: URLSession
    /// Same per-stream headers the player's AVURLAsset sends (#119); header-enforcing origins
    /// 403 the tap's playlist / segment / key fetches without them. The credential headers go only
    /// to the origin of `credentialOrigin`, the URL the host loaded: every other URL here is one a
    /// playlist named, on any host or scheme (audit DEC-103, the NET-7 rule).
    private let credentials: CredentialScope
    private let keyCacheLock = NSLock()
    private var keyCache: [String: Data] = [:]

    init(session: URLSession? = nil, httpHeaders: [String: String] = [:], credentialOrigin: URL? = nil) {
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 10
            cfg.timeoutIntervalForResource = 30
            self.session = URLSession(
                configuration: cfg, delegate: EngineTLS.sessionDelegate, delegateQueue: nil)
        }
        credentials = CredentialScope(headers: httpHeaders, anchor: credentialOrigin)
    }

    /// Audit DEC-103: every body is cut off at its cap while it arrives. Playlists take the ingest
    /// readers' 8 MiB, keys 64 bytes, and a segment, which here is audio only, the floor of the
    /// duration-derived video cap.
    private static let maximumPlaylistBytes = 8 * 1024 * 1024
    private static let maximumSegmentBytes = BoundedFetch.segmentLimit(forDuration: 0)

    private func get(_ url: URL, limit: Int) async throws -> (Data, URLResponse) {
        var request = URLRequest(engineURL: url)
        for (field, value) in credentials.headers(for: url) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        do {
            return try await BoundedFetch.data(for: request, session: session, limit: limit)
        } catch let error as BoundedFetch.Exceeded {
            throw FetchError.invalidPlaylist("body exceeds \(error.limit) bytes")
        }
    }

    func fetchPlaylist(_ url: URL) async throws -> (HLSPlaylist, URL) {
        let (data, response) = try await get(url, limit: Self.maximumPlaylistBytes)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else { throw FetchError.http(status) }
        guard let text = String(data: data, encoding: .utf8) else {
            throw FetchError.invalidPlaylist("non-UTF8")
        }
        return (try HLSPlaylistParser.parse(text), response.url ?? url)
    }

    func fetchSegment(_ url: URL, crypt: HLSSegmentCrypt?, base: URL) async throws -> Data {
        let (data, response) = try await get(url, limit: Self.maximumSegmentBytes)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if status == 404 { return Data() }               // slid out of window; caller advances
        guard (200..<300).contains(status) else { throw FetchError.http(status) }
        guard let crypt else { return data }
        guard let keyURL = HLSPlaylistParser.resolve(uri: crypt.keyURI, against: base) else {
            throw FetchError.unresolvable
        }
        let key = try await fetchKey(keyURL)
        guard let plain = HLSSegmentDecryptor.decryptAES128CBC(data, key: key, iv: crypt.iv) else {
            throw FetchError.invalidPlaylist("aes-128 decrypt failed")
        }
        return plain
    }

    private func fetchKey(_ url: URL) async throws -> Data {
        let cacheKey = url.absoluteString
        if let cached = keyCacheLock.withLock({ keyCache[cacheKey] }) { return cached }
        let (data, response) = try await get(url, limit: BoundedFetch.keyLimit)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status), data.count == 16 else { throw FetchError.http(status) }
        keyCacheLock.withLock { keyCache[cacheKey] = data }
        return data
    }
}
