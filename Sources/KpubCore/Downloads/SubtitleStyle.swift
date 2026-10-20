import Foundation

/// Насколько заметны субтитры: непрозрачность текста и размер. Одна настройка на всё приложение.
public struct SubtitleStyle: Codable, Hashable, Sendable {
    /// 0.2…1 — непрозрачность текста (1 — как обычно).
    public var opacity: Double
    /// 0.7…1.4 — множитель размера.
    public var scale: Double

    public init(opacity: Double = 1, scale: Double = 1) {
        self.opacity = opacity
        self.scale = scale
    }

    public static let opacityRange: ClosedRange<Double> = 0.2...1
    public static let scaleRange: ClosedRange<Double> = 0.7...1.4

    public var isDefault: Bool { opacity >= 0.995 && abs(scale - 1) < 0.01 }

    /// Альфа в ASS: 00 — непрозрачно, FF — полностью прозрачно.
    static func assAlpha(_ opacity: Double) -> String {
        String(format: "%02X", Int(((1 - min(max(opacity, 0), 1)) * 255).rounded()))
    }

    /// Строка стиля Default для ASS (PlayResY 288, как в заголовке ffmpeg).
    /// Обводка тоньше и прозрачнее текста, тени нет — субтитры не «кричат».
    public var assStyleLine: String {
        let text = Self.assAlpha(opacity)
        let outline = Self.assAlpha(opacity * 0.55)
        let size = Int((16 * scale).rounded())
        return "Style: Default,Helvetica Neue,\(size),&H\(text)FFFFFF,&H\(text)FFFFFF,&H\(outline)000000,&HFF000000,"
            + "0,0,0,0,100,100,0,0,1,0.8,0,2,10,10,12,1"
    }

    /// Подставляет наш стиль вместо строк Style: в разделе стилей ASS-файла.
    public func apply(toASS text: String) -> String {
        var inStyles = false
        var replaced = false
        var lines: [String] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { inStyles = trimmed.lowercased().hasPrefix("[v4") }
            if inStyles, trimmed.hasPrefix("Style:") {
                if !replaced { lines.append(assStyleLine) }
                replaced = true
                continue
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}

public enum SubtitleStyler {
    /// SRT/VTT-файл или N-й поток субтитров медиафайла → ASS с нашим стилем.
    public static func makeStyledASS(
        _ tools: FFmpegTools, input: String, streamIndex: Int? = nil, style: SubtitleStyle, output: String
    ) async throws {
        var args = ["-hide_banner", "-loglevel", "error", "-y", "-i", input]
        if let streamIndex { args += ["-map", "0:s:\(streamIndex)"] }
        args += ["-c:s", "ass", "-f", "ass", output]
        let result = try await ProcessRunner.run(tools.ffmpeg, arguments: args)
        guard result.status == 0 else { throw TranscodeError.ffmpegFailed(result.status, result.stderrTail) }
        let text = try String(contentsOfFile: output, encoding: .utf8)
        try style.apply(toASS: text).write(toFile: output, atomically: true, encoding: .utf8)
    }

    /// Добавляет в готовый файл ещё одну дорожку субтитров (без пережатия; в MKV — со стилем, если он задан).
    public static func addSubtitle(
        _ tools: FFmpegTools, file: URL, subtitle: URL, language: String, title: String, style: SubtitleStyle
    ) async throws {
        let probe = try await FFprobe.probe(tools, input: file.path)
        let fm = FileManager.default
        let dir = file.deletingLastPathComponent().appendingPathComponent(".kpub-addsub-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let isMP4 = ["mp4", "m4v", "mov"].contains(file.pathExtension.lowercased())
        var input = subtitle.path
        var newCodec = isMP4 ? "mov_text" : "srt"
        if !isMP4, !style.isDefault {
            input = dir.appendingPathComponent("new.ass").path
            try await makeStyledASS(tools, input: subtitle.path, style: style, output: input)
            newCodec = "copy"
        }
        let index = probe.subtitles.count
        let output = dir.appendingPathComponent("out.\(file.pathExtension)")
        var args = ["-hide_banner", "-nostdin", "-loglevel", "error", "-y", "-i", file.path, "-i", input,
                    "-map", "0", "-map", "1:0", "-c", "copy", "-c:s:\(index)", newCodec,
                    "-metadata:s:s:\(index)", "language=\(language)",
                    "-metadata:s:s:\(index)", "title=\(title)", "-metadata:s:s:\(index)", "handler_name=\(title)",
                    "-disposition:s:\(index)", "0"]
        if isMP4 { args += ["-movflags", "+faststart"] }
        args.append(output.path)
        let result = try await ProcessRunner.run(tools.ffmpeg, arguments: args)
        guard result.status == 0 else { throw TranscodeError.ffmpegFailed(result.status, result.stderrTail) }
        _ = try fm.replaceItemAt(file, withItemAt: output)
    }

    /// Пересобирает готовый файл: видео и звук копируются, субтитры получают новый стиль. Быстро, без пережатия.
    /// Возвращает false, если субтитров в файле нет.
    @discardableResult
    public static func restyle(_ tools: FFmpegTools, file: URL, style: SubtitleStyle) async throws -> Bool {
        let probe = try await FFprobe.probe(tools, input: file.path)
        guard !probe.subtitles.isEmpty else { return false }
        let fm = FileManager.default
        // Временная папка рядом с файлом — чтобы замена была на том же диске.
        let dir = file.deletingLastPathComponent().appendingPathComponent(".kpub-restyle-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        var args = ["-hide_banner", "-nostdin", "-loglevel", "error", "-y", "-i", file.path]
        for i in probe.subtitles.indices {
            let ass = dir.appendingPathComponent("s\(i).ass").path
            try await makeStyledASS(tools, input: file.path, streamIndex: i, style: style, output: ass)
            args += ["-i", ass]
        }
        args += ["-map", "0:v", "-map", "0:a?"]
        for i in probe.subtitles.indices { args += ["-map", "\(i + 1):0"] }
        let isMP4 = ["mp4", "m4v", "mov"].contains(file.pathExtension.lowercased())
        args += ["-c:v", "copy", "-c:a", "copy", "-c:s", isMP4 ? "mov_text" : "copy"]
        for (i, sub) in probe.subtitles.enumerated() {
            if let lang = sub.language { args += ["-metadata:s:s:\(i)", "language=\(lang)"] }
            if let title = sub.title { args += ["-metadata:s:s:\(i)", "title=\(title)", "-metadata:s:s:\(i)", "handler_name=\(title)"] }
        }
        if isMP4 { args += ["-movflags", "+faststart"] }
        let output = dir.appendingPathComponent("out.\(file.pathExtension)")
        args.append(output.path)

        let result = try await ProcessRunner.run(tools.ffmpeg, arguments: args)
        guard result.status == 0 else { throw TranscodeError.ffmpegFailed(result.status, result.stderrTail) }
        _ = try fm.replaceItemAt(file, withItemAt: output)
        return true
    }
}
