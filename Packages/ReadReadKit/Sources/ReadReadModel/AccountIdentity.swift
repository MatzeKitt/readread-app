import Foundation

/// What actually identifies an account, as opposed to what happens to key it.
///
/// `AccountRecord.id` is a `UUID` minted on whichever device the account was added on. That is
/// fine as a local key and wrong as an identity: the *same* account added on two devices gets two
/// ids, and since the account list syncs while credentials deliberately do not, each device ends
/// up holding one account it can authenticate and one it never can.
///
/// Comparison is normalised, because the same server is typed differently on a phone and a Mac —
/// a trailing slash, a capital letter, `https://` typed on one and omitted on the other. Two
/// records that differ only in that are the same account and have to compare equal, or the
/// deduplication this exists for silently does nothing.
public struct AccountIdentity: Hashable, Sendable {

    public let kindRaw: String
    public let host: String
    public let path: String
    public let username: String

    public init(kindRaw: String, serverURLString: String, username: String) {
        self.kindRaw = kindRaw
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let trimmed = serverURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalised = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        let url = URL(string: normalised)

        host = (url?.host()?.lowercased()) ?? normalised.lowercased()
        // Kept, because one FreshRSS host can serve two installs on different paths. Trailing
        // slashes are stripped so `/rss` and `/rss/` are one place.
        var component = url?.path() ?? ""
        while component.hasSuffix("/") { component.removeLast() }
        path = component
    }

    public init(_ account: AccountRecord) {
        self.init(
            kindRaw: account.kindRaw,
            serverURLString: account.serverURLString,
            username: account.username
        )
    }

    /// The record for this account, if it is already in the list.
    ///
    /// Asked at the end of a sign-in, before a record is created. Adding an account twice is easy
    /// to do by accident on a server where several accounts live: the instance may hand back an
    /// authorisation for whoever is already logged in to it without showing anything, so the
    /// reader can press "Add Account", see nothing happen, and end up with a second copy of the
    /// account they already had. Two records for one account then refresh the same timeline twice
    /// and each count it once.
    ///
    /// Returns the record rather than a yes-or-no, because the answer is not "refuse" — it is
    /// "this is the one whose credential the new token belongs to". Signing in again is also the
    /// only way to widen an account's granted scopes, so a sign-in that lands on an account
    /// already present has to renew it in place: throwing the fresh token away would leave no
    /// route to a token that can favourite and boost.
    public static func account(
        matching identity: AccountIdentity,
        in accounts: [AccountRecord]
    ) -> AccountRecord? {
        accounts.first { AccountIdentity($0) == identity }
    }

    /// Whether the list already holds an account of this kind on the same server.
    ///
    /// Not the same question as ``isAlreadyAdded(_:in:)``, and asked at the *start* of a sign-in
    /// rather than the end: a *different* account on a server already signed in to is the case
    /// that needs the instance to be told to ask who is signing in, before it assumes.
    ///
    /// The username is deliberately not part of it — it is not known yet. That is the whole
    /// problem.
    public static func hasAccount(
        kindRaw: String,
        onSameServerAs identity: AccountIdentity,
        in accounts: [AccountRecord]
    ) -> Bool {
        accounts.contains {
            let candidate = AccountIdentity($0)
            return candidate.kindRaw == kindRaw
                && candidate.host == identity.host
                && candidate.path == identity.path
        }
    }
}
