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

    @Test
    func pipeTable() {
        let blocks = GemtextParser.parse(
            "```table\n| Name | Tier |\n| :--- | ---: |\n| arm | 2 |\n```"
        )
        #expect(blocks == [.table(rows: [["Name", "Tier"], ["arm", "2"]])])
    }

    @Test
    func pipeTableAltTextCaseInsensitive() {
        let blocks = GemtextParser.parse("```Table\n| A |\n| :- |\n| b |\n```")
        #expect(blocks == [.table(rows: [["A"], ["b"]])])
    }

    @Test
    func gridTable() {
        let blocks = GemtextParser.parse(
            "```table\n+-------+------+\n| Name  | Tier |\n+=======+======+\n| arm   | 2    |\n+-------+------+\n| x86   | 1    |\n+-------+------+\n```"
        )
        #expect(
            blocks == [.table(rows: [["Name", "Tier"], ["arm", "2"], ["x86", "1"]])])
    }

    @Test
    func gridTableWrappedCellsMerge() {
        let blocks = GemtextParser.parse(
            "```table\n+-------+-----+\n| A     | B   |\n+-------+-----+\n| long  | x   |\n| text  |     |\n+-------+-----+\n```"
        )
        #expect(blocks == [.table(rows: [["A", "B"], ["long text", "x"]])])
    }

    @Test
    func malformedTableFallsBackToPre() {
        let blocks = GemtextParser.parse("```table\n| a | b |\n| c |\n```")
        #expect(blocks == [.pre("| a | b |\n| c |")])
    }

    @Test
    func nonTableAltTextStaysPre() {
        let blocks = GemtextParser.parse("```swift\n| a |\n```")
        #expect(blocks == [.pre("| a |")])
    }

    @Test
    func gridContentWithoutTableAltStaysPre() {
        let blocks = GemtextParser.parse("```\n+---+\n| a |\n+---+\n```")
        #expect(blocks == [.pre("+---+\n| a |\n+---+")])
    }

    @Test
    func textStringDecodesUTF8() {
        let data = Data("héllo wörld".utf8)
        #expect(textString(from: data) == "héllo wörld")
        #expect(textString(from: data, charset: "utf-8") == "héllo wörld")
        #expect(textString(from: data, charset: "UTF-8") == "héllo wörld")
    }

    @Test
    func textStringHonorsASCIICharset() {
        let data = Data("plain ascii".utf8)
        #expect(textString(from: data, charset: "us-ascii") == "plain ascii")
        #expect(textString(from: data, charset: "ASCII") == "plain ascii")
        #expect(textString(from: data, charset: "\"us-ascii\"") == "plain ascii")
    }

    @Test
    func textStringFallsBackToLossyASCII() {
        // 0xE9 alone is not valid UTF-8; Latin-1 would decode it as "é".
        let data = Data([0x63, 0x61, 0x66, 0xE9])
        let decoded = textString(from: data)
        #expect(decoded == "caf�")
        #expect(textString(from: data, charset: "utf-8") == "caf�")
        #expect(textString(from: data, charset: nil) == "caf�")
    }

    @Test
    func textStringTreatsUnknownCharsetAsUTF8() {
        let data = Data("héllo".utf8)
        #expect(textString(from: data, charset: "iso-8859-1") == "héllo")
        #expect(textString(from: data, charset: "") == "héllo")
    }

    @Test
    func gemtextStringFallsBackToLossyASCII() {
        #expect(gemtextString(from: Data("hi".utf8)) == "hi")
        #expect(gemtextString(from: Data([0xE9])) == "�")
    }
}
