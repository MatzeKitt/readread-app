import Foundation
import Security

/// Stores the app's secrets in the Keychain.
///
/// Everything sensitive lives here and **nowhere else** — not in the SwiftData store, and not in
/// anything that syncs through the user's own server. The sync endpoint carries the *account list*
/// so a new device knows which servers exist, but never a credential, which is what makes it safe
/// to self-host that endpoint at all.
///
/// Items are deliberately **not** marked `kSecAttrSynchronizable`. iCloud Keychain sync would be
/// convenient, but it would also replicate this device's `DeviceIdentity`-adjacent state across
/// devices, and more importantly a shared OAuth token means one device revoking it breaks the
/// others with no way to tell which did it. Each device authorises itself once.
public struct KeychainStore: Sendable {

    /// What kind of secret a stored item is, so keys cannot collide across purposes.
    public enum Purpose: String, Sendable {

        /// A FreshRSS API password, keyed by account id.
        case freshRSSAPIPassword

        /// A Mastodon OAuth access token, keyed by account id.
        case mastodonAccessToken

        /// A Mastodon app registration, keyed by *instance host* rather than account, because the
        /// registration belongs to the instance and is reused if the user re-authorises.
        case mastodonClientCredentials

        /// The bearer token for the user's own sync endpoint.
        case syncBearerToken
    }

    public enum KeychainError: Error, Sendable {
        case unexpectedStatus(OSStatus)
        case dataCorrupted
    }

    private let service: String

    /// Whether the data-protection keychain may be tried at all.
    ///
    /// Normally yes, with an automatic fallback — see ``perform(purpose:key:_:)``. Tests set this
    /// to false to skip a probe that can never succeed for them.
    private let prefersDataProtectionKeychain: Bool

    public init(
        service: String = "com.kittmedia.ReadRead",
        prefersDataProtectionKeychain: Bool = true
    ) {
        self.service = service
        self.prefersDataProtectionKeychain = prefersDataProtectionKeychain
    }

    // MARK: - Strings

    public func string(for purpose: Purpose, key: String) throws -> String? {
        guard let data = try data(for: purpose, key: key) else { return nil }
        guard let string = String(data: data, encoding: .utf8) else {
            throw KeychainError.dataCorrupted
        }
        return string
    }

    public func setString(_ value: String, for purpose: Purpose, key: String) throws {
        try setData(Data(value.utf8), for: purpose, key: key)
    }

    // MARK: - Codable payloads

    public func value<Value: Decodable>(_ type: Value.Type, for purpose: Purpose, key: String) throws -> Value? {
        guard let data = try data(for: purpose, key: key) else { return nil }
        return try JSONDecoder().decode(Value.self, from: data)
    }

    public func setValue(_ value: some Encodable, for purpose: Purpose, key: String) throws {
        try setData(try JSONEncoder().encode(value), for: purpose, key: key)
    }

    // MARK: - Data

    public func data(for purpose: Purpose, key: String) throws -> Data? {
        var result: CFTypeRef?

        let status = perform(purpose: purpose, key: key) { base in
            var query = base
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            return SecItemCopyMatching(query as CFDictionary, &result)
        }

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw KeychainError.dataCorrupted }
            return data
        case errSecItemNotFound:
            // A missing secret is an ordinary state — an account that has not been signed in yet —
            // so it is nil rather than an error.
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func setData(_ data: Data, for purpose: Purpose, key: String) throws {
        // Update first, then add. `SecItemAdd` on an existing item fails with a duplicate error,
        // and deleting before adding would leave a window where the credential is simply gone if
        // the process died in between.
        //
        // Both steps go through one `perform`, so an update and its follow-up add cannot land in
        // different keychains — which would leave the item written to one and looked for in the
        // other.
        let status = perform(purpose: purpose, key: key) { base in
            let updateStatus = SecItemUpdate(
                base as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            if updateStatus != errSecItemNotFound { return updateStatus }

            var insert = base
            insert[kSecValueData as String] = data
            // Available after first unlock rather than always: a background refresh needs it
            // without the user present, but it should not be readable while the device has never
            // been unlocked.
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecDuplicateItem else { return addStatus }

            // Another writer added the same item between the update and the add. Rare, but real —
            // observed when two writes to one key overlapped — and the right answer is simply to
            // do what the update would have done, not to report a failure for a key that now
            // exists.
            return SecItemUpdate(
                base as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
        }

        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // MARK: - Off the calling actor

    /// The same operations, run somewhere that is allowed to block.
    ///
    /// Every Keychain call above is synchronous, and against the legacy login keychain any of them
    /// can stop dead behind a SecurityAgent prompt until the user answers it. From the main actor
    /// that freezes the whole app — including, in the case that surfaced this, the window the
    /// prompt appears over.
    ///
    /// These are `async` overloads rather than new names so that `await`ing picks the safe one
    /// without the caller having to know why it exists.

    public func string(for purpose: Purpose, key: String) async throws -> String? {
        try await offCallingActor { try string(for: purpose, key: key) }
    }

    public func setString(_ value: String, for purpose: Purpose, key: String) async throws {
        try await offCallingActor { try setString(value, for: purpose, key: key) }
    }

    public func value<Value: Decodable & Sendable>(
        _ type: Value.Type,
        for purpose: Purpose,
        key: String
    ) async throws -> Value? {
        try await offCallingActor { try self.value(type, for: purpose, key: key) }
    }

    public func setValue(_ value: some Encodable & Sendable, for purpose: Purpose, key: String) async throws {
        try await offCallingActor { try setValue(value, for: purpose, key: key) }
    }

    public func remove(for purpose: Purpose, key: String) async throws {
        try await offCallingActor { try remove(for: purpose, key: key) }
    }

    public func removeAll(forAccountKey key: String) async throws {
        try await offCallingActor { try removeAll(forAccountKey: key) }
    }

    private func offCallingActor<Value: Sendable>(
        _ work: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await Task.detached(priority: .userInitiated, operation: work).value
    }

    public func remove(for purpose: Purpose, key: String) throws {
        let status = perform(purpose: purpose, key: key) { base in
            SecItemDelete(base as CFDictionary)
        }
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Removes every secret belonging to one account, for sign-out.
    public func removeAll(forAccountKey key: String) throws {
        for purpose in [Purpose.freshRSSAPIPassword, .mastodonAccessToken] {
            try remove(for: purpose, key: key)
        }
    }

    // MARK: - Query

    /// Which keychain an operation is talking to.
    private enum Backend {
        /// Scopes items by the app's access group. No per-item ACL, so nothing to prompt about,
        /// and it is the only keychain on iOS.
        case dataProtection

        /// The legacy file-based login keychain, whose items carry a per-application ACL.
        case legacy
    }

    /// Runs a keychain operation, preferring the data-protection keychain.
    ///
    /// ## Why there are two, and why this falls back
    ///
    /// The data-protection keychain is what the app wants. The legacy login keychain guards each
    /// item with an ACL bound to the binary's **code signature**, so a rebuild invalidates it and
    /// macOS asks the user to allow access all over again — every launch, during development.
    ///
    /// But the data-protection keychain needs an `application-identifier` entitlement, which only
    /// team signing provides. This project is ad-hoc signed by default (see `project.yml`), so in a
    /// development build every call to it fails with `errSecMissingEntitlement` — measured, after
    /// switching unconditionally and finding that no secret could be saved at all. Naming an
    /// explicit `keychain-access-groups` entitlement does not help either: it makes the build
    /// demand a provisioning profile.
    ///
    /// So both are supported, chosen at runtime by what the running binary is actually allowed to
    /// do. Set `DEVELOPMENT_TEAM` and the app moves to the data-protection keychain and stops
    /// prompting; leave it ad-hoc and secrets still work, at the cost of a prompt after each
    /// rebuild.
    ///
    /// The fallback deliberately does **not** migrate items between the two. An item written to
    /// one is invisible to the other, so changing signing configuration means re-entering
    /// credentials once — which is a far better failure than silently reading a stale token.
    private func perform(
        purpose: Purpose,
        key: String,
        _ operation: ([String: Any]) -> OSStatus
    ) -> OSStatus {
        if prefersDataProtectionKeychain {
            let status = operation(baseQuery(purpose: purpose, key: key, backend: .dataProtection))
            guard Self.shouldFallBack(from: status) else { return status }
        }
        return operation(baseQuery(purpose: purpose, key: key, backend: .legacy))
    }

    /// Whether a data-protection result means "ask the other keychain instead".
    ///
    /// Two statuses, and the second one is the whole reason this is a function rather than a single
    /// comparison. A **write** without the entitlement fails with `errSecMissingEntitlement`, which
    /// is the obvious signal — but a **read** does not: it comes back `errSecItemNotFound`, exactly
    /// as if the item simply were not there. Falling back only on the entitlement error therefore
    /// left every credential write succeeding into the legacy keychain and every read of it
    /// answering nil, which is precisely the state the settings pane reported as "no token saved
    /// yet" moments after saving one.
    ///
    /// Treating a genuine miss as a reason to look in the other keychain costs one extra lookup for
    /// an absent item. That is cheap and, unlike the alternative, correct.
    private static func shouldFallBack(from status: OSStatus) -> Bool {
        status == errSecMissingEntitlement || status == errSecItemNotFound
    }

    private func baseQuery(purpose: Purpose, key: String, backend: Backend) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            // Namespacing the service by purpose keeps a Mastodon token and a FreshRSS password
            // for the same account id from overwriting one another.
            kSecAttrService as String: "\(service).\(purpose.rawValue)",
            kSecAttrAccount as String: key,
        ]

        if backend == .dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }

        return query
    }
}
