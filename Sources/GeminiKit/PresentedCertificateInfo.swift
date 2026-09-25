import Foundation
import X509

/// The leaf certificate a server presented during a fetch, parsed for display.
///
/// GeminiKit verifies servers by TOFU fingerprint only; this type carries the
/// human-relevant details of the presented certificate (validity dates, DNS
/// names) so clients can show page-info panels without re-parsing DER.
public struct PresentedCertificateInfo: Sendable, Equatable {
    /// SHA-256 fingerprint of the DER encoding (the same bytes the TOFU pin covers).
    public let fingerprint: [UInt8]
    public let notValidBefore: Date
    public let notValidAfter: Date
    /// DNS names from the subjectAlternativeName extension (often empty on gemini).
    public let dnsNames: [String]
    /// `SecCertificateCopySubjectSummary`, when available.
    public let subjectSummary: String?

    public init(
        fingerprint: [UInt8],
        notValidBefore: Date,
        notValidAfter: Date,
        dnsNames: [String],
        subjectSummary: String?
    ) {
        self.fingerprint = fingerprint
        self.notValidBefore = notValidBefore
        self.notValidAfter = notValidAfter
        self.dnsNames = dnsNames
        self.subjectSummary = subjectSummary
    }

    /// Parses leaf DER bytes. Returns nil when the bytes are not a certificate;
    /// callers should still surface the fingerprint they already hold.
    static func parse(
        der: Data,
        fingerprint: [UInt8],
        subjectSummary: String?
    ) -> PresentedCertificateInfo? {
        guard let certificate = try? X509.Certificate(derEncoded: Array(der)) else {
            return nil
        }
        let dnsNames =
            (try? certificate.extensions.subjectAlternativeNames)?.compactMap { name -> String? in
                if case .dnsName(let dnsName) = name { return dnsName }
                return nil
            } ?? []
        return PresentedCertificateInfo(
            fingerprint: fingerprint,
            notValidBefore: certificate.notValidBefore,
            notValidAfter: certificate.notValidAfter,
            dnsNames: dnsNames,
            subjectSummary: subjectSummary
        )
    }
}
