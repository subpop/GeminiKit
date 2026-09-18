import Foundation
import Security

/// Keychain-backed store of SHA-256 certificate fingerprints, keyed by host:port.
/// An actor, so all Keychain operations are serialized without blocking callers.
///
/// Uses the data-protection Keychain (no per-item ACLs), so reads and writes
/// never trigger "wants to access your keychain" prompts.
///
/// - Parameter servicePrefix: Keychain service namespace. Defaults to `geminikit.tofu`.
public actor CertificateStore {
    private let servicePrefix: String

    /// Creates a store in the given Keychain namespace.
    /// - Parameter servicePrefix: Keychain service namespace. Defaults to `geminikit.tofu`;
    ///   pass a different prefix to isolate pins (e.g. per test run).
    public init(servicePrefix: String = "geminikit.tofu") {
        self.servicePrefix = servicePrefix
    }

    /// Compares `fingerprint` against the pin for `host:port`.
    /// - Returns: `.trusted` on match, `.mismatch` on change, `.unknown` on first sight.
    public func check(host: String, port: Int, fingerprint: [UInt8]) -> CertOutcome {
        let service = service(for: host, port: port)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, data.count == 32 else {
            return .unknown
        }
        let stored = [UInt8](data)
        return stored == fingerprint
            ? CertOutcome.trusted : .mismatch(stored: stored, presented: fingerprint)
    }

    /// Pins `fingerprint` for `host:port`, replacing any previous pin.
    public func save(host: String, port: Int, fingerprint: [UInt8]) {
        let service = service(for: host, port: port)
        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
        ]
        let updateAttrs: [String: Any] = [
            kSecValueData as String: Data(fingerprint)
        ]
        if SecItemUpdate(updateQuery as CFDictionary, updateAttrs as CFDictionary)
            == errSecSuccess
        {
            return
        }
        _ = SecItemDelete(updateQuery as CFDictionary)
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecValueData as String: Data(fingerprint),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecUseDataProtectionKeychain as String: true,
        ]
        _ = SecItemAdd(addQuery as CFDictionary, nil)
    }

    /// Removes the pin for `host:port`, if any.
    public func delete(host: String, port: Int) {
        let service = service(for: host, port: port)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
        ]
        _ = SecItemDelete(query as CFDictionary)
    }

    /// Delete only fingerprints stored under this store's service prefix.
    /// Enumerates generic-password items (attributes only) and removes matches.
    public func forgetAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecUseDataProtectionKeychain as String: true,
        ]
        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess else {
            return
        }
        let prefix = servicePrefix + "."
        let matches: [[String: Any]]
        if let arr = items as? [[String: Any]] {
            matches = arr
        } else if let single = items as? [String: Any] {
            matches = [single]
        } else {
            return
        }
        for attrs in matches {
            guard let service = attrs[kSecAttrService as String] as? String,
                service.hasPrefix(prefix)
            else { continue }
            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecUseDataProtectionKeychain as String: true,
            ]
            _ = SecItemDelete(deleteQuery as CFDictionary)
        }
    }

    private func service(for host: String, port: Int) -> String {
        "\(servicePrefix).\(host):\(port)"
    }

    /// Outcome of ``check(host:port:fingerprint:)``: known-good, changed, or never seen.
    public enum CertOutcome: Sendable {
        /// The fingerprint matches the stored pin.
        case trusted
        /// The fingerprint differs from the stored pin; verify out-of-band before re-pinning.
        case mismatch(stored: [UInt8], presented: [UInt8])
        /// No pin exists yet; the caller should pin via ``save(host:port:fingerprint:)``.
        case unknown
    }
}
