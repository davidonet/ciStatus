import AppKit
import CIStatusKit
import SwiftUI

extension Health {
    var tint: Color { Color(nsColor: StatusDot.color(for: self)) }
}

struct MenuContent: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var settingsModel: SettingsModel

    var body: some View {
        if let error = monitor.configError {
            Text("Config error")
            Text(error).font(.caption).foregroundStyle(.red)
            Text(CIStatusPaths.configURL.path).font(.caption2).foregroundStyle(.secondary)
        } else if monitor.statuses.isEmpty {
            Text("No sources configured")
        } else {
            ForEach(monitor.statuses) { status in
                Row(status: status)
            }
        }

        Divider()

        if let lastChecked = monitor.lastChecked {
            Text("Checked \(lastChecked, format: .dateTime.hour().minute().second())")
        }
        Button {
            Task { await monitor.refresh() }
        } label: {
            Text(monitor.isLoading ? "Refreshing…" : "Refresh now")
        }
        .disabled(monitor.isLoading)

        Divider()

        Button("Settings…") {
            openSettingsWindow()
        }
        Button("Reload config") {
            monitor.start(configURL: CIStatusPaths.configURL)
        }
        Button("Reveal Log in Finder") {
            revealLog()
        }
        Button("Quit CIStatus") {
            NSApplication.shared.terminate(nil)
        }
    }
}

/// Shows the log file, creating it first if the app has not logged yet.
///
/// A missing file would otherwise open an empty Finder selection and look like
/// logging is broken, so an empty one is written rather than left absent.
private func revealLog() {
    let url = Log.currentURL() ?? Log.defaultURL
    let manager = FileManager.default
    if !manager.fileExists(atPath: url.path) {
        try? manager.createDirectory(at: url.deletingLastPathComponent(),
                                     withIntermediateDirectories: true)
        manager.createFile(atPath: url.path, contents: nil)
    }
    NSWorkspace.shared.activateFileViewerSelecting([url])
}

/// Opens the settings window and brings it to the front.
///
/// `openWindow` is only in scope inside a `Scene`, and a `MenuBarExtra` menu is
/// not one, so this goes through the responder chain instead. The action is the
/// one SwiftUI registers for a `Settings` scene.
private func openSettingsWindow() {
    NSApp.activate(ignoringOtherApps: true)
    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
}

struct Row: View {
    let status: SourceStatus

    var body: some View {
        Button {
            if let url = status.url { NSWorkspace.shared.open(url) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: status.health.symbolName)
                    .foregroundStyle(status.health.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(status.name).fontWeight(.medium)
                    Text(status.summary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if !status.failingItems.isEmpty {
                    Text("\(status.failingItems.count)")
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(status.health.tint.opacity(0.25), in: Capsule())
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(status.url == nil)
    }
}


