import Foundation

/// #95 follow-up: minimal HLS fetch for the remote-HLS tap. Reuses the standalone parser and
/// AES-128 decryptor; independent of HLSLiveIngestReader (which keeps its device-verified live
/// retry path). Best-effort: transient failures surface as thrown errors the reader treats as a
/// sleep-and-retry, never a playback stall.
final class AudioTapHLSFetcher: @unchecked Sendable {
    enum FetchError: Error { case http(Int), invalidPlaylist(String), unresolvable }

    private let session: URLSession
    /// Same per-stream headers the player's AVURLAsset sends (#119); header-enforcing origins
    /// 403 the tap's playlist / segment / key fetches without them.
    private let httpHeaders: [String: String]
    private let keyCacheLock = NSLock()
    private var keyCache: [String: Data] = [:]

    init(session: URLSession? = nil, httpHeaders: [String: String] = [:]) {
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 10
            cfg.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: cfg)
        }
        self.httpHeaders = httpHeaders
    }

    private func get(_ url: URL) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        for (field, value) in httpHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return try await session.data(for: request)
    }

    func fetchPlaylist(_ url: URL) async throws -> (HLSPlaylist, URL) {
        let (data, response) = try await get(url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else { throw FetchError.http(status) }
        guard let text = String(data: data, encoding: .utf8) else {
            throw FetchError.invalidPlaylist("non-UTF8")
        }
        return (try HLSPlaylistParser.parse(text), response.url ?? url)
    }

    func fetchSegment(_ url: URL, crypt: HLSSegmentCrypt?, base: URL) async throws -> Data {
        let (data, response) = try await get(url)
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
        let (data, response) = try await get(url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status), data.count == 16 else { throw FetchError.http(status) }
        keyCacheLock.withLock { keyCache[cacheKey] = data }
        return data
    }
}
