import Foundation

/// One parsed Gemtext line: prose, heading, list item, quote, preformatted text, table, or link.
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
    /// Fenced ` ```table ` ASCII-grid table (e.g. md2gemtext output);
    /// `rows[0]` is the header row.
    case table(rows: [[String]])
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
        var preAlt: String?
        var inPre = false

        for rawLine in gemtext.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        {
            let line = String(rawLine)

            if inPre {
                if line.trimmingCharacters(in: .whitespaces) == "```" {
                    inPre = false
                    blocks.append(finishPre(lines: preLines, altText: preAlt))
                    preLines.removeAll()
                    preAlt = nil
                } else {
                    preLines.append(line)
                }
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inPre = true
                let alt = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                preAlt = alt.isEmpty ? nil : String(alt)
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

    /// Builds the block for a closed preformatted section: a `.table` when the
    /// fence alt text is `table` (case-insensitive, e.g. md2gemtext output) and
    /// the content parses as an ASCII grid, otherwise a plain `.pre`.
    private static func finishPre(lines: [String], altText: String?) -> GemtextBlock {
        if let altText, altText.lowercased() == "table", let rows = parseTable(lines) {
            return .table(rows: rows)
        }
        return .pre(lines.joined(separator: "\n"))
    }

    /// Parses table-drawing preformatted content into rows (`rows[0]` is the header).
    /// Supports `+---+` separator grids (consecutive `|` lines between separators
    /// merge into one logical row for wrapped cells) and md2gemtext-style `| a | b |`
    /// rows with a `:---` delimiter row after the header. Returns nil when the
    /// content is not a well-formed table.
    private static func parseTable(_ lines: [String]) -> [[String]]? {
        let content = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !content.isEmpty else { return nil }
        if content.contains(where: isGridSeparator) {
            return parseGridTable(content)
        }
        return parsePipeTable(content)
    }

    /// `+---+` (or `+===+`) separator line.
    private static func isGridSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("+"), trimmed.hasSuffix("+"), trimmed.count >= 3,
            trimmed.allSatisfy({ "+-=".contains($0) }),
            trimmed.contains("-") || trimmed.contains("=")
        else { return false }
        return true
    }

    /// Splits a `| cell | cell |` line into trimmed cells, or nil if not pipe-delimited.
    private static func splitPipeRow(_ line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|"), trimmed.hasSuffix("|"), trimmed.count >= 2 else {
            return nil
        }
        return trimmed.dropFirst().dropLast().split(
            separator: "|", omittingEmptySubsequences: false
        ).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Grid tables: groups of consecutive `|` lines separated by `+---+` lines.
    private static func parseGridTable(_ lines: [String]) -> [[String]]? {
        var rows: [[String]] = []
        var run: [[String]] = []
        var columnCount: Int?
        var sawData = false

        func flush() {
            guard !run.isEmpty else { return }
            let merged = (0..<(columnCount ?? 0)).map { col in
                run.compactMap { $0[col].isEmpty ? nil : $0[col] }.joined(separator: " ")
            }
            rows.append(merged)
            run.removeAll()
        }

        for line in lines {
            if isGridSeparator(line) {
                flush()
                continue
            }
            guard let cells = splitPipeRow(line) else { return nil }
            if let columnCount, cells.count != columnCount { return nil }
            columnCount = cells.count
            run.append(cells)
            sawData = true
        }
        flush()
        guard sawData else { return nil }
        return rows
    }

    /// md2gemtext tables: `| a | b |` rows with a `:---` delimiter row after the header.
    private static func parsePipeTable(_ lines: [String]) -> [[String]]? {
        var rows: [[String]] = []
        for line in lines {
            guard let cells = splitPipeRow(line) else { return nil }
            rows.append(cells)
        }
        guard let first = rows.first, !first.isEmpty,
            rows.allSatisfy({ $0.count == first.count })
        else { return nil }
        // Drop the `:---` alignment delimiter below the header, when present.
        if rows.count >= 2,
            rows[1].allSatisfy({
                !$0.isEmpty
                    && $0.allSatisfy({ "-:".contains($0) })
                    && $0.contains("-")
            })
        {
            rows.remove(at: 1)
        }
        return rows
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

/// Normalize a `charset` MIME parameter value for the supported charsets (UTF-8, US-ASCII).
/// - Parameter charset: Raw `charset` parameter value (e.g. `"\"us-ascii\""`), or `nil`.
/// - Returns: Canonical lowercase name without quotes, or `nil` when absent/empty.
func normalizedCharset(_ charset: String?) -> String? {
    guard var value = charset?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
        return nil
    }
    if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
        value = String(value.dropFirst().dropLast())
    }
    let lowered = value.lowercased()
    return lowered.isEmpty ? nil : lowered
}

/// Decode a `text/*` response body to String, honoring the `charset` MIME parameter.
///
/// UTF-8 is tried first (per the Gemini spec, an absent or unrecognized charset
/// means UTF-8); when it fails, decoding falls back to lossy US-ASCII.
/// - Parameters:
///   - data: Raw response body bytes from ``GeminiFetchResult/content(statusCode:mimetype:data:certificate:)``.
///   - charset: Raw `charset` parameter value from the response MIME type, or `nil`.
public func textString(from data: Data, charset: String? = nil) -> String {
    switch normalizedCharset(charset) {
    case "us-ascii", "ascii":
        return String(decoding: data, as: Unicode.ASCII.self)
    default:
        // UTF-8 (default per spec), or an unrecognized charset treated as UTF-8.
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: Unicode.ASCII.self)
    }
}

/// Decode a `text/gemini` body to String (UTF-8, falling back to lossy ASCII).
/// - Parameter data: Raw response body bytes from ``GeminiFetchResult/content(statusCode:mimetype:data:certificate:)``.
public func gemtextString(from data: Data) -> String {
    textString(from: data)
}
