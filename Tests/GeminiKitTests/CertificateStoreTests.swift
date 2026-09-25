import Foundation
import Testing

@testable import GeminiKit

// MARK: - CertificateStore.listPins tests.

@Suite(.serialized)
struct CertificateStoreTests {
    @Test func listPinsRoundTrip() async {
        let store = CertificateStore(servicePrefix: "geminikit.pinstest.\(UUID().uuidString)")
        defer { Task { await store.forgetAll() } }

        #expect(await store.listPins().isEmpty)

        let alpha = [UInt8](repeating: 0xAA, count: 32)
        let beta = [UInt8](repeating: 0xBB, count: 32)
        await store.save(host: "zeta.example", port: 1965, fingerprint: alpha)
        // The data-protection Keychain requires a team-signed process.
        // Unsigned `swift test` runners get errSecMissingEntitlement and
        // writes silently drop, so there is no persistence to assert.
        guard case .trusted = await store.check(host: "zeta.example", port: 1965, fingerprint: alpha) else { return }
        await store.save(host: "alpha.example", port: 1966, fingerprint: beta)

        let pins = await store.listPins()
        #expect(pins.count == 2)
        // Sorted by host then port.
        #expect(pins[0].host == "alpha.example")
        #expect(pins[0].port == 1966)
        #expect(pins[0].fingerprint == beta)
        #expect(pins[1].host == "zeta.example")
        #expect(pins[1].port == 1965)
        #expect(pins[1].fingerprint == alpha)

        await store.delete(host: "alpha.example", port: 1966)
        let remaining = await store.listPins()
        #expect(remaining.count == 1)
        #expect(remaining[0].host == "zeta.example")

        await store.forgetAll()
        #expect(await store.listPins().isEmpty)
    }
}
