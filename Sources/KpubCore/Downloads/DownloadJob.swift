import Foundation

public struct SelectedAudio: Codable, Hashable, Sendable {
    /// `index` дорожки из API — по нему ищем озвучку в hls4 (NAME="NN. …").
    public var apiIndex: Int
    /// Позиция дорожки среди аудиопотоков файла (0-based): порядок `audios` из API, отсортированных по `index`.
    public var streamPosition: Int
    public var language: String?
    public var title: String

    public init(apiIndex: Int = 0, streamPosition: Int, language: String?, title: String) {
        self.apiIndex = apiIndex
        self.streamPosition = streamPosition
        self.language = language
        self.title = title
    }
}

public struct SelectedSubtitle: Codable, Hashable, Sendable {
    public var url: URL
    public var language: String?
    public var forced: Bool
    public var shift: Double

    public init(url: URL, language: String?, forced: Bool, shift: Double) {
        self.url = url
        self.language = language
        self.forced = forced
        self.shift = shift
    }

    public var title: String {
        var name = language.map(Language.displayName) ?? "Субтитры"
        if forced { name += " (форсированные)" }
        return name
    }
}

/// Повторное пережатие готового файла: что было до него (для отмены и сравнения размера).
public struct RecompressInfo: Codable, Sendable {
    public var originalPath: String
    public var originalSettings: EncodeSettings
    public var originalSize: Int64?
}

/// Одна загрузка: фильм или эпизод. Сохраняется на диск, переживает перезапуск приложения.
public struct DownloadJob: Codable, Identifiable, Sendable {
    public enum SourceKind: String, Codable, Sendable {
        /// HLS: видео и озвучки отдельными плейлистами, качаются сегментами.
        case hls
        /// Цельный mp4 по прямой ссылке.
        case file
    }

    public enum Status: String, Codable, Sendable {
        case queued, downloading, waitingEncode, encoding, completed, failed, paused

        public var isActive: Bool { self == .downloading || self == .encoding }
        public var isFinished: Bool { self == .completed }
    }

    public let id: UUID
    public var itemID: Int
    public var videoID: Int
    public var showTitle: String
    public var originalTitle: String?
    public var year: Int?
    public var isSerial: Bool
    public var seasonNumber: Int?
    public var episodeNumber: Int?
    public var episodeTitle: String?
    public var posterURL: URL?
    public var duration: Double?

    /// Желаемый класс качества источника (1080, 720…).
    public var sourceHeight: Int
    public var sourceURL: URL?
    public var sourceKind: SourceKind
    /// Выбранные озвучки (в порядке выбора; первая — по умолчанию).
    public var audio: [SelectedAudio]
    /// Озвучки, скачанные отдельными HLS-дорожками audio_0, audio_1… (nil/пусто — звук внутри видео).
    public var downloadedAudio: [SelectedAudio]?
    public var subtitles: [SelectedSubtitle]
    /// Языки субтитров, которые нужно найти на стороне (OpenSubtitles), если их нет на кинопабе.
    public var externalSubtitleLanguages: [String]?
    public var imdbID: Int?
    public var settings: EncodeSettings
    public var outputPath: String

    public var status: Status
    public var sourceComplete: Bool
    public var progress: Double
    public var bytesReceived: Int64
    public var bytesTotal: Int64?
    public var speedText: String?
    public var errorMessage: String?
    public var createdAt: Date
    public var completedAt: Date?
    public var outputSize: Int64?
    /// Идёт повторное пережатие уже скачанного файла.
    public var recompress: RecompressInfo?
    /// Пояснение к результату (например, сколько сэкономило пережатие).
    public var note: String?

    public init(
        itemID: Int, videoID: Int, showTitle: String, originalTitle: String?, year: Int?, isSerial: Bool,
        seasonNumber: Int?, episodeNumber: Int?, episodeTitle: String?, posterURL: URL?, duration: Double?,
        sourceHeight: Int, sourceURL: URL?, sourceKind: SourceKind, audio: [SelectedAudio],
        subtitles: [SelectedSubtitle], settings: EncodeSettings, outputPath: String,
        externalSubtitleLanguages: [String] = [], imdbID: Int? = nil
    ) {
        id = UUID()
        self.itemID = itemID
        self.videoID = videoID
        self.showTitle = showTitle
        self.originalTitle = originalTitle
        self.year = year
        self.isSerial = isSerial
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.episodeTitle = episodeTitle
        self.posterURL = posterURL
        self.duration = duration
        self.sourceHeight = sourceHeight
        self.sourceURL = sourceURL
        self.sourceKind = sourceKind
        self.audio = audio
        self.subtitles = subtitles
        self.externalSubtitleLanguages = externalSubtitleLanguages
        self.imdbID = imdbID
        self.settings = settings
        self.outputPath = outputPath
        status = .queued
        sourceComplete = false
        progress = 0
        bytesReceived = 0
        createdAt = Date()
    }

    public var displayTitle: String {
        guard isSerial, let episodeNumber else {
            if let episodeNumber, episodeNumber > 1 { return "\(showTitle) — часть \(episodeNumber)" }
            return showTitle
        }
        let code = String(format: "S%02dE%02d", seasonNumber ?? 1, episodeNumber)
        if let episodeTitle, !episodeTitle.isEmpty { return "\(showTitle) · \(code) · \(episodeTitle)" }
        return "\(showTitle) · \(code)"
    }

    public var outputURL: URL { URL(fileURLWithPath: outputPath) }
}

public enum OutputNaming {
    /// Movies: <root>/Фильмы/Название (2020).mp4
    /// Сериалы: <root>/Сериалы/Название/Season 01/Название - S01E02 - Эпизод.mp4
    public static func path(
        root: URL, title: String, year: Int?, isSerial: Bool, season: Int?, episode: Int?,
        episodeTitle: String?, partCount: Int, ext: String
    ) -> String {
        let show = sanitize(title)
        if isSerial {
            let s = season ?? 1
            let e = episode ?? 1
            var name = "\(show) - " + String(format: "S%02dE%02d", s, e)
            if let episodeTitle, !episodeTitle.isEmpty, !episodeTitle.lowercased().hasPrefix("эпизод") {
                name += " - " + sanitize(episodeTitle)
            }
            return root.appendingPathComponent("Сериалы")
                .appendingPathComponent(show)
                .appendingPathComponent(String(format: "Season %02d", s))
                .appendingPathComponent(name + "." + ext).path
        }
        var name = show
        if let year { name += " (\(year))" }
        if partCount > 1, let episode { name += " - часть \(episode)" }
        return root.appendingPathComponent("Фильмы").appendingPathComponent(name + "." + ext).path
    }

    public static func sanitize(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.controlCharacters).union(.newlines)
        let cleaned = name.components(separatedBy: forbidden).joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return String(cleaned.prefix(120)).nonEmpty ?? "Без названия"
    }

    /// Если файл уже есть — добавляет " (2)", " (3)"…
    public static func uniquePath(_ path: String) -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return path }
        let url = URL(fileURLWithPath: path)
        let base = url.deletingPathExtension().path
        let ext = url.pathExtension
        var n = 2
        while fm.fileExists(atPath: "\(base) (\(n)).\(ext)") { n += 1 }
        return "\(base) (\(n)).\(ext)"
    }
}

public enum Formatting {
    public static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    public static func duration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        return h > 0 ? "\(h) ч \(m) мин" : "\(m) мин"
    }
}
