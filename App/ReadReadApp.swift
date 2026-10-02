import ReadReadModel
import ReadReadSync
import ReadReadUI
import SwiftData
import SwiftUI

@main
struct ReadReadApp: App {

    /// Built once here rather than with the `.modelContainer(for:)` convenience, because the
    /// schema is assembled in `ReadReadStore` and a failure to open it needs to surface rather
    /// than silently fall back to an empty in-memory store.
    private let container: ModelContainer

    /// Owned by the app rather than by `RootView`, because the macOS `Settings` scene is a separate
    /// window with its own view tree. Two instances would each write the same `UserDefaults` keys
    /// while showing each other's changes only after a relaunch.
    @State private var settings: SettingsModel

    /// Starts nothing on its own. `RootView` calls `start()` once it is on screen, so a window that
    /// never opens never spins up timers or a network monitor.
    @State private var services: AppServices

    #if os(macOS)
    /// Holds up quitting until the last reading position has been sent.
    @NSApplicationDelegateAdaptor(QuitDelegate.self) private var appDelegate
    #else
    /// Registers the background refresh task before launch finishes. See `BackgroundTaskDelegate`.
    @UIApplicationDelegateAdaptor(BackgroundTaskDelegate.self) private var appDelegate
    #endif

    init() {
        do {
            container = try ReadReadStore.container()
        } catch {
            // Nothing the app can do without its store, and continuing with an empty one would
            // look like total data loss to the user. Fail loudly instead.
            fatalError("Failed to open the ReadRead store: \(error)")
        }

        #if DEBUG
        Self.seedFixturesIfRequested(in: container)
        #endif

        #if os(macOS)
        // Before the window exists, because AppKit restores the divider positions as the split
        // view is built and a restored frame makes SwiftUI ignore the width the app asks for.
        // `ColumnWidths` remembers both columns instead; its documentation has the measurements.
        ColumnWidths.discardSystemAutosave()
        #endif

        let settings = SettingsModel()
        let services = AppServices(container: container, settings: settings)
        _settings = State(initialValue: settings)
        _services = State(initialValue: services)

        #if os(iOS)
        // Here rather than in `AppServices.start()`, which only runs once a window is on screen: a
        // background launch may never build one, and its task handler runs as soon as the
        // delegate registers it.
        BackgroundRefresh.setOperation { [services] in
            await services.performBackgroundRefresh()
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(services)
        }
        .modelContainer(container)
        #if os(macOS)
        // Three columns need room; the default content size is far too narrow for a sidebar,
        // a timeline with excerpts, and a readable measure of article text side by side.
        .defaultSize(width: 1_280, height: 820)
        #endif

        #if os(macOS)
        // The standard preferences window, under the app menu where people look for it. On iOS
        // the same view is presented as a sheet from the sidebar instead.
        Settings {
            SettingsView()
                .environment(settings)
                .environment(services)
                .modelContainer(container)
        }
        #endif
    }

    #if DEBUG
    /// Fills an empty store with fixtures, when asked for with `-ReadReadFixtures`.
    ///
    /// Opt-in rather than automatic. It used to seed any empty debug store, which was right while
    /// there was no way to add a real account — but now that there is, fixture accounts would sit
    /// in the accounts list alongside real ones, with no credentials, reporting a refresh failure
    /// on every tick. Passing the flag in a scheme's arguments brings them back for UI work.
    private static func seedFixturesIfRequested(in container: ModelContainer) {
        guard ProcessInfo.processInfo.arguments.contains("-ReadReadFixtures") else { return }

        let context = ModelContext(container)
        do {
            guard try context.fetchCount(FetchDescriptor<AccountRecord>()) == 0 else { return }
            // `-ReadReadFixtureItems 200` seeds a timeline big enough to see scrolling behave the
            // way it does on a real account, which twelve items per feed never will.
            let perFeed = UserDefaults.standard.object(forKey: "ReadReadFixtureItems") as? Int
            try FixtureData.seed(into: context, itemsPerFeed: perFeed ?? 12)
        } catch {
            // Fixtures are a convenience, so a failure here must not stop the app launching.
            print("Fixture seeding skipped: \(error)")
        }
    }
    #endif
}

#if os(iOS)
/// Registers the background refresh task.
///
/// A delegate rather than SwiftUI's `.backgroundTask(.appRefresh(_:))` scene modifier, which
/// registered the same identifier out of sight: every submit on a new phone failed with
/// `notPermitted` while the build's `Info.plist` declared both the identifier and the `fetch`
/// mode, and nothing could say whether the registration had happened. `BGTaskScheduler`
/// requires it before launch finishes, which is exactly this callback, and it reports whether it
/// worked. The two cannot coexist — registering an identifier twice raises.
final class BackgroundTaskDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BackgroundRefresh.register()
        return true
    }
}
#endif
