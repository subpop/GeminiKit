import Testing
import Foundation
@testable import GeminiKit

struct GemtextParserTests {
    @Test
    func headings() {
        let blocks = GemtextParser.parse("# Title\n## Sub\n### Sub3\n#nospace\n#### four")
        #expect(blocks == [
            .heading(level: 1, text: "Title"),
            .heading(level: 2, text: "Sub"),
            .heading(level: 3, text: "Sub3"),
            .text("#nospace"),
            .text("#### four"),
        ])
    }

    @Test
    func bulletAndQuote() {
        let blocks = GemtextParser.parse("* item\n*squish\n> quoted")
        #expect(blocks == [.bullet("item"), .text("*squish"), .quote("quoted")])
    }

    @Test
    func links() {
        let blocks = GemtextParser.parse(
            "=> gemini://example.org A label\n=> /relative\n=> gopher://example.org/7_selector alt\n=>/foo noSpace\nprefix=> /foo label"
        )
        #expect(blocks == [
            .link(url: "gemini://example.org", label: "A label"),
            .link(url: "/relative", label: nil),
            .link(url: "gopher://example.org/7_selector", label: "alt"),
            .link(url: "/foo", label: "noSpace"),
            .text("prefix=> /foo label")
        ])
    }

    @Test
    func tabSeparatedLinks() {
        let blocks = GemtextParser.parse(
            "=> docs/faq.gmi\tIf you'd like to know more, read our FAQ\n=>\t/tab-after-arrow"
        )
        #expect(blocks == [
            .link(
                url: "docs/faq.gmi",
                label: "If you'd like to know more, read our FAQ"),
            .link(url: "/tab-after-arrow", label: nil),
        ])
    }

    @Test
    func malformedLinksAreLiteral() {
        let blocks = GemtextParser.parse("=>nospace\n=>\n=>  ")
        #expect(blocks == [.link(url: "nospace", label: nil), .text("=>"), .text("=>  ")])
    }

    @Test
    func preformatToggle() {
        let blocks = GemtextParser.parse("text\n```\nfoo\n\tbar*=># ```\n```\nafter")
        #expect(blocks[1] == .pre("foo\n\tbar*=># ```"))
        #expect(blocks.last == .text("after"))
    }

    @Test
    func unterminatedPre() {
        let blocks = GemtextParser.parse("```\nonly pre")
        #expect(blocks == [.pre("only pre")])
    }

    @Test
    func blankLinesAndCRLF() {
        let blocks = GemtextParser.parse("a\r\n\r\nb\r\n")
        #expect(blocks == [.text("a"), .text("b")])
    }

    @Test
    func empty() {
        #expect(GemtextParser.parse("") == [])
    }
}
