import Foundation

public enum HTTPError: LocalizedError {
    case badURL(String)
    case status(Int, String)
    case decoding(String, String)

    public var errorDescription: String? {
        switch self {
        case let .badURL(s):            return "Malformed URL: \(s)"
        case let .status(code, body):  return "HTTP \(code) \(body.prefix(160))"
        case let .decoding(what, why):  return "Could not read \(what): \(why)"
        }
    }
}

/// A thin JSON client over `URLSession`.
///
/// A class rather than a struct so tests can subclass it and answer from a
/// fixture instead of the network, which is what makes the polling and fallback
/// logic testable at all.
open class HTTP: @unchecked Sendable {
    public var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    public init() {}

    /// The single entry point the providers use. Subclasses override this to
    /// answer from a fixture instead of the network.
    open func get<T: Decodable>(_ type: T.Type, url: URL, token: String?,
                                 accept: String = "application/json") async throws -> T {
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("ciStatus/1.0", forHTTPHeaderField: "User-Agent")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HTTPError.badURL(url.absoluteString)
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw HTTPError.status(http.statusCode, body)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw HTTPError.decoding(String(describing: type), error.localizedDescription)
        }
    }
}

public extension URL {
    /// Builds a query string, skipping parameters that are not configured.
    static func build(_ base: String, _ items: [(String, String?)]) -> URL? {
        guard var components = URLComponents(string: base) else { return nil }
        components.queryItems = items.compactMap { key, value in
            guard let value, !value.isEmpty else { return nil }
            return URLQueryItem(name: key, value: value)
        }
        return components.url
    }
}
