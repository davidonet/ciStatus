import AppKit
import CIStatusKit
import SwiftUI

/// The menu bar extra's content view is only built when the user clicks it, so
/// the poll loop has to be started from the app launch hook instead.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let monitor = Monitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        monitor.start(configURL: CIStatusPaths.configURL)
    }
}

@main
struct CIStatusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(monitor: delegate.monitor)
        } label: {
            StatusIcon(monitor: delegate.monitor)
        }
        .menuBarExtraStyle(.menu)
    }
}

enum CIStatusPaths {
    /// `~/Library/Application Support/CIStatus/config.json`, overridable with
    /// `CISTATUS_CONFIG=/path/to/config.json` when testing.
    static var configURL: URL {
        if let override = ProcessInfo.processInfo.environment["CISTATUS_CONFIG"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CIStatus", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("config.json")
    }
}
