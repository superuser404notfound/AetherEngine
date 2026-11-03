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

    /// Audit NET-7: the headers a host handed over for `anchor` as they may be sent to `target`, a URI
    /// some playlist named. A playlist can name any host and scheme, so it gets the rule a redirect
    /// gets: credentials only to the same origin with no TLS downgrade, everything else as given.
    static func scoped(_ headers: [String: String], grantedFor anchor: URL?, sentTo target: URL?)
        -> [String: String]
    {
        headersToReplay(extraHeaders: headers, originalURL: anchor, redirectURL: target)
    }

    /// Builds the request actually handed back to URLSession on redirect: re-applies the
    /// original Range (Range-dependent proxies 400 without it), replays the policy-filtered
    /// extra headers, and scrubs any credential header URLSession itself carried over when
    /// the target is not credential-worthy. URLSession's default redirect copies every custom
    /// header except `Authorization` to the new host (measured on CFNetwork 3896, audit
    /// NET-108), so the scrub is what keeps a token and a cookie off a cross-origin target.
    static func redirectRequest(
        _ request: URLRequest,
        originalURL: URL?,
        originalRange: String?,
        extraHeaders: [String: String]
    ) -> URLRequest {
        var updated = request
        if let upgraded = upgradedDowngrade(request.url, from: originalURL) {
            updated.url = upgraded
        }
        if let originalRange {
            updated.setValue(originalRange, forHTTPHeaderField: "Range")
        }
        if !credentialsAllowed(from: originalURL, to: updated.url) {
            for name in credentialHeaders {
                updated.setValue(nil, forHTTPHeaderField: name)
            }
        }
        let replayable = headersToReplay(
            extraHeaders: extraHeaders, originalURL: originalURL, redirectURL: updated.url)
        for (name, value) in replayable {
            updated.setValue(value, forHTTPHeaderField: name)
        }
        return updated
    }

    /// An https source redirected to plain http on a public host: App Transport Security refuses
    /// that hop before a byte moves (-1022), and every reopen meets the same refusal until the
    /// opening budget runs out and the load reads as a source that never answered. A server behind
    /// a TLS-terminating proxy builds exactly this link from the inner http request (an add-on
    /// bridge whose 302 names its own host over http). Ask for the same address over https.
    /// Local names and IP literals keep the redirect as sent (ATS lets local ones through, and a
    /// certificate rarely names an address), and so does any target the app's own ATS
    /// configuration already lets through over http.
    static func upgradedDowngrade(_ target: URL?, from original: URL?) -> URL? {
        guard original?.scheme?.lowercased() == "https",
              let target, target.scheme?.lowercased() == "http",
              let host = target.host?.lowercased(), !isLocalNetworkHost(host),
              !appATSRules.allows(host),
              var components = URLComponents(url: target, resolvingAgainstBaseURL: false)
        else { return nil }
        components.scheme = "https"
        if components.port == 80 { components.port = nil }
        return components.url
    }

    /// Single-label names, `.local` and IP literals.
    private static func isLocalNetworkHost(_ host: String) -> Bool {
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if bare.hasSuffix(".local") || !bare.contains(".") { return true }
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, bare, &v4) == 1 || inet_pton(AF_INET6, bare, &v6) == 1
    }

    private static let appATSRules = PlainHTTPRules(
        Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any] ?? [:])

    /// Whether `ats` (an `NSAppTransportSecurity` dictionary) already allows plain http to `host`.
    static func atsAllowsPlainHTTP(to host: String, in ats: [String: Any]) -> Bool {
        PlainHTTPRules(ats).allows(host)
    }

    /// The parts of an ATS configuration that decide plain http to a named host: an
    /// `NSExceptionDomains` entry with `NSExceptionAllowsInsecureHTTPLoads` for the host or, with
    /// `NSIncludesSubdomains`, a parent domain; otherwise `NSAllowsArbitraryLoads`, which the system
    /// ignores whenever `NSAllowsLocalNetworking`, `NSAllowsArbitraryLoadsForMedia` or
    /// `NSAllowsArbitraryLoadsInWebContent` is also present.
    struct PlainHTTPRules: Sendable {
        private struct Exception: Sendable {
            let includesSubdomains: Bool
            let allowsInsecureHTTP: Bool
        }
        private let exceptions: [String: Exception]
        private let arbitraryLoads: Bool

        init(_ ats: [String: Any]) {
            var exceptions: [String: Exception] = [:]
            for (domain, value) in ats["NSExceptionDomains"] as? [String: Any] ?? [:] {
                guard let entry = value as? [String: Any] else { continue }
                exceptions[domain.lowercased()] = Exception(
                    includesSubdomains: entry["NSIncludesSubdomains"] as? Bool == true,
                    allowsInsecureHTTP: entry["NSExceptionAllowsInsecureHTTPLoads"] as? Bool == true)
            }
            self.exceptions = exceptions
            let overridingKeys = [
                "NSAllowsLocalNetworking", "NSAllowsArbitraryLoadsForMedia", "NSAllowsArbitraryLoadsInWebContent",
            ]
            arbitraryLoads = !overridingKeys.contains { ats[$0] != nil }
                && ats["NSAllowsArbitraryLoads"] as? Bool == true
        }

        /// The most specific entry decides: the host itself, then the longest parent domain.
        func allows(_ host: String) -> Bool {
            if let exact = exceptions[host] { return exact.allowsInsecureHTTP }
            let parent = exceptions
                .filter { $0.value.includesSubdomains && host.hasSuffix("." + $0.key) }
                .max { $0.key.count < $1.key.count }
            return parent?.value.allowsInsecureHTTP ?? arbitraryLoads
        }
    }

    /// Same host and no TLS downgrade. Ports may differ only across an http -> https
    /// upgrade (Emby-style 8096 -> 8920); within the same scheme a port change is a
    /// different origin.
    static func credentialsAllowed(from original: URL?, to redirect: URL?) -> Bool {
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

/// Audit NET-109: which URLs may receive the headers a host handed over. Being allowed to fetch a
/// URL (a playlist named it, a redirect landed there) and being granted the host's credentials are
/// separate decisions: only the URLs the host itself passed in are anchors, and every other target
/// gets the same headers minus the credentials, the rule a redirect follows. One type so the relay,
/// the subtitle proxy, the audio tap and the live rendition fetch cannot each decide differently.
struct CredentialScope: Sendable {
    let headers: [String: String]
    let anchors: [URL]

    init(headers: [String: String], anchors: [URL]) {
        self.headers = headers
        self.anchors = anchors
    }

    init(headers: [String: String], anchor: URL?) {
        self.init(headers: headers, anchors: anchor.map { [$0] } ?? [])
    }

    func headers(for target: URL) -> [String: String] {
        if anchors.contains(where: { RedirectHeaderPolicy.credentialsAllowed(from: $0, to: target) }) {
            return headers
        }
        return RedirectHeaderPolicy.scoped(headers, grantedFor: nil, sentTo: target)
    }
}
