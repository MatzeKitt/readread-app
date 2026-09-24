import CryptoKit
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

    // MARK: - The id this account should have

    /// The namespace the account ids are derived in.
    ///
    /// A constant of this app's own, so the derivation cannot collide with a UUID from anywhere
    /// else and so it never changes: every device has to arrive at the same answer, for ever, or
    /// they stop agreeing about what an account is called. Changing this is a data migration, not
    /// an edit.
    private static let namespace = UUID(uuidString: "0EDEA7C0-0D62-4A3B-9C01-71A35A10B851")!

    /// The id every device gives this account, derived rather than minted.
    ///
    /// ## Why an account's id cannot be random
    ///
    /// `AccountRecord.id` is embedded in everything the account produces — `CachedSource.id`,
    /// `CachedItem.id`, the `source:` and `mastodon-home:` scopes, and through the scopes the key
    /// of every `PositionMark`. A random id per device therefore means the same article, the same
    /// feed and the same scope are named differently on each device, and **every synced record
    /// that mentions one points at a row the receiving device does not have.** Three separate
    /// symptoms came out of that single fact: per-feed and Mastodon-Home positions that never
    /// synced at all, a restored position landing one item off, and Read Later entries opening an
    /// empty reading pane.
    ///
    /// Deriving it from what actually identifies the account — kind, server, username, already
    /// normalised by this type — makes two devices compute the same id without ever having to
    /// agree on one. No handshake, no first-writer-wins, and it works for an account added
    /// independently on both devices before either has synced.
    ///
    /// A version 5 UUID (RFC 4122 §4.3): a hash, not a random number, so it is stable; namespaced,
    /// so it cannot collide with UUIDs from elsewhere; and a real UUID, so nothing downstream has
    /// to learn a new kind of id. SHA-1 is used because the standard specifies it — this is a
    /// naming scheme, not a security boundary, and nothing is being authenticated by it.
    public var accountID: UUID {
        // The fields, not the record: two records for one account differ in id, display name and
        // creation date, and every one of those would fork the derivation.
        let canonical = "\(kindRaw)\n\(host)\(path)\n\(username)"

        var hasher = Insecure.SHA1()
        hasher.update(data: withUnsafeBytes(of: Self.namespace.uuid) { Data($0) })
        hasher.update(data: Data(canonical.utf8))
        var bytes = Array(hasher.finalize().prefix(16))

        // Version 5 in the high nibble of byte 6, RFC 4122 variant in the top bits of byte 8. The
        // rest of the digest is taken as it comes.
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80

        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
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
