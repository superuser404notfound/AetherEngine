import Foundation

/// Decides which caller-supplied headers may be replayed onto a redirected request (#126).
/// Credential headers are replayed only to a trustworthy destination: same host with no
/// TLS downgrade. A cross-host redirect target (presigned object storage, CDN) must not
/// see the media-server token; replaying it both discloses the credential and can break
/// the request outright when the target authenticates via the URL itself and rejects
/// conflicting auth mechanisms with 400. Non-credential headers are replayed
/// unconditionally so header-dependent proxies keep working (#8).
enum RedirectHeaderPolicy {
    private static let credentialHeaders: Set<String> = [
        "authorization",
        "proxy-authorization",
        "cookie",
        "x-emby-token",
        "x-emby-authorization",
        "x-mediabrowser-token",
    ]

    static func headersToReplay(
        extraHeaders: [String: String],
        originalURL: URL?,
        redirectURL: URL?
    ) -> [String: String] {
        if credentialsAllowed(from: originalURL, to: redirectURL) {
            return extraHeaders
        }
        return extraHeaders.filter { !credentialHeaders.contains($0.key.lowercased()) }
    }

    /// Builds the request actually handed back to URLSession on redirect: re-applies the
    /// original Range (URLSession drops custom headers on cross-host redirect, and
    /// Range-dependent proxies 400 without it), replays the policy-filtered extra
    /// headers, and scrubs any credential header URLSession itself carried over when
    /// the target is not credential-worthy.
    static func redirectRequest(
        _ request: URLRequest,
        originalURL: URL?,
        originalRange: String?,
        extraHeaders: [String: String]
    ) -> URLRequest {
        var updated = request
        if let originalRange {
            updated.setValue(originalRange, forHTTPHeaderField: "Range")
        }
        if !credentialsAllowed(from: originalURL, to: request.url) {
            for name in credentialHeaders {
                updated.setValue(nil, forHTTPHeaderField: name)
            }
        }
        let replayable = headersToReplay(
            extraHeaders: extraHeaders, originalURL: originalURL, redirectURL: request.url)
        for (name, value) in replayable {
            updated.setValue(value, forHTTPHeaderField: name)
        }
        return updated
    }

    /// Same host and no TLS downgrade. Ports may differ only across an http -> https
    /// upgrade (Emby-style 8096 -> 8920); within the same scheme a port change is a
    /// different origin.
    private static func credentialsAllowed(from original: URL?, to redirect: URL?) -> Bool {
        guard let original, let redirect,
              let fromHost = original.host?.lowercased(),
              let toHost = redirect.host?.lowercased(),
              fromHost == toHost,
              let fromScheme = original.scheme?.lowercased(),
              let toScheme = redirect.scheme?.lowercased()
        else { return false }
        if fromScheme == toScheme {
            return effectivePort(original, scheme: fromScheme)
                == effectivePort(redirect, scheme: toScheme)
        }
        return fromScheme == "http" && toScheme == "https"
    }

    private static func effectivePort(_ url: URL, scheme: String) -> Int {
        url.port ?? (scheme == "https" ? 443 : 80)
    }
}
