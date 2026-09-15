import Foundation

/// How far back a refresh reaches when fetching items.
///
/// A bound on both fetching and keeping. Items published before the window are not fetched, and
/// ``RetentionPolicy/historyWindowDays`` prunes the ones already stored, so the cache is a rolling
/// window rather than an archive that only grows — otherwise a week's window against a year of
/// history leaves fifty-one weeks of items that no refresh will ever revisit.
///
/// Retention's own ``RetentionPolicy/maximumAge`` is still a separate rule with a separate job;
/// see `RetentionService`. Read Later keeps its own snapshots regardless of either.
///
/// Seven days by default. The reason is what a fresh account does without it: the walk pages
/// downwards through the entire history of every subscription, which for a real FreshRSS account
/// meant thousands of articles nobody asked for on the first refresh. A week is more than most
/// people read behind, and the value is a setting for the people it is not.
public enum HistoryWindow {

    /// Stored as a plain day count rather than an enum case, so a value this build does not
    /// recognise still round-trips through settings instead of resetting to the default.
    /// Zero means no bound.
    public static let unlimited = 0

    public static let `default` = 7

    /// The choices offered in Settings.
    public static let choices: [Int] = [1, 3, 7, 14, 30, 90, unlimited]

    /// The name shown for a day count.
    public static func title(forDays days: Int) -> String {
        switch days {
        case ..<1: String(localized: "Everything")
        case 1: String(localized: "1 day")
        case 7: String(localized: "1 week")
        case 14: String(localized: "2 weeks")
        case 30: String(localized: "1 month")
        case 90: String(localized: "3 months")
        default: String(localized: "\(days) days")
        }
    }

    /// The oldest instant a refresh should fetch, or `nil` when unbounded.
    public static func cutoff(forDays days: Int, now: Date = .now) -> Date? {
        guard days > 0 else { return nil }
        return now.addingTimeInterval(-Double(days) * 24 * 60 * 60)
    }
}
