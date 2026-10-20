import Foundation

/// Превращает выбор пользователя (видео, качество, дорожки, субтитры) в задания на загрузку.
public enum DownloadRequest {
    public struct Entry: Sendable {
        public var season: Int?
        public var video: Video

        public init(season: Int?, video: Video) {
            self.season = season
            self.video = video
        }
    }

    /// Ссылка на источник. hls4 — основной вариант: в нём все озвучки отдельными дорожками.
    /// Прямой mp4 CDN kino.pub почти не отдаёт (и в нём одна озвучка), поэтому он лишь запасной.
    public static func sourceURL(of file: MediaFile) -> (url: URL, kind: DownloadJob.SourceKind)? {
        if let hls4 = file.url?.hls4 { return (hls4, .hls) }
        if let http = file.url?.http { return (http, .file) }
        if let hls = file.url?.hls2 ?? file.url?.hls { return (hls, .hls) }
        return nil
    }

    /// `preferredHeight == 0` — выбрать автоматически под настройки пережатия.
    public static func pickFile(_ files: [MediaFile], preferredHeight: Int, settings: EncodeSettings) -> MediaFile? {
        let sorted = files.filter { sourceURL(of: $0) != nil }.sorted { $0.height < $1.height }
        guard !sorted.isEmpty else { return nil }
        if preferredHeight > 0 {
            return sorted.last { $0.height <= preferredHeight } ?? sorted.first
        }
        if settings.videoCodec != .copy, settings.maxHeight > 0 {
            // Самый маленький источник, которого хватает на целевое разрешение.
            return sorted.first { $0.height >= settings.maxHeight } ?? sorted.last
        }
        // Без пережатия по умолчанию не тащим 4K.
        return sorted.last { $0.height <= 1080 } ?? sorted.last
    }

    /// Сопоставляет выбранные (на образцовом видео) озвучки с дорожками конкретного видео.
    public static func matchAudio(_ selected: [AudioTrack], in video: Video) -> [AudioTrack] {
        guard !video.audios.isEmpty else { return [] }
        var result: [AudioTrack] = []
        for track in selected {
            if let match = video.audios.first(where: { $0.matchKey == track.matchKey && !result.contains($0) }) {
                result.append(match)
            } else if let byIndex = video.audios.first(where: { $0.index == track.index && !result.contains($0) }) {
                result.append(byIndex)
            }
        }
        return result.isEmpty ? [video.audios[0]] : result
    }

    public static func matchSubtitles(_ selected: [SubtitleTrack], in video: Video) -> [SubtitleTrack] {
        let keys = Set(selected.map(\.matchKey))
        var seen = Set<String>()
        return video.subtitles.filter { sub in
            guard sub.url != nil, keys.contains(sub.matchKey), !seen.contains(sub.matchKey) else { return false }
            seen.insert(sub.matchKey)
            return true
        }
    }

    public static func makeJobs(
        item: Item,
        entries: [Entry],
        preferredHeight: Int,
        audio selectedAudio: [AudioTrack],
        subtitles selectedSubtitles: [SubtitleTrack],
        settings: EncodeSettings,
        root: URL,
        externalSubtitleLanguages: [String] = []
    ) -> [DownloadJob] {
        let partCount = item.videos?.count ?? 1
        return entries.compactMap { entry in
            let video = entry.video
            guard let file = pickFile(video.files, preferredHeight: preferredHeight, settings: settings),
                  let source = sourceURL(of: file)
            else { return nil }

            let audio = matchAudio(selectedAudio, in: video).map { track in
                SelectedAudio(
                    apiIndex: track.index,
                    streamPosition: video.audios.firstIndex(of: track) ?? 0,
                    language: Language.iso639_2(track.lang),
                    title: track.trackTitle
                )
            }
            let subs = matchSubtitles(selectedSubtitles, in: video).compactMap { sub -> SelectedSubtitle? in
                guard let url = sub.url else { return nil }
                return SelectedSubtitle(url: url, language: Language.iso639_2(sub.lang), forced: sub.forced, shift: sub.shift)
            }
            // Внешние субтитры ищем только для языков, которых у этого видео на кинопабе нет совсем.
            let present = Set(video.subtitles.compactMap { Language.iso639_2($0.lang) })
            let external = item.imdb == nil ? [] : externalSubtitleLanguages.filter { !present.contains($0) }
            let output = OutputNaming.path(
                root: root, title: item.title, year: item.year, isSerial: item.isSerial,
                season: entry.season, episode: video.number, episodeTitle: video.title,
                partCount: partCount, ext: settings.container.fileExtension
            )
            return DownloadJob(
                itemID: item.id, videoID: video.id, showTitle: item.title, originalTitle: item.originalTitle,
                year: item.year, isSerial: item.isSerial, seasonNumber: entry.season,
                episodeNumber: item.isSerial || partCount > 1 ? video.number : nil, episodeTitle: video.title,
                posterURL: item.posterURL, duration: video.duration, sourceHeight: file.height,
                sourceURL: source.url, sourceKind: source.kind, audio: audio, subtitles: subs,
                settings: settings, outputPath: output,
                externalSubtitleLanguages: external, imdbID: item.imdb
            )
        }
    }
}
