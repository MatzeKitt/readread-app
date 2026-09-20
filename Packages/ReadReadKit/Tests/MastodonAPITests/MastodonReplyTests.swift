import Foundation
import ReadReadSupport
import ReadReadTestSupport
import Testing

@testable import MastodonAPI

/// Posting a reply, and muting an account.
///
/// The two newest things this app can do to somebody else's server, and the only two where a
/// mistake is *published*: a wrong boost can be taken back, where a reply posted twice — or posted
/// to a wider audience than the post it answers — is out in other people's timelines before anyone
/// notices.
@Suite("Mastodon replies and mutes")
struct MastodonReplyTests {

    private func makeClient(_ transport: StubTransport, token: String? = "tok") -> MastodonClient {
        MastodonClient(
            instanceURL: URL(string: "https://mastodon.social")!,
            accessToken: token,
            http: HTTPClient(transport: transport, policy: RetryPolicy(maxAttempts: 1), clock: TestClock())
        )
    }

    private let statusJSON = """
    {"id":"777","uri":"https://mastodon.social/users/a/statuses/777",
     "created_at":"2026-09-01T09:00:00.000Z",
     "account":{"id":"1","username":"a","acct":"a","display_name":"A","avatar":"https://x/a.png","url":"https://mastodon.social/@a","emojis":[]},
     "content":"<p>Hello.</p>","visibility":"unlisted","sensitive":false,"spoiler_text":"",
     "media_attachments":[],"emojis":[],"tags":[],"mentions":[],
     "replies_count":0,"reblogs_count":0,"favourites_count":0}
    """

    // MARK: - What a reply sends

    @Test("A reply posts the text, the parent and the visibility")
    func replyPostsTheDocumentedFields() async throws {
        let transport = StubTransport(.json(statusJSON))
        _ = try await makeClient(transport).postStatus(
            "Quite so.",
            inReplyTo: MastodonStatusID("110"),
            visibility: .unlisted,
            idempotencyKey: "key-1"
        )

        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/v1/statuses")

        let body = await transport.body(at: 0)
        #expect(body.contains("in_reply_to_id=110"))
        #expect(body.contains("status=Quite%20so."))
        #expect(body.contains("visibility=unlisted"))
    }

    /// The header that makes a retry safe. `HTTPClient` retries a 5xx, and an instance that accepted
    /// the post before the gateway gave up would otherwise publish it twice.
    @Test("A reply carries the idempotency key it was given")
    func replyCarriesItsIdempotencyKey() async throws {
        let transport = StubTransport(.json(statusJSON))
        _ = try await makeClient(transport).postStatus(
            "Hello.",
            visibility: .public,
            idempotencyKey: "draft-42"
        )

        #expect(await transport.header("Idempotency-Key", at: 0) == "draft-42")
    }

    /// Sending an empty `spoiler_text` marks the post as warned with a blank warning on some
    /// instances, which is a content warning nobody wrote and nobody can read.
    @Test("No content warning means no spoiler field at all")
    func emptyWarningIsOmitted() async throws {
        let transport = StubTransport(.json(statusJSON))
        _ = try await makeClient(transport).postStatus(
            "Hello.",
            visibility: .public,
            spoilerText: "   ",
            idempotencyKey: "k"
        )

        #expect(!(await transport.body(at: 0)).contains("spoiler_text"))
    }

    @Test("A content warning is sent when there is one")
    func warningIsSent() async throws {
        let transport = StubTransport(.json(statusJSON))
        _ = try await makeClient(transport).postStatus(
            "Spoilers.",
            visibility: .public,
            spoilerText: "Plot",
            idempotencyKey: "k"
        )

        #expect((await transport.body(at: 0)).contains("spoiler_text=Plot"))
    }

    /// The characters a person actually types. `.urlQueryAllowed` lets `&`, `=` and `+` through, and
    /// a post containing any of them would arrive at the instance as extra form fields — or with
    /// its pluses silently turned into spaces.
    @Test("Form encoding survives the characters a reply is written with")
    func formEncodingEscapesEverythingReserved() async throws {
        let transport = StubTransport(.json(statusJSON))
        _ = try await makeClient(transport).postStatus(
            "a&b=c+d e",
            visibility: .public,
            idempotencyKey: "k"
        )

        let body = await transport.body(at: 0)
        #expect(body.contains("status=a%26b%3Dc%2Bd%20e"))
        // One field, so exactly one separator — between `status` and `visibility`.
        #expect(body.filter { $0 == "&" }.count == 1)
    }

    /// 422 is the instance saying "I read it and it is wrong", which is the only failure here whose
    /// answer is to change the text rather than to sign in again or try later.
    @Test("A refused post is reported as refused, not as a dead token")
    func refusedPostIsItsOwnFailure() async throws {
        let transport = StubTransport(.status(422, body: #"{"error":"Text character limit exceeded"}"#))

        await #expect(throws: MastodonError.self) {
            _ = try await makeClient(transport).postStatus(
                String(repeating: "x", count: 600),
                visibility: .public,
                idempotencyKey: "k"
            )
        }

        do {
            _ = try await makeClient(StubTransport(.status(422))).postStatus(
                "x",
                visibility: .public,
                idempotencyKey: "k"
            )
            Issue.record("Expected the post to be refused")
        } catch let error as MastodonError {
            guard case .rejected = error else {
                Issue.record("Expected .rejected, got \(error)")
                return
            }
        }
    }

    // MARK: - Muting

    @Test("Muting posts to the documented path")
    func mutePath() async throws {
        let transport = StubTransport(.json(#"{"id":"9","muting":true}"#))
        let relationship = try await makeClient(transport).mute("9")

        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/v1/accounts/9/mute")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(relationship.muting == true)
    }

    /// Muting someone whose replies still reach you is not what the word means to anyone who
    /// reached for it.
    @Test("A mute silences notifications too")
    func muteSilencesNotifications() async throws {
        let transport = StubTransport(.json(#"{"id":"9","muting":true}"#))
        _ = try await makeClient(transport).mute("9")

        #expect((await transport.body(at: 0)).contains("notifications=true"))
    }

    /// A 403 on a write means the token predates the scope, not that it has been revoked — the
    /// reader has to sign in again, and telling them their account was revoked sends them looking
    /// for a sign-out they never performed.
    @Test("A refused mute reads as a missing permission")
    func refusedMuteIsAScopeProblem() async throws {
        let transport = StubTransport(.status(403))

        do {
            _ = try await makeClient(transport).mute("9")
            Issue.record("Expected the mute to be refused")
        } catch let error as MastodonError {
            guard case .writeNotAuthorized = error else {
                Issue.record("Expected .writeNotAuthorized, got \(error)")
                return
            }
        }
    }
}

/// Which audience a reply may be sent to.
///
/// The rule here is the one with a consequence that cannot be undone. Replying publicly to a
/// followers-only post republishes the fact that the post exists to an audience its author
/// deliberately excluded — and the reply quotes it by being attached to it.
@Suite("Reply visibility")
struct MastodonVisibilityTests {

    @Test("A reply defaults to the visibility of the post it answers", arguments: [
        MastodonVisibility.public,
        .unlisted,
        .private,
        .direct,
    ])
    func replyInheritsVisibility(parent: MastodonVisibility) {
        #expect(MastodonVisibility.defaultForReply(to: parent) == parent)
    }

    @Test("A reply can never reach further than its parent", arguments: [
        MastodonVisibility.public,
        .unlisted,
        .private,
        .direct,
    ])
    func repliesNeverWiden(parent: MastodonVisibility) {
        for option in MastodonVisibility.allowedForReply(to: parent) {
            #expect(option.reach <= parent.reach, "\(option) is wider than \(parent)")
        }
    }

    /// There must always be something to choose, or the picker is empty and nothing can be sent.
    @Test("The parent's own visibility is always on offer", arguments: [
        MastodonVisibility.public,
        .unlisted,
        .private,
        .direct,
    ])
    func parentIsAlwaysOffered(parent: MastodonVisibility) {
        #expect(MastodonVisibility.allowedForReply(to: parent).contains(parent))
    }

    @Test("Answering a followers-only post offers no public option")
    func followersOnlyCannotBeAnsweredPublicly() {
        let allowed = MastodonVisibility.allowedForReply(to: .private)

        #expect(allowed == [.private, .direct])
    }

    @Test("Answering a public post offers everything")
    func publicOffersEverything() {
        #expect(MastodonVisibility.allowedForReply(to: .public) == [.public, .unlisted, .private, .direct])
    }

    /// An instance that adds a visibility this build has never heard of must not have it read as
    /// the widest one. Guessing wide on something unknown is how a reply escapes its parent's
    /// audience.
    @Test("An unrecognised visibility is read as the narrow end, not the wide one")
    func unknownVisibilityIsNarrow() {
        #expect(MastodonVisibility(statusValue: "local-only") == .private)
        #expect(MastodonVisibility(statusValue: "") == .private)
        #expect(MastodonVisibility(statusValue: "public") == .public)
    }
}

/// What the composer's counter says, against Mastodon's own arithmetic.
@Suite("Post length")
struct MastodonPostLengthTests {

    @Test("Plain text counts as itself")
    func plainText() {
        #expect(MastodonPostLength.count(text: "Hello.") == 6)
    }

    /// A link is a fixed cost, which is what makes a long tracking URL postable at all.
    @Test("A link counts as 23 however long it is")
    func linksAreFixedWidth() {
        let long = "https://example.com/" + String(repeating: "a", count: 300)

        #expect(MastodonPostLength.count(text: long) == 23)
        #expect(MastodonPostLength.count(text: "See \(long)") == 4 + 23)
    }

    @Test("Two links cost two links")
    func severalLinks() {
        #expect(MastodonPostLength.count(text: "https://a.example https://b.example") == 23 + 1 + 23)
    }

    /// The case that would otherwise make a reply to somebody on a long-named instance look nearly
    /// full before a word of it had been written.
    @Test("A mention costs its username, not its domain")
    func mentionsDropTheDomain() {
        #expect(MastodonPostLength.count(text: "@someone@a.very.long.instance.example") == "@someone".count)
        #expect(MastodonPostLength.count(text: "@someone hello") == "@someone hello".count)
    }

    /// A URL can contain an `@`, so the order the two rules are applied in is load-bearing.
    @Test("A link containing an at-sign is still one link")
    func mentionRuleDoesNotEatLinks() {
        #expect(MastodonPostLength.count(text: "https://example.com/?to=@someone@host.example") == 23)
    }

    /// The warning counts against the same limit as the body, which is why the composer's counter
    /// takes both.
    @Test("A content warning counts too")
    func warningCounts() {
        #expect(MastodonPostLength.count(text: "body", spoilerText: "cw") == 6)
    }
}
