import Foundation

/// A parsed `gemini://` URL, faithful to the Gemini spec:
/// default port 1965, no userinfo, request line capped at 1024 bytes.
///
/// Use ``parse(_:)`` to parse user input or response metadata; use
/// ``resolving(_:)`` to follow links relative to a fetched page.
public struct GeminiURI: Equatable, Sendable {
    /// Lowercased host without brackets or port (punycode for international names).
    public let host: String
    /// Port, defaulting to ``defaultPort`` (1965) when absent.
    public let port: Int
    /// Percent-decoded, dot-segment-normalized path, always starting with `/`.
    public let path: String
    /// Percent-decoded query string, or `nil` when the URL has no `?`.
    public let query: String?

    /// Creates a URI from components. Prefer ``parse(_:)`` for raw strings.
    public init(host: String, port: Int = GeminiURI.defaultPort, path: String, query: String? = nil)
    {
        self.host = host
        self.port = port
        self.path = path
        self.query = query
    }

    /// The default Gemini port (1965).
    public static let defaultPort = 1965
    /// Maximum request-line length in bytes, per the Gemini spec.
    public static let maxRequestLengthBytes = 1024

    /// The exact bytes sent on the wire (`<url>\r\n`).
    public var requestLine: Data {
        var line = "gemini://\(host)\(port == GeminiURI.defaultPort ? "" : ":\(port)")\(path)"
        if let query, !query.isEmpty {
            line += "?\(query)"
        }
        line += "\r\n"
        return Data(line.utf8)
    }

    /// Canonical textual form including the scheme: `gemini://host[:port]path[?query]`.
    public var absolute: String { normalizedScheme() }

    /// Canonical textual form: `gemini://host[:port]path[?query]`.
    public func normalizedScheme() -> String {
        var s = "gemini://\(host)"
        if port != GeminiURI.defaultPort { s += ":\(port)" }
        s += path
        if let query { s += "?\(query)" }
        return s
    }

    /// Host for display purposes, appending `:port` when non-default.
    public var hostForDisplay: String {
        port == GeminiURI.defaultPort ? host : "\(host):\(port)"
    }

    /// Copy of this URI with the query replaced (used to answer `10`/`11` input prompts).
    public func withInputQuery(_ q: String) -> GeminiURI {
        GeminiURI(host: host, port: port, path: path, query: q)
    }

    /// Ways ``parse(_:)`` and ``resolving(_:)`` can fail.
    public enum ParseError: LocalizedError {
        case invalidScheme
        case missingHost
        case emptyHost
        case invalidPort
        case containsUserinfo
        case tooLong
        case invalidPercentEncoding
        case nonASCIIHost

        public var errorDescription: String? {
            switch self {
            case .invalidScheme: return "URL scheme must be gemini://"
            case .missingHost: return "URL has no host"
            case .emptyHost: return "URL host is empty"
            case .invalidPort: return "Invalid port"
            case .containsUserinfo: return "Gemini URLs cannot contain userinfo"
            case .tooLong: return "Request URI would exceed the 1024-byte limit"
            case .invalidPercentEncoding: return "Malformed percent-encoding"
            case .nonASCIIHost: return "Host must be ASCII (use punycode)"
            }
        }
    }

    /// Parses a `gemini://` URL, percent-decoding path and query, lowercasing
    /// the host, and normalizing dot segments.
    ///
    /// - Parameter raw: A full URL such as `gemini://example.com/docs`.
    /// - Throws: ``ParseError`` when the scheme, host, port, or length is invalid.
    public static func parse(_ raw: String) throws -> GeminiURI {
        let schemaPrefix = "gemini://"
        guard raw.lowercased().hasPrefix(schemaPrefix) else {
            throw ParseError.invalidScheme
        }
        let rest = String(raw.dropFirst(schemaPrefix.count))
        guard !rest.isEmpty else { throw ParseError.missingHost }

        var authority = rest
        var pathAndQuery = ""
        if let slashIndex = rest.firstIndex(of: "/") {
            authority = String(rest[..<slashIndex])
            pathAndQuery = String(rest[slashIndex...])
        }
        if let qIndex = authority.firstIndex(of: "?") {
            pathAndQuery = "?" + String(authority[authority.index(after: qIndex)...])
            authority = String(authority[..<qIndex])
        }
        guard !authority.isEmpty else { throw ParseError.emptyHost }
        guard !authority.contains("@") else { throw ParseError.containsUserinfo }

        var host = authority
        var port = defaultPort
        if host.hasPrefix("[") {
            guard let close = host.firstIndex(of: "]") else { throw ParseError.invalidPort }
            let v6 = String(host[host.index(after: host.startIndex)..<close])
            let after = host[host.index(after: close)...]
            if after.hasPrefix(":") {
                guard let p = Int(after.dropFirst()), (1...65535).contains(p) else {
                    throw ParseError.invalidPort
                }
                port = p
            }
            host = v6
        } else if let colon = host.firstIndex(of: ":") {
            guard let p = Int(host[host.index(after: colon)...]), (1...65535).contains(p) else {
                throw ParseError.invalidPort
            }
            port = p
            host = String(host[..<colon])
        }
        guard !host.isEmpty, host.allSatisfy({ $0.isASCII }) else {
            throw host.isEmpty ? ParseError.emptyHost : ParseError.nonASCIIHost
        }

        // Split path / query, percent-decode each.
        var path = ""
        var query: String?
        if let q = pathAndQuery.firstIndex(of: "?") {
            path = String(pathAndQuery[..<q])
            query = percentDecode(String(pathAndQuery[pathAndQuery.index(after: q)...]))
        } else {
            path = pathAndQuery
        }

        let decodedPath = percentDecode(path)
        var normalizedPath = decodedPath.isEmpty ? "/" : decodedPath
        // Resolve . and ..
        normalizedPath = normalizeDots(normalizedPath)

        let uri = GeminiURI(host: host.lowercased(), port: port, path: normalizedPath, query: query)

        // Request line (assuming empty user query placeholder) must fit 1024 bytes.
        if uri.requestLine.count > maxRequestLengthBytes {
            throw ParseError.tooLong
        }
        return uri
    }

    /// Percent-decodes `s` (leaving `+` alone unless `plusAsSpace` is set).
    public static func percentDecode(_ s: String, plusAsSpace: Bool = false) -> String {
        var replaced = s
        if plusAsSpace {
            replaced = replaced.replacingOccurrences(of: "+", with: " ")
        }
        return replaced.removingPercentEncoding ?? replaced
    }

    /// Percent-encodes a URL component, preserving characters legal in Gemini URLs.
    public static func encode(_ component: String) -> String {
        component.addingPercentEncoding(
            withAllowedCharacters: CharacterSet(
                charactersIn:
                    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~:/#[]@!$&'()*+,;= "
            )) ?? component
    }

    /// Resolves `.` and `..` segments in `path`, preserving the leading `/`.
    public static func normalizeDots(_ path: String) -> String {
        guard path.contains("/.") else { return path }
        var segments: [String] = []
        for seg in path.split(separator: "/") {
            if seg == ".." {
                _ = segments.popLast()
            } else if seg == "." {
                continue
            } else {
                segments.append(String(seg))
            }
        }
        return "/" + segments.joined(separator: "/")
    }

    /// Resolve a possibly-relative link against this URI.
    ///
    /// Handles absolute `gemini://` URLs, protocol-relative (`//host/path`),
    /// root-relative (`/path`), and page-relative links.
    /// - Parameter link: The link target, e.g. from a Gemtext `=>` line.
    /// - Throws: ``ParseError`` when the resolved URL is invalid.
    public func resolving(_ link: String) throws -> GeminiURI {
        let trimmed = link.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("gemini://") {
            return try GeminiURI.parse(trimmed)
        }
        if trimmed.hasPrefix("//") {
            return try GeminiURI.parse("gemini:" + trimmed)
        }
        guard !trimmed.isEmpty else { return self }
        if trimmed.hasPrefix("/") {
            let full = "gemini://\(hostForDisplay)\(trimmed)"
            return try GeminiURI.parse(full)
        }
        // Relative to current directory
        var dir =
            path.hasSuffix("/")
            ? path : (path.split(separator: "/").dropLast().map(String.init).joined(separator: "/"))
        dir = dir.isEmpty ? "/" : (dir.hasPrefix("/") ? dir : "/" + dir)
        if !dir.hasSuffix("/") { dir += "/" }
        return try GeminiURI.parse("gemini://\(hostForDisplay)\(dir)\(trimmed)")
    }
}

/// URL-bar style validation: accepts `gemini://…`, `//…`, or a bare host.
///
/// - Parameter text: Raw user input, such as `example.com` or `gemini://example.com`.
/// - Returns: `true` when the input parses as a valid ``GeminiURI``.
public func isAcceptableGeminiURL(_ text: String) -> Bool {
    let t = text.trimmingCharacters(in: .whitespaces)
    guard !t.isEmpty else { return false }
    if t.contains("://") || t.hasPrefix("//") {
        return (try? GeminiURI.parse(t.normalizedScheme())) != nil
    }
    // Bare host input
    return (try? GeminiURI.parse("gemini://\(t)")) != nil
}

extension String {
    /// Prepends `gemini://` unless the string already has a scheme (or `//` prefix).
    public func normalizedScheme() -> String {
        let lower = lowercased()
        if lower.hasPrefix("gemini://") { return self }
        if lower.hasPrefix("//") { return "gemini:" + self }
        return "gemini://" + self
    }
}
