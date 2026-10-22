#if os(macOS)
import Foundation
import Observation
import ReadReadUI
import Sparkle

/// Sparkle's updater, observable so the menu item and the settings follow its state.
///
/// The feed, the public key and the sandbox's installer service are set in `project.yml`
/// (`SUFeedURL`, `SUPublicEDKey`, `SUEnableInstallerLauncherService`).
@MainActor
@Observable
final class Updater: AppUpdater {

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observation: NSKeyValueObservation?

    private(set) var canCheckForUpdates = false

    var automaticallyChecksForUpdates: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }

    var automaticallyDownloadsUpdates: Bool {
        didSet { controller.updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates }
    }

    init() {
        // Not started in a debug build. It would offer the latest release to the build in
        // DerivedData, and installing it would replace that build with the downloaded one.
        #if DEBUG
        let starts = false
        #else
        let starts = true
        #endif
        controller = SPUStandardUpdaterController(
            startingUpdater: starts,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = controller.updater.automaticallyDownloadsUpdates
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.canCheckForUpdates = self.controller.updater.canCheckForUpdates
            }
        }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
#endif
