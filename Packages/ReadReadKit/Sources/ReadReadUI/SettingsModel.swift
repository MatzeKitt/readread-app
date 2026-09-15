import Foundation
import Observation
import ReadReadModel
import ReadReadSync

/// The app's preferences, observable so a change takes effect everywhere at once.
///
/// The two stores underneath are plain `UserDefaults` blobs, which views cannot observe. This wraps
/// them so that toggling "archive saved articles" in Settings changes what the timeline's Read
/// Later action does immediately, rather than at the next launch — and so the refresh coordinator
/// can be handed new intervals the moment they are edited.
///
/// Writes through on every mutation. Settings are a handful of bytes edited by hand, so there is
/// nothing to debounce, and a preference that is lost because the app was quit before some timer
/// fired is a bug with no upside.
@MainActor
@Observable
public final class SettingsModel {

    public var reading: ReadingSettings {
        didSet {
            guard reading != oldValue else { return }
            readingStore.save(reading)
        }
    }

    public var shortcuts: ShortcutSettings {
        didSet {
            guard shortcuts != oldValue else { return }
            shortcutStore.save(shortcuts)
        }
    }

    public var refresh: RefreshSettings {
        didSet {
            guard refresh != oldValue else { return }
            refreshStore.save(refresh)
            onRefreshSettingsChanged?(refresh)
        }
    }

    /// Called when the refresh cadence changes, so the coordinator can restart its timers.
    ///
    /// A closure rather than a reference to the coordinator: this type is created before the
    /// coordinator exists and is used in previews where there is none.
    @ObservationIgnored public var onRefreshSettingsChanged: (@Sendable (RefreshSettings) -> Void)?

    @ObservationIgnored private let readingStore: ReadingSettingsStore
    @ObservationIgnored private let refreshStore: RefreshSettingsStore
    @ObservationIgnored private let shortcutStore: ShortcutSettingsStore

    public init(
        readingStore: ReadingSettingsStore = ReadingSettingsStore(),
        refreshStore: RefreshSettingsStore = RefreshSettingsStore(),
        shortcutStore: ShortcutSettingsStore = ShortcutSettingsStore()
    ) {
        self.readingStore = readingStore
        self.refreshStore = refreshStore
        self.shortcutStore = shortcutStore
        reading = readingStore.load()
        refresh = refreshStore.load()
        shortcuts = shortcutStore.load()
    }
}
