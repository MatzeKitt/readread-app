import Foundation
import ReadReadModel
import ReadReadSync
import Testing

@testable import ReadReadUI

/// Which accounts the Like and Boost menu offers, and in what order.
///
/// Worth pinning because a boost from the wrong account is not something the reader can quietly
/// undo — it has already appeared in other people's timelines by then.
@Suite("Status action menu")
struct StatusActionMenuTests {

    private func account(
        _ name: String,
        kind: AccountKind = .mastodon,
        isEnabled: Bool = true,
        id: UUID = UUID()
    ) -> AccountRecord {
        AccountRecord(
            id: id,
            kind: kind,
            displayName: name,
            serverURLString: "https://mastodon.social",
            username: name.lowercased(),
            isEnabled: isEnabled
        )
    }

    @Test("The post's own account comes first")
    func owningAccountLeads() {
        let owner = UUID()
        let accounts = [
            account("Alpha"),
            account("Zulu", id: owner),
            account("Mike"),
        ]

        let order = StatusInteractions.Actor.menuOrder(for: accounts, owner: owner)

        #expect(order.map(\.displayName) == ["Zulu", "Alpha", "Mike"])
    }

    /// Everything after the first is in the Finder's order, so the menu does not reshuffle from
    /// one post to the next.
    @Test("The rest are in a stable, human order")
    func restAreSorted() {
        let accounts = [account("zeta"), account("Ärger"), account("alpha"), account("Beta")]

        let order = StatusInteractions.Actor.menuOrder(for: accounts, owner: UUID())

        #expect(order.map(\.displayName) == ["alpha", "Ärger", "Beta", "zeta"])
    }

    @Test("FreshRSS accounts are not offered")
    func freshRSSExcluded() {
        let accounts = [account("Feeds", kind: .freshRSS), account("Home")]

        let order = StatusInteractions.Actor.menuOrder(for: accounts, owner: UUID())

        #expect(order.map(\.displayName) == ["Home"])
    }

    /// A switched-off account still has a token, so acting as it would work — and would be a post
    /// from an account the reader has told the app to leave alone.
    @Test("A disabled account is not offered")
    func disabledExcluded() {
        let accounts = [account("Off", isEnabled: false), account("Home")]

        let order = StatusInteractions.Actor.menuOrder(for: accounts, owner: UUID())

        #expect(order.map(\.displayName) == ["Home"])
    }

    @Test("Nothing to act as means nothing is offered")
    func emptyWhenNoMastodonAccount() {
        #expect(StatusInteractions.Actor.menuOrder(for: [], owner: UUID()).isEmpty)
    }

    /// The address travels as a string, because the acting side runs off the main actor and a
    /// SwiftData model cannot cross it.
    @Test("The server address travels with the account")
    func serverAddressTravels() {
        let order = StatusInteractions.Actor.menuOrder(for: [account("Home")], owner: UUID())

        #expect(order.first?.serverURLString == "https://mastodon.social")
    }
}

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// That the glyphs the actions draw actually exist.
///
/// Worth a test because a bad SF Symbol name fails *silently*: nothing logs, nothing fails to
/// build, and the box where the icon should be only appears once you have boosted something. The
/// first version of this feature asked for `arrow.2.squarepath.circle.fill`, which does not exist
/// in any release, and that is how it was found.
@Suite("Status action symbols")
struct StatusActionSymbolTests {

    @Test("Every symbol the actions use resolves", arguments: StatusActionSymbol.all)
    func symbolResolves(name: String) throws {
        #if canImport(AppKit)
        #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil)
        #elseif canImport(UIKit)
        #expect(UIImage(systemName: name) != nil)
        #endif
    }

    /// Not a stylistic preference: `arrow.2.squarepath` has no variants at all, so a boosted post
    /// cannot be marked by a filled glyph and has to be marked some other way. If a future release
    /// adds one, this is the test to delete.
    @Test("Boosting has no filled variant to switch to")
    func boostHasNoFilledVariant() {
        #if canImport(AppKit)
        #expect(NSImage(systemSymbolName: "arrow.2.squarepath.fill", accessibilityDescription: nil) == nil)
        #expect(NSImage(systemSymbolName: "arrow.2.squarepath.circle.fill", accessibilityDescription: nil) == nil)
        #endif
    }
}
