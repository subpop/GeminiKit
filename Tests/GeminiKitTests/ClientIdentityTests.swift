import Foundation
import Security
import SwiftASN1
import Testing
import X509

@testable import GeminiKit

// MARK: - Client-identity (6x support) round-trip tests.

// Mints a throwaway client SecIdentity: non-persistent P-256 key plus a
// self-signed certificate. Mirrors EphemeralIdentity but returns the
// SecIdentity itself so tests can present it via fetch(_:clientIdentity:).
private func makeClientIdentity() throws -> SecIdentity {
    let attributes: [CFString: Any] = [
        kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
        kSecAttrKeySizeInBits: 256,
        kSecPrivateKeyAttrs: [kSecAttrIsPermanent: false],
    ]
    var keyError: Unmanaged<CFError>?
    guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &keyError) else {
        throw keyError!.takeRetainedValue() as Error
    }
    let signingKey = try X509.Certificate.PrivateKey(privateKey)
    let notValidBefore = Date()
    let notValidAfter = notValidBefore.addingTimeInterval(3600)
    let name = try X509.DistinguishedName {
        X509.CommonName("geminikit-test-client")
    }
    let extensions = try X509.Certificate.Extensions {
        X509.Critical(X509.BasicConstraints.notCertificateAuthority)
        X509.KeyUsage(digitalSignature: true)
        try X509.ExtendedKeyUsage([.clientAuth])
    }
    let certificate = try X509.Certificate(
        version: .v3,
        serialNumber: .init(),
        publicKey: signingKey.publicKey,
        notValidBefore: notValidBefore,
        notValidAfter: notValidAfter,
        issuer: name,
        subject: name,
        signatureAlgorithm: .ecdsaWithSHA256,
        extensions: extensions,
        issuerPrivateKey: signingKey
    )
    let secCertificate = try SecCertificate.makeWithCertificate(certificate)
    guard let identity = SecIdentityCreate(kCFAllocatorDefault, secCertificate, privateKey) else {
        throw TestIdentityError.creationFailed
    }
    return identity
}

private enum TestIdentityError: Error {
    case creationFailed
}

@Suite(.serialized)
struct ClientIdentityTests {
    private func withLoopbackServer<T>(
        _ body: (GeminiServer, GeminiClient) async throws -> T
    ) async throws -> T {
        let prefix = "geminikit.identitytest.\(UUID().uuidString)"
        let store = CertificateStore(servicePrefix: prefix)
        defer { Task { await store.forgetAll() } }
        let client = GeminiClient(servicePrefix: prefix)
        let server = GeminiServer(port: 0) { _ in
            .init(status: 20, meta: "text/gemini", body: Data("# identity ok\n".utf8))
        }
        try await server.start()
        defer { server.stop() }
        return try await body(server, client)
    }

    @Test func fetchWithoutIdentityBaselines() async throws {
        try await withLoopbackServer { server, client in
            let port = try #require(server.boundPort)
            let uri = try GeminiURI.parse("gemini://localhost:\(port)/")
            let result = try await client.fetch(uri, timeout: 15)
            guard case .content(_, _, let data, _) = result else {
                Issue.record("expected content, got \(result)")
                return
            }
            #expect(String(data: data, encoding: .utf8) == "# identity ok\n")
        }
    }

    @Test func fetchWithClientIdentityCompletes() async throws {
        try await withLoopbackServer { server, client in
            let port = try #require(server.boundPort)
            let uri = try GeminiURI.parse("gemini://localhost:\(port)/")
            let identity = try makeClientIdentity()
            let result = try await client.fetch(uri, clientIdentity: identity, timeout: 15)
            guard case .content(_, _, let data, _) = result else {
                Issue.record("expected content, got \(result)")
                return
            }
            #expect(String(data: data, encoding: .utf8) == "# identity ok\n")
        }
    }
}
