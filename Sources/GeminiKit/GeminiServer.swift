import Foundation
import Network
import Security

/// A response served by ``GeminiServer`` for one request.
public struct GeminiServerResponse: Sendable {
    /// Numeric status code (e.g. 20, 30, 51).
    public let status: Int
    /// META field: MIME type, prompt, or redirect target depending on ``status``.
    public let meta: String
    /// Optional body bytes, sent only for `2x` success responses.
    public let body: Data?

    /// Creates a response with an explicit status, META, and optional body.
    public init(status: Int, meta: String, body: Data? = nil) {
        self.status = status
        self.meta = meta
        self.body = body
    }

    /// `20` success with a MIME type and body.
    public static func success(mime: String, body: Data) -> GeminiServerResponse {
        GeminiServerResponse(status: 20, meta: mime, body: body)
    }

    /// `10` (or `11` when `sensitive`) input prompt.
    public static func input(prompt: String, sensitive: Bool = false) -> GeminiServerResponse {
        GeminiServerResponse(status: sensitive ? 11 : 10, meta: prompt)
    }

    /// `30` (or `31` when `permanent`) redirect.
    public static func redirect(to target: String, permanent: Bool = false) -> GeminiServerResponse
    {
        GeminiServerResponse(status: permanent ? 31 : 30, meta: target)
    }

    /// Any failure status (`40`...`69`).
    public static func error(code: Int, meta: String) -> GeminiServerResponse {
        GeminiServerResponse(status: code, meta: meta)
    }
}

/// Failures thrown by ``GeminiServer/start()`` and ``GeminiServer/makeEphemeralIdentity()``.
public enum GeminiServerError: LocalizedError, Equatable {
    case identity(String)
    case listenFailed(String)
    case alreadyRunning

    public var errorDescription: String? {
        switch self {
        case .identity(let s), .listenFailed(let s): return s
        case .alreadyRunning: return "Server is already running"
        }
    }
}

/// Hosts a Gemini server: accepts TLS connections, parses each request line
/// into a ``GeminiURI``, runs the handler, and sends the response.
///
/// Mirrors ``GeminiClient`` — the handler runs on Swift concurrency, so it can
/// be `async` and do file I/O, database lookups, etc.
///
///     let server = GeminiServer(port: 1965) { uri in
///         .success(mime: "text/gemini", body: Data("# Hello\n".utf8))
///     }
///     try await server.start()
///     // ... later ...
///     server.stop()
///
/// Drive `start()` from an `async` context with a live concurrency pool (e.g.
/// `static func main() async`). A detached `Task` created from a synchronous
/// `main()` while the main thread is blocked is never scheduled, so `start()`
/// would hang.
public final class GeminiServer: @unchecked Sendable {
    /// Maps a parsed request URI to the response; runs on Swift concurrency and may be `async`.
    public typealias Handler = @Sendable (GeminiURI) async -> GeminiServerResponse

    /// Port requested at creation; `0` asks the OS for any free port (see ``boundPort``).
    public let requestedPort: UInt16
    private let identitySource: IdentitySource
    private let handler: Handler

    private let queue = DispatchQueue(label: "geminikit.server")
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var boundPortValue: UInt16?

    private enum IdentitySource {
        case ephemeral
        case provided(sec_identity_t)
    }

    /// Serve with an ephemeral self-signed identity, generated at ``start()``
    /// time. Clients will TOFU-pin it on first connect (same as `gemini serve`).
    public init(port: UInt16 = 1966, handler: @escaping Handler) {
        self.requestedPort = port
        self.identitySource = .ephemeral
        self.handler = handler
    }

    /// Serve with a caller-provided TLS identity (e.g. a proper certificate).
    public init(port: UInt16 = 1966, identity: sec_identity_t, handler: @escaping Handler) {
        self.requestedPort = port
        self.identitySource = .provided(identity)
        self.handler = handler
    }

    /// The port the listener actually bound (equals `requestedPort` unless that
    /// was 0, which asks the OS for any free port). `nil` while stopped.
    public var boundPort: UInt16? {
        lock.withLock { boundPortValue }
    }

    /// `true` while the listener is bound and accepting connections.
    public var isRunning: Bool {
        lock.withLock { listener != nil }
    }

    /// Start listening. Resumes once the listener is `.ready`; throws
    /// ``GeminiServerError`` if the identity cannot be created or the port
    /// cannot be bound. May be called again after ``stop()``.
    public func start() async throws {
        let alreadyRunning = lock.withLock { self.listener != nil }
        if alreadyRunning { throw GeminiServerError.alreadyRunning }

        let identity = try resolveIdentity()

        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
        let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = true

        let newListener: NWListener
        do {
            newListener = try NWListener(
                using: params, on: NWEndpoint.Port(rawValue: requestedPort)!)
        } catch {
            throw GeminiServerError.listenFailed(error.localizedDescription)
        }

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            let once = ResumeBox()
            newListener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.lock.withLock {
                        self?.listener = newListener
                        self?.boundPortValue = newListener.port?.rawValue
                    }
                    once.run { continuation.resume() }
                case .failed(let error):
                    once.run {
                        continuation.resume(
                            throwing: GeminiServerError.listenFailed(error.localizedDescription))
                    }
                default:
                    break
                }
            }
            newListener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            newListener.start(queue: self.queue)
        }
    }

    /// Stop listening and cancel all open connections.
    public func stop() {
        let (listener, connections): (NWListener?, [NWConnection]) = lock.withLock {
            let l = self.listener
            self.listener = nil
            self.boundPortValue = nil
            let c = Array(self.connections)
            self.connections.removeAll()
            return (l, c)
        }
        listener?.cancel()
        for conn in connections { conn.cancel() }
    }

    // MARK: - Connections

    private func handle(_ conn: NWConnection) {
        lock.withLock { connections.append(conn) }
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receiveRequest(conn, buffer: Data())
            case .failed, .cancelled:
                self?.close(conn)
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func close(_ conn: NWConnection) {
        lock.withLock { connections.removeAll { $0 === conn } }
        conn.cancel()
    }

    private func receiveRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 2048) {
            [weak self] data, _, _, error in
            guard let self else {
                conn.cancel()
                return
            }
            if error != nil {
                self.close(conn)
                return
            }
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.count > GeminiURI.maxRequestLengthBytes + 2 {
                self.respond(conn, with: .error(code: 59, meta: "Request too long"))
                return
            }
            guard buffer.firstRange(of: Data("\r\n".utf8)) != nil else {
                self.receiveRequest(conn, buffer: buffer)
                return
            }
            let line = String(decoding: buffer, as: UTF8.self).trimmingCharacters(
                in: .whitespacesAndNewlines)
            guard let uri = try? GeminiURI.parse(line) else {
                self.respond(conn, with: .error(code: 59, meta: "Bad request"))
                return
            }
            let handler = self.handler
            Task {
                let response = await handler(uri)
                self.respond(conn, with: response)
            }
        }
    }

    private func respond(_ conn: NWConnection, with response: GeminiServerResponse) {
        var out = Data("\(response.status) \(response.meta)\r\n".utf8)
        if let body = response.body { out.append(body) }
        conn.send(
            content: out,
            completion: .contentProcessed { [weak self] _ in
                guard let self else {
                    conn.cancel()
                    return
                }
                self.close(conn)
            })
    }

    // MARK: - Identity

    private func resolveIdentity() throws -> sec_identity_t {
        switch identitySource {
        case .ephemeral:
            return try Self.makeEphemeralIdentity()
        case .provided(let identity):
            return identity
        }
    }
}

// MARK: - Helpers

/// Runs `work` at most once across threads (for checked continuations shared
/// with `NWListener` state callbacks).
private final class ResumeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func run(_ work: () -> Void) {
        let shouldRun = lock.withLock { () -> Bool in
            if resumed { return false }
            resumed = true
            return true
        }
        if shouldRun { work() }
    }
}
