import Foundation
import ReadReadSupport
import Testing

@testable import ReadReadSync

@Suite("SyncEndpoint")
struct SyncEndpointTests {

    /// A `UserDefaults` suite of its own per test, so these never touch the real preferences and
    /// cannot leak into each other.
    private func makeDefaults() -> UserDefaults {
        let name = "readread.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: - Address parsing

    @Test("A bare host is assumed to be https, never http")
    func bareHostDefaultsToHTTPS() {
        let settings = SyncEndpointSettings(urlString: "rss.example.com/readread")

        // Load-bearing: this request carries a bearer token, so guessing http would put it on the
        // wire in clear text on a network the user did not choose.
        #expect(settings.url?.scheme == "https")
        #expect(settings.url?.host() == "rss.example.com")
    }

    @Test("An explicit scheme is left alone")
    func explicitSchemeIsKept() {
        #expect(SyncEndpointSettings(urlString: "http://192.168.1.10:8080").url?.scheme == "http")
    }

    @Test("Nonsense is not a URL")
    func rejectsUnusableAddresses() {
        #expect(SyncEndpointSettings(urlString: "").url == nil)
        #expect(SyncEndpointSettings(urlString: "   ").url == nil)
        #expect(!SyncEndpointSettings(urlString: "not a host").isConfigured)
    }

    @Test("Surrounding whitespace is tolerated")
    func trimsWhitespace() {
        // Pasted addresses routinely carry a trailing newline, and failing on it would be baffling.
        #expect(SyncEndpointSettings(urlString: "  https://sync.example.com \n").url?.host() == "sync.example.com")
    }

    // MARK: - Storage

    @Test("The address round-trips through UserDefaults")
    func settingsRoundTrip() {
        let defaults = makeDefaults()
        let keychain = KeychainStore(service: service(), prefersDataProtectionKeychain: false)
        let endpoint = SyncEndpoint(defaults: defaults, keychain: keychain)

        endpoint.saveSettings(SyncEndpointSettings(urlString: "https://sync.example.com", isEnabled: false))

        let loaded = SyncEndpoint(defaults: defaults, keychain: keychain).loadSettings()
        #expect(loaded.urlString == "https://sync.example.com")
        #expect(!loaded.isEnabled)
    }

    @Test("The token is never written to UserDefaults")
    func tokenStaysOutOfDefaults() throws {
        let defaults = makeDefaults()
        let keychainService = service()
        let endpoint = SyncEndpoint(defaults: defaults, keychain: KeychainStore(service: keychainService, prefersDataProtectionKeychain: false))
        defer { try? endpoint.removeToken() }

        endpoint.saveSettings(SyncEndpointSettings(urlString: "https://sync.example.com"))
        try endpoint.setToken("super-secret-token")

        // `UserDefaults` is a plist in the container and goes into every backup. Asserting on the
        // whole domain rather than on the one key, because the point is that it is nowhere in there.
        let dumped = String(describing: defaults.dictionaryRepresentation())
        #expect(!dumped.contains("super-secret-token"))
        #expect(try endpoint.token() == "super-secret-token")
    }

    @Test("Configuration needs an address, a token and the switch on")
    func configurationRequiresEverything() throws {
        let defaults = makeDefaults()
        let endpoint = SyncEndpoint(defaults: defaults, keychain: KeychainStore(service: service(), prefersDataProtectionKeychain: false))
        defer { try? endpoint.removeToken() }

        endpoint.saveSettings(SyncEndpointSettings(urlString: "https://sync.example.com"))
        // An address with no token yet is an ordinary state mid-setup, not an error — returning nil
        // is what keeps it from being reported as a failure on every refresh tick.
        #expect(endpoint.configuration() == nil)

        try endpoint.setToken("token")
        #expect(endpoint.configuration()?.baseURL.host() == "sync.example.com")

        endpoint.saveSettings(SyncEndpointSettings(urlString: "https://sync.example.com", isEnabled: false))
        #expect(endpoint.configuration() == nil)
    }

    @Test("Turning sync off keeps the address and the token")
    func disablingPreservesCredentials() throws {
        let defaults = makeDefaults()
        let endpoint = SyncEndpoint(defaults: defaults, keychain: KeychainStore(service: service(), prefersDataProtectionKeychain: false))
        defer { try? endpoint.removeToken() }

        endpoint.saveSettings(SyncEndpointSettings(urlString: "https://sync.example.com"))
        try endpoint.setToken("token")
        endpoint.saveSettings(SyncEndpointSettings(urlString: "https://sync.example.com", isEnabled: false))

        // Otherwise switching sync off for a trip would mean re-entering the token to switch it
        // back on.
        #expect(endpoint.hasToken())
        #expect(endpoint.loadSettings().urlString == "https://sync.example.com")
    }

    @Test("An empty token clears the stored one rather than storing nothing")
    func emptyTokenRemoves() throws {
        let endpoint = SyncEndpoint(defaults: makeDefaults(), keychain: KeychainStore(service: service(), prefersDataProtectionKeychain: false))
        defer { try? endpoint.removeToken() }

        try endpoint.setToken("token")
        try endpoint.setToken("   ")

        #expect(!endpoint.hasToken())
    }

    /// A Keychain service name unique to each call.
    ///
    /// The token's *key* is fixed by `SyncEndpoint`, so two tests sharing a service name would be
    /// writing the same Keychain item — and since tests run concurrently, they raced and one lost
    /// with a duplicate-item error. Varying the service is what keeps them independent, and it
    /// also keeps them away from the real app's items.
    /// The probe is skipped here: the test binary has no sandbox and no entitlements, so the
    /// data-protection keychain answers `errSecMissingEntitlement` and the store falls back anyway.
    private func service() -> String {
        "com.kittmedia.ReadRead.tests.\(UUID().uuidString)"
    }
}
