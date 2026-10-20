import Foundation

/// Качает HLS-дорожки сегментами (параллельно, с докачкой) и пишет локальные плейлисты для ffmpeg.
public enum HLSDownloader {
    public struct Track: Sendable {
        /// Имя для файлов: "video", "audio_0"…
        public var name: String
        public var playlistURL: URL
        /// Примерный битрейт (бит/с) — для оценки прогресса.
        public var bandwidth: Int

        public init(name: String, playlistURL: URL, bandwidth: Int) {
            self.name = name
            self.playlistURL = playlistURL
            self.bandwidth = bandwidth
        }
    }

    private struct WorkItem: Sendable {
        var resource: HLSMediaPlaylist.Resource
        var destination: URL
        var weight: Double
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes: Int64 = 0
        private var doneWeight: Double = 0
        private var windowStart = Date()
        private var windowBytes: Int64 = 0
        private var speed: Double = 0

        func add(bytes: Int64, weight: Double) -> (Int64, Double, Double) {
            lock.lock()
            defer { lock.unlock() }
            self.bytes += bytes
            doneWeight += weight
            windowBytes += bytes
            let elapsed = Date().timeIntervalSince(windowStart)
            if elapsed >= 2 {
                let current = Double(windowBytes) / elapsed
                speed = speed == 0 ? current : speed * 0.6 + current * 0.4
                windowStart = Date()
                windowBytes = 0
            }
            return (self.bytes, doneWeight, speed)
        }
    }

    static let session: URLSession = {
        // Общее хранилище cookie: манифесты идут через зеркало, где может понадобиться сессия сайта.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.httpMaximumConnectionsPerHost = 8
        config.httpAdditionalHeaders = ["User-Agent": KpubAPI.userAgent]
        return URLSession(configuration: config)
    }()

    public static func fetchText(_ url: URL) async throws -> String {
        let (data, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw DownloadError.badStatus(status) }
        return String(decoding: data, as: UTF8.self)
    }

    /// Возвращает пути к локальным плейлистам по именам дорожек.
    public static func download(
        tracks: [Track],
        into dir: URL,
        concurrency: Int = 6,
        onProgress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> [String: URL] {
        let fm = FileManager.default
        var work: [WorkItem] = []
        var playlists: [(Track, HLSMediaPlaylist, [String: String])] = []
        var totalWeight: Double = 0
        var doneWeight: Double = 0
        var doneBytes: Int64 = 0

        for track in tracks {
            let text = try await fetchText(track.playlistURL)
            let playlist = HLSMediaPlaylist.parse(text, baseURL: track.playlistURL)
            guard playlist.isMediaPlaylist else {
                throw DownloadError.badStatus(415)
            }
            let trackDir = dir.appendingPathComponent(track.name, isDirectory: true)
            // Если сегментация поменялась (другой файл на сервере) — старые куски не годятся.
            let marker = trackDir.appendingPathComponent(".count")
            let expected = "\(playlist.segments.count)"
            if (try? String(contentsOf: marker, encoding: .utf8)) != expected {
                try? fm.removeItem(at: trackDir)
            }
            try fm.createDirectory(at: trackDir, withIntermediateDirectories: true)
            try expected.write(to: marker, atomically: true, encoding: .utf8)

            let bytesPerSecond = Double(max(track.bandwidth, 64_000)) / 8
            var tagNames: [String: String] = [:]
            for (k, res) in playlist.tagResources.enumerated() where tagNames[key(res)] == nil {
                let name = "res_\(k).\(fileExtension(res.url, fallback: "bin"))"
                tagNames[key(res)] = name
                work.append(WorkItem(resource: res, destination: trackDir.appendingPathComponent(name), weight: 1))
            }
            for (i, seg) in playlist.segments.enumerated() {
                let dest = trackDir.appendingPathComponent(segmentName(i, seg.resource.url))
                work.append(WorkItem(resource: seg.resource, destination: dest, weight: max(seg.duration, 0.1) * bytesPerSecond))
            }
            playlists.append((track, playlist, tagNames))
        }

        totalWeight = work.reduce(0) { $0 + $1.weight }
        var pending: [WorkItem] = []
        for item in work {
            if let size = try? fm.attributesOfItem(atPath: item.destination.path)[.size] as? Int64, size > 0 {
                doneWeight += item.weight
                doneBytes += size
            } else {
                pending.append(item)
            }
        }

        let counter = Counter()
        _ = counter.add(bytes: doneBytes, weight: doneWeight)
        let total = totalWeight
        func report(_ state: (Int64, Double, Double)) {
            let (bytes, weight, speed) = state
            // Оценка полного размера по уже скачанному.
            let estimate = weight > 0 ? Int64(Double(bytes) / weight * total) : nil
            onProgress(DownloadProgress(received: bytes, total: estimate, bytesPerSecond: speed, fractionOverride: total > 0 ? weight / total : nil))
        }
        report((doneBytes, doneWeight, 0))

        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = pending.makeIterator()
            func addNext() -> Bool {
                guard let item = iterator.next() else { return false }
                group.addTask {
                    let size = try await fetch(item.resource, to: item.destination)
                    report(counter.add(bytes: size, weight: item.weight))
                }
                return true
            }
            for _ in 0..<concurrency where !addNext() { break }
            while try await group.next() != nil {
                _ = addNext()
            }
        }

        // Локальные плейлисты.
        var result: [String: URL] = [:]
        for (track, playlist, tagNames) in playlists {
            var lines = ["#EXTM3U"]
            lines += playlist.headerTags.filter { !$0.hasPrefix("#EXT-X-KEY") && !$0.hasPrefix("#EXT-X-MAP") }
            if !lines.contains(where: { $0.hasPrefix("#EXT-X-PLAYLIST-TYPE") }) { lines.append("#EXT-X-PLAYLIST-TYPE:VOD") }
            for (i, seg) in playlist.segments.enumerated() {
                for tag in seg.prefixTags {
                    if let res = HLSMediaPlaylist.tagResource(tag, baseURL: track.playlistURL), let local = tagNames[key(res)] {
                        lines.append(HLSMediaPlaylist.localizeTag(tag, localName: "\(track.name)/\(local)"))
                    } else {
                        lines.append(tag)
                    }
                }
                lines.append(String(format: "#EXTINF:%.6f,", seg.duration))
                lines.append("\(track.name)/\(segmentName(i, seg.resource.url))")
            }
            lines.append("#EXT-X-ENDLIST")
            let url = dir.appendingPathComponent("\(track.name).m3u8")
            try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
            result[track.name] = url
        }
        return result
    }

    /// Качает один ресурс с повторами; протухшие ссылки (403/404/410) пробрасываются сразу.
    private static func fetch(_ resource: HLSMediaPlaylist.Resource, to destination: URL) async throws -> Int64 {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                var request = URLRequest(url: resource.url)
                if let r = resource.range {
                    request.setValue("bytes=\(r.offset)-\(r.offset + r.length - 1)", forHTTPHeaderField: "Range")
                }
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(status) else { throw DownloadError.badStatus(status) }
                var body = data
                if let r = resource.range, status == 200, data.count > r.length {
                    // Сервер проигнорировал Range — вырезаем сами.
                    let start = Int(r.offset)
                    body = data.subdata(in: start..<min(start + Int(r.length), data.count))
                }
                guard !body.isEmpty else { throw DownloadError.incomplete(received: 0, expected: resource.range?.length ?? 1) }
                let part = destination.appendingPathExtension("part")
                try body.write(to: part)
                _ = try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: part, to: destination)
                return Int64(body.count)
            } catch let error as DownloadError where error.isLinkExpired {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if (error as? URLError)?.code == .cancelled { throw CancellationError() }
                attempt += 1
                if attempt >= 6 { throw error }
                try await Task.sleep(for: .seconds(min(2 * attempt * attempt, 30)))
            }
        }
    }

    private static func key(_ r: HLSMediaPlaylist.Resource) -> String {
        "\(r.url.absoluteString)#\(r.range?.offset ?? -1)-\(r.range?.length ?? -1)"
    }

    private static func segmentName(_ index: Int, _ url: URL) -> String {
        String(format: "seg_%05d.", index) + fileExtension(url, fallback: "ts")
    }

    private static func fileExtension(_ url: URL, fallback: String) -> String {
        let ext = url.pathExtension.lowercased()
        return ["ts", "m4s", "mp4", "m4a", "m4v", "aac", "ac3", "ec3", "key", "vtt"].contains(ext) ? ext : fallback
    }
}
