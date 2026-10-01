import Foundation

/// Severity of one source, ordered by how loudly it should be reported.
///
/// The raw values are the reporting priority, so `overall` is a plain max().
/// `.unknown` sits below `.failing` on purpose: not being able to reach an API
/// must never hide a failure we did detect.
public enum Health: Int, Comparable, Sendable {
    case ok       // everything went well
    case unknown  // we could not reach the API, or the source is misconfigured
    case pending  // a process is ongoing
    case failing  // a process reported an error

    public static func < (lhs: Health, rhs: Health) -> Bool { lhs.rawValue < rhs.rawValue }

    public var symbolName: String {
        switch self {
        case .ok:      return "checkmark.circle.fill"
        case .pending: return "clock.badge.exclamationmark.fill"
        case .failing: return "xmark.octagon.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }
}

/// The result of polling one configured source.
public struct SourceStatus: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let health: Health
    public let summary: String
    public let detail: String?
    public let url: URL?
    /// Names of the individual things needing attention, shown in the menu.
    public let failingItems: [String]

    public init(id: String, name: String, health: Health, summary: String,
                detail: String?, url: URL?, failingItems: [String]) {
        self.id = id
        self.name = name
        self.health = health
        self.summary = summary
        self.detail = detail
        self.url = url
        self.failingItems = failingItems
    }
}

public extension Array where Element == SourceStatus {
    /// The icon shows the worst thing that is happening, not the average.
    var overall: Health {
        var worst: Health = .ok
        for status in self {
            if status.health > worst { worst = status.health }
        }
        return self.isEmpty ? .unknown : worst
    }
}
