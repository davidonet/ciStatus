// Temporary manual probe: exercises each provider against real APIs so the
// response shapes can be verified. Not part of the app.
import Foundation
import CIStatusKit

@main
struct Probe {
    static func main() async {
        var arguments = CommandLine.arguments
        // --overall prints just the rolled-up health, for scripting.
        let overallOnly = arguments.contains("--overall")
        arguments.removeAll { $0 == "--overall" }
        let path = arguments.count > 1
            ? arguments[1]
            : FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/cistatus/probe.json").path
        let config: Config
        do {
            config = try Config.load(from: URL(fileURLWithPath: path))
        } catch {
            print("config error: \(error.localizedDescription)")
            return
        }

        let http = HTTP()
        var results: [SourceStatus] = []
        for source in config.sources {
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
}
