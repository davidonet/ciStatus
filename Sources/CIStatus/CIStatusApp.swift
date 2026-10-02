import AppKit
import CIStatusKit
import SwiftUI

@main
struct CIStatusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(monitor: delegate.monitor, settingsModel: delegate.settings)
        } label: {
            StatusIcon(monitor: delegate.monitor)
        }
        .menuBarExtraStyle(.menu)

        // A `Settings` scene, not `Window`. Picking branches and reading a token
        // need real controls that a menu cannot host, and this is the scene that
        // registers the `showSettingsWindow:` action the menu item sends — plus
        // the standard Cmd-, shortcut for free.
        Settings {
            SettingsView(model: delegate.settings)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let monitor = Monitor()
    /// Shared with the settings window, and created eagerly so the window and
    /// the poll loop always agree on one draft.
    lazy var settings = SettingsModel(monitor: monitor)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before anything else: the config load below is the first thing worth
        // having a record of.
        Log.configure()
        Log.info("ciStatus \(Self.version) starting")
        // Registered so a token echoed back inside an API error body is masked
        // before it reaches the log.
        for (_, token) in TokenStore.all() { Log.registerSecret(token) }

        monitor.start(configURL: CIStatusPaths.configURL)
        // Without this the menu bar app has no way to become interactive, so
        // the settings window and its buttons would never receive clicks.
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.info("ciStatus terminating")
    }

    static var version: String {
        let bundle = Bundle.main
        let short = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return short ?? "dev"
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
