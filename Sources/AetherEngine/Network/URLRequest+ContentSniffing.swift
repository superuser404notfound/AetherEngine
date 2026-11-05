import Foundation

extension URLRequest {
    /// AE#986: CFNetwork content-sniffs a response whose `Content-Type` is `text/plain` or absent,
    /// and holds `didReceive response` back until 512 body bytes arrive or the connection ends,
    /// whatever the status. An origin that answers 500 with a short body and keeps the connection
    /// open therefore looks unanswered for the whole open budget (measured: 40 s, `status=0`).
    /// The engine never reads a sniffed MIME type, it reads the status and the `Content-Type`
    /// header itself, so every engine request turns sniffing off. The key is CFNetwork's own
    /// per-request property, set through public API; an OS that stops honouring it falls back
    /// to the old delay, not to a failure.
    init(engineURL url: URL, timeoutInterval: TimeInterval = 60) {
        let request = NSMutableURLRequest(url: url, cachePolicy: .useProtocolCachePolicy,
                                          timeoutInterval: timeoutInterval)
        URLProtocol.setProperty(false, forKey: Self.contentSniffingPropertyKey, in: request)
        self = request as URLRequest
    }

    static let contentSniffingPropertyKey = "_kCFURLConnectionPropertyShouldSniff"

    var sniffsContent: Bool {
        (URLProtocol.property(forKey: Self.contentSniffingPropertyKey, in: self) as? Bool) ?? true
    }
}
