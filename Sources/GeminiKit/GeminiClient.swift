import CryptoKit
import Foundation
import Network
import Security

/// The outcome of ``GeminiClient/fetch(_:)``: body bytes, a redirect,
/// a terminal status, or a TOFU certificate mismatch.
public enum GeminiFetchResult: Sendable {
    /// `2x` success: MIME type plus raw body bytes.
    case content(mimetype: String, data: Data)
    /// `3x` redirect: the target URL from the response META field.
    case redirect(target: String)
    /// Any non-body terminal status (`1x` input, `4x`–`6x` failures).
    case status(GeminiStatus)
    /// The server presented a different certificate than the pinned one.
    /// Compare fingerprints, then clear the pin and retry if the change is expected.
    case certMismatch(storedFingerprint: [UInt8], presentedFingerprint: [UInt8])

    /// One-line summary for logging (body bytes and metadata elided).
    public var tag: String {
        switch self {
        case .content(let m, let d): return "content \(m) \(d.count)B"
        case .redirect(let t): return "redirect \(t)"
        case .status(let s): return "status \(s.code)"
        case .certMismatch: return "certMismatch"
        }
    }
}

/// Transport-level failures thrown by ``GeminiClient/fetch(_:)``.
/// Protocol-level outcomes (redirects, input prompts, status codes) arrive as
/// ``GeminiFetchResult`` instead of errors.
public enum GeminiFetchError: LocalizedError, Equatable, Sendable {
    case timedOut
    case connectionFailed(String)
    case sendFailed(String)
    case protocolError(String)
    case tooLarge

    public var errorDescription: String? {
        switch self {
        case .timedOut: return "Connection timed out"
        case .connectionFailed(let s), .sendFailed(let s), .protocolError(let s): return s
        case .tooLarge: return "Response exceeds 32 MB limit"
        }
    }
}

/// Fetches gemini URLs using NWConnection with TLS and TOFU certificate verification.
///
/// The single public API is async; results resume on the caller's executor.
///
///     let uri = try GeminiURI.parse("gemini://example.com/")
///     switch try await GeminiClient.shared.fetch(uri) {
///     case .content(let mime, let data): print(mime, data.count)
///     case .redirect(let target): print("redirect:", target)
///     case .status(let status): print("status:", status.code)
///     case .certMismatch: print("certificate changed!")
///     }
/// A TLS client identity for `6x` challenges.
///
/// `SecIdentity` is a thread-safe Security object but is not marked `Sendable`,
/// which Swift 6 callers need in order to pass an identity across isolation
/// boundaries. This wrapper carries the same reference and is `Sendable` by
/// construction; `nil` (no wrapper) presents no identity.
public struct ClientIdentity: @unchecked Sendable {
    public let identity: SecIdentity

    public init(_ identity: SecIdentity) {
        self.identity = identity
    }
}

public final class GeminiClient: @unchecked Sendable {
    /// Shared client using the default certificate store namespace.
    public static let shared = GeminiClient()

    /// Keychain-backed TOFU pins consulted (and updated) on every fetch.
    public let certificateStore: CertificateStore

    /// Responses larger than this are rejected with ``GeminiFetchError/tooLarge``.
    public static let maxBodyBytes = 32 * 1024 * 1024

    /// Creates a client with an isolated certificate namespace.
    /// - Parameter servicePrefix: Keychain service namespace, forwarded to ``CertificateStore``.
    public init(servicePrefix: String = "geminikit.tofu") {
        self.certificateStore = CertificateStore(servicePrefix: servicePrefix)
    }

    /// Fetches `uri`, following no redirects automatically.
    /// - Parameter uri: A parsed Gemini URL (see ``GeminiURI/parse(_:)``).
    /// - Returns: The fetch outcome; see ``GeminiFetchResult``.
    public func fetch(_ uri: GeminiURI) async throws -> GeminiFetchResult {
        let store = certificateStore
        return try await withCheckedThrowingContinuation { continuation in
            GeminiConnection.run(uri: uri, certificateStore: store) { result in
                continuation.resume(with: result)
            }
        }
    }

    /// Fetches `uri` while presenting a TLS client certificate.
    ///
    /// Use this after a host replies with a `6x` status: the server rejected the
    /// previous (or absent) client certificate and requests an acceptable one.
    /// `nil` presents no identity, equivalent to ``fetch(_:)``.
    /// - Parameters:
    ///   - uri: A parsed Gemini URL (see ``GeminiURI/parse(_:)``).
    ///   - clientIdentity: The identity to present during the TLS handshake.
    /// - Returns: The fetch outcome; see ``GeminiFetchResult``.
    public func fetch(
        _ uri: GeminiURI,
        clientIdentity: SecIdentity?
    ) async throws -> GeminiFetchResult {
        let store = certificateStore
        return try await withCheckedThrowingContinuation { continuation in
            GeminiConnection.run(
                uri: uri, certificateStore: store, clientIdentity: clientIdentity
            ) { result in
                continuation.resume(with: result)
            }
        }
    }

    /// Fetch with an overall deadline and a TLS client certificate.
    /// Throws ``GeminiFetchError/timedOut`` if the fetch does not complete in
    /// time. `nil` presents no identity.
    public func fetch(
        _ uri: GeminiURI,
        clientIdentity: SecIdentity?,
        timeout: TimeInterval
    ) async throws -> GeminiFetchResult {
        try await withThrowingTaskGroup(of: GeminiFetchResult.self) { group in
            group.addTask { try await self.fetch(uri, clientIdentity: clientIdentity) }
            group.addTask {
                try await Task.sleep(for: .seconds(max(timeout, 0)))
                throw GeminiFetchError.timedOut
            }
            guard let first = try await group.next() else {
                throw GeminiFetchError.timedOut
            }
            group.cancelAll()
            return first
        }
    }

    /// Fetches `uri` while presenting a TLS client certificate.
    ///
    /// `Sendable` variant of ``fetch(_:clientIdentity:)`` for Swift 6 callers:
    /// pass a ``ClientIdentity`` (or `nil` for no identity).
    public func fetch(
        _ uri: GeminiURI,
        clientIdentity: ClientIdentity?
    ) async throws -> GeminiFetchResult {
        try await fetch(uri, clientIdentity: clientIdentity?.identity)
    }

    /// Fetch with an overall deadline and a TLS client certificate.
    ///
    /// `Sendable` variant of ``fetch(_:clientIdentity:timeout:)`` for Swift 6
    /// callers. Throws ``GeminiFetchError/timedOut`` if the fetch does not
    /// complete in time. `nil` presents no identity.
    public func fetch(
        _ uri: GeminiURI,
        clientIdentity: ClientIdentity?,
        timeout: TimeInterval
    ) async throws -> GeminiFetchResult {
        try await fetch(uri, clientIdentity: clientIdentity?.identity, timeout: timeout)
    }

    /// Fetch with an overall deadline. Throws ``GeminiFetchError/timedOut`` if the
    /// fetch does not complete in time (the underlying connection keeps its own
    /// 10s connect / 30s idle timeouts, whichever fires first wins).
    public func fetch(_ uri: GeminiURI, timeout: TimeInterval) async throws -> GeminiFetchResult {
        try await withThrowingTaskGroup(of: GeminiFetchResult.self) { group in
            group.addTask { try await self.fetch(uri) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
                throw GeminiFetchError.timedOut
            }
            guard let first = try await group.next() else {
                throw GeminiFetchError.timedOut
            }
            group.cancelAll()
            return first
        }
    }
}

private enum GeminiConnection {
    static func run(
        uri: GeminiURI,
        certificateStore: CertificateStore,
        clientIdentity: SecIdentity? = nil,
        completion: @escaping @Sendable (Result<GeminiFetchResult, GeminiFetchError>) -> Void
    ) {
        let queue = DispatchQueue(label: "geminikit.network", qos: .userInitiated)

        // Per-session state lives in a class so nested closures can mutate it.
        let state = SessionState()
        let certMismatch = CertMismatchBox()

        // ----- TLS TOFU -----
        // The verify block must be attached BEFORE NWConnection is created:
        // NWConnection copies the TLS options at init, so blocks added later are ignored.

        func tofuVerify(
            _ metadata: sec_protocol_metadata_t,
            _ trust: sec_trust_t,
            _ complete: @escaping @Sendable (Bool) -> Void
        ) {
            let trustRef = sec_trust_copy_ref(trust).takeRetainedValue()
            let chain = SecTrustCopyCertificateChain(trustRef) as? [SecCertificate]
            guard let cert = chain?.first else {
                complete(false)
                return
            }
            let der = SecCertificateCopyData(cert) as Data
            let digest = SHA256.hash(data: der)
            let presented = [UInt8](digest)

            // The store is an actor: hop onto Swift concurrency for the Keychain
            // check, then hop back to the network queue before touching session
            // state or `complete`, keeping all of that serialized on one queue.
            Task {
                let outcome = await certificateStore.check(
                    host: uri.host, port: uri.port, fingerprint: presented)
                if case .unknown = outcome {
                    await certificateStore.save(
                        host: uri.host, port: uri.port, fingerprint: presented)
                }
                queue.async {
                    if case .mismatch(let stored, let presentedFingerprint) = outcome {
                        certMismatch.value = (stored: stored, presented: presentedFingerprint)
                        complete(false)
                    } else {
                        complete(true)
                    }
                }
            }
        }

        let tcp = NWProtocolTCP.Options()
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, tofuVerify, queue)
        if let clientIdentity,
            let secIdentity = sec_identity_create(clientIdentity)
        {
            sec_protocol_options_set_local_identity(
                tls.securityProtocolOptions, secIdentity)
        }
        let params = NWParameters(tls: tls, tcp: tcp)
        let conn = NWConnection(
            to: NWEndpoint.hostPort(
                host: NWEndpoint.Host(uri.host),
                port: NWEndpoint.Port(rawValue: UInt16(uri.port)) ?? 1965),
            using: params
        )

        @Sendable func finishSuccess(_ result: GeminiFetchResult) {
            guard !state.finished else { return }
            state.finished = true
            state.idleTimer?.cancel()
            conn.cancel()
            if let mismatch = certMismatch.value {
                completion(
                    .success(
                        .certMismatch(
                            storedFingerprint: mismatch.stored,
                            presentedFingerprint: mismatch.presented)))
                return
            }
            completion(.success(result))
        }

        func fail(_ error: GeminiFetchError) {
            guard !state.finished else { return }
            state.finished = true
            state.idleTimer?.cancel()
            conn.cancel()
            completion(.failure(error))
        }

        func armTimeout(seconds: TimeInterval, _ error: GeminiFetchError) {
            state.idleTimer?.cancel()
            state.idleTimer = Task {
                do {
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                } catch {
                    return  // cancelled by re-arm or finish; the replacement wins
                }
                queue.async { fail(error) }
            }
        }

        func receiveLoop() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
                data, _, isComplete, error in
                guard !state.finished else { return }
                if let error {
                    fail(.connectionFailed(error.localizedDescription))
                    return
                }
                if state.headerParsed && state.earlyResultPending {
                    return  // already delivered a non-body result; wait for cancel
                }
                if let data, !data.isEmpty {
                    state.totalReceived += data.count
                    if state.totalReceived > GeminiClient.maxBodyBytes {
                        fail(.tooLarge)
                        return
                    }
                    if state.headerParsed {
                        state.body.append(data)
                    } else {
                        state.buffer.append(data)
                        processBuffer()
                    }
                }
                guard !state.finished else { return }
                let drained = data == nil || data!.isEmpty
                if state.headerParsed && state.isSuccess && drained {
                    deliverContent()
                    return
                }
                if !state.headerParsed && drained {
                    fail(.protocolError("Connection closed before header was received"))
                    return
                }
                receiveLoop()
            }
        }

        func processBuffer() {
            guard !state.headerParsed else { return }
            guard let range = bufferHeaderRange(state.buffer) else {
                if state.buffer.count > GeminiResponseHeader.maxHeaderBytes {
                    fail(.protocolError("Response header exceeded 1029 bytes"))
                }
                return
            }
            let headData = state.buffer[state.buffer.startIndex..<range.lowerBound]
            var headPlusCRLF = Data(headData)
            headPlusCRLF.append(Data("\r\n".utf8))
            guard let header = try? GeminiResponseHeader.parse(headPlusCRLF) else {
                fail(.protocolError("Malformed response header"))
                return
            }
            state.headerParsed = true
            state.isSuccess = header.status.isSuccess
            if header.status.isSuccess {
                state.body = Data(state.buffer[range.upperBound...])
                state.mimetype = header.status.meta
                state.buffer.removeAll(keepingCapacity: false)
            } else if header.status.isRedirect {
                state.earlyResultPending = true
                finishSuccess(.redirect(target: header.status.meta))
            } else {
                state.earlyResultPending = true
                finishSuccess(.status(header.status))
            }
        }

        func deliverContent() {
            guard let mime = state.mimetype else {
                fail(.protocolError("Invalid success response"))
                return
            }
            finishSuccess(.content(mimetype: mime, data: state.body))
        }

        conn.stateUpdateHandler = { st in
            guard !state.finished else { return }
            switch st {
            case .ready:
                armTimeout(seconds: 30, GeminiFetchError.timedOut)
                conn.send(
                    content: uri.requestLine,
                    completion: .contentProcessed { error in
                        guard !state.finished else { return }
                        if let error {
                            fail(.sendFailed(error.localizedDescription))
                            return
                        }
                        receiveLoop()
                    })
            case .failed(let error), .waiting(let error):
                if let mismatch = certMismatch.value {
                    finishSuccess(
                        .certMismatch(
                            storedFingerprint: mismatch.stored,
                            presentedFingerprint: mismatch.presented))
                } else {
                    fail(.connectionFailed(error.localizedDescription))
                }
            default:
                break
            }
        }

        armTimeout(seconds: 10, GeminiFetchError.timedOut)  // connect timeout
        conn.start(queue: queue)
    }
}

// MARK: - Session helpers

private func bufferHeaderRange(_ data: Data) -> Range<Data.Index>? {
    data.firstRange(of: Data("\r\n".utf8))
}

private final class SessionState: @unchecked Sendable {
    // Every access runs on the connection's network queue: the TOFU-verify and
    // timeout Tasks hop back via `queue.async` before touching this state,
    // which is what makes this unchecked conformance sound.
    var buffer = Data()
    var body = Data()
    var headerParsed = false
    var isSuccess = false
    var earlyResultPending = false
    var mimetype: String?
    var totalReceived = 0
    var finished = false
    var idleTimer: Task<Void, Never>?
}

private final class CertMismatchBox: @unchecked Sendable {
    var value: (stored: [UInt8], presented: [UInt8])?
}
