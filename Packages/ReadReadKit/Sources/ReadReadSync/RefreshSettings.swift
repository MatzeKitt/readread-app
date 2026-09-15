import Foundation
import ReadReadModel

/// The three things that refresh on their own, each on its own cadence.
public enum RefreshKind: String, CaseIterable, Sendable, Codable {

    /// Reading positions, Read Later and filters, through the sync endpoint.
    ///
    /// A pull with nothing new is a few hundred bytes, so this can run often.
    case syncState

    /// Mastodon home timelines.
    case mastodonFeeds

    /// FreshRSS subscriptions.
    case freshRSSFeeds

    public var displayName: String {
        switch self {
        case .syncState: "Reading position"
        case .mastodonFeeds: "Mastodon"
        case .freshRSSFeeds: "Feeds"
        }
    }

    /// Whether this kind fetches items, as opposed to small sync state.
    ///
    /// Used to decide what a completed run may publish a badge from: the badge counts items, so a
    /// run that only refreshed positions has not established a new item count.
    public var ingestsItems: Bool {
        self != .syncState
    }
}

/// How often each kind refreshes, and when refreshing should hold off.
///
/// Device-local, in `UserDefaults`, and deliberately **not** synced. A Mac on mains power and a
/// phone on battery want different cadences, and syncing this would force one choice on both.
public struct RefreshSettings: Sendable, Equatable, Codable {

    /// Seconds between runs, or `nil` for off. Stored as seconds because `Duration` is not
    /// `Codable` and a plain integer is what a settings screen edits anyway.
    public var syncStateSeconds: Int?
    public var mastodonSeconds: Int?
    public var freshRSSSeconds: Int?

    /// Suspend timers while no window is visible.
    ///
    /// Matters most on macOS, where the app is typically left open for days — a hidden window that
    /// keeps polling is pure battery cost for something nobody is looking at.
    public var pauseWhenHidden: Bool

    /// Stretch every interval while Low Power Mode is on.
    public var respectLowPowerMode: Bool

    /// Multiplier applied under Low Power Mode.
    public var lowPowerMultiplier: Int

    /// Which scope's count the badge shows.
    public var badgeScopeRaw: String

    /// Count late arrivals toward the badge.
    ///
    /// Off by default: a late arrival sits below the marker in a chronologically-ordered list, so
    /// counting it would advertise something the user cannot find by scrolling to the top.
    public var badgeIncludesLateArrivals: Bool

    /// How many days back a refresh fetches. `0` means everything. See ``HistoryWindow``.
    public var historyWindowDays: Int

    public init(
        syncStateSeconds: Int? = 30,
        mastodonSeconds: Int? = 5 * 60,
        freshRSSSeconds: Int? = 15 * 60,
        pauseWhenHidden: Bool = true,
        respectLowPowerMode: Bool = true,
        lowPowerMultiplier: Int = 4,
        badgeScopeRaw: String = ScopeID.all.rawValue,
        badgeIncludesLateArrivals: Bool = false,
        historyWindowDays: Int = HistoryWindow.default
    ) {
        self.syncStateSeconds = syncStateSeconds
        self.mastodonSeconds = mastodonSeconds
        self.freshRSSSeconds = freshRSSSeconds
        self.pauseWhenHidden = pauseWhenHidden
        self.respectLowPowerMode = respectLowPowerMode
        self.lowPowerMultiplier = lowPowerMultiplier
        self.badgeScopeRaw = badgeScopeRaw
        self.badgeIncludesLateArrivals = badgeIncludesLateArrivals
        self.historyWindowDays = max(0, historyWindowDays)
    }

    /// Decoded field by field, so adding one does not reset the rest.
    ///
    /// Synthesised `Decodable` makes every stored property mandatory, and the store below reads a
    /// decode failure as "use the defaults" — so a new field here would silently throw away every
    /// interval, the badge scope and the pause preferences on the update that introduced it.
    /// Learned the expensive way twice already; see `ReadingSettings` for the other one.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = RefreshSettings()

        // The three intervals get **no** fallback, unlike everything below them, and that
        // asymmetry is deliberate. They are optional, and the synthesised encoder omits the key
        // entirely for `nil` — so in an already-written blob "the key is missing" does not mean
        // "this build is older", it means *the user switched this off*. Defaulting them the way a
        // genuinely new field is defaulted would quietly switch refreshing back on for anyone who
        // had turned it off. This matches the synthesised decoder these blobs were written for.
        syncStateSeconds = try container.decodeIfPresent(Int.self, forKey: .syncStateSeconds)
        mastodonSeconds = try container.decodeIfPresent(Int.self, forKey: .mastodonSeconds)
        freshRSSSeconds = try container.decodeIfPresent(Int.self, forKey: .freshRSSSeconds)
        pauseWhenHidden = try container.decodeIfPresent(Bool.self, forKey: .pauseWhenHidden)
            ?? fallback.pauseWhenHidden
        respectLowPowerMode = try container.decodeIfPresent(Bool.self, forKey: .respectLowPowerMode)
            ?? fallback.respectLowPowerMode
        lowPowerMultiplier = try container.decodeIfPresent(Int.self, forKey: .lowPowerMultiplier)
            ?? fallback.lowPowerMultiplier
        badgeScopeRaw = try container.decodeIfPresent(String.self, forKey: .badgeScopeRaw)
            ?? fallback.badgeScopeRaw
        badgeIncludesLateArrivals = try container.decodeIfPresent(Bool.self, forKey: .badgeIncludesLateArrivals)
            ?? fallback.badgeIncludesLateArrivals
        historyWindowDays = max(0, try container.decodeIfPresent(Int.self, forKey: .historyWindowDays)
            ?? fallback.historyWindowDays)
    }

    public static let `default` = RefreshSettings()

    /// The oldest instant a refresh should reach for, or `nil` when unbounded.
    public func historyCutoff(now: Date = .now) -> Date? {
        HistoryWindow.cutoff(forDays: historyWindowDays, now: now)
    }

    /// The choices offered in Settings.
    ///
    /// Separate lists because the sensible range differs by an order of magnitude: a Mastodon
    /// timeline moves far faster than an RSS river, and forcing one set on both means either a
    /// stale timeline or needless load on the FreshRSS host.
    public static let syncStateChoices: [Int?] = [nil, 15, 30, 60]
    public static let mastodonChoices: [Int?] = [nil, 2 * 60, 5 * 60, 15 * 60, 30 * 60]
    public static let freshRSSChoices: [Int?] = [nil, 5 * 60, 15 * 60, 30 * 60, 60 * 60]

    public var badgeScope: ScopeID {
        get { ScopeID(rawValue: badgeScopeRaw) ?? .all }
        set { badgeScopeRaw = newValue.rawValue }
    }

    public func seconds(for kind: RefreshKind) -> Int? {
        switch kind {
        case .syncState: syncStateSeconds
        case .mastodonFeeds: mastodonSeconds
        case .freshRSSFeeds: freshRSSSeconds
        }
    }

    public mutating func setSeconds(_ seconds: Int?, for kind: RefreshKind) {
        switch kind {
        case .syncState: syncStateSeconds = seconds
        case .mastodonFeeds: mastodonSeconds = seconds
        case .freshRSSFeeds: freshRSSSeconds = seconds
        }
    }

    /// The interval to wait before the next run of `kind`, or `nil` when it is off.
    public func interval(for kind: RefreshKind, isLowPower: Bool) -> Duration? {
        guard let seconds = seconds(for: kind), seconds > 0 else { return nil }
        let multiplier = (respectLowPowerMode && isLowPower) ? max(1, lowPowerMultiplier) : 1
        return .seconds(seconds * multiplier)
    }

    public func isEnabled(_ kind: RefreshKind) -> Bool {
        (seconds(for: kind) ?? 0) > 0
    }

    /// The soonest a background refresh should be asked for, or `nil` when there is nothing to ask
    /// for at all.
    ///
    /// The shortest enabled interval, floored. The floor is the load-bearing part: the system
    /// decides when a `BGAppRefreshTask` actually runs and budgets an app by how often it is
    /// opened, so asking every thirty seconds — which is what the sync cadence would ask for —
    /// spends that budget on requests that are declined and teaches the scheduler to trust the app
    /// less. A quarter of an hour is about the finest granularity iOS grants a well-used app in
    /// practice.
    ///
    /// Nil when every kind is switched off, so a reader who has turned refreshing off is not
    /// woken in the background to do nothing.
    public var backgroundRefreshSeconds: Int? {
        let enabled = RefreshKind.allCases.compactMap { seconds(for: $0) }.filter { $0 > 0 }
        guard let shortest = enabled.min() else { return nil }
        return max(shortest, Self.minimumBackgroundSeconds)
    }

    /// The floor under ``backgroundRefreshSeconds``.
    public static let minimumBackgroundSeconds = 15 * 60
}

/// Reads and writes ``RefreshSettings``.
///
/// `@unchecked Sendable` because `UserDefaults` is not marked `Sendable` but is documented as
/// thread-safe, and this type only ever reads and writes one key through it.
public struct RefreshSettingsStore: @unchecked Sendable {

    private static let key = "media.kitt.readread.refreshSettings"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> RefreshSettings {
        guard let data = defaults.data(forKey: Self.key),
              let settings = try? JSONDecoder().decode(RefreshSettings.self, from: data)
        else {
            // A decode failure means the stored shape predates a change to the type. Falling back
            // to defaults is right: refresh cadence is a preference, not data, and silently
            // resetting it is far better than refusing to refresh at all.
            return .default
        }
        return settings
    }

    public func save(_ settings: RefreshSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
