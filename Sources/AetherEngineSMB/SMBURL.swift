import Foundation

/// Parses an `smb://[user[:password]@]host[:port]/share/path/to/file` URL into
/// connection parts. An omitted username is left empty (not substituted with
/// "guest"): `SMBConnection.connect` treats an empty username as "no account"
/// and drives the guest-then-anonymous fallback itself. Substituting "guest"
/// here would make that fallback unreachable for credential-less URLs.
public struct SMBURL: Sendable {
    public let server: URL
    public let share: String
    public let path: String
    public let user: String
    public let password: String

    public struct ParseError: Error, CustomStringConvertible, LocalizedError {
        public let message: String
        public var description: String { "SMB URL: \(message)" }
        public var errorDescription: String? { description }
    }

    public static func parse(_ raw: String) throws -> SMBURL {
        // Case-insensitive scheme (RFC 3986), and the error names the scheme only: `raw` can hold a password (audit NET-209).
        let parsed = URLComponents(string: raw)
        guard let comps = parsed, comps.scheme?.lowercased() == "smb" else {
            throw ParseError(message: "not an smb:// URL (scheme: \(parsed?.scheme ?? "none"))")
        }
        guard let host = comps.host, !host.isEmpty else {
            throw ParseError(message: "missing host")
        }
        // Path is /share/segments...; need at least share + one file segment.
        let segments = comps.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard segments.count >= 2 else {
            throw ParseError(message: "expected /share/path/to/file, got \(comps.path)")
        }
        var serverComps = URLComponents()
        serverComps.scheme = "smb"
        serverComps.host = host
        serverComps.port = comps.port
        guard let server = serverComps.url else {
            throw ParseError(message: "could not rebuild server URL")
        }
        return SMBURL(
            server: server,
            share: segments[0],
            path: segments.dropFirst().joined(separator: "/"),
            user: comps.user ?? "",
            password: comps.password ?? ""
        )
    }
}
