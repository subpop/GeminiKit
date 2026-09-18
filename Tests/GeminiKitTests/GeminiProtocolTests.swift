import Testing
import Foundation
@testable import GeminiKit

struct GeminiURITests {
    @Test func parseBasic() throws {
        let u = try GeminiURI.parse("gemini://example.com/path?q=1")
        #expect(u.host == "example.com")
        #expect(u.port == 1965)
        #expect(u.path == "/path")
        #expect(u.query == "q=1")
    }

    @Test func parseBareHostGetsSlash() throws {
        let u = try GeminiURI.parse("gemini://example.com")
        #expect(u.path == "/")
        #expect(u.query == nil)
    }

    @Test func parseCustomPortAndTrailingSlash() throws {
        let u = try GeminiURI.parse("gemini://example.com:1966/a/b/")
        #expect(u.port == 1966)
        #expect(u.path == "/a/b/")
    }

    @Test func parseIPv6() throws {
        let u = try GeminiURI.parse("gemini://[::1]:1965/x")
        #expect(u.host == "::1")
        #expect(u.path == "/x")
    }

    @Test func rejectNonGeminiScheme() {
        #expect(throws: GeminiURI.ParseError.self) { try GeminiURI.parse("https://example.com/") }
    }

    @Test func rejectUserinfo() {
        #expect(throws: GeminiURI.ParseError.self) { try GeminiURI.parse("gemini://user@example.com/") }
    }

    @Test func rejectBadPort() {
        #expect(throws: GeminiURI.ParseError.self) { try GeminiURI.parse("gemini://example.com:abc/") }
        #expect(throws: GeminiURI.ParseError.self) { try GeminiURI.parse("gemini://example.com:99999/") }
    }

    @Test func rejectMissingHost() {
        #expect(throws: GeminiURI.ParseError.self) { try GeminiURI.parse("gemini:///path") }
    }

    @Test func requestLineRoundTrip() throws {
        let u = try GeminiURI.parse("gemini://example.com/a%20b?x=%2F")
        let line = String(decoding: u.requestLine, as: UTF8.self)
        #expect(line.hasSuffix("\r\n"))
        #expect(line.hasPrefix("gemini://example.com/"))
        #expect(u.requestLine.count <= GeminiURI.maxRequestLengthBytes + 2)
    }

    @Test func requestLineTooLong() throws {
        let long = String(repeating: "a", count: 2000)
        let u = GeminiURI(host: "example.com", path: "/\(long)")
        // requestLine itself doesn't throw; client validates. Just assert it exceeds cap.
        #expect(u.requestLine.count > GeminiURI.maxRequestLengthBytes)
    }

    @Test func resolveAbsolute() throws {
        let base = try GeminiURI.parse("gemini://a.com/dir/page")
        let u = try base.resolving("gemini://b.com/other")
        #expect(u.host == "b.com")
        #expect(u.path == "/other")
    }

    @Test func resolveRootRelative() throws {
        let base = try GeminiURI.parse("gemini://a.com/dir/page")
        let u = try base.resolving("/top")
        #expect(u.host == "a.com")
        #expect(u.path == "/top")
    }

    @Test func resolveRelative() throws {
        let base = try GeminiURI.parse("gemini://a.com/dir/page")
        let u = try base.resolving("sibling")
        #expect(u.path == "/dir/sibling")
    }

    @Test func resolveProtocolRelative() throws {
        let base = try GeminiURI.parse("gemini://a.com/dir/page")
        let u = try base.resolving("//b.com/x")
        #expect(u.host == "b.com")
    }

    @Test func dotSegmentsNormalized() throws {
        let u = try GeminiURI.parse("gemini://a.com/x/../y/./z")
        #expect(u.path == "/y/z")
    }

    @Test func percentEncodeDecodeRoundTrip() {
        let original = "héllo wörld/50%"
        let encoded = GeminiURI.encode(original)
        // encode() leaves unreserved + sub-delim chars (incl. space, /) alone,
        // but must encode non-ASCII and the literal %.
        #expect(!encoded.contains("é"))
        #expect(encoded.contains("%25"))
        #expect(GeminiURI.percentDecode(encoded) == original)
    }

    @Test func normalizedSchemeAddsPrefix() {
        #expect("example.com".normalizedScheme() == "gemini://example.com")
        #expect("gemini://example.com".normalizedScheme() == "gemini://example.com")
    }

    @Test func withInputQuery() throws {
        let base = try GeminiURI.parse("gemini://a.com/search")
        let q = base.withInputQuery("hello world")
        #expect(q.query == "hello world")
        #expect(q.host == "a.com")
    }
}

struct GeminiResponseTests {
    @Test func parseSuccess() throws {
        let h = try GeminiResponseHeader.parse(Data("20 text/gemini\r\n".utf8))
        #expect(h.status.code == 20)
        #expect(h.status.meta == "text/gemini")
        #expect(h.status.isSuccess)
    }

    @Test func parseInput() throws {
        let h = try GeminiResponseHeader.parse(Data("10 prompt here\r\n".utf8))
        #expect(h.status.isInput)
        #expect(!h.status.isSensitiveInput)
    }

    @Test func parseSensitiveInput() throws {
        let h = try GeminiResponseHeader.parse(Data("11 password\r\n".utf8))
        #expect(h.status.isSensitiveInput)
    }

    @Test func parseRedirect() throws {
        let h = try GeminiResponseHeader.parse(Data("30 /elsewhere\r\nrest of body".utf8))
        #expect(h.status.isRedirect)
    }

    @Test func parseEmptyMeta() throws {
        // The separating space is required even when META is empty.
        let h = try GeminiResponseHeader.parse(Data("51 \r\n".utf8))
        #expect(h.status.code == 51)
        #expect(h.status.meta == "")
    }

    @Test func rejectBadCode() {
        #expect(throws: GeminiProtocolError.self) {
            try GeminiResponseHeader.parse(Data("99 nope\r\n".utf8))
        }
    }

    @Test func rejectMissingCRLF() {
        #expect(throws: GeminiProtocolError.self) {
            try GeminiResponseHeader.parse(Data("20 text/gemini".utf8))
        }
    }

    @Test func rejectOversize() {
        let big = Data(("20 " + String(repeating: "x", count: 2000) + "\r\n").utf8)
        #expect(throws: GeminiProtocolError.self) { try GeminiResponseHeader.parse(big) }
    }

    @Test func statusDescriptions() {
        #expect(GeminiStatus(code: 20, meta: "")?.statusDescription == "Success")
        #expect(GeminiStatus(code: 51, meta: "")?.statusDescription == "Not found")
        #expect(GeminiStatus(code: 10, meta: "")?.statusDescription == "Input required")
        #expect(GeminiStatus(code: 61, meta: "")?.statusDescription == "Client certificate not authorized")
    }

    @Test func invalidStatusInit() {
        #expect(GeminiStatus(code: 0, meta: "") == nil)
        #expect(GeminiStatus(code: 70, meta: "") == nil)
    }
}
