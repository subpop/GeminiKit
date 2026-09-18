import ArgumentParser
import Foundation
import GeminiKit

// MARK: - gemini fetch: fetch a gemini URL and print it.
//
// Default output renders text/gemini with light ANSI styling.
// --raw writes the body bytes untouched (for downloads / non-gemtext).
// --status prints only "<code> <meta>" to stdout.
// Exit 0 on a completed fetch, 1 on any error (message on stderr).

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

struct Fetch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fetch",
        abstract: "Fetch a Gemini URL and print it."
    )

    @Flag(help: "Write the body bytes untouched (for downloads / non-gemtext).")
    var raw = false

    @Flag(name: .customLong("status"), help: "Print only \"<code> <meta>\" to stdout.")
    var statusOnly = false

    @Option(help: "Request timeout in seconds (must be greater than zero).")
    var timeout: TimeInterval = 60

    @Flag(help: "Forget the stored certificate for this host instead of enforcing TOFU.")
    var insecure = false

    @Option(help: "Service prefix for the certificate store.")
    var tofuPrefix: String?

    @Argument(help: "The gemini:// URL to fetch.")
    var url: String

    mutating func run() async throws {
        guard timeout > 0 else {
            throw ValidationError("'--timeout' must be greater than zero.")
        }

        let uri: GeminiURI
        do {
            uri = try GeminiURI.parse(url.normalizedScheme())
        } catch {
            fail("invalid URL: \(error.localizedDescription)")
        }

        let client = tofuPrefix.map(GeminiClient.init(servicePrefix:)) ?? GeminiClient()
        let result: GeminiFetchResult
        do {
            result = try await client.fetch(uri, timeout: timeout)
        } catch {
            fail("fetch failed: \(error.localizedDescription)")
        }
        if insecure {
            await client.certificateStore.delete(host: uri.host, port: uri.port)
        }

        switch result {
        case .status(let s):
            if statusOnly {
                print("\(s.code) \(s.meta)")
            } else {
                fail("\(s.code) \(s.meta.isEmpty ? s.statusDescription : s.meta)")
            }
        case .redirect(let target):
            print("30 \(target)")
        case .certMismatch(let stored, let presented):
            let hex = { (b: [UInt8]) in b.map { String(format: "%02x", $0) }.joined() }
            fail(
                "certificate mismatch: trusted \(hex(stored).prefix(16))… presented \(hex(presented).prefix(16))…"
            )
        case .content(let mime, let data):
            if statusOnly {
                print("20 \(mime)")
            } else if raw || !mime.hasPrefix("text/gemini") {
                FileHandle.standardOutput.write(data)
            } else {
                print(renderANSI(GemtextParser.parse(gemtextString(from: data))))
            }
        }
    }
}

// MARK: - Minimal ANSI renderer for text/gemini

private enum ANSI {
    static let reset = "\u{1B}[0m"
    static let bold = "\u{1B}[1m"
    static let dim = "\u{1B}[2m"
    static let italic = "\u{1B}[3m"
    static let underline = "\u{1B}[4m"
    static let cyan = "\u{1B}[36m"
    static let yellow = "\u{1B}[33m"
}

func renderANSI(_ blocks: [GemtextBlock]) -> String {
    var out: [String] = []
    for block in blocks {
        switch block {
        case .text(let s):
            out.append(s)
        case .heading(let level, let text):
            let hashes = String(repeating: "#", count: level)
            out.append("\(ANSI.bold)\(hashes) \(text)\(ANSI.reset)")
        case .bullet(let s):
            out.append("• \(s)")
        case .link(let url, let label):
            out.append(
                "\(ANSI.cyan)\(ANSI.underline)=> \(label ?? url)\(ANSI.reset) \(ANSI.dim)(\(url))\(ANSI.reset)"
            )
        case .quote(let s):
            out.append("\(ANSI.dim)> \(s)\(ANSI.reset)")
        case .pre(let s):
            out.append("\(ANSI.dim)\(s)\(ANSI.reset)")
        }
    }
    return out.joined(separator: "\n") + "\n"
}

private func yellow(_ s: String) -> String { "\(ANSI.yellow)\(s)\(ANSI.reset)" }
