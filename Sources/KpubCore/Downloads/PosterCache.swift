import AppKit
import CryptoKit
import Foundation

/// Persistent artwork: Application Support survives HTTP cache eviction and app restarts.
public actor PosterCache {
    public static let shared = PosterCache()
    private let directory: URL
    private var pending: [URL: Task<Data?, Never>] = [:]

    public init(directory: URL = AppPaths.supportDirectory.appendingPathComponent("Posters", isDirectory: true)) {
        self.directory = directory
    }

    private func path(for url: URL) -> URL {
        let key = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key)
    }

    public func cachedData(for url: URL) -> Data? {
        guard let data = try? Data(contentsOf: path(for: url)), NSImage(data: data) != nil else { return nil }
        return data
    }

    @discardableResult
    public func store(_ data: Data, for url: URL) throws -> Bool {
        guard NSImage(data: data) != nil else { return false }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: path(for: url), options: .atomic)
        return true
    }

    public func data(for url: URL) async -> Data? {
        if let data = cachedData(for: url) { return data }
        if let task = pending[url] { return await task.value }
        let task = Task<Data?, Never> {
            do {
                let request = URLRequest(url: url, timeoutInterval: 20)
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let response = response as? HTTPURLResponse,
                      (200..<300).contains(response.statusCode),
                      try self.store(data, for: url) else { return nil }
                return data
            } catch { return nil }
        }
        pending[url] = task
        let result = await task.value
        pending[url] = nil
        return result
    }

    public func prefetch(_ urls: [URL]) async {
        for url in Set(urls) { _ = await data(for: url) }
    }
}
