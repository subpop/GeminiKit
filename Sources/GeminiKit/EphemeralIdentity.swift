import Foundation
import Network
import Security
import SwiftASN1
import X509

extension GeminiServer {
    /// Generate a throwaway self-signed TLS identity for `localhost`.
    ///
    /// The private key never leaves the Security framework: it is created as a
    /// non-persistent P-256 key and combined in memory with a self-signed X.509
    /// certificate.
    public static func makeEphemeralIdentity() throws -> sec_identity_t {
        do {
            let attributes: [CFString: Any] = [
                kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeySizeInBits: 256,
                kSecPrivateKeyAttrs: [kSecAttrIsPermanent: false],
            ]
            var keyError: Unmanaged<CFError>?
            guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &keyError)
            else {
                let detail =
                    (keyError?.takeRetainedValue() as? Error)?.localizedDescription
                    ?? "unknown error"
                throw GeminiServerError.identity("SecKeyCreateRandomKey failed: \(detail)")
            }

            let signingKey = try X509.Certificate.PrivateKey(privateKey)
            let notValidBefore = Date()
            guard
                let notValidAfter = Calendar(identifier: .gregorian).date(
                    byAdding: .day,
                    value: 3650,
                    to: notValidBefore
                )
            else {
                throw GeminiServerError.identity("Unable to calculate certificate expiry")
            }

            let localhostIPv4: [UInt8] = [127, 0, 0, 1]
            let subject = try X509.DistinguishedName {
                X509.CommonName("localhost")
            }
            let extensions = try X509.Certificate.Extensions {
                X509.Critical(X509.BasicConstraints.notCertificateAuthority)
                X509.KeyUsage(digitalSignature: true)
                try X509.ExtendedKeyUsage([.serverAuth])
                X509.SubjectAlternativeNames([
                    .dnsName("localhost"),
                    .ipAddress(SwiftASN1.ASN1OctetString(contentBytes: localhostIPv4[...])),
                ])
            }
            let certificate = try X509.Certificate(
                version: .v3,
                serialNumber: X509.Certificate.SerialNumber(),
                publicKey: signingKey.publicKey,
                notValidBefore: notValidBefore,
                notValidAfter: notValidAfter,
                issuer: subject,
                subject: subject,
                signatureAlgorithm: .ecdsaWithSHA256,
                extensions: extensions,
                issuerPrivateKey: signingKey
            )
            let secCertificate = try SecCertificate.makeWithCertificate(certificate)

            guard let identity = SecIdentityCreate(kCFAllocatorDefault, secCertificate, privateKey),
                let secIdentity = sec_identity_create(identity)
            else {
                throw GeminiServerError.identity("SecIdentityCreate failed")
            }
            return secIdentity
        } catch let error as GeminiServerError {
            throw error
        } catch {
            throw GeminiServerError.identity(error.localizedDescription)
        }
    }
}
