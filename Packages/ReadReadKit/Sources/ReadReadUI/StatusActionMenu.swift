import ReadReadModel
import ReadReadSync
import SwiftUI

/// The glyphs for liking and boosting, named once.
///
/// In one place because the timeline row, the context menu and the reading pane's toolbar all draw
/// them and all three have to agree — and because an SF Symbol that does not exist fails silently.
/// `arrow.2.squarepath` has no `.fill` or `.circle` variant, and asking for one drew a
/// missing-symbol box on every boosted post: nothing logged it, nothing failed to build, and the
/// only way to see it was to boost something. `StatusActionSymbolTests` now resolves each of these
/// against the system, which is the check that would have caught it.
enum StatusActionSymbol {

    static let favourite = "star"
    static let favourited = "star.fill"

    /// The same glyph whether or not the reader has boosted, for want of a variant. The state is
    /// carried by the button's title, and in a timeline row by contrast — see `EngagementCounts`.
    static let boost = "arrow.2.squarepath"

    static let reply = "bubble.left"

    static let all = [favourite, favourited, boost, reply]
}

/// Like and Boost, for a Mastodon post.
///
/// A view rather than a `@ViewBuilder` on the row, so that the work of running an action lives next
/// to the buttons that start it rather than in the timeline's own body — and so the timeline's
/// context menu and the reading pane's toolbar are one implementation. Two copies would be free to
/// disagree about which account acts, which is the part of this nobody can afford to have wrong
/// twice.
///
/// The account list is passed in, not queried here. A context menu belongs to a row, and a row is
/// realised as fast as the list can scroll: a `@Query` in here would be one fetch per cell for a
/// list of two or three accounts that never changes while scrolling. `TimelineQueryHost` fetches
/// it once for the whole list, which is the same arrangement the source titles use.
struct StatusActionMenu: View {

    /// Where these buttons are being drawn.
    ///
    /// The actions are identical; only their presentation differs. A menu row wants its title
    /// beside its icon, and a toolbar draws the icon alone — so there the name has to be available
    /// on hover instead, the way every other button in that strip does it.
    enum Placement {
        case contextMenu
        case toolbar
    }

    let item: CachedItem

    /// Every Mastodon account that could act, the post's own first.
    let accounts: [StatusInteractions.Actor]

    var placement: Placement = .contextMenu

    @Environment(AppServices.self) private var services

    private var isFavourited: Bool { item.isFavourited ?? false }
    private var isReblogged: Bool { item.isReblogged ?? false }

    var body: some View {
        // Nothing to offer for an article, or before any Mastodon account exists.
        if item.kind == .status, !accounts.isEmpty {
            action(
                .favourite(isOn: !isFavourited),
                title: isFavourited ? "Unlike" : "Like",
                // Filled when it is already done, which is the convention everywhere else: the
                // outline is the offer, the fill is the state.
                systemImage: isFavourited ? StatusActionSymbol.favourited : StatusActionSymbol.favourite
            )

            action(
                .boost(isOn: !isReblogged),
                title: isReblogged ? "Remove Boost" : "Boost",
                systemImage: StatusActionSymbol.boost
            )
        }
    }

    /// One action: a plain button with a single account, a submenu with more than one.
    ///
    /// The distinction matters more than it looks. With one account there is no choice to make, and
    /// burying Like behind a submenu would put a decision in front of the commonest action in the
    /// app. With several, *which account* is the whole question — a boost from the wrong one is not
    /// something the reader can quietly undo, because it has already appeared in other people's
    /// timelines.
    @ViewBuilder
    private func action(
        _ action: StatusInteractions.Action,
        title: LocalizedStringKey,
        systemImage: String
    ) -> some View {
        if accounts.count == 1, let only = accounts.first {
            Button(title, systemImage: systemImage) {
                perform(action, as: only)
            }
            .modifier(ActionPresentation(placement: placement, title: title))
        } else {
            Menu {
                ForEach(accounts, id: \.id) { account in
                    Button(account.displayName) {
                        perform(action, as: account)
                    }
                }
            } label: {
                Label(title, systemImage: systemImage)
            }
            .modifier(ActionPresentation(placement: placement, title: title))
        }
    }

    /// What the placement changes: whether the button's name is available on hover.
    ///
    /// A modifier rather than an `if` inside the builder, because branching on the placement would
    /// give the two cases different view identities — and a toolbar item that changes identity when
    /// a second account is added is a toolbar item that animates itself out and back in.
    private struct ActionPresentation: ViewModifier {

        let placement: Placement
        let title: LocalizedStringKey

        func body(content: Content) -> some View {
            switch placement {
            case .contextMenu:
                // The title is already beside the icon; a tooltip repeating it would be noise.
                content
            case .toolbar:
                content.toolbarButtonHelp(title)
            }
        }
    }

    private func perform(_ action: StatusInteractions.Action, as account: StatusInteractions.Actor) {
        Task {
            // Nothing is done with the answer here. The row is updated by `AppServices` from what
            // the server said — so a Like the instance refused leaves the row still offering Like
            // — and a failure is raised as an alert at the window, because this menu has closed by
            // the time the request comes back.
            await services.favouriteOrBoost(action, on: item, as: account)
        }
    }
}

/// Turning account rows into something a menu can act with.
extension StatusInteractions.Actor {

    /// The Mastodon accounts that can act, with `owner`'s first.
    ///
    /// Ordered rather than sorted alphabetically, and this is the one ordering decision in the
    /// feature: the account whose timeline the post arrived in is the one a reader means nine times
    /// out of ten, and it is also the only one that can act without asking its instance to go and
    /// fetch the post first. Putting it at the top makes the common case the first item in the
    /// menu; the rest follow in the Finder's order so the list is stable between posts.
    static func menuOrder(for accounts: [AccountRecord], owner: UUID) -> [StatusInteractions.Actor] {
        accounts
            .filter { $0.kind == .mastodon && $0.isEnabled }
            .sorted { left, right in
                if (left.id == owner) != (right.id == owner) { return left.id == owner }
                return left.displayName.localizedStandardCompare(right.displayName) == .orderedAscending
            }
            .map {
                StatusInteractions.Actor(
                    id: $0.id,
                    displayName: $0.displayName,
                    serverURLString: $0.serverURLString
                )
            }
    }
}
