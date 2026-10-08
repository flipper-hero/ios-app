import Foundation

public struct CatalogApp: Sendable, Equatable {
    public var id: String
    public var alias: String
    public var name: String
    public var version: String
    public var versionID: String
    public var summary: String
    public var categoryID: String
}

public enum CatalogError: Error, CustomStringConvertible {
    case http(Int)
    case malformed
    case notFound(String)
    case tooLarge(Int)

    public var description: String {
        switch self {
        case .http(let code): L("App catalog returned HTTP \(code)")
        case .malformed: L("Unexpected response from the app catalog")
        case .notFound(let q): L("No app found for '\(q)'")
        case .tooLarge(let n): L("Download is \(n) bytes, which is above the limit")
        }
    }
}

/// Read-only client for the official Flipper app catalog (FapHub).
/// Builds are requested for the exact SDK version the connected device reports, so an
/// installed app cannot be incompatible with the running firmware.
public struct FapHubClient: Sendable {
    public static let maxDownloadBytes = 4 * 1024 * 1024
    public var base: URL
    public var session: URLSession

    public init(base: URL = URL(string: "https://catalog.flipperzero.one/api/v0")!,
                session: URLSession = .shared) {
        self.base = base
        self.session = session
    }

    private func get(_ path: String, query: [URLQueryItem]) async throws -> Data {
        var components = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = query
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 45
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw CatalogError.http(status) }
        return data
    }

    public func search(_ query: String, api: String, target: String = "f7", limit: Int = 8) async throws -> [CatalogApp] {
        let data = try await get("application", query: [
            .init(name: "query", value: query),
            .init(name: "limit", value: String(limit)),
            .init(name: "api", value: api),
            .init(name: "target", value: target),
        ])
        return try Self.parseApps(data)
    }

    static func parseApps(_ data: Data) throws -> [CatalogApp] {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw CatalogError.malformed
        }
        return raw.compactMap { item in
            guard let id = item["_id"] as? String,
                  let version = item["current_version"] as? [String: Any],
                  let versionID = version["_id"] as? String else { return nil }
            return CatalogApp(
                id: id,
                alias: item["alias"] as? String ?? "",
                name: version["name"] as? String ?? item["alias"] as? String ?? "app",
                version: version["version"] as? String ?? "?",
                versionID: versionID,
                summary: version["short_description"] as? String ?? "",
                categoryID: item["category_id"] as? String ?? ""
            )
        }
    }

    /// Category id to display name, used to pick the folder under /ext/apps.
    public func categories(api: String, target: String = "f7") async throws -> [String: String] {
        let data = try await get("category", query: [
            .init(name: "api", value: api), .init(name: "target", value: target),
        ])
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw CatalogError.malformed
        }
        return Dictionary(uniqueKeysWithValues: raw.compactMap { item in
            guard let id = item["_id"] as? String, let name = item["name"] as? String else { return nil }
            return (id, name)
        })
    }

    public func downloadBuild(versionID: String, api: String, target: String = "f7") async throws -> Data {
        let data = try await get("application/version/\(versionID)/build/compatible", query: [
            .init(name: "target", value: target), .init(name: "api", value: api),
        ])
        guard data.count <= Self.maxDownloadBytes else { throw CatalogError.tooLarge(data.count) }
        guard data.starts(with: [0x7F, 0x45, 0x4C, 0x46]) else {
            throw CatalogError.malformed // .fap files are ELF
        }
        return data
    }
}

/// Searches GitHub for Flipper-compatible files and fetches raw file contents.
public struct GitHubClient: Sendable {
    public static let maxDownloadBytes = 1 * 1024 * 1024
    public var session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public struct Hit: Sendable, Equatable {
        public var repository: String
        public var path: String
        public var rawURL: String
    }

    public func searchCode(_ query: String, fileExtension: String?, limit: Int = 8) async throws -> [Hit] {
        var q = query
        if let fileExtension { q += " extension:\(fileExtension)" }
        var components = URLComponents(string: "https://api.github.com/search/code")!
        components.queryItems = [.init(name: "q", value: q), .init(name: "per_page", value: String(limit))]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 45
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw CatalogError.http(status) }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["items"] as? [[String: Any]] else { throw CatalogError.malformed }
        return items.compactMap { item in
            guard let path = item["path"] as? String,
                  let repo = (item["repository"] as? [String: Any])?["full_name"] as? String,
                  let html = item["html_url"] as? String else { return nil }
            return Hit(repository: repo, path: path,
                       rawURL: html.replacingOccurrences(of: "https://github.com/", with: "https://raw.githubusercontent.com/")
                                   .replacingOccurrences(of: "/blob/", with: "/"))
        }
    }

    public func fetchRaw(_ urlString: String) async throws -> Data {
        guard let url = URL(string: urlString), url.scheme == "https",
              let host = url.host(), host == "raw.githubusercontent.com" || host == "github.com" else {
            throw CatalogError.malformed
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 45
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw CatalogError.http(status) }
        guard data.count <= Self.maxDownloadBytes else { throw CatalogError.tooLarge(data.count) }
        return data
    }
}
