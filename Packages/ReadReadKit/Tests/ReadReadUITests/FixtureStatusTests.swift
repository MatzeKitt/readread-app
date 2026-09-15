import Foundation
import ReadReadModel
import SwiftData
import Testing

@testable import ReadReadUI

/// The fixture Mastodon posts carry a real `MastodonStatus` payload so the detail view can be
/// exercised without an account. If that payload stops decoding, the status view silently falls
/// back to the plain columns — no poll, no emoji, no handle — and everything still *looks* fine,
/// which is exactly the kind of rot a fixture is supposed to prevent.
@Suite("Fixture statuses")
struct FixtureStatusTests {

    private func statuses() throws -> [RenderableStatus] {
        let container = try ReadReadStore.inMemoryContainer()
        try FixtureData.seed(into: ModelContext(container))

        let context = ModelContext(container)
        let kind = ItemKind.status.rawValue
        let items = try context.fetch(
            FetchDescriptor<CachedItem>(predicate: #Predicate { $0.kindRaw == kind })
        )
        return items.map(RenderableStatus.init)
    }

    @Test("Fixture statuses decode their payload rather than falling back")
    func payloadsDecode() throws {
        let all = try statuses()
        #expect(!all.isEmpty)

        // `canLoadConversation` is only true on the payload path, so it doubles as the check that
        // the decode succeeded at all.
        #expect(all.allSatisfy { $0.canLoadConversation })
        #expect(all.allSatisfy { $0.authorHandle != nil })
    }

    @Test("A fixture poll survives the round trip")
    func pollDecodes() throws {
        let poll = try #require(try statuses().compactMap(\.poll).first)

        #expect(poll.options.count == 3)
        #expect(poll.totalVotes == 137)
        #expect(!poll.isExpired)
        #expect(poll.showsResults)
        #expect(poll.options.first?.title == "Published date")
    }

    @Test("Fixture custom emoji survive the round trip")
    func emojiDecode() throws {
        let status = try #require(try statuses().first { !$0.emojis.isEmpty })

        #expect(status.emojis["blobcat"] != nil)
        #expect(status.emojis["rust"] != nil)
    }

    @Test("A shortcode in a display name is found")
    func displayNameShortcodeIsSegmented() throws {
        let status = try #require(try statuses().first { $0.authorName.contains(":blobcat:") })

        let segments = CustomEmojiText.segments(
            of: AttributedString(status.authorName),
            shortcodes: Set(status.emojis.keys)
        )
        // A display name is where custom emoji turn up most, and Mastodon lists those on the
        // account rather than on the post — so this checks both halves are being merged.
        #expect(segments.contains(.emoji(shortcode: "blobcat")))
    }

    @Test("The store's item id wins over the status id")
    func storeIDWins() throws {
        let all = try statuses()
        // The timeline selects by the store's id; taking the status's own would break scrolling to
        // the focused post.
        #expect(all.allSatisfy { $0.id.hasPrefix("mastodon:") })
    }
}
