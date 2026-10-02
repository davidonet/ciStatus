// Terminal front end for the providers.
//
// Exercises each provider against real APIs so the response shapes can be
// verified, stores tokens, prints a diagnosis of the current config, and renders
// the README's colour legend. The app and this tool share CIStatusKit, so a
// difference in behaviour here is a difference in the code and not in the tooling.
import AppKit
import CIStatusKit
import Foundation

@main
struct Probe {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())

        switch arguments.first {
        case "--store-token":
            await storeToken(arguments)
        case "--tokens":
            listTokens()
        case "--render-dots":
            // Regenerates the README's colour legend. It uses StatusDot itself
            // rather than a reimplementation, so the picture in the README cannot
            // drift away from what the menu bar actually draws.
            renderDots(to: arguments.dropFirst().first.map { configURL($0) }
                ?? configDirectory.appendingPathComponent("dots.png"))
        case "--enable":
            _ = enable(arguments.dropFirst().first, in: configURL())
        case "--disable":
            setEnabled(false, for: arguments.dropFirst().first, in: configURL())
        case "--diagnose", nil:
            await diagnose(arguments.dropFirst().first.map { configURL($0) } ?? configURL())
        case "--overall":
            await diagnose(configURL(), overallOnly: true)
        default:
            // A bare path, as `make probe` passes it.
            await diagnose(configURL(arguments[0]))
        }
    }

    // MARK: - Locations

    static var configDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CIStatus", isDirectory: true)
    }

    static func configURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["CISTATUS_CONFIG"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return configDirectory.appendingPathComponent("config.json")
    }

    static func configURL(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    // MARK: - Commands

    /// Stores a token *and* switches the service on.
    ///
    /// Storing only was the bug this fixed: a token sat in the store while the
    /// config still had no `tokens` section, so every row reported the service as
    /// not enabled and nothing looked configured.
    static func storeToken(_ arguments: [String]) async {
        guard arguments.count >= 3 else {
            print("usage: probe --store-token <github|vercel|sentry> <token> [config]")
            return
        }
        let kind = Source.Kind(rawValue: arguments[1]) ?? .github
        let url = arguments.count > 3 ? configURL(arguments[3]) : configURL()

        do {
            try TokenStore.save(arguments[2], for: kind)
            print("stored the \(kind.displayName) token in \(TokenStore.fileURL.path)")
        } catch {
            print("could not store the \(kind.displayName) token: "
                  + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
            return
        }
        _ = enable(kind.rawValue, in: url)    }

    /// Writes a PNG showing the dot in each state, for the README.
    static func renderDots(to url: URL) {
        let states: [(Health, String, String)] = [
            (.ok, "green", "everything passed"),
            (.pending, "orange", "something is running"),
            (.failing, "red", "something failed"),
            (.unknown, "grey", "unreachable or misconfigured"),
        ]
        let size: CGFloat = 34
        let pad: CGFloat = 16
        let rowHeight = size + pad * 2
        let labelWidth: CGFloat = 78
        let width = labelWidth + size + pad + 320
        let height = rowHeight * CGFloat(states.count)

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor(calibratedWhite: 0.13, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        for (index, entry) in states.enumerated() {
            let (health, name, meaning) = entry
            let y = rowHeight * CGFloat(index)

            let dot = StatusDot.image(for: health, size: size)
            // The menu bar draws the dot onto its own background, so this matches
            // what the legend is showing rather than a white page.
            dot.draw(in: NSRect(x: labelWidth, y: y + pad, width: size, height: size),
                     from: .zero, operation: .sourceOver, fraction: 1)

            let baseline = y + rowHeight / 2 - 8
            name.draw(at: NSPoint(x: 14, y: baseline), withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 15, weight: .semibold),
                .foregroundColor: NSColor(calibratedWhite: 0.93, alpha: 1),
            ])
            meaning.draw(at: NSPoint(x: labelWidth + size + pad + 12, y: baseline),
                         withAttributes: [
                .font: NSFont.systemFont(ofSize: 14),
                .foregroundColor: NSColor(calibratedWhite: 0.62, alpha: 1),
            ])
        }
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("could not encode the image")
            return
        }
        do {
            try png.write(to: url)
            print("wrote \(url.path)")
        } catch {
            print("could not write \(url.path): \(error.localizedDescription)")
        }
    }

    /// Prints which services hold a token, and whether the config uses them.
    /// Existence only; the values are never read out.
    static func listTokens() {
        let url = configURL()
        let config = try? Config.load(from: url)
        print("config: \(url.path)\(config == nil ? " (could not be read)" : "")")
        print("tokens: \(TokenStore.fileURL.path)")
        for kind in Source.Kind.allCases {
            let stored = TokenStore.hasToken(for: kind)
            let enabled = config?.tokens.isEnabled(kind) ?? false
            let targets = config?.services.targets(for: kind).count ?? 0
            var flags: [String] = []
            flags.append(stored ? "token stored" : "no token")
            flags.append(enabled ? "enabled" : "not enabled")
            flags.append("\(targets) target(s)")
            print("  \(kind.displayName): \(flags.joined(separator: ", "))")
        }
        if let config {
            advise(config)
        }
    }

    static func enable(_ name: String?, in url: URL) -> Bool {
        guard let name, let kind = Source.Kind(rawValue: name) else {
            print("usage: probe --enable <github|vercel|sentry> [config]")
            return false
        }
        do {
            try Config.update(at: url) { $0.tokens[kind] = true }
            print("\(kind.displayName) enabled in \(url.path)")
            return true
        } catch {
            print("could not update \(url.path): \(error.localizedDescription)")
            return false
        }
    }

    static func setEnabled(_ enabled: Bool, for name: String?, in url: URL) {
        guard let name, let kind = Source.Kind(rawValue: name) else {
            print("usage: probe --disable <github|vercel|sentry> [config]")
            return
        }
        do {
            try Config.update(at: url) { config in
                config.tokens[kind] = enabled ? true : nil
            }
            print("\(kind.displayName) \(enabled ? "enabled" : "disabled") in \(url.path)")
        } catch {
            print("could not update \(url.path): \(error.localizedDescription)")
        }
    }

    /// Polls every row and prints what the app would show.
    static func diagnose(_ url: URL, overallOnly: Bool = false) async {
        let config: Config
        do {
            config = try Config.load(from: url)
        } catch {
            print("config error: \(error.localizedDescription)")
            exit(1)
        }

        Log.configure()
        for (_, token) in TokenStore.all() { Log.registerSecret(token) }
        advise(config)

        let http = HTTP()
        var results: [SourceStatus] = []
        for source in config.expandedSources {
            let status: SourceStatus
            switch source.kind {
            case .github: status = await GitHubProvider(http: http, source: source).poll()
            case .vercel: status = await VercelProvider(http: http, source: source).poll()
            case .sentry: status = await SentryProvider(http: http, source: source).poll()
            }
            results.append(status)
            if !overallOnly {
                print("\(status.health) | \(status.name) | \(status.summary) | \(status.detail ?? "-")")
                for item in status.failingItems { print("    - \(item)") }
            }
        }
        if overallOnly { print(results.overall) }
    }

    /// The misconfigurations that look like "nothing works" from the menu bar,
    /// called out before the poll output rather than buried in it.
    static func advise(_ config: Config) {
        for kind in Source.Kind.allCases {
            let targets = config.services.targets(for: kind).count
            let enabled = config.tokens.isEnabled(kind)
            let stored = TokenStore.hasToken(for: kind)
            if targets > 0 && !enabled {
                print("!! \(kind.displayName) has \(targets) target(s) but is not enabled. "
                      + "Fix with: probe --enable \(kind.rawValue)")
            }
            if enabled && targets > 0 && !stored {
                print("!! \(kind.displayName) is enabled but has no token stored. "
                      + "Fix with: probe --store-token \(kind.rawValue) <token>")
            }
        }
        if config.expandedSources.isEmpty {
            print("!! no targets configured; add one with the settings window or by hand")
        }
    }
}
