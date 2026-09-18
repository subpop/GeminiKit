import Foundation

/// One parsed Gemtext line: prose, heading, list item, quote, preformatted text, or link.
public enum GemtextBlock: Equatable, Sendable {
    /// Plain paragraph text.
    case text(String)
    /// `#`–`###` heading; `level` is 1–3.
    case heading(level: Int, text: String)
    /// `* ` list item.
    case bullet(String)
    /// `>` quotation line.
    case quote(String)
    /// Fenced ` ``` ` preformatted block (fences excluded).
    case pre(String)
    /// `=> URL [label]` link line.
    case link(url: String, label: String?)

    /// Label shown to the user; falls back to the host+path of the URL.
    public var linkText: String? {
        if case .link(let url, let label) = self { return label ?? url }
        return nil
    }
}

/// Stateless Gemtext parser (see `gemtext.gmi` in the Gemini spec).
public enum GemtextParser {
    /// Parses a Gemtext document into blocks per gemini://geminiprotocol.net/docs/gemtext.gmi.
    /// Invalid link lines are treated as literal text.
    /// - Parameter gemtext: The decoded `text/gemini` body (see ``gemtextString(from:)``).
    /// - Returns: Blocks in document order; blank lines are skipped.
    public static func parse(_ gemtext: String) -> [GemtextBlock] {
        var blocks: [GemtextBlock] = []
        var preLines: [String] = []
        var inPre = false

        for rawLine in gemtext.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        {
            let line = String(rawLine)

            if inPre {
                if line.trimmingCharacters(in: .whitespaces) == "```" {
                    inPre = false
                    blocks.append(.pre(preLines.joined(separator: "\n")))
                    preLines.removeAll()
                } else {
                    preLines.append(line)
                }
                continue
            }

            if line.trimmingCharacters(in: .whitespaces) == "```" {
                inPre = true
                continue
            }

            guard !line.isEmpty else { continue }

            if let heading = parseHeading(line) {
                blocks.append(.heading(level: heading.0, text: heading.1))
            } else if line.hasPrefix("* ") {
                blocks.append(
                    .bullet(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
            } else if line == "*" {
                blocks.append(.bullet(""))
            } else if line.hasPrefix(">") {
                blocks.append(
                    .quote(String(line.dropFirst(1)).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("=>") {
                if let link = parseLink(line) {
                    blocks.append(.link(url: link.0, label: link.1))
                } else {
                    blocks.append(.text(line))
                }
            } else {
                blocks.append(.text(line))
            }
        }
        // Unterminated pre-format block: include it as-is.
        if inPre, !preLines.isEmpty {
            blocks.append(.pre(preLines.joined(separator: "\n")))
        }
        return blocks
    }

    /// "#", "##", "###" followed by optional space + text; anything else is literal text.
    private static func parseHeading(_ line: String) -> (Int, String)? {
        let hashCount = line.prefix(while: { $0 == "#" }).count
        guard (1...3).contains(hashCount) else { return nil }
        let rest = line.dropFirst(hashCount)
        guard rest.isEmpty || rest.first == " " else { return nil }
        let text = String(rest).trimmingCharacters(in: .whitespaces)
        return (hashCount, text)
    }

    /// Returns (url, label?) or nil for a malformed link line (caller renders literal).
    private static func parseLink(_ line: String) -> (String, String?)? {
        var rest = String(line.dropFirst(2))  // strip "=>"
        // The whitespace between "=>" and the URL is optional.
        rest = rest.trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        // url is first token, label is everything after the FIRST following whitespace
        if let sp = rest.firstIndex(where: { $0 == " " || $0 == "\t" }) {
            let url = String(rest[..<sp]).trimmingCharacters(in: .whitespaces)
            let label = String(rest[rest.index(after: sp)...]).trimmingCharacters(
                in: .whitespaces)
            if url.isEmpty { return nil }
            return (url, label.isEmpty ? nil : label)
        }
        return (rest, nil)
    }
}

/// Decode a `text/gemini` body to String (UTF-8, falling back to Latin-1).
/// - Parameter data: Raw response body bytes from ``GeminiFetchResult/content(mimetype:data:)``.
public func gemtextString(from data: Data) -> String {
    String(data: data, encoding: .utf8)
        ?? String(data: data, encoding: .isoLatin1)
        ?? String(decoding: data, as: UTF8.self)
}
