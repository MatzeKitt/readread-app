import Foundation
import MastodonAPI
import ReadReadModel
import Testing

@testable import ReadReadUI

/// Opening a profile: whose, through which account, and the lists it pages through.
@Suite("Profile viewer")
@MainActor
struct ProfileViewerTests {

    /// On a boost, the person a reader wants to know about is the one who wrote the post — the
    /// same rule Mute follows.
    @Test("Show Profile on a boost opens the boosted post's author")
    func boostOpensTheAuthor() throws {
        let inner = Self.status(id: "1", accountID: "7", acct: "author@example.social")
        let boost = Self.status(id: "2", accountID: "8", acct: "booster", reblog: inner)
        let accountID = UUID()
        let item = Self.item(payload: boost, accountID: accountID)

        let model = ProfileViewerModel()
        #expect(model.open(authorOf: item))

        #expect(model.session?.profile.id == "7")
        #expect(model.session?.profile.handle == "author@example.social")
        // The id is only meaningful on the instance it was read from.
        #expect(model.session?.accountID == accountID)
    }

    @Test("A row without a payload cannot say whose profile it is")
    func rowWithoutPayloadOpensNothing() {
        let model = ProfileViewerModel()

        #expect(!model.open(authorOf: Self.item(payload: nil, accountID: UUID())))
        #expect(model.session == nil)
    }

    @Test("A post knows its author and whom it mentions")
    func statusCarriesProfiles() throws {
        let json = Self.status(
            id: "1",
            accountID: "7",
            acct: "a",
            mentions: #"[{"id": "9", "username": "c", "acct": "c@other.social", "url": "https://other.social/@c"}]"#
        )
        let status = RenderableStatus(try JSONDecoder.mastodon.decode(MastodonStatus.self, from: Data(json.utf8)))

        #expect(status.authorProfile?.id == "7")
        #expect(status.mentionedProfiles["https://other.social/@c"]?.id == "9")
        #expect(status.mentionedProfiles["https://other.social/@c"]?.handle == "c@other.social")
    }

    /// Without the id there is nothing to ask the instance for, so the author must stay plain text
    /// rather than become a button that fails.
    @Test("A post from the store without a payload has no profile to open")
    func storedRowHasNoProfile() {
        #expect(RenderableStatus(Self.item(payload: nil, accountID: UUID())).authorProfile == nil)
    }

    /// A post and a boost of it both display the post under its own id. Listed twice, `ForEach`
    /// would lose track of which row is which.
    @Test("A page repeating what is already listed adds only what is new")
    func listingSkipsRepeats() {
        var listing = ProfileLoader.Listing<ProfileLoader.AccountRow>()
        #expect(listing.canLoadMore)

        listing.append([Self.row("1"), Self.row("2")], next: "50")
        listing.append([Self.row("2"), Self.row("3")], next: "40")

        #expect(listing.elements.map(\.id) == ["1", "2", "3"])
        #expect(listing.canLoadMore)
    }

    @Test("An empty page ends the list even when it offers another")
    func emptyPageEndsTheList() {
        var listing = ProfileLoader.Listing<ProfileLoader.AccountRow>()

        listing.append([], next: "50")

        #expect(!listing.canLoadMore)
        #expect(listing.hasLoaded)
    }

    // MARK: - Fixtures

    private static func row(_ id: String) -> ProfileLoader.AccountRow {
        ProfileLoader.AccountRow(profile: ProfileReference(id: id, name: id, handle: id, avatarURLString: nil))
    }

    private static func item(payload: String?, accountID: UUID) -> CachedItem {
        let key = SortKey(millis: 1_700_000_000_000, id: "s")
        return CachedItem(
            id: "mastodon:acct:1",
            sourceID: "mastodon:acct:home",
            accountID: accountID,
            kind: .status,
            title: "Hello",
            excerpt: "Hello",
            publishedAt: .now,
            sortKey: key,
            ingestKey: key,
            mastodonPayload: payload.map { Data($0.utf8) }
        )
    }

    private static func status(
        id: String,
        accountID: String,
        acct: String,
        mentions: String = "[]",
        reblog: String? = nil
    ) -> String {
        """
        {
          "id": "\(id)",
          "uri": "https://example.social/users/a/statuses/\(id)",
          "created_at": "2026-01-01T10:00:00.000Z",
          "account": {
            "id": "\(accountID)",
            "username": "a",
            "acct": "\(acct)",
            "display_name": "A",
            "avatar": "https://example.social/avatar.png",
            "url": "https://example.social/@a"
          },
          "content": "<p>Hello</p>",
          "visibility": "public",
          "sensitive": false,
          "spoiler_text": "",
          "media_attachments": [],
          "emojis": [],
          "tags": [],
          "mentions": \(mentions),
          "replies_count": 0,
          "reblogs_count": 0,
          "favourites_count": 0,
          "reblog": \(reblog ?? "null")
        }
        """
    }

    // MARK: - Following as another account

    /// The URI names the account the same way on every server, so it is what another instance is
    /// asked to find — never the id, which only the viewing instance understands.
    @Test("Another account finds the profile by its URI")
    func resolvesByURI() throws {
        let profile = try Self.profile(acct: "ada", uri: "https://example.social/users/ada")

        #expect(ProfileLoader.resolutionQuery(for: profile, viewingHost: "example.social") == "https://example.social/users/ada")
    }

    /// Without a URI, a local account's `acct` is a bare username that means nothing to any other
    /// server; it has to be completed with the host it is local to.
    @Test("Without a URI, a local handle is completed with the viewing server")
    func resolvesLocalHandle() throws {
        let local = try Self.profile(acct: "ada", uri: nil)
        let remote = try Self.profile(acct: "bob@elsewhere.social", uri: nil)

        #expect(ProfileLoader.resolutionQuery(for: local, viewingHost: "example.social") == "ada@example.social")
        #expect(ProfileLoader.resolutionQuery(for: remote, viewingHost: "example.social") == "bob@elsewhere.social")
        #expect(ProfileLoader.resolutionQuery(for: local, viewingHost: nil) == nil)
    }

    /// A reader's own account is not offered as a follower of itself, but a namesake on another
    /// server is a different person.
    @Test("Only the local account with the reader's username is the reader")
    func recognisesSelf() {
        #expect(ProfileLoader.isSelf(acct: "Ada", username: "ada"))
        #expect(ProfileLoader.isSelf(acct: "ada", username: "@ada"))
        #expect(!ProfileLoader.isSelf(acct: "ada@elsewhere.social", username: "ada"))
        #expect(!ProfileLoader.isSelf(acct: "bob", username: "ada"))
    }

    private static func profile(acct: String, uri: String?) throws -> MastodonProfile {
        let json = """
            {
              "id": "1", "username": "x", "acct": "\(acct)", "display_name": "",
              "url": "https://example.social/@x", "uri": \(uri.map { "\"\($0)\"" } ?? "null"),
              "note": "", "avatar": "", "header": "",
              "followers_count": 0, "following_count": 0, "statuses_count": 0
            }
            """
        return try JSONDecoder.mastodon.decode(MastodonProfile.self, from: Data(json.utf8))
    }
}
