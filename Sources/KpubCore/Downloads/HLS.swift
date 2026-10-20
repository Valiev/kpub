import Foundation

// Разбор HLS-плейлистов kino.pub (hls4: видео-варианты + отдельные озвучки с NAME="01. Дубляж (RUS)").

public struct HLSMaster: Sendable {
    public struct Variant: Sendable {
        public var url: URL
        public var bandwidth: Int
        public var width: Int?
        public var height: Int?
        public var codecs: String?
        public var audioGroup: String?

        /// Класс качества (1080, 720…) по размеру кадра — широкоформатное кино ниже по высоте.
        public var qualityClass: Int {
            let w = width ?? 0
            let h = height ?? 0
            if w >= 3200 || h >= 1800 { return 2160 }
            if w >= 1700 || h >= 1000 { return 1080 }
            if w >= 1200 || h >= 700 { return 720 }
            if w >= 1000 || h >= 560 { return 576 }
            return w == 0 && h == 0 ? 0 : 480
        }

        public var isHEVC: Bool {
            guard let codecs = codecs?.lowercased() else { return false }
            return codecs.contains("hvc1") || codecs.contains("hev1")
        }
    }

    public struct Rendition: Sendable {
        public var groupID: String
        public var name: String
        public var language: String?
        public var channels: String?
        public var url: URL?

        /// Номер дорожки из префикса "NN." — совпадает с `audios[].index` в API.
        public var trackIndex: Int? {
            let digits = name.prefix { $0.isNumber }
            guard !digits.isEmpty, name.dropFirst(digits.count).first == "." else { return nil }
            return Int(digits)
        }

        public var isAC3: Bool {
            let upper = name.uppercased()
            return upper.hasSuffix(" AC3") || upper.contains("AC3") || upper.contains("AC-3")
        }
    }

    public var variants: [Variant]
    public var audio: [Rendition]

    public static func parse(_ text: String, baseURL: URL) -> HLSMaster {
        var variants: [Variant] = []
        var audio: [Rendition] = []
        var pendingVariant: [String: String]?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#EXT-X-MEDIA:") {
                let attrs = parseAttributes(String(line.dropFirst("#EXT-X-MEDIA:".count)))
                guard attrs["TYPE"] == "AUDIO" else { continue }
                audio.append(Rendition(
                    groupID: attrs["GROUP-ID"] ?? "",
                    name: attrs["NAME"] ?? "",
                    language: attrs["LANGUAGE"],
                    channels: attrs["CHANNELS"],
                    url: attrs["URI"].flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL }
                ))
            } else if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pendingVariant = parseAttributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
            } else if !line.hasPrefix("#"), let attrs = pendingVariant {
                pendingVariant = nil
                guard let url = URL(string: line, relativeTo: baseURL)?.absoluteURL else { continue }
                let res = attrs["RESOLUTION"]?.split(separator: "x").compactMap { Int($0) }
                variants.append(Variant(
                    url: url,
                    bandwidth: Int(attrs["BANDWIDTH"] ?? "") ?? 0,
                    width: res?.count == 2 ? res?[0] : nil,
                    height: res?.count == 2 ? res?[1] : nil,
                    codecs: attrs["CODECS"],
                    audioGroup: attrs["AUDIO"]
                ))
            }
        }
        return HLSMaster(variants: variants, audio: audio)
    }

    /// `preferredHeight` — желаемый класс качества; берём такой или ближайший ниже. AVC предпочтительнее HEVC.
    public func pickVariant(preferredHeight: Int) -> Variant? {
        let video = variants.filter { $0.qualityClass > 0 || $0.codecs?.contains("avc") == true || $0.codecs?.contains("hvc") == true }
        let pool = video.isEmpty ? variants : video
        guard !pool.isEmpty else { return nil }
        let classes = Set(pool.map(\.qualityClass)).sorted()
        let target = classes.last { $0 <= preferredHeight } ?? classes.first!
        let candidates = pool.filter { $0.qualityClass == target }
        let avc = candidates.filter { !$0.isHEVC }
        return (avc.isEmpty ? candidates : avc).max { $0.bandwidth < $1.bandwidth }
    }

    /// Озвучки группы варианта, подобранные под выбранные индексы API.
    /// Возвращает пары (номер в списке выбора или nil, если взяли первую попавшуюся; озвучка).
    public func pickAudio(for variant: Variant, apiIndices: [Int], positions: [Int], preferAC3: Bool) -> [(selection: Int?, rendition: Rendition)] {
        let group = audio.filter { $0.url != nil && (variant.audioGroup == nil || $0.groupID == variant.audioGroup) }
        guard !group.isEmpty else { return [] }

        func best(_ list: [Rendition]) -> Rendition? {
            let preferred = list.filter { $0.isAC3 == preferAC3 }
            return preferred.first ?? list.first
        }

        // Уникальные дорожки в порядке номеров — для запасного сопоставления по позиции.
        var byIndex: [Int: [Rendition]] = [:]
        var order: [Int] = []
        for r in group {
            let key = r.trackIndex ?? (1000 + order.count)
            if byIndex[key] == nil { order.append(key) }
            byIndex[key, default: []].append(r)
        }
        order.sort()

        var result: [(selection: Int?, rendition: Rendition)] = []
        var used = Set<Int>()
        for (selection, (apiIndex, position)) in zip(apiIndices, positions).enumerated() {
            var key: Int?
            if byIndex[apiIndex] != nil {
                key = apiIndex
            } else if position < order.count {
                key = order[position]
            }
            guard let key, !used.contains(key), let r = best(byIndex[key] ?? []) else { continue }
            used.insert(key)
            result.append((selection, r))
        }
        if result.isEmpty, let first = order.first, let r = best(byIndex[first] ?? []) {
            result.append((nil, r))
        }
        return result
    }

    /// Разбор списка атрибутов: KEY=VALUE,KEY="VALUE, с запятыми"
    static func parseAttributes(_ s: String) -> [String: String] {
        var result: [String: String] = [:]
        var key = ""
        var value = ""
        var readingKey = true
        var inQuotes = false
        func flush() {
            let k = key.trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { result[k] = value }
            key = ""
            value = ""
            readingKey = true
        }
        for ch in s {
            if readingKey {
                if ch == "=" { readingKey = false } else if ch != "," { key.append(ch) }
            } else if ch == "\"" {
                inQuotes.toggle()
            } else if ch == "," && !inQuotes {
                flush()
            } else {
                value.append(ch)
            }
        }
        flush()
        return result
    }
}

public struct HLSMediaPlaylist: Sendable {
    public struct ByteRange: Sendable, Hashable {
        public var length: Int64
        public var offset: Int64
    }

    public struct Resource: Sendable, Hashable {
        public var url: URL
        public var range: ByteRange?
    }

    public struct Segment: Sendable {
        public var resource: Resource
        public var duration: Double
        /// Строки, которые нужно сохранить перед сегментом (#EXT-X-KEY, #EXT-X-MAP, #EXT-X-DISCONTINUITY).
        public var prefixTags: [String]
    }

    public var headerTags: [String]
    public var segments: [Segment]
    /// Ресурсы, на которые ссылаются теги (ключи, init-сегменты): URI → ресурс.
    public var tagResources: [Resource]

    public var totalDuration: Double { segments.reduce(0) { $0 + $1.duration } }

    /// Ресурс из тега #EXT-X-KEY / #EXT-X-MAP (URI + необязательный BYTERANGE).
    static func tagResource(_ line: String, baseURL: URL) -> Resource? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let attrs = HLSMaster.parseAttributes(String(line[line.index(after: colon)...]))
        guard let uri = attrs["URI"], let url = URL(string: uri, relativeTo: baseURL)?.absoluteURL else { return nil }
        var range: ByteRange?
        if let spec = attrs["BYTERANGE"] {
            let parts = spec.split(separator: "@")
            if let len = Int64(parts.first ?? "") {
                range = ByteRange(length: len, offset: parts.count > 1 ? Int64(parts[1]) ?? 0 : 0)
            }
        }
        return Resource(url: url, range: range)
    }

    /// Тот же тег, но со ссылкой на локальный файл (BYTERANGE убирается — диапазон уже вырезан).
    static func localizeTag(_ line: String, localName: String) -> String {
        guard let colon = line.firstIndex(of: ":") else { return line }
        let name = line[...colon]
        var attrs = HLSMaster.parseAttributes(String(line[line.index(after: colon)...]))
        attrs["URI"] = localName
        attrs["BYTERANGE"] = nil
        let quoted: Set<String> = ["URI", "KEYFORMAT", "KEYFORMATVERSIONS"]
        let body = attrs.keys.sorted().map { key in
            quoted.contains(key) ? "\(key)=\"\(attrs[key]!)\"" : "\(key)=\(attrs[key]!)"
        }.joined(separator: ",")
        return name + body
    }
    public var isMediaPlaylist: Bool { !segments.isEmpty }

    public static func parse(_ text: String, baseURL: URL) -> HLSMediaPlaylist {
        var header: [String] = []
        var segments: [Segment] = []
        var tagResources: [Resource] = []
        var pendingTags: [String] = []
        var duration: Double = 0
        var pendingRange: (length: Int64, offset: Int64?)?
        var lastRangeEnd: [URL: Int64] = [:]
        var seenFirstSegment = false

        func parseRange(_ spec: String) -> (length: Int64, offset: Int64?)? {
            let parts = spec.split(separator: "@")
            guard let len = Int64(parts.first ?? "") else { return nil }
            return (len, parts.count > 1 ? Int64(parts[1]) : nil)
        }

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line == "#EXTM3U" { continue }
            if line.hasPrefix("#EXTINF:") {
                let value = line.dropFirst("#EXTINF:".count).split(separator: ",").first ?? ""
                duration = Double(value) ?? 0
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                pendingRange = parseRange(String(line.dropFirst("#EXT-X-BYTERANGE:".count)))
            } else if line.hasPrefix("#EXT-X-KEY:") || line.hasPrefix("#EXT-X-MAP:") {
                if let resource = tagResource(line, baseURL: baseURL) { tagResources.append(resource) }
                pendingTags.append(line)
            } else if line.hasPrefix("#EXT-X-DISCONTINUITY") && !line.hasPrefix("#EXT-X-DISCONTINUITY-SEQUENCE") {
                pendingTags.append(line)
            } else if line.hasPrefix("#") {
                if !seenFirstSegment && !line.hasPrefix("#EXT-X-ENDLIST") { header.append(line) }
            } else if let url = URL(string: line, relativeTo: baseURL)?.absoluteURL {
                seenFirstSegment = true
                var range: ByteRange?
                if let pendingRange {
                    let offset = pendingRange.offset ?? lastRangeEnd[url] ?? 0
                    range = ByteRange(length: pendingRange.length, offset: offset)
                    lastRangeEnd[url] = offset + pendingRange.length
                }
                segments.append(Segment(resource: Resource(url: url, range: range), duration: duration, prefixTags: pendingTags))
                pendingTags = []
                duration = 0
                pendingRange = nil
            }
        }
        return HLSMediaPlaylist(headerTags: header, segments: segments, tagResources: tagResources)
    }
}
