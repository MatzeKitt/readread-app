import Foundation
import SwiftData

public enum AccountKind: String, Hashable, Sendable, Codable, CaseIterable {
    case freshRSS
    case mastodon

    public var displayName: String {
        switch self {
        case .freshRSS: "FreshRSS"
        case .mastodon: "Mastodon"
        }
    }

    /// The kind of item this account produces.
    public var itemKind: ItemKind {
        switch self {
        case .freshRSS: .article
        case .mastodon: .status
        }
    }
}

/// A configured connection to a FreshRSS server or Mastodon instance.
///
/// **This model deliberately holds no secrets.** It syncs to the user's own server so a new device
/// discovers which accounts exist, but passwords, OAuth client secrets and access tokens live only
/// in the device Keychain, keyed by `id`. That split is what makes it safe to sync the account list
/// at all: the sync endpoint never sees a credential, so a compromised endpoint cannot read the
/// user's feeds or post to their Mastodon account.
@Model
public final class AccountRecord {

    #Unique<AccountRecord>([\.id])
    public var id: UUID = UUID()

    /// `AccountKind.rawValue`.
    public var kindRaw: String = AccountKind.freshRSS.rawValue

    /// What to call this account in the sidebar. Defaults to the host, which is usually what the
    /// user thinks of it as.
    public var displayName: String = ""

    /// Base URL of the FreshRSS installation or the Mastodon instance.
    public var serverURLString: String = ""

    /// FreshRSS username, or the Mastodon `acct`. Not a secret; the API password is.
    public var username: String = ""

    public var createdAt: Date = Date.now

    /// Cleared rather than deleted when signed out, so its cached items and reading positions are
    /// not destroyed by an accidental tap.
    public var isEnabled: Bool = true

    public init(
        id: UUID = UUID(),
        kind: AccountKind,
        displayName: String,
        serverURLString: String,
        username: String,
        createdAt: Date = .now,
        isEnabled: Bool = true
    ) {
        self.id = id
        kindRaw = kind.rawValue
        self.displayName = displayName
        self.serverURLString = serverURLString
        self.username = username
        self.createdAt = createdAt
        self.isEnabled = isEnabled
    }

    public var kind: AccountKind {
        get { AccountKind(rawValue: kindRaw) ?? .freshRSS }
        set { kindRaw = newValue.rawValue }
    }

    /// The server address, if it is one that could actually be contacted.
    ///
    /// The host check is load-bearing, not defensive. `URL(string:)` accepts almost anything —
    /// "not a url" parses happily into a relative URL with no host — so testing only for `nil`
    /// yielded a URL that built a client, issued a request, and failed somewhere far from the
    /// typo that caused it.
    public var serverURL: URL? {
        guard let url = URL(string: serverURLString), url.host() != nil else { return nil }
        return url
    }
}
