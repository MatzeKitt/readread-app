import Foundation
import Testing

@testable import MastodonAPI

@Suite("Mastodon decoding")
struct MastodonDecodingTests {

    private func fixture(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json") else {
            throw FixtureError.missing(name)
        }
        return try Data(contentsOf: url)
    }

    enum FixtureError: Error { case missing(String) }

    private func timeline() throws -> [MastodonStatus] {
        try JSONDecoder.mastodon.decode([MastodonStatus].self, from: fixture("home-timeline"))
    }

    // MARK: - Dates

    /// The documented format carries fractional seconds, which `.iso8601` rejects outright — the
    /// whole timeline would fail to decode against a stock decoder.
    @Test("Timestamps with fractional seconds decode")
    func fractionalSecondsDecode() throws {
        let statuses = try timeline()

        let expected = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            .parseStrategy
        #expect(statuses[0].createdAt == (try Date("2026-09-03T10:15:30.123Z", strategy: expected)))
    }

    /// Some servers and some endpoints omit the fraction, so both spellings have to work.
    @Test("Timestamps without fractional seconds decode")
    func wholeSecondsDecode() throws {
        let statuses = try timeline()

        #expect(statuses[2].createdAt == (try Date("2026-09-03T08:00:00Z", strategy: .iso8601)))
    }

    @Test("A bare yyyy-MM-dd is tolerated rather than failing the whole status")
    func bareDateIsTolerated() {
        // An unparseable date is a hard decode failure, so one odd poll timestamp would otherwise
        // reject the entire status containing it.
        #expect(MastodonDate.parse("2026-09-10") != nil)
    }

    @Test("Nonsense dates are rejected", arguments: ["", "not-a-date", "2026-13-45", "2026-09"])
    func nonsenseDatesRejected(raw: String) {
        #expect(MastodonDate.parse(raw) == nil)
    }

    // MARK: - Statuses

    @Test("A plain status decodes")
    func plainStatusDecodes() throws {
        let status = try timeline()[0]

        #expect(status.id == MastodonStatusID("110451234567890001"))
        #expect(status.account.displayName == "Ada L.")
        #expect(status.content.contains("how many ways a date can be wrong"))
        #expect(status.isBoost == false)
        #expect(status.spoilerText.isEmpty)
        #expect(status.language == "en")
        #expect(status.editedAt == nil)
    }

    /// The avatar shown should be the non-animated one where the server offers it, so reduced-motion
    /// settings are respected without a second request.
    @Test("A static avatar is preferred over the animated one")
    func staticAvatarPreferred() throws {
        let statuses = try timeline()

        #expect(statuses[0].account.avatarURLString == "https://files.example/avatars/ada-static.png")
        // Falls back to the animated URL when there is no static variant.
        #expect(statuses[1].account.avatarURLString == "https://files.example/avatars/booster.png")
    }

    /// Many accounts leave `display_name` empty, and a blank byline reads as a rendering bug.
    @Test("An empty display name falls back to the handle")
    func emptyDisplayNameFallsBack() throws {
        let boost = try timeline()[1]

        #expect(boost.account.displayName.isEmpty)
        #expect(boost.account.bestDisplayName == "@booster@other.example")
    }

    // MARK: - Boosts

    /// A boost carries its own id and timestamp — which place it in the timeline — while the
    /// content and author belong to the status it wraps. Conflating the two shows the wrong author
    /// or files the post weeks in the past.
    @Test("A boost exposes its own timing but the original's content")
    func boostSeparatesTimingFromContent() throws {
        let boost = try timeline()[1]

        #expect(boost.isBoost)
        #expect(boost.reblog != nil)

        // The boost's own timing.
        #expect(boost.id == MastodonStatusID("110451234567890002"))
        #expect(boost.createdAt == (try Date("2026-09-03T09:00:00.000Z", strategy: .iso8601)))
        #expect(boost.content.isEmpty)

        // The original's content and author.
        #expect(boost.displayStatus.content.contains("written weeks earlier"))
        #expect(boost.displayStatus.account.bestDisplayName == "Core Team")
        #expect(boost.boostedBy?.acct == "booster@other.example")
        // Weeks earlier than the boost, which is why the boost's time is what orders the timeline.
        #expect(boost.displayStatus.createdAt < boost.createdAt)
    }

    @Test("A non-boost's displayStatus is itself")
    func nonBoostDisplaysItself() throws {
        let status = try timeline()[0]

        #expect(status.displayStatus.id == status.id)
        #expect(status.boostedBy == nil)
    }

    // MARK: - Attachments

    @Test("Attachment metadata decodes")
    func attachmentMetadataDecodes() throws {
        let attachments = try timeline()[1].displayStatus.mediaAttachments

        #expect(attachments.count == 2)
        #expect(attachments[0].type == "image")
        #expect(attachments[0].description == "A diagram of the ingest walk")
        #expect(attachments[0].blurhash == "UBL_:rof00ay0hWB")
        #expect(attachments[0].meta?.original?.width == 1_600)
        #expect(attachments[0].meta?.original?.aspect == 1.7777778)
        #expect(attachments[0].meta?.focus?.y == 0.1)
        // Prefers the scaled version for a grid thumbnail.
        #expect(attachments[0].thumbnailURLString == "https://files.example/media/photo-small.jpg")
    }

    /// `url` is null while the server is still processing an upload — a real state, not corruption.
    @Test("An attachment still being processed has no usable URL")
    func inFlightAttachmentHasNoURL() throws {
        let attachments = try timeline()[1].displayStatus.mediaAttachments

        #expect(attachments[1].url == nil)
        #expect(attachments[1].fullURLString == nil)
        #expect(attachments[1].thumbnailURLString == nil)
    }

    // MARK: - Content warnings, polls, emoji

    @Test("A content warning and its poll decode")
    func warningAndPollDecode() throws {
        let status = try timeline()[2]

        #expect(status.sensitive)
        #expect(status.spoilerText == "spoilers for the finale")
        #expect(status.poll?.options.count == 2)
        #expect(status.poll?.options[0].votesCount == 7)
        #expect(status.poll?.votesCount == 12)
        #expect(status.poll?.expired == false)
        #expect(status.emojis.first?.shortcode == "blobcat")
        #expect(status.tags.first?.name == "finale")
        #expect(status.mentions.first?.acct == "ada")
        #expect(status.inReplyToId == "110451234567890001")
    }

    // MARK: - Round-tripping

    /// A decoded status is re-encoded onto `CachedItem.mastodonPayload` and decoded again by the
    /// detail view, so the encoder's key and date strategies must be exact inverses of the
    /// decoder's. If they drift, every stored payload silently becomes undecodable.
    @Test("A status survives an encode/decode round trip")
    func statusRoundTrips() throws {
        let original = try timeline()[1]

        let encoded = try JSONEncoder.mastodon.encode(original)
        let decoded = try JSONDecoder.mastodon.decode(MastodonStatus.self, from: encoded)

        #expect(decoded.id == original.id)
        #expect(decoded.createdAt == original.createdAt)
        #expect(decoded.account.acct == original.account.acct)
        #expect(decoded.reblog?.content == original.reblog?.content)
        #expect(decoded.displayStatus.mediaAttachments.count == original.displayStatus.mediaAttachments.count)
        #expect(decoded.displayStatus.mediaAttachments[0].blurhash == "UBL_:rof00ay0hWB")
    }

    // MARK: - OAuth payloads

    @Test("App registration decodes")
    func applicationDecodes() throws {
        let application = try JSONDecoder.mastodon.decode(MastodonApplication.self, from: fixture("application"))

        #expect(application.clientId == "cid-abc123")
        #expect(application.clientSecret == "csecret-xyz789")
        #expect(application.redirectUris == ["readread://oauth-callback"])
    }

    @Test("Token response decodes")
    func tokenDecodes() throws {
        let token = try JSONDecoder.mastodon.decode(MastodonTokenResponse.self, from: fixture("token"))

        #expect(token.accessToken == "tok-9f8e7d")
        #expect(token.tokenType == "Bearer")
    }
}
