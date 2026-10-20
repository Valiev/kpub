import Foundation

/// Субтитры из OpenSubtitles (старый REST rest.opensubtitles.org — работает без ключа) по IMDb-id.
public enum OpenSubtitles {
    struct Candidate: Decodable {
        let SubFileName: String?
        let MovieReleaseName: String?
        let SubFormat: String?
        let SubSumCD: String?
        let SubBad: String?
        let SubAutoTranslation: String?
        let SubForeignPartsOnly: String?
        let SubHearingImpaired: String?
        let SubFromTrusted: String?
        let SubDownloadsCnt: String?
        let SubEncoding: String?
        let MovieTimeMS: String?
        let SubDownloadLink: URL?

        var downloads: Double { Double(SubDownloadsCnt ?? "") ?? 0 }
        var releaseName: String { MovieReleaseName ?? SubFileName ?? "" }
    }

    static let base = URL(string: "https://rest.opensubtitles.org/search")!

    static func searchURL(imdbID: Int, season: Int?, episode: Int?, language: String) -> URL {
        let imdb = String(format: "%07d", imdbID)
        var path = ""
        if let season, let episode {
            path = "episode-\(episode)/imdbid-\(imdb)/season-\(season)/sublanguageid-\(language)"
        } else {
            path = "imdbid-\(imdb)/sublanguageid-\(language)"
        }
        return base.appendingPathComponent(path)
    }

    static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 30)
        // Публичный идентификатор, которым пользуются открытые клиенты старого API.
        request.setValue("TemporaryUserAgent", forHTTPHeaderField: "X-User-Agent")
        request.setValue("TemporaryUserAgent", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// Находит и сохраняет лучший вариант в `destination` (SRT, UTF-8, без рекламных реплик).
    /// `duration` — длительность видео в секундах, по ней отсекаются субтитры под другую версию.
    public static func fetch(
        imdbID: Int, season: Int?, episode: Int?, language: String, duration: Double?, to destination: URL
    ) async throws -> Bool {
        let (data, response) = try await URLSession.shared.data(for: request(searchURL(imdbID: imdbID, season: season, episode: episode, language: language)))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw DownloadError.badStatus(status) }
        let candidates = rank((try? JSONDecoder().decode([Candidate].self, from: data)) ?? [], duration: duration, isEpisode: season != nil)

        var fallback: Data?
        for candidate in candidates.prefix(4) {
            guard let link = candidate.SubDownloadLink else { continue }
            guard let (raw, _) = try? await URLSession.shared.data(for: request(link)),
                  let srt = decode(raw, encoding: candidate.SubEncoding)
            else { continue }
            let cleaned = SRT.removeAds(srt)
            guard let lastEnd = SRT.lastCueEnd(cleaned) else { continue }
            if fallback == nil { fallback = Data(cleaned.utf8) }
            if fits(lastCueEnd: lastEnd, duration: duration) {
                try Data(cleaned.utf8).write(to: destination, options: .atomic)
                return true
            }
        }
        if let fallback, duration == nil {
            try fallback.write(to: destination, options: .atomic)
            return true
        }
        return false
    }

    /// Порядок попыток: годные по метаданным, затем совпадение длительности релиза, доверенность, популярность.
    static func rank(_ list: [Candidate], duration: Double?, isEpisode: Bool) -> [Candidate] {
        let usable = list.filter {
            ($0.SubFormat ?? "srt").lowercased() == "srt" && ($0.SubSumCD ?? "1") == "1" && $0.SubBad != "1"
                && $0.SubAutoTranslation != "1" && $0.SubForeignPartsOnly != "1" && $0.SubDownloadLink != nil
        }
        func score(_ c: Candidate) -> Double {
            var s = log10(c.downloads + 1)
            if c.SubFromTrusted == "1" { s += 1 }
            if c.SubHearingImpaired != "1" { s += 0.5 }
            if isEpisode, c.releaseName.uppercased().contains("WEB") { s += 0.5 }
            if let duration, let ms = Double(c.MovieTimeMS ?? ""), ms > 0, abs(ms / 1000 - duration) / duration < 0.02 { s += 3 }
            return s
        }
        return usable.sorted { score($0) > score($1) }
    }

    /// Последняя реплика не позже конца видео и не раньше 60% его длины.
    static func fits(lastCueEnd: Double, duration: Double?) -> Bool {
        guard let duration, duration > 0 else { return true }
        return lastCueEnd <= duration + 5 && lastCueEnd >= duration * 0.6
    }

    static func decode(_ raw: Data, encoding: String?) -> String? {
        let data = Gzip.isGzip(raw) ? (Gzip.decompress(raw) ?? raw) : raw
        if let s = String(data: data, encoding: .utf8) { return s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s }
        let hinted: String.Encoding? = switch (encoding ?? "").uppercased() {
        case "CP1252", "WINDOWS-1252": .windowsCP1252
        case "CP1251", "WINDOWS-1251": .windowsCP1251
        case "ISO-8859-1", "LATIN1": .isoLatin1
        case "CP1250": .windowsCP1250
        default: nil
        }
        if let hinted, let s = String(data: data, encoding: hinted) { return s }
        return String(data: data, encoding: .windowsCP1252)
    }
}

enum SRT {
    private static let adPattern = try! NSRegularExpression(
        pattern: "opensubtitles|osdb\\.link|subtitles by|advertise your product|become vip|addic7ed|subscene",
        options: [.caseInsensitive]
    )

    static func blocks(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Убирает рекламные реплики и перенумеровывает.
    static func removeAds(_ text: String) -> String {
        let kept = blocks(text).filter { block in
            adPattern.firstMatch(in: block, range: NSRange(block.startIndex..., in: block)) == nil
        }
        return kept.enumerated().map { i, block -> String in
            var lines = block.components(separatedBy: "\n")
            if let first = lines.first, Int(first.trimmingCharacters(in: .whitespaces)) != nil { lines[0] = "\(i + 1)" }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n") + "\n"
    }

    /// Время окончания последней реплики в секундах.
    static func lastCueEnd(_ text: String) -> Double? {
        var latest: Double?
        for line in text.components(separatedBy: .newlines) where line.contains("-->") {
            let parts = line.components(separatedBy: "-->")
            guard parts.count == 2, let end = parseTime(parts[1].trimmingCharacters(in: .whitespaces)) else { continue }
            latest = max(latest ?? 0, end)
        }
        return latest
    }

    /// "00:56:28,305" → 3388.305
    static func parseTime(_ s: String) -> Double? {
        let main = s.split(separator: " ").first.map(String.init) ?? s
        let parts = main.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let sec = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + sec
    }
}

enum Gzip {
    static func isGzip(_ data: Data) -> Bool { data.count > 18 && data[data.startIndex] == 0x1F && data[data.startIndex + 1] == 0x8B }

    /// Разбирает заголовок gzip (RFC 1952) и распаковывает deflate-поток.
    static func decompress(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else { return nil }
        let flags = bytes[3]
        var offset = 10
        if flags & 0x04 != 0 { // FEXTRA
            guard offset + 2 <= bytes.count else { return nil }
            offset += 2 + Int(bytes[offset]) + Int(bytes[offset + 1]) << 8
        }
        if flags & 0x08 != 0 { while offset < bytes.count, bytes[offset] != 0 { offset += 1 }; offset += 1 } // FNAME
        if flags & 0x10 != 0 { while offset < bytes.count, bytes[offset] != 0 { offset += 1 }; offset += 1 } // FCOMMENT
        if flags & 0x02 != 0 { offset += 2 } // FHCRC
        guard offset < bytes.count - 8 else { return nil }
        let deflate = Data(bytes[offset..<(bytes.count - 8)])
        return try? (deflate as NSData).decompressed(using: .zlib) as Data
    }
}
