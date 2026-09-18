import ArgumentParser
import Foundation
import GeminiKit
import Network
import Security

// MARK: - gemini serve: basic Gemini server for testing clients.
//
// Generates an ephemeral self-signed identity at startup (in-process),
// serves demo routes exercising every status class, and optionally serves
// static files from --root (.gmi -> text/gemini, everything else octet-stream).

// MARK: - Routes

/// Route a request URI to (status, meta, body?).
func route(_ uri: GeminiURI, root: URL?) -> (Int, String, Data?) {
    let body: (String) -> Data? = { Data($0.utf8) }
    switch uri.path {
    case "/":
        return (
            20, "text/gemini",
            body(
                """
                # gemini demo server

                Reference server for testing Gemini clients.

                ## Input flow
                => /input Ask me something

                ## Redirects
                => /redirect Single temporary redirect
                => /chain/3 Three-hop chain
                => /foreign Off-host redirect (points at geminiprotocol.net)

                ## Errors
                => /error/40 Temporary failure
                => /error/51 Not found
                => /error/59 Bad request

                ## Misc
                => /echo?hello Echo a query back
                => /big 1 MB payload
                """)
        )
    case "/input":
        if let q = uri.query, !q.isEmpty {
            return (20, "text/gemini", body("# You said\n\n> \(q)\n"))
        }
        return (10, "Say something", nil)
    case "/echo":
        let q = uri.query ?? "(no query)"
        return (20, "text/gemini", body("# Echo\n\nYou sent: \(q)\n"))
    case "/redirect":
        return (30, "/echo?from=redirect", nil)
    case "/foreign":
        return (30, "gemini://geminiprotocol.net/", nil)
    case "/big":
        return (20, "text/plain", Data(repeating: 0x41, count: 1024 * 1024))
    case "/binary":
        return (
            20, "application/octet-stream", Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        )
    default:
        if uri.path.hasPrefix("/chain/") {
            let n = Int(uri.path.dropFirst("/chain/".count)) ?? -1
            if n < 0 { return (59, "Bad chain index", nil) }
            if n == 0 {
                return (
                    20, "text/gemini", body("# Chain complete\n\nYou followed the whole chain.\n")
                )
            }
            return (30, "/chain/\(n - 1)", nil)
        }
        if uri.path.hasPrefix("/error/") {
            let code = Int(uri.path.dropFirst("/error/".count)) ?? 40
            let known: [Int: String] = [
                40: "Temporary failure", 41: "Unavailable", 44: "Slow down",
                50: "Permanent failure", 51: "Not found", 52: "Gone", 59: "Bad request",
            ]
            return (code, known[code] ?? "Error", nil)
        }
        if let root {
            return serveStatic(path: uri.path, root: root)
        }
        return (51, "Not found", nil)
    }
}

func serveStatic(path: String, root: URL) -> (Int, String, Data?) {
    // Block traversal: lexically normalize and reject escapes.
    var segs: [String] = []
    for seg in path.split(separator: "/").map(String.init) {
        if seg == "." || seg.isEmpty { continue }
        if seg == ".." { return (59, "Bad request", nil) }
        segs.append(seg)
    }
    var url = root
    for s in segs { url.appendPathComponent(s) }
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
        return (51, "Not found: \(path)", nil)
    }
    if isDir.boolValue {
        let index = url.appendingPathComponent("index.gmi")
        if FileManager.default.fileExists(atPath: index.path) {
            url = index
        } else {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            let links = names.map { "=> \(path.hasSuffix("/") ? path : path + "/")\($0) \($0)" }
                .joined(separator: "\n")
            return (20, "text/gemini", Data("# Index of \(path)\n\n\(links)\n".utf8))
        }
    }
    guard let data = try? Data(contentsOf: url) else { return (50, "Cannot read file", nil) }
    let mime = url.pathExtension.lowercased() == "gmi" ? "text/gemini" : "application/octet-stream"
    return (20, mime, data)
}

// MARK: - Listener

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Run the reference Gemini server for testing clients."
    )

    @Option(help: "Port to listen on.")
    var port: UInt16 = 1966

    @Option(help: "Directory to serve static files from.")
    var root: String?

    mutating func run() async throws {
        guard port > 0 else {
            throw ValidationError("'--port' must be greater than zero.")
        }
        let port = self.port
        let root = root.map { URL(fileURLWithPath: $0, isDirectory: true) }

        let identity: sec_identity_t
        do {
            identity = try GeminiServer.makeEphemeralIdentity()
        } catch {
            fputs("identity: \(error.localizedDescription)\n", stderr)
            Darwin.exit(1)
        }

        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
        let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = true

        let listener: NWListener
        do {
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            fputs("listen: \(error.localizedDescription)\n", stderr)
            Darwin.exit(1)
        }
        let queue = DispatchQueue(label: "gemini-serve")
        listener.newConnectionHandler = { conn in Self.handle(conn, root: root, queue: queue) }
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                print("gemini listening on port \(port)")
                fflush(stdout)
            }
            if case .failed(let e) = state {
                fputs("listener failed: \(e)\n", stderr)
                Darwin.exit(1)
            }
        }
        listener.start(queue: queue)
        // Park forever: the listener's callbacks run on their own queue and the
        // server lives until the process is killed. Unsafe (not checked) on
        // purpose — this continuation is intentionally never resumed.
        await withUnsafeContinuation { (_: UnsafeContinuation<Never, Never>) in }
    }

    static func handle(_ conn: NWConnection, root: URL?, queue: DispatchQueue) {
        conn.stateUpdateHandler = { state in
            if case .ready = state { receiveRequest(conn, root: root, buffer: Data()) }
            if case .failed = state { conn.cancel() }
        }
        conn.start(queue: queue)
    }

    static func receiveRequest(_ conn: NWConnection, root: URL?, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 2048) { data, _, _, error in
            if error != nil {
                conn.cancel()
                return
            }
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.count > GeminiURI.maxRequestLengthBytes + 2 {
                respond(conn, status: 59, meta: "Request too long", body: nil)
                return
            }
            guard buffer.firstRange(of: Data("\r\n".utf8)) != nil else {
                receiveRequest(conn, root: root, buffer: buffer)
                return
            }
            let line = String(decoding: buffer, as: UTF8.self).trimmingCharacters(
                in: .whitespacesAndNewlines)
            let uri = try? GeminiURI.parse(line)
            guard let uri else {
                respond(conn, status: 59, meta: "Bad request", body: nil)
                return
            }
            let (code, meta, respBody) = route(uri, root: root)
            respond(conn, status: code, meta: meta, body: respBody)
        }
    }

    static func respond(_ conn: NWConnection, status: Int, meta: String, body: Data?) {
        var out = Data("\(status) \(meta)\r\n".utf8)
        if let body { out.append(body) }
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }
}
