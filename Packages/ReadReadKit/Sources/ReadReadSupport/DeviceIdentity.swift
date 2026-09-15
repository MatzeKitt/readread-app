import Foundation

/// A stable per-installation identifier, used to key this device's own `PositionMark` rows.
///
/// The whole conflict-free position design depends on this value being stable across launches and
/// **distinct between devices**. It must not be derived from hardware: `identifierForVendor`
/// changes when the last app from a vendor is uninstalled, and there is no equivalent on macOS. So
/// a UUID is minted once and kept.
///
/// It lives in `UserDefaults` rather than the Keychain deliberately. Keychain items can be
/// configured to sync via iCloud, and a synced device id would make two devices claim the same
/// position row — silently reintroducing the write conflicts this design exists to avoid. A
/// device-local store is the correct semantics, and losing the id (a reinstall) is harmless: the
/// device simply starts a new row and reduction still picks the furthest position.
public struct DeviceIdentity: Sendable {

    private static let defaultsKey = "media.kitt.readread.deviceID"

    public let id: String

    /// Resolves the identifier, minting and persisting one on first use.
    ///
    /// - Parameter defaults: Injected so tests can exercise both the mint and reuse paths without
    ///   touching the real domain.
    public init(defaults: UserDefaults = .standard) {
        if let existing = defaults.string(forKey: Self.defaultsKey), !existing.isEmpty {
            id = existing
        } else {
            let minted = UUID().uuidString
            defaults.set(minted, forKey: Self.defaultsKey)
            id = minted
        }
    }

    /// For tests and previews that need a known value.
    public init(id: String) {
        self.id = id
    }

    /// This process's identity, resolved once.
    ///
    /// A shared constant because it is read from view code on every position write, and minting is
    /// idempotent but a `UserDefaults` round trip per read is not free. Safe as a `let` on an
    /// immutable `Sendable` value.
    public static let current = DeviceIdentity()
}
