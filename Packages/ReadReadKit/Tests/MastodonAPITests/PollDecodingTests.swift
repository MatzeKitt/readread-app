import Foundation
import Testing

@testable import MastodonAPI

/// Polls come off the wire in two quite different shapes depending on whether the instance is
/// hiding running tallies, and the difference is a `null` that is easy to read as a zero.
@Suite("Poll decoding")
struct PollDecodingTests {

    private func decode(_ json: String) throws -> MastodonPoll {
        try JSONDecoder.mastodon.decode(MastodonPoll.self, from: Data(json.utf8))
    }

    @Test("A finished poll decodes its tallies")
    func finishedPoll() throws {
        let poll = try decode("""
        {
          "id": "34830",
          "expires_at": "2019-12-05T04:05:08.302Z",
          "expired": true,
          "multiple": false,
          "votes_count": 10,
          "voters_count": 10,
          "options": [
            { "title": "accnt", "votes_count": 6 },
            { "title": "instance", "votes_count": 3 },
            { "title": "prof", "votes_count": 1 }
          ]
        }
        """)

        #expect(poll.expired)
        #expect(poll.votesCount == 10)
        #expect(poll.options.map(\.votesCount) == [6, 3, 1])
    }

    @Test("A running poll's hidden tallies decode as nil, not zero")
    func runningPollHidesVotes() throws {
        let poll = try decode("""
        {
          "id": "34830",
          "expires_at": "2099-12-05T04:05:08.302Z",
          "expired": false,
          "multiple": false,
          "votes_count": 10,
          "voters_count": null,
          "options": [
            { "title": "accnt", "votes_count": null },
            { "title": "instance", "votes_count": null }
          ]
        }
        """)

        // "Not saying" and "nobody voted for this" are different answers, and rendering the second
        // when the server meant the first would invent a result.
        #expect(poll.options.allSatisfy { $0.votesCount == nil })
        #expect(poll.votersCount == nil)
    }

    @Test("A poll with no expiry decodes")
    func pollWithoutExpiry() throws {
        let poll = try decode("""
        {
          "id": "1", "expires_at": null, "expired": false, "multiple": true,
          "votes_count": 4, "voters_count": 2,
          "options": [{ "title": "a", "votes_count": 3 }, { "title": "b", "votes_count": 1 }]
        }
        """)

        #expect(poll.expiresAt == nil)
        #expect(poll.multiple)
    }
}
