import SwiftUI

/// Checking for and installing new versions of the app, which only the Mac build does.
///
/// A protocol the app target implements rather than a type here, because the implementation is
/// Sparkle and Sparkle belongs to the app target alone. As a dependency of this package it would be
/// resolved — a binary download — by every `swift test`, and it has no iOS build to link against.
@MainActor
public protocol AppUpdater: AnyObject, Observable, Sendable {

    /// False while a check or an update is already under way.
    var canCheckForUpdates: Bool { get }

    var automaticallyChecksForUpdates: Bool { get set }

    var automaticallyDownloadsUpdates: Bool { get set }

    func checkForUpdates()
}

extension EnvironmentValues {
    /// Nil on iOS, and in any build that does not update itself, which is how the settings window
    /// knows to leave its Updates tab out.
    @Entry public var appUpdater: (any AppUpdater)? = nil
}
