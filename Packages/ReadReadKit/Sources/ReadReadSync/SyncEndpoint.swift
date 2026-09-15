import Foundation
import ReadReadSupport

/// Where the position-sync service lives, and whether to use it.
///
/// The **token is not in here.** It lives in the Keychain, and this struct is a plain `UserDefaults`
/// blob — putting a bearer token in `UserDefaults` would write it to a world-readable plist inside
/// the container and, worse, into every backup. `SyncEndpoint.configuration()` puts the two halves
/// together only at the moment a request is about to be made.
public struct SyncEndpointSettings: Sendable, Equatable, Codable {

    /// Whatever the user typed. Kept as text rather than a `URL` so a half-typed address survives
    /// being edited, and is only parsed when it is used.
    public var urlString: String

    /// Off means the app never contacts the endpoint, whatever is stored.
    ///
    /// Separate from "is a URL configured" so the sync can be turned off for a while — travelling,
    /// or the server is down — without losing the address and having to re-enter the token.
    public var isEnabled: Bool

    public init(urlString: String = "", isEnabled: Bool = true) {
        self.urlString = urlString
        self.isEnabled = isEnabled
    }

    public static let `default` = SyncEndpointSettings()

    /// The base URL, if what is stored parses into one that could be contacted.
    public var url: URL? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // A bare host is what people type. Defaulting the scheme to https rather than http matters
        // here: this request carries a bearer token, so guessing wrong would put it on the wire in
        // clear text.
        let normalised = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: normalised), url.host() != nil else { return nil }
        return url
    }

    public var isConfigured: Bool { url != nil }
}

/// Reads and writes the sync endpoint's address and token.
///
/// The address is a preference; the token is a credential. They are stored apart for that reason
/// and only ever joined in ``configuration()``.
///
/// `@unchecked Sendable` for the same reason as `RefreshSettingsStore`: `UserDefaults` is documented
/// as thread-safe but is not marked `Sendable`, and this type only reads and writes one key through
/// it.
public struct SyncEndpoint: @unchecked Sendable {

    /// The Keychain key for the bearer token. One endpoint per install, so a fixed key rather than
    /// one per account.
    public static let tokenKey = "sync-endpoint"

    private static let settingsKey = "media.kitt.readread.syncEndpoint"

    private let defaults: UserDefaults
    private let keychain: KeychainStore

    public init(defaults: UserDefaults = .standard, keychain: KeychainStore = KeychainStore()) {
        self.defaults = defaults
        self.keychain = keychain
    }

    public func loadSettings() -> SyncEndpointSettings {
        guard let data = defaults.data(forKey: Self.settingsKey),
              let settings = try? JSONDecoder().decode(SyncEndpointSettings.self, from: data)
        else {
            return .default
        }
        return settings
    }

    public func saveSettings(_ settings: SyncEndpointSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.settingsKey)
    }

    public func token() throws -> String? {
        try keychain.string(for: .syncBearerToken, key: Self.tokenKey)
    }

    public func setToken(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try removeToken()
            return
        }
        try keychain.setString(trimmed, for: .syncBearerToken, key: Self.tokenKey)
    }

    public func removeToken() throws {
        try keychain.remove(for: .syncBearerToken, key: Self.tokenKey)
    }

    public func hasToken() -> Bool {
        ((try? token()) ?? nil) != nil
    }

    /// The two halves joined, or `nil` when sync is off or not fully configured.
    ///
    /// Returns `nil` rather than throwing for a missing token: an endpoint with no token yet is an
    /// ordinary state during setup, not an error to report on every refresh tick.
    // MARK: - Off the main actor

    /// The Keychain calls above, run somewhere that is allowed to block.
    ///
    /// Every one of them is synchronous, and against the legacy login keychain any of them can
    /// stop dead behind a SecurityAgent prompt until the user answers it. On the main actor that
    /// freezes the whole app — found exactly that way: opening Settings blocked the window server
    /// on `hasToken()` from a `.task`, which is `@MainActor` for a `View`, and the app looked hung
    /// with the prompt hidden behind it.
    ///
    /// These are `async` overloads rather than differently-named methods so that `await`ing gets
    /// the safe one and the compiler picks it without the caller having to know why.

    public func hasToken() async -> Bool {
        await offMainActor { hasToken() }
    }

    public func token() async throws -> String? {
        try await offMainActor { try token() }
    }

    public func setToken(_ token: String) async throws {
        try await offMainActor { try setToken(token) }
    }

    public func removeToken() async throws {
        try await offMainActor { try removeToken() }
    }

    public func configuration() async -> SyncConfiguration? {
        await offMainActor { configuration() }
    }

    /// Runs a blocking Keychain call off whatever actor the caller is on.
    ///
    /// Two overloads rather than one `rethrows`: a detached task's `value` is always throwing (it
    /// can be cancelled), so `rethrows` cannot describe it, and collapsing them would make the
    /// non-throwing callers handle an error that never comes.
    private func offMainActor<Value: Sendable>(
        _ work: @escaping @Sendable () -> Value
    ) async -> Value {
        await Task.detached(priority: .userInitiated, operation: work).value
    }

    private func offMainActor<Value: Sendable>(
        _ work: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await Task.detached(priority: .userInitiated, operation: work).value
    }

    public func configuration() -> SyncConfiguration? {
        let settings = loadSettings()
        guard settings.isEnabled, let url = settings.url else { return nil }
        guard let token = (try? token()) ?? nil else { return nil }
        return SyncConfiguration(baseURL: url, token: token)
    }
}
