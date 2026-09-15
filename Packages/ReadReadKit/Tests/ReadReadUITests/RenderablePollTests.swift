import Foundation
import MastodonAPI
import Testing

@testable import ReadReadUI

@Suite("RenderablePoll")
struct RenderablePollTests {

    private func poll(
        _ votes: [Int?],
        total: Int,
        multiple: Bool = false,
        expired: Bool = false
    ) -> RenderablePoll {
        let options = votes
            .map { count in #"{"title":"o","votes_count":\#(count.map(String.init) ?? "null")}"# }
            .joined(separator: ",")
        let json = """
        {
          "id": "1",
          "expires_at": null,
          "expired": \(expired),
          "multiple": \(multiple),
          "votes_count": \(total),
          "voters_count": null,
          "options": [\(options)]
        }
        """
        // Built through the real decoder so the fixture cannot drift from the wire shape.
        let decoded = try! JSONDecoder.mastodon.decode(MastodonPoll.self, from: Data(json.utf8))
        return RenderablePoll(decoded)
    }

    @Test("A single-choice poll's bars are shares of the total")
    func singleChoiceShares() {
        let subject = poll([6, 3, 1], total: 10)

        #expect(subject.share(of: subject.options[0]) == 0.6)
        #expect(subject.share(of: subject.options[2]) == 0.1)
    }

    @Test("A multiple-choice poll's bars are relative to the leading option")
    func multipleChoiceShares() {
        // Options sum to more than the total, because each voter picks several. Dividing by the
        // total gives shares over 100% and bars wider than the row they sit in.
        let subject = poll([8, 4, 2], total: 10, multiple: true)

        #expect(subject.share(of: subject.options[0]) == 1)
        #expect(subject.share(of: subject.options[1]) == 0.5)
    }

    @Test("Percentages stay relative to the total even when bars are not")
    func percentagesUseTheTotal() throws {
        let subject = poll([8, 4, 2], total: 10, multiple: true)
        // The label answers "what share of voters chose this", which is the total — only the bar's
        // geometry needs the other denominator.
        #expect(try #require(subject.percentage(of: subject.options[0])) == 0.8)
    }

    @Test("A running poll with hidden tallies shows no bars")
    func hiddenTalliesShowNothing() {
        let subject = poll([nil, nil], total: 10)

        // Nil, not zero: drawing empty bars would state a result the server declined to give.
        #expect(!subject.showsResults)
        #expect(subject.share(of: subject.options[0]) == nil)
        #expect(subject.percentage(of: subject.options[0]) == nil)
    }

    @Test("A poll nobody voted in does not divide by zero")
    func emptyPoll() {
        let subject = poll([0, 0], total: 0)

        #expect(subject.share(of: subject.options[0]) == 0)
        #expect(subject.percentage(of: subject.options[0]) == 0)
    }

    @Test("An option cannot exceed a full bar")
    func shareIsClamped() {
        // A tally larger than the reported total is inconsistent, but it comes from someone else's
        // server and must not draw outside its row.
        let subject = poll([12], total: 10)
        #expect(subject.share(of: subject.options[0]) == 1)
    }
}
