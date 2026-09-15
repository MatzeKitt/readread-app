import Foundation

/// Preferences about reading itself, as opposed to how often things refresh.
///
/// Device-local, in `UserDefaults`, and deliberately **not** synced — the same reasoning as
/// `RefreshSettings`. Whether this machine keeps offline copies of saved articles is a fact about
/// this machine's disk, not about the account.
///
/// Kept separate from `RefreshSettings` rather than added to it because the two are edited from
/// different places and one already stretches its name by carrying the badge preferences; a
/// settings blob that accumulates everything is how a "refresh interval" ends up controlling
/// offline storage.
public struct ReadingSettings: Sendable, Equatable, Codable {

    /// Snapshot an article's body when it is saved for later.
    ///
    /// On by default. The point of Read Later is that the item is still there when you get to it,
    /// and a link is not — feeds roll off, posts are deleted, articles go behind a wall. The cost
    /// is disk, which is the cheaper of the two things to run out of.
    public var archivesReadLaterContent: Bool

    /// Show the "Arrived late" badge on timeline rows.
    ///
    /// On by default, because a row sitting a long way down the list despite having just arrived
    /// is otherwise inexplicable. Off for people who find the annotation noisy.
    public var showsLateArrivalBadges: Bool

    /// Show a count beside Filtered Items in the sidebar.
    ///
    /// Off by default, and that is the point of it being a setting at all. Every other count in the
    /// sidebar is work waiting to be done — items above a reading position — and a permanent number
    /// beside the filtered pile reads as the same kind of thing, so a rule doing its job all day
    /// looks like a growing backlog. The list is a diagnostic: you go to it when something has
    /// vanished, not because it has a number on it. For anyone who does want to watch how much the
    /// rules are hiding, the count is the total size of the list.
    public var showsFilteredItemsBadge: Bool

    /// Load a Mastodon post's whole conversation when opening it.
    ///
    /// Off by default, and the reason is cost rather than taste: a thread is a second network
    /// request per post opened, against the instance, every time — so it is opt-in, and the detail
    /// view offers to load one on demand for people who leave it off.
    public var loadsMastodonThreads: Bool

    /// Size of a timeline row's headline — an article's title, or a post's author.
    public var listHeadingScale: TextScale

    /// Size of a timeline row's text — an article's excerpt, or a post's body.
    ///
    /// Separate from the headline on purpose. The two are read differently: the headline is
    /// scanned and the text beneath it is sampled, so someone who wants a denser list usually
    /// wants smaller *excerpts* while keeping headlines legible at a glance.
    public var listBodyScale: TextScale

    /// Size of an article's or post's text in the reading pane.
    public var contentScale: TextScale

    /// Leading in the reading pane, as a multiple of the font size.
    ///
    /// The same number CSS calls `line-height`, and applied as that in the article stylesheet.
    /// Native text gets the closest equivalent — see `ScaledFont` — because SwiftUI expresses
    /// leading as *extra* points between lines rather than as a total line box, so the two are the
    /// same idea measured from different places.
    ///
    /// 1.5 by default. The stylesheet used to hard-code 1.6, which is comfortable for a wide
    /// article column and too airy for a short post, and there was no way to say so.
    public var contentLineHeight: Double

    /// Open a tapped link inside the app rather than handing it to the browser.
    ///
    /// On by default, and iOS only — there is no in-app browser on the Mac, where handing a link
    /// to the default browser is both what the platform expects and what the reader has already
    /// chosen. On a phone the opposite is true: leaving the app to read one linked page and coming
    /// back by way of the app switcher loses your place in the timeline, which is the one thing
    /// this app is built not to lose.
    ///
    /// Stored on both platforms so the blob is one shape everywhere; only iOS reads it.
    public var opensLinksInApp: Bool

    public init(
        archivesReadLaterContent: Bool = true,
        showsLateArrivalBadges: Bool = true,
        showsFilteredItemsBadge: Bool = false,
        loadsMastodonThreads: Bool = false,
        listHeadingScale: TextScale = .standard,
        listBodyScale: TextScale = .standard,
        contentScale: TextScale = .standard,
        contentLineHeight: Double = ReadingSettings.defaultLineHeight,
        opensLinksInApp: Bool = true
    ) {
        self.archivesReadLaterContent = archivesReadLaterContent
        self.showsLateArrivalBadges = showsLateArrivalBadges
        self.showsFilteredItemsBadge = showsFilteredItemsBadge
        self.loadsMastodonThreads = loadsMastodonThreads
        self.listHeadingScale = listHeadingScale
        self.listBodyScale = listBodyScale
        self.contentScale = contentScale
        self.contentLineHeight = Self.clampedLineHeight(contentLineHeight)
        self.opensLinksInApp = opensLinksInApp
    }

    /// What the reading pane uses when nothing has been chosen.
    public static let defaultLineHeight = 1.5

    /// The range the setting may take.
    ///
    /// Bounded because the value reaches a stylesheet and a layout engine, and neither refuses
    /// anything: 0 collapses every line on top of the last, and a large number scrolls a paragraph
    /// off the screen. Clamped on the way in rather than validated at the point of use, so a value
    /// that arrives from an edited preferences file is corrected once instead of at every read.
    public static let lineHeightRange = 1.0...2.5

    static func clampedLineHeight(_ value: Double) -> Double {
        guard value.isFinite else { return defaultLineHeight }
        return min(max(value, lineHeightRange.lowerBound), lineHeightRange.upperBound)
    }

    /// Decoded field by field, with every field optional.
    ///
    /// Synthesised `Decodable` makes each stored property mandatory, so **adding a field here
    /// would fail the decode of every settings blob written before it existed** — and the store
    /// below treats a decode failure as "reset to defaults". Someone who had turned off late
    /// arrival badges and turned on Mastodon threads would silently get both back on an update,
    /// with nothing to attribute it to. The same shape of bug, in the same week, cost a live
    /// FreshRSS account its entire feed list.
    ///
    /// So: a missing key means the default for that key, never a reset of the rest.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ReadingSettings()
        archivesReadLaterContent = try container.decodeIfPresent(Bool.self, forKey: .archivesReadLaterContent)
            ?? fallback.archivesReadLaterContent
        showsLateArrivalBadges = try container.decodeIfPresent(Bool.self, forKey: .showsLateArrivalBadges)
            ?? fallback.showsLateArrivalBadges
        showsFilteredItemsBadge = try container.decodeIfPresent(Bool.self, forKey: .showsFilteredItemsBadge)
            ?? fallback.showsFilteredItemsBadge
        loadsMastodonThreads = try container.decodeIfPresent(Bool.self, forKey: .loadsMastodonThreads)
            ?? fallback.loadsMastodonThreads
        listHeadingScale = try container.decodeIfPresent(TextScale.self, forKey: .listHeadingScale)
            ?? fallback.listHeadingScale
        listBodyScale = try container.decodeIfPresent(TextScale.self, forKey: .listBodyScale)
            ?? fallback.listBodyScale
        contentScale = try container.decodeIfPresent(TextScale.self, forKey: .contentScale)
            ?? fallback.contentScale
        contentLineHeight = Self.clampedLineHeight(
            try container.decodeIfPresent(Double.self, forKey: .contentLineHeight)
                ?? fallback.contentLineHeight
        )
        opensLinksInApp = try container.decodeIfPresent(Bool.self, forKey: .opensLinksInApp)
            ?? fallback.opensLinksInApp
    }

    public static let `default` = ReadingSettings()
}

/// Reads and writes ``ReadingSettings``.
///
/// `@unchecked Sendable` for the same reason as `RefreshSettingsStore`: `UserDefaults` is
/// documented as thread-safe but is not marked `Sendable`, and this type only touches one key.
public struct ReadingSettingsStore: @unchecked Sendable {

    private static let key = "media.kitt.readread.readingSettings"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> ReadingSettings {
        guard let data = defaults.data(forKey: Self.key),
              let settings = try? JSONDecoder().decode(ReadingSettings.self, from: data)
        else {
            // A decode failure means the stored shape predates a change to the type. These are
            // preferences, not data, so resetting them beats refusing to launch.
            return .default
        }
        return settings
    }

    public func save(_ settings: ReadingSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
