import Foundation

/// Параметры пережатия одного видео.
public struct EncodeSettings: Codable, Hashable, Sendable {
    public enum VideoCodec: String, Codable, CaseIterable, Identifiable, Sendable {
        /// Без пережатия: видеопоток копируется как есть.
        case copy
        /// HEVC через VideoToolbox — быстро, хорошее сжатие.
        case hevcHardware
        /// HEVC через libx265 — медленно, лучшее качество на бит.
        case hevcSoftware
        /// H.264 через VideoToolbox — максимальная совместимость.
        case h264Hardware

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .copy: "Без пережатия"
            case .hevcHardware: "HEVC (аппаратно, быстро)"
            case .hevcSoftware: "HEVC x265 (медленно, компактнее)"
            case .h264Hardware: "H.264 (аппаратно, совместимо)"
            }
        }

        public var usesCRF: Bool { self == .hevcSoftware }
    }

    public enum AudioMode: String, Codable, CaseIterable, Identifiable, Sendable {
        case copy
        case aacStereo

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .copy: "Как в источнике"
            case .aacStereo: "AAC стерео"
            }
        }
    }

    public enum Container: String, Codable, CaseIterable, Identifiable, Sendable {
        case mp4
        case mkv

        public var id: String { rawValue }
        public var fileExtension: String { rawValue }

        public var title: String {
            switch self {
            case .mp4: "MP4 (QuickTime, iPad, встроенный плеер)"
            case .mkv: "MKV (VLC, IINA, Infuse)"
            }
        }
    }

    public var videoCodec: VideoCodec
    /// Максимальная высота кадра; 0 — как в источнике.
    public var maxHeight: Int
    /// Целевой битрейт видео для аппаратных кодеков.
    public var videoBitrateKbps: Int
    /// CRF для libx265.
    public var crf: Int
    public var audioMode: AudioMode
    public var audioBitrateKbps: Int
    public var container: Container
    /// Сохранять субтитры ещё и отдельными .srt рядом с видео.
    public var saveSubtitleFiles: Bool

    public init(
        videoCodec: VideoCodec = .hevcHardware,
        maxHeight: Int = 720,
        videoBitrateKbps: Int = 1400,
        crf: Int = 26,
        audioMode: AudioMode = .aacStereo,
        audioBitrateKbps: Int = 128,
        container: Container = .mp4,
        saveSubtitleFiles: Bool = false
    ) {
        self.videoCodec = videoCodec
        self.maxHeight = maxHeight
        self.videoBitrateKbps = videoBitrateKbps
        self.crf = crf
        self.audioMode = audioMode
        self.audioBitrateKbps = audioBitrateKbps
        self.container = container
        self.saveSubtitleFiles = saveSubtitleFiles
    }

    public static let heightOptions = [0, 1080, 720, 576, 480]

    public static func heightTitle(_ height: Int) -> String {
        height == 0 ? "Как в источнике" : "\(height)p"
    }

    /// Примерный размер результата в байтах, если известны длительность и (для copy) размер источника.
    public func estimatedBytes(duration: Double, audioTracks: Int, sourceVideoKbps: Double? = nil) -> Int64? {
        guard duration > 0 else { return nil }
        let videoKbps: Double
        switch videoCodec {
        case .copy:
            guard let sourceVideoKbps else { return nil }
            videoKbps = sourceVideoKbps
        case .hevcHardware, .h264Hardware:
            videoKbps = Double(videoBitrateKbps)
        case .hevcSoftware:
            // Грубая оценка для CRF: от ~2 Мбит/с при 1080p CRF 23 вниз.
            let base: Double = switch maxHeight {
            case 0, 1080...: 2400
            case 720...: 1200
            case 576...: 850
            default: 650
            }
            videoKbps = base * pow(0.89, Double(crf - 23))
        }
        let audioKbps: Double = audioMode == .copy ? 192 : Double(audioBitrateKbps)
        let totalKbps = videoKbps + audioKbps * Double(max(audioTracks, 1))
        return Int64(totalKbps * 1000 / 8 * duration)
    }
}

/// Готовые наборы настроек для быстрого выбора.
public struct EncodePreset: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let settings: EncodeSettings

    public static let all: [EncodePreset] = [
        EncodePreset(
            id: "compact720",
            title: "Компактно · HEVC 720p",
            subtitle: "≈ 0.7 ГБ за час, хорошо смотрится на ноутбуке",
            settings: EncodeSettings(videoCodec: .hevcHardware, maxHeight: 720, videoBitrateKbps: 1400, audioMode: .aacStereo, audioBitrateKbps: 128)
        ),
        EncodePreset(
            id: "tiny480",
            title: "Минимум места · HEVC 480p",
            subtitle: "≈ 0.35 ГБ за час, для длинных перелётов и сериалов",
            settings: EncodeSettings(videoCodec: .hevcHardware, maxHeight: 480, videoBitrateKbps: 650, audioMode: .aacStereo, audioBitrateKbps: 96)
        ),
        EncodePreset(
            id: "quality1080",
            title: "Качество · HEVC 1080p",
            subtitle: "≈ 1.4 ГБ за час",
            settings: EncodeSettings(videoCodec: .hevcHardware, maxHeight: 1080, videoBitrateKbps: 2800, audioMode: .aacStereo, audioBitrateKbps: 160)
        ),
        EncodePreset(
            id: "x265_720",
            title: "Лучшее сжатие · x265 720p CRF 26",
            subtitle: "Медленно (в разы дольше), но компактнее при том же качестве",
            settings: EncodeSettings(videoCodec: .hevcSoftware, maxHeight: 720, crf: 26, audioMode: .aacStereo, audioBitrateKbps: 128)
        ),
        EncodePreset(
            id: "original",
            title: "Оригинал без пережатия",
            subtitle: "Только выбранные дорожки и субтитры, видео как есть",
            settings: EncodeSettings(videoCodec: .copy, maxHeight: 0, audioMode: .copy)
        ),
    ]

    public static let `default` = all[0]
}
