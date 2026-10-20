import Foundation

/// Пути к ffmpeg/ffprobe и список доступных кодировщиков.
public struct FFmpegTools: Sendable, Equatable {
    public let ffmpeg: URL
    public let ffprobe: URL

    static let searchDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"]

    /// Ищет ffmpeg: сначала по пользовательскому пути, потом в типичных местах и в PATH.
    public static func locate(customPath: String? = nil) -> FFmpegTools? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let customPath, !customPath.isEmpty {
            let expanded = (customPath as NSString).expandingTildeInPath
            candidates.append(expanded.hasSuffix("ffmpeg") ? (expanded as NSString).deletingLastPathComponent : expanded)
        }
        candidates += searchDirectories
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map(String.init)
        }
        for dir in candidates {
            let ffmpeg = (dir as NSString).appendingPathComponent("ffmpeg")
            let ffprobe = (dir as NSString).appendingPathComponent("ffprobe")
            if fm.isExecutableFile(atPath: ffmpeg), fm.isExecutableFile(atPath: ffprobe) {
                return FFmpegTools(ffmpeg: URL(fileURLWithPath: ffmpeg), ffprobe: URL(fileURLWithPath: ffprobe))
            }
        }
        return nil
    }

    public func availableEncoders() async -> Set<String> {
        guard let result = try? await ProcessRunner.run(ffmpeg, arguments: ["-hide_banner", "-encoders"]) else { return [] }
        var encoders = Set<String>()
        for line in result.stdout.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            // Строки вида " V....D hevc_videotoolbox  VideoToolbox H.265 Encoder"
            if parts.count >= 2, parts[0].count == 6 { encoders.insert(String(parts[1])) }
        }
        return encoders
    }
}

// MARK: - ffprobe

public struct ProbeResult: Sendable {
    public struct Stream: Sendable {
        public let index: Int
        public let codecType: String
        public let codecName: String?
        public let width: Int?
        public let height: Int?
        public let channels: Int?
        public let language: String?
        public let title: String?
        public let bitRate: Int?
    }

    public let streams: [Stream]
    public let startTime: Double?
    public let duration: Double?
    public let bitRate: Int?

    public var video: Stream? { streams.first { $0.codecType == "video" } }
    public var audio: [Stream] { streams.filter { $0.codecType == "audio" } }
    public var subtitles: [Stream] { streams.filter { $0.codecType == "subtitle" } }
}

public enum FFprobe {
    private struct Output: Decodable {
        struct Stream: Decodable {
            let index: Int
            let codec_type: String?
            let codec_name: String?
            let width: Int?
            let height: Int?
            let channels: Int?
            let bit_rate: String?
            let tags: [String: String]?
        }
        struct Format: Decodable {
            let start_time: String?
            let duration: String?
            let bit_rate: String?
        }
        let streams: [Stream]?
        let format: Format?
    }

    public static func probe(_ tools: FFmpegTools, input: String, isHLSPlaylist: Bool = false) async throws -> ProbeResult {
        var args = ["-v", "error", "-print_format", "json", "-show_format", "-show_streams"]
        if isHLSPlaylist { args += ["-protocol_whitelist", "file,crypto,data", "-allowed_extensions", "ALL"] }
        let result = try await ProcessRunner.run(tools.ffprobe, arguments: args + [input])
        guard result.status == 0 else {
            throw TranscodeError.ffprobeFailed(result.stderrTail)
        }
        return try parse(Data(result.stdout.utf8))
    }

    static func parse(_ data: Data) throws -> ProbeResult {
        let output = try JSONDecoder().decode(Output.self, from: data)
        let streams = (output.streams ?? []).map { s in
            ProbeResult.Stream(
                index: s.index,
                codecType: s.codec_type ?? "",
                codecName: s.codec_name,
                width: s.width,
                height: s.height,
                channels: s.channels,
                language: s.tags?["language"],
                title: s.tags?["title"] ?? s.tags?["handler_name"],
                bitRate: s.bit_rate.flatMap(Int.init)
            )
        }
        return ProbeResult(
            streams: streams,
            startTime: output.format?.start_time.flatMap(Double.init),
            duration: output.format?.duration.flatMap(Double.init),
            bitRate: output.format?.bit_rate.flatMap(Int.init)
        )
    }
}

// MARK: - Сборка команды ffmpeg

public struct TranscodePlan: Sendable {
    /// Вход ffmpeg: файл, URL или локальный HLS-плейлист.
    public struct Input: Sendable, Hashable {
        public var path: String
        public var isHLSPlaylist: Bool
        /// Время начала потока (ffprobe start_time) — чтобы выровнять раздельные дорожки.
        public var startTime: Double

        public init(path: String, isHLSPlaylist: Bool = false, startTime: Double = 0) {
            self.path = path
            self.isHLSPlaylist = isHLSPlaylist
            self.startTime = startTime
        }
    }

    public struct Audio: Sendable, Hashable {
        public enum Source: Sendable, Hashable {
            /// N-й аудиопоток основного входа (`-map 0:a:N`).
            case main(Int)
            /// Отдельный вход с одной дорожкой (HLS-озвучка).
            case separate(Input)
        }

        public var source: Source
        public var language: String?
        public var title: String?

        public init(source: Source, language: String?, title: String?) {
            self.source = source
            self.language = language
            self.title = title
        }

        public init(sourceAudioIndex: Int, language: String?, title: String?) {
            self.init(source: .main(sourceAudioIndex), language: language, title: title)
        }
    }

    public struct Subtitle: Sendable, Hashable {
        public var path: String
        public var language: String?
        public var title: String?
        public var forced: Bool
        /// Сдвиг в секундах (поле `shift` из API).
        public var shift: Double
        /// Субтитры уже внутри основного входа (`-map 0:s:N`) — при повторном пережатии готового файла.
        public var embeddedIndex: Int?

        public init(path: String, language: String?, title: String?, forced: Bool, shift: Double) {
            self.path = path
            self.language = language
            self.title = title
            self.forced = forced
            self.shift = shift
        }

        public init(embeddedIndex: Int, language: String?, title: String?, forced: Bool = false) {
            self.init(path: "", language: language, title: title, forced: forced, shift: 0)
            self.embeddedIndex = embeddedIndex
        }
    }

    public var input: Input
    public var audio: [Audio]
    public var subtitles: [Subtitle]
    public var settings: EncodeSettings
    public var sourceVideoCodec: String?
    public var title: String?
    public var output: String
    public var encoders: Set<String>
    /// Субтитры уже подготовлены как ASS со стилем — в MKV копируем как есть.
    public var subtitlesAreStyledASS = false

    public init(
        input: Input,
        audio: [Audio],
        subtitles: [Subtitle],
        settings: EncodeSettings,
        sourceVideoCodec: String?,
        title: String?,
        output: String,
        encoders: Set<String>
    ) {
        self.input = input
        self.audio = audio
        self.subtitles = subtitles
        self.settings = settings
        self.sourceVideoCodec = sourceVideoCodec
        self.title = title
        self.output = output
        self.encoders = encoders
    }

    public init(
        input: String,
        audio: [Audio],
        subtitles: [Subtitle],
        settings: EncodeSettings,
        sourceVideoCodec: String?,
        title: String?,
        output: String,
        encoders: Set<String>
    ) {
        self.init(input: Input(path: input), audio: audio, subtitles: subtitles, settings: settings,
                  sourceVideoCodec: sourceVideoCodec, title: title, output: output, encoders: encoders)
    }

    private var separateInputs: [Input] {
        audio.compactMap { if case .separate(let input) = $0.source { input } else { nil } }
    }

    private func inputArguments(_ input: Input, offset: Double?) -> [String] {
        var args: [String] = []
        if input.isHLSPlaylist {
            args += ["-protocol_whitelist", "file,crypto,data", "-allowed_extensions", "ALL"]
        } else if input.path.hasPrefix("http://") || input.path.hasPrefix("https://") {
            args += ["-user_agent", KpubAPI.userAgent, "-reconnect", "1", "-reconnect_on_network_error", "1", "-reconnect_delay_max", "30"]
        }
        if let offset, offset != 0 { args += ["-itsoffset", String(format: "%.6f", offset)] }
        return args + ["-i", input.path]
    }

    public func arguments() -> [String] {
        let s = settings
        var args = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-nostats", "-progress", "pipe:1"]

        // Раздельные дорожки (видео и озвучки HLS) сдвигаем на общее смещение, сохраняя их взаимную синхронизацию.
        let separate = separateInputs
        let aligned = !separate.isEmpty
        let base = ([input] + separate).map(\.startTime).min() ?? 0
        if aligned { args += ["-copyts"] }

        args += inputArguments(input, offset: aligned ? -base : nil)
        for extra in separate {
            args += inputArguments(extra, offset: -base)
        }
        let firstSubtitleInput = 1 + separate.count
        for sub in subtitles where sub.embeddedIndex == nil {
            if sub.shift != 0 { args += ["-itsoffset", String(format: "%.3f", sub.shift)] }
            args += ["-i", sub.path]
        }

        args += ["-map", "0:v:0"]
        if audio.isEmpty {
            args += ["-map", "0:a?"]
        } else {
            var nextSeparate = 1
            for a in audio {
                switch a.source {
                case .main(let index):
                    args += ["-map", "0:a:\(index)"]
                case .separate:
                    args += ["-map", "\(nextSeparate):a:0"]
                    nextSeparate += 1
                }
            }
        }
        var nextSubtitleInput = firstSubtitleInput
        for sub in subtitles {
            if let embedded = sub.embeddedIndex {
                args += ["-map", "0:s:\(embedded)"]
            } else {
                args += ["-map", "\(nextSubtitleInput):0"]
                nextSubtitleInput += 1
            }
        }
        args += ["-map_metadata", "-1", "-map_chapters", "-1"]

        // Видео
        switch s.videoCodec {
        case .copy:
            args += ["-c:v", "copy"]
            if s.container == .mp4, sourceVideoCodec == "hevc" { args += ["-tag:v", "hvc1"] }
        case .hevcHardware:
            args += ["-c:v", "hevc_videotoolbox", "-b:v", "\(s.videoBitrateKbps)k", "-tag:v", "hvc1"]
        case .h264Hardware:
            args += ["-c:v", "h264_videotoolbox", "-b:v", "\(s.videoBitrateKbps)k", "-profile:v", "high"]
        case .hevcSoftware:
            args += ["-c:v", "libx265", "-crf", "\(s.crf)", "-preset", "medium", "-x265-params", "log-level=error", "-tag:v", "hvc1"]
        }
        if s.videoCodec != .copy {
            if s.maxHeight > 0 {
                // Вписываем в рамку 16:9 нужного класса, чтобы широкоформатное кино тоже уменьшалось.
                let maxWidth = s.maxHeight * 16 / 9
                args += ["-vf", "scale='min(\(maxWidth),iw)':'min(\(s.maxHeight),ih)':force_original_aspect_ratio=decrease:force_divisible_by=2"]
            }
            args += ["-pix_fmt", "yuv420p"]
        }

        // Аудио
        switch s.audioMode {
        case .copy:
            args += ["-c:a", "copy"]
        case .aacStereo:
            let encoder = encoders.contains("aac_at") ? "aac_at" : "aac"
            args += ["-c:a", encoder, "-b:a", "\(s.audioBitrateKbps)k", "-ac", "2"]
        }
        for (i, a) in audio.enumerated() {
            if let lang = a.language, !lang.isEmpty { args += ["-metadata:s:a:\(i)", "language=\(lang)"] }
            if let title = a.title, !title.isEmpty {
                args += ["-metadata:s:a:\(i)", "title=\(title)", "-metadata:s:a:\(i)", "handler_name=\(title)"]
            }
            args += ["-disposition:a:\(i)", i == 0 ? "default" : "0"]
        }

        // Субтитры
        if !subtitles.isEmpty {
            args += ["-c:s", s.container == .mp4 ? "mov_text" : (subtitlesAreStyledASS ? "copy" : "srt")]
        }
        for (i, sub) in subtitles.enumerated() {
            if let lang = sub.language, !lang.isEmpty { args += ["-metadata:s:s:\(i)", "language=\(lang)"] }
            if let title = sub.title, !title.isEmpty {
                args += ["-metadata:s:s:\(i)", "title=\(title)", "-metadata:s:s:\(i)", "handler_name=\(title)"]
            }
            args += ["-disposition:s:\(i)", sub.forced ? "forced" : "0"]
        }

        if let title, !title.isEmpty { args += ["-metadata", "title=\(title)"] }
        if s.container == .mp4 { args += ["-movflags", "+faststart"] }
        args += ["-max_muxing_queue_size", "9999", output]
        return args
    }
}

public enum TranscodeError: LocalizedError {
    case ffmpegNotFound
    case ffprobeFailed(String)
    case ffmpegFailed(Int32, String)
    case noVideoStream

    public var errorDescription: String? {
        switch self {
        case .ffmpegNotFound: "ffmpeg не найден. Установите: brew install ffmpeg (или укажите путь в настройках)."
        case .ffprobeFailed(let msg): "ffprobe не смог прочитать файл: \(msg)"
        case .ffmpegFailed(let code, let msg): "ffmpeg завершился с кодом \(code): \(msg)"
        case .noVideoStream: "В файле нет видеопотока."
        }
    }
}

public struct TranscodeProgress: Sendable {
    public var fraction: Double
    public var speed: String?
}

public enum FFmpegRunner {
    /// Запускает ffmpeg и сообщает прогресс (доля от `duration`). Отмена задачи убивает процесс.
    public static func run(
        _ tools: FFmpegTools,
        plan: TranscodePlan,
        duration: Double?,
        onProgress: @escaping @Sendable (TranscodeProgress) -> Void
    ) async throws {
        let parser = ProgressParser(duration: duration, onProgress: onProgress)
        let result = try await ProcessRunner.run(tools.ffmpeg, arguments: plan.arguments()) { line in
            parser.consume(line)
        }
        try Task.checkCancellation()
        guard result.status == 0 else {
            throw TranscodeError.ffmpegFailed(result.status, result.stderrTail)
        }
    }

    final class ProgressParser: @unchecked Sendable {
        let duration: Double?
        let onProgress: @Sendable (TranscodeProgress) -> Void
        private var outTime: Double = 0
        private var speed: String?

        init(duration: Double?, onProgress: @escaping @Sendable (TranscodeProgress) -> Void) {
            self.duration = duration
            self.onProgress = onProgress
        }

        func consume(_ line: String) {
            guard let eq = line.firstIndex(of: "=") else { return }
            let key = line[..<eq]
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "out_time_us":
                if let us = Double(value) { outTime = us / 1_000_000 }
            case "speed":
                speed = value == "N/A" ? nil : value
            case "progress":
                let fraction: Double
                if value == "end" {
                    fraction = 1
                } else if let duration, duration > 0 {
                    fraction = min(max(outTime / duration, 0), 0.999)
                } else {
                    fraction = 0
                }
                onProgress(TranscodeProgress(fraction: fraction, speed: speed))
            default:
                break
            }
        }
    }
}
