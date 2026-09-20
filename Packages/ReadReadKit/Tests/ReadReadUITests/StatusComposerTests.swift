import Foundation
import MastodonAPI
import Testing

@testable import ReadReadUI

/// Who a reply is addressed to.
///
/// Worth asserting because both ways of getting it wrong are invisible to the person writing the
/// reply and obvious to everyone else: dropping a mention removes somebody from a conversation they
/// were part of, and keeping a duplicate notifies them twice.
@Suite("Reply addressing")
struct StatusComposerTests {

    private func status(
        author: String,
        mentions: [String] = [],
        json: String? = nil
    ) throws -> MastodonStatus {
        let mentionJSON = mentions
            .enumerated()
            .map { index, acct in
                """
                {"id":"\(index)","username":"\(acct.split(separator: "@").first ?? "")",
                 "url":"https://example.social/@\(acct)","acct":"\(acct)"}
                """
            }
            .joined(separator: ",")

        let body = json ?? """
        {"id":"1","uri":"https://example.social/users/x/statuses/1",
         "created_at":"2026-09-01T09:00:00.000Z",
         "account":{"id":"7","username":"\(author.split(separator: "@").first ?? "")","acct":"\(author)",
                    "display_name":"Author","avatar":"https://x/a.png","url":"https://example.social/@\(author)","emojis":[]},
         "content":"<p>Hello.</p>","visibility":"public","sensitive":false,"spoiler_text":"",
         "media_attachments":[],"emojis":[],"tags":[],"mentions":[\(mentionJSON)],
         "replies_count":0,"reblogs_count":0,"favourites_count":0}
        """
        return try JSONDecoder.mastodon.decode(MastodonStatus.self, from: Data(body.utf8))
    }

    /// The author leads, because the reply is to them.
    @Test("The author comes first")
    func authorLeads() throws {
        let mentions = StatusComposer.mentions(of: try status(author: "writer@a.social", mentions: ["other@b.social"]))

        #expect(mentions == ["writer@a.social", "other@b.social"])
    }

    /// Everyone the post was talking to stays in the conversation. Dropping them is a silent
    /// removal — they simply stop seeing the thread they were in.
    @Test("Everyone the post mentioned is carried over, in the post's own order")
    func mentionsAreCarriedOver() throws {
        let mentions = StatusComposer.mentions(
            of: try status(author: "writer@a.social", mentions: ["first@b.social", "second@c.social"])
        )

        #expect(mentions == ["writer@a.social", "first@b.social", "second@c.social"])
    }

    /// A post that mentions its own author — replying to yourself in a thread does this — must not
    /// produce the handle twice.
    @Test("Nobody is addressed twice")
    func duplicatesAreDropped() throws {
        let mentions = StatusComposer.mentions(
            of: try status(author: "writer@a.social", mentions: ["writer@a.social", "other@b.social"])
        )

        #expect(mentions == ["writer@a.social", "other@b.social"])
    }

    @Test("A post mentioning nobody is addressed to its author alone")
    func authorOnly() throws {
        #expect(StatusComposer.mentions(of: try status(author: "writer@a.social")) == ["writer@a.social"])
    }
}
