import Foundation

/// Gemini response status, faithful to the 1.0 spec (codes 10..62, classes by first digit).
///
/// The `code` selects the class (`1x` input … `6x` client certificates) and
/// `meta` carries the prompt, MIME type, or redirect target depending on class.
public struct GeminiStatus: Equatable, Sendable, CustomStringConvertible {
    /// Two-digit status code (10–69).
    public let code: Int
    /// META field: prompt, MIME type, or redirect target depending on ``code``.
    public let meta: String

    /// Creates a status, or `nil` when `code` is outside 1–69.
    public init?(code: Int, meta: String) {
        guard (1...69).contains(code) else { return nil }
        self.code = code
        self.meta = meta
    }

    /// `true` for input prompts (codes 10–11).
    public var isInput: Bool { (10...11).contains(code) }
    /// `true` for sensitive (masked) input prompts (code 11).
    public var isSensitiveInput: Bool { code == 11 }
    /// `true` for success with a body (codes 20–29).
    public var isSuccess: Bool { (20...29).contains(code) }
    /// `true` for redirects (codes 30–39).
    public var isRedirect: Bool { (30...39).contains(code) }
    /// `true` for temporary failures (codes 40–49).
    public var isTemporaryFailure: Bool { (40...49).contains(code) }
    /// `true` for permanent failures (codes 50–59).
    public var isPermanentFailure: Bool { (50...59).contains(code) }
    /// `true` for client-certificate failures (codes 60–69).
    public var isClientCertFailure: Bool { (60...69).contains(code) }

    public var description: String { String(code) }

    /// Human-readable label for ``code``, e.g. `"Success"` or `"Not found"`.
    public var statusDescription: String {
        switch code {
        case 10, 11: return "Input required"
        case 20: return "Success"
        case 30: return "Temporary redirect"
        case 31: return "Permanent redirect"
        case 40: return "Temporary failure"
        case 41: return "Server unavailable"
        case 42: return "CGI error"
        case 43: return "Proxy error"
        case 44: return "Slow down"
        case 45: return "Too many requests"
        case 50: return "Permanent failure"
        case 51: return "Not found"
        case 52: return "Gone"
        case 53: return "Proxy request refused"
        case 59: return "Bad request"
        case 60: return "Client certificate required"
        case 61: return "Client certificate not authorized"
        case 62: return "Client certificate not valid"
        default: return "Unknown status \(code)"
        }
    }
}

/// Failures thrown by ``GeminiResponseHeader/parse(_:)`` for malformed headers.
public enum GeminiProtocolError: LocalizedError, Equatable {
    case malformedHeader
    case headerTooLong
    case missingMeta
    case redirectWithoutTarget

    public var errorDescription: String? {
        switch self {
        case .malformedHeader: return "Malformed response header from server"
        case .headerTooLong: return "Response header exceeded 1029 bytes"
        case .missingMeta: return "Success response missing META field"
        case .redirectWithoutTarget: return "Redirect response missing target URL"
        }
    }
}

/// A parsed `<STATUS> <META>\r\n` response header line.
public struct GeminiResponseHeader: Equatable, Sendable {
    /// The parsed status code and META field.
    public let status: GeminiStatus

    /// Maximum header length in bytes (1029), per the Gemini spec.
    public static let maxHeaderBytes = 1029

    /// Parse "<STATUS> <META>\r\n" from the head of `data`. Only reads up to the first CRLF.
    public static func parse(_ data: Data) throws -> GeminiResponseHeader {
        guard data.count <= maxHeaderBytes + 1024,
            let crlfRange = data.firstRange(of: Data("\r\n".utf8))
        else {
            throw GeminiProtocolError.malformedHeader
        }
        let head = String(decoding: data[data.startIndex..<crlfRange.lowerBound], as: UTF8.self)
        guard head.count <= maxHeaderBytes else { throw GeminiProtocolError.headerTooLong }

        let parts = head.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw GeminiProtocolError.malformedHeader }
        let codeStr = parts[0]
        guard codeStr.count == 2, let code = Int(codeStr),
            let status = GeminiStatus(code: code, meta: String(parts[1]))
        else {
            throw GeminiProtocolError.malformedHeader
        }
        if status.isSuccess && status.meta.isEmpty {
            throw GeminiProtocolError.missingMeta
        }
        if status.isRedirect && status.meta.isEmpty {
            throw GeminiProtocolError.redirectWithoutTarget
        }
        return GeminiResponseHeader(status: status)
    }
}
