import Foundation

// Модели ответов API kino.pub (https://api.service-kp.com/v1, зеркала проксируют тот же /v1).
// Декодирование сделано терпимым: почти всё опционально, числа могут прийти строкой.

public struct Pagination: Decodable, Sendable {
    public let total: Int?
    public let current: Int?
    public let perpage: Int?
    public let totalItems: Int?

    enum CodingKeys: String, CodingKey {
        case total, current, perpage
        case totalItems = "total_items"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        total = c.flexibleInt(.total)
        current = c.flexibleInt(.current)
        perpage = c.flexibleInt(.perpage)
        totalItems = c.flexibleInt(.totalItems)
    }

    public var hasMore: Bool {
        guard let total, let current else { return false }
        return current < total
    }
}

public struct ItemsResponse: Decodable, Sendable {
    public let items: [Item]
    public let pagination: Pagination?

    public init(items: [Item], pagination: Pagination?) {
        self.items = items
        self.pagination = pagination
    }
}

public struct ItemResponse: Decodable, Sendable {
    public let item: Item
}

public struct NamedEntity: Decodable, Hashable, Sendable, Identifiable {
    public let id: Int
    public let title: String

    enum CodingKeys: String, CodingKey { case id, title }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexibleInt(.id) ?? 0
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
    }
}

public struct Posters: Decodable, Hashable, Sendable {
    public let small: URL?
    public let medium: URL?
    public let big: URL?
    public let wide: URL?

    public init(small: URL?, medium: URL?, big: URL?, wide: URL?) {
        self.small = small
        self.medium = medium
        self.big = big
        self.wide = wide
    }
}

public struct Item: Decodable, Identifiable, Hashable, Sendable {
    public let id: Int
    public let type: String?
    public let rawTitle: String
    public let year: Int?
    public let plot: String?
    public let posters: Posters?
    public let genres: [NamedEntity]
    public let countries: [NamedEntity]
    public let director: String?
    public let cast: String?
    public let voice: String?
    public let imdbRating: Double?
    public let kinopoiskRating: Double?
    /// IMDb-id без "tt" — для поиска субтитров на стороне.
    public let imdb: Int?
    public let rating: Double?
    public let quality: Int?
    public let finished: Bool?
    public let subtitles: String?
    /// Для фильмов (и многосерийных без сезонов).
    public let videos: [Video]?
    /// Для сериалов.
    public let seasons: [Season]?

    enum CodingKeys: String, CodingKey {
        case id, type, title, year, plot, posters, genres, countries, director, cast, voice, imdb
        case imdbRating = "imdb_rating"
        case kinopoiskRating = "kinopoisk_rating"
        case rating, quality, finished, subtitles, videos, seasons
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexibleInt(.id) ?? 0
        type = try? c.decodeIfPresent(String.self, forKey: .type)
        rawTitle = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        year = c.flexibleInt(.year)
        plot = try? c.decodeIfPresent(String.self, forKey: .plot)
        posters = try? c.decodeIfPresent(Posters.self, forKey: .posters)
        genres = (try? c.decodeIfPresent([NamedEntity].self, forKey: .genres)) ?? []
        countries = (try? c.decodeIfPresent([NamedEntity].self, forKey: .countries)) ?? []
        director = try? c.decodeIfPresent(String.self, forKey: .director)
        cast = try? c.decodeIfPresent(String.self, forKey: .cast)
        voice = try? c.decodeIfPresent(String.self, forKey: .voice)
        imdbRating = c.flexibleDouble(.imdbRating)
        kinopoiskRating = c.flexibleDouble(.kinopoiskRating)
        imdb = c.flexibleInt(.imdb).flatMap { $0 > 0 ? $0 : nil }
        rating = c.flexibleDouble(.rating)
        quality = c.flexibleInt(.quality)
        finished = try? c.decodeIfPresent(Bool.self, forKey: .finished)
        subtitles = try? c.decodeIfPresent(String.self, forKey: .subtitles)
        videos = try? c.decodeIfPresent([Video].self, forKey: .videos)
        seasons = try? c.decodeIfPresent([Season].self, forKey: .seasons)
    }

    /// Заглушка для перехода в карточку, когда известны только id и название (полные данные загрузятся там).
    public init(stubID id: Int, title: String, year: Int?, poster: URL?, isSerial: Bool) {
        self.id = id
        type = isSerial ? "serial" : "movie"
        rawTitle = title
        self.year = year
        plot = nil
        posters = poster.map { Posters(small: $0, medium: $0, big: $0, wide: nil) }
        genres = []
        countries = []
        director = nil
        cast = nil
        voice = nil
        imdbRating = nil
        kinopoiskRating = nil
        imdb = nil
        rating = nil
        quality = nil
        finished = nil
        subtitles = nil
        videos = nil
        seasons = nil
    }

    public static func == (lhs: Item, rhs: Item) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// Название до " / " — обычно русское.
    public var title: String {
        rawTitle.components(separatedBy: " / ").first?.trimmingCharacters(in: .whitespaces) ?? rawTitle
    }

    /// Оригинальное название после " / ", если есть.
    public var originalTitle: String? {
        let parts = rawTitle.components(separatedBy: " / ")
        guard parts.count > 1 else { return nil }
        return parts.dropFirst().joined(separator: " / ").trimmingCharacters(in: .whitespaces)
    }

    public var isSerial: Bool {
        if let seasons, !seasons.isEmpty { return true }
        return ["serial", "docuserial", "tvshow"].contains(type ?? "")
    }

    public var posterURL: URL? { posters?.medium ?? posters?.big ?? posters?.small }
}

public struct Season: Decodable, Identifiable, Hashable, Sendable {
    public let id: Int
    public let number: Int
    public let title: String?
    public let episodes: [Video]

    enum CodingKeys: String, CodingKey { case id, number, title, episodes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexibleInt(.id) ?? 0
        number = c.flexibleInt(.number) ?? 0
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        episodes = (try? c.decodeIfPresent([Video].self, forKey: .episodes)) ?? []
    }
}

/// Видео фильма или эпизод сериала.
public struct Video: Decodable, Identifiable, Hashable, Sendable {
    public let id: Int
    public let number: Int
    public let title: String?
    public let duration: Double?
    public let thumbnail: URL?
    public let files: [MediaFile]
    public let audios: [AudioTrack]
    public let subtitles: [SubtitleTrack]
    public let watched: Int?

    enum CodingKeys: String, CodingKey {
        case id, number, title, duration, thumbnail, files, audios, subtitles, watched
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexibleInt(.id) ?? 0
        number = c.flexibleInt(.number) ?? 0
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        duration = c.flexibleDouble(.duration)
        thumbnail = try? c.decodeIfPresent(URL.self, forKey: .thumbnail)
        files = (try? c.decodeIfPresent([MediaFile].self, forKey: .files)) ?? []
        audios = ((try? c.decodeIfPresent([AudioTrack].self, forKey: .audios)) ?? []).sorted { $0.index < $1.index }
        subtitles = (try? c.decodeIfPresent([SubtitleTrack].self, forKey: .subtitles)) ?? []
        watched = c.flexibleInt(.watched)
    }

    public init(id: Int, number: Int, title: String?, duration: Double?, files: [MediaFile], audios: [AudioTrack], subtitles: [SubtitleTrack]) {
        self.id = id
        self.number = number
        self.title = title
        self.duration = duration
        self.thumbnail = nil
        self.files = files
        self.audios = audios
        self.subtitles = subtitles
        self.watched = nil
    }

    /// Файлы от лучшего качества к худшему.
    public var sortedFiles: [MediaFile] { files.sorted { $0.height > $1.height } }
}

public struct MediaFile: Decodable, Hashable, Sendable {
    public struct URLs: Decodable, Hashable, Sendable {
        public let http: URL?
        public let hls: URL?
        public let hls2: URL?
        public let hls4: URL?

        public init(http: URL?, hls: URL?, hls2: URL?, hls4: URL?) {
            self.http = http
            self.hls = hls
            self.hls2 = hls2
            self.hls4 = hls4
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            http = try? c.decodeIfPresent(URL.self, forKey: .http)
            hls = try? c.decodeIfPresent(URL.self, forKey: .hls)
            hls2 = try? c.decodeIfPresent(URL.self, forKey: .hls2)
            hls4 = try? c.decodeIfPresent(URL.self, forKey: .hls4)
        }

        enum CodingKeys: String, CodingKey { case http, hls, hls2, hls4 }
    }

    public let quality: String
    public let qualityId: Int?
    public let w: Int?
    public let h: Int?
    public let codec: String?
    public let url: URLs?
    public let file: String?

    enum CodingKeys: String, CodingKey {
        case quality, w, h, codec, url, urls, file
        case qualityId = "quality_id"
    }

    public init(quality: String, w: Int?, h: Int?, codec: String?, url: URLs?) {
        self.quality = quality
        self.qualityId = nil
        self.w = w
        self.h = h
        self.codec = codec
        self.url = url
        self.file = nil
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        quality = (try? c.decodeIfPresent(String.self, forKey: .quality)) ?? ""
        qualityId = c.flexibleInt(.qualityId)
        w = c.flexibleInt(.w)
        h = c.flexibleInt(.h)
        codec = try? c.decodeIfPresent(String.self, forKey: .codec)
        file = try? c.decodeIfPresent(String.self, forKey: .file)
        // В старых ответах `url` бывает строкой (прямая ссылка на mp4); в media-links по документации — `urls`.
        if let urls = try? c.decodeIfPresent(URLs.self, forKey: .url) {
            url = urls
        } else if let urls = try? c.decodeIfPresent(URLs.self, forKey: .urls) {
            url = urls
        } else if let single = try? c.decodeIfPresent(URL.self, forKey: .url) {
            url = URLs(http: single, hls: nil, hls2: nil, hls4: nil)
        } else {
            url = nil
        }
    }

    /// Класс качества по названию ("1080p" → 1080), с запасным вариантом по высоте кадра.
    public var height: Int {
        let digits = quality.prefix { $0.isNumber }
        if let value = Int(digits), value > 0 { return value }
        if quality.lowercased().contains("4k") { return 2160 }
        return h ?? 0
    }
}

public struct AudioTrack: Decodable, Identifiable, Hashable, Sendable {
    public let id: Int
    /// Порядковый номер дорожки в файле (в API начинается с 1).
    public let index: Int
    public let codec: String?
    public let channels: Int?
    public let lang: String?
    public let type: NamedEntity?
    public let author: NamedEntity?

    enum CodingKeys: String, CodingKey { case id, index, codec, channels, lang, type, author }

    public init(id: Int, index: Int, codec: String?, channels: Int?, lang: String?, typeTitle: String?, authorTitle: String?) {
        self.id = id
        self.index = index
        self.codec = codec
        self.channels = channels
        self.lang = lang
        self.type = nil
        self.author = nil
        self.fallbackType = typeTitle
        self.fallbackAuthor = authorTitle
    }

    private var fallbackType: String?
    private var fallbackAuthor: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexibleInt(.id) ?? 0
        index = c.flexibleInt(.index) ?? 0
        codec = try? c.decodeIfPresent(String.self, forKey: .codec)
        channels = c.flexibleInt(.channels)
        lang = try? c.decodeIfPresent(String.self, forKey: .lang)
        type = try? c.decodeIfPresent(NamedEntity.self, forKey: .type)
        author = try? c.decodeIfPresent(NamedEntity.self, forKey: .author)
    }

    public var typeTitle: String? { type?.title.nonEmpty ?? fallbackType }
    public var authorTitle: String? { author?.title.nonEmpty ?? fallbackAuthor }

    /// "Многоголосый · LostFilm · RUS · 5.1 AC3"
    public var displayName: String {
        var parts: [String] = []
        if let t = typeTitle { parts.append(t) }
        if let a = authorTitle { parts.append(a) }
        if let lang { parts.append(Language.displayName(lang)) }
        var tech: [String] = []
        if let channels { tech.append(channels == 6 ? "5.1" : channels == 2 ? "2.0" : "\(channels)ch") }
        if let codec { tech.append(codec.uppercased()) }
        if !tech.isEmpty { parts.append(tech.joined(separator: " ")) }
        return parts.isEmpty ? "Дорожка \(index)" : parts.joined(separator: " · ")
    }

    /// Короткое имя для метаданных файла.
    public var trackTitle: String {
        [typeTitle, authorTitle].compactMap { $0 }.joined(separator: " — ").nonEmpty
            ?? lang.map(Language.displayName) ?? "Дорожка \(index)"
    }

    /// Ключ для сопоставления «той же» озвучки в разных эпизодах.
    public var matchKey: String {
        [lang ?? "", typeTitle ?? "", authorTitle ?? ""].joined(separator: "|").lowercased()
    }
}

public struct SubtitleTrack: Decodable, Hashable, Sendable {
    public let lang: String?
    public let shift: Double
    public let embed: Bool
    public let forced: Bool
    public let file: String?
    public let url: URL?

    enum CodingKeys: String, CodingKey { case lang, shift, embed, forced, file, url }

    public init(lang: String?, url: URL?, forced: Bool = false, shift: Double = 0) {
        self.lang = lang
        self.url = url
        self.forced = forced
        self.shift = shift
        self.embed = false
        self.file = nil
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lang = try? c.decodeIfPresent(String.self, forKey: .lang)
        shift = c.flexibleDouble(.shift) ?? 0
        embed = c.flexibleBool(.embed) ?? false
        forced = c.flexibleBool(.forced) ?? false
        file = try? c.decodeIfPresent(String.self, forKey: .file)
        url = try? c.decodeIfPresent(URL.self, forKey: .url)
    }

    public var displayName: String {
        var name = lang.map(Language.displayName) ?? "Субтитры"
        if forced { name += " (форсированные)" }
        return name
    }

    public var matchKey: String { "\(lang ?? "")|\(forced)".lowercased() }
}

public struct ContentType: Decodable, Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
}

public struct TypesResponse: Decodable, Sendable {
    public let items: [ContentType]
}

public struct BookmarkFolder: Decodable, Identifiable, Hashable, Sendable {
    public let id: Int
    public let title: String
    public let count: Int?

    enum CodingKeys: String, CodingKey { case id, title, count }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexibleInt(.id) ?? 0
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        count = c.flexibleInt(.count)
    }
}

public struct BookmarkFoldersResponse: Decodable, Sendable {
    public let items: [BookmarkFolder]
}

public struct UserInfo: Decodable, Sendable {
    public struct Subscription: Decodable, Sendable {
        public let active: Bool?
        public let days: Double?
        public let endTime: Double?

        enum CodingKeys: String, CodingKey {
            case active, days
            case endTime = "end_time"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            active = c.flexibleBool(.active)
            days = c.flexibleDouble(.days)
            endTime = c.flexibleDouble(.endTime)
        }
    }

    public let username: String?
    public let subscription: Subscription?
}

public struct UserResponse: Decodable, Sendable {
    public let user: UserInfo
}

// MARK: - Языки

public enum Language {
    static let names: [String: String] = [
        "rus": "Русский", "ru": "Русский",
        "eng": "Английский", "en": "Английский",
        "ukr": "Украинский", "uk": "Украинский", "ua": "Украинский",
        "jpn": "Японский", "ja": "Японский",
        "kor": "Корейский", "ko": "Корейский",
        "fre": "Французский", "fra": "Французский", "fr": "Французский",
        "ger": "Немецкий", "deu": "Немецкий", "de": "Немецкий",
        "spa": "Испанский", "es": "Испанский",
        "ita": "Итальянский", "it": "Итальянский",
        "chi": "Китайский", "zho": "Китайский", "zh": "Китайский",
        "pol": "Польский", "tur": "Турецкий", "por": "Португальский",
        "heb": "Иврит", "ara": "Арабский", "hin": "Хинди",
    ]

    public static func displayName(_ code: String) -> String {
        names[code.lowercased()] ?? code.uppercased()
    }

    /// ISO 639-2 код для метаданных контейнера.
    public static func iso639_2(_ code: String?) -> String? {
        guard let code = code?.lowercased(), !code.isEmpty else { return nil }
        let map = ["ru": "rus", "en": "eng", "uk": "ukr", "ua": "ukr", "ja": "jpn", "ko": "kor",
                   "fr": "fre", "de": "ger", "es": "spa", "it": "ita", "zh": "chi"]
        return map[code] ?? (code.count == 3 ? code : nil)
    }
}

// MARK: - Гибкое декодирование

extension KeyedDecodingContainer {
    func flexibleInt(_ key: Key) -> Int? {
        if let v = try? decodeIfPresent(Int.self, forKey: key) { return v }
        if let v = try? decodeIfPresent(Double.self, forKey: key) { return Int(v) }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return Int(s) ?? Double(s).map { Int($0) } }
        if let b = try? decodeIfPresent(Bool.self, forKey: key) { return b ? 1 : 0 }
        return nil
    }

    func flexibleDouble(_ key: Key) -> Double? {
        if let v = try? decodeIfPresent(Double.self, forKey: key) { return v }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return Double(s) }
        return nil
    }

    func flexibleBool(_ key: Key) -> Bool? {
        if let v = try? decodeIfPresent(Bool.self, forKey: key) { return v }
        if let v = try? decodeIfPresent(Int.self, forKey: key) { return v != 0 }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return ["1", "true", "yes"].contains(s.lowercased()) }
        return nil
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
