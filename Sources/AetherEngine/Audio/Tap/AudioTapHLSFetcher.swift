import Foundation

/// #95 follow-up: minimal HLS fetch for the remote-HLS tap. Reuses the standalone parser and
/// AES-128 decryptor; independent of HLSLiveIngestReader (which keeps its device-verified live
/// retry path). Best-effort: transient failures surface as thrown errors the reader treats as a
/// sleep-and-retry, never a playback stall.
final class AudioTapHLSFetcher: @unchecked Sendable {
    enum FetchError: Error { case http(Int), invalidPlaylist(String), unresolvable }

    private let session: URLSession
    private let keyCacheLock = NSLock()
    private var keyCache: [String: Data] = [:]

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 10
            cfg.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: cfg)
        }
    }

    func fetchPlaylist(_ url: URL) async throws -> (HLSPlaylist, URL) {
        let (data, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else { throw FetchError.http(status) }
        guard let text = String(data: data, encoding: .utf8) else {
            throw FetchError.invalidPlaylist("non-UTF8")
        }
        return (try HLSPlaylistParser.parse(text), response.url ?? url)
    }

    func fetchSegment(_ url: URL, crypt: HLSSegmentCrypt?, base: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
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
        let (data, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status), data.count == 16 else { throw FetchError.http(status) }
        keyCacheLock.withLock { keyCache[cacheKey] = data }
        return data
    }
}
