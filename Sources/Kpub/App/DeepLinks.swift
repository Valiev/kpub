import Foundation
import KpubCore

/// Ссылки kpub://download?… — ставят загрузку тем же кодом, что и окно «Скачать».
///
/// Параметры:
/// - `item` — id тайтла (обязательно);
/// - `season`, `episodes` — номер сезона и список серий через запятую (по умолчанию все);
/// - `audio` — озвучки через запятую: язык (`eng`) или номер дорожки из API (`3`); первая — по умолчанию;
/// - `quality` — качество источника (720, 1080…); по умолчанию авто;
/// - `subs` — языки субтитров кинопаба через запятую;
/// - `external` — языки субтитров с OpenSubtitles, если на кинопабе нет (по умолчанию — из настроек);
/// - `preset` — профиль пережатия (compact720, tiny480, quality1080, x265_720, original), `container` — mp4 / mkv.
///
/// Пример: kpub://download?item=89458&season=4&audio=eng&quality=720&external=eng
extension AppModel {
    /// kpub://subtitles?item=66136&season=2&episodes=7&lang=eng — найти субтитры для уже скачанных серий.
    private func handleSubtitlesLink(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let itemID = value("item").flatMap(Int.init) else {
            bookmarks.toast = "В ссылке нет item"
            return
        }
        let season = value("season").flatMap(Int.init)
        let episodes = value("episodes").map { Set($0.split(separator: ",").compactMap { Int($0) }) }
        let jobs = downloads.jobs.filter {
            $0.itemID == itemID && $0.status == .completed && (season == nil || $0.seasonNumber == season)
                && (episodes == nil || episodes!.contains($0.episodeNumber ?? -1))
        }
        guard !jobs.isEmpty else {
            bookmarks.toast = "Нет скачанных файлов под эту ссылку"
            return
        }
        fetchMissingSubtitles(jobs, language: Language.iso639_2(value("lang") ?? "eng") ?? "eng")
    }

    func handleDeepLink(_ url: URL) async {
        guard url.scheme == "kpub" else { return }
        guard isAuthorized else {
            bookmarks.toast = "Сначала войдите в аккаунт"
            return
        }
        if url.host() == "subtitles" {
            handleSubtitlesLink(url)
            return
        }
        guard url.host() == "download" else {
            bookmarks.toast = "Неизвестная ссылка: \(url.host() ?? "")"
            return
        }
        let params = Dictionary(
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { _, last in last }
        )
        func list(_ key: String) -> [String]? {
            params[key].map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        }
        guard let itemID = params["item"].flatMap(Int.init) else {
            bookmarks.toast = "В ссылке нет item"
            return
        }

        let item: Item
        do {
            item = try await api.item(id: itemID)
        } catch {
            bookmarks.toast = "Не удалось открыть тайтл \(itemID): \(error.localizedDescription)"
            return
        }

        let season = params["season"].flatMap(Int.init)
        let episodes = list("episodes").map { Set($0.compactMap(Int.init)) }
        var entries: [DownloadRequest.Entry] = []
        if let seasons = item.seasons, !seasons.isEmpty {
            for s in seasons.sorted(by: { $0.number < $1.number }) where season == nil || s.number == season {
                for e in s.episodes.sorted(by: { $0.number < $1.number }) where episodes?.contains(e.number) ?? true {
                    entries.append(.init(season: s.number, video: e))
                }
            }
        } else {
            for v in (item.videos ?? []).sorted(by: { $0.number < $1.number }) where episodes?.contains(v.number) ?? true {
                entries.append(.init(season: nil, video: v))
            }
        }
        // Уже скачанное или стоящее в очереди не дублируем.
        let known = Set(downloads.jobs.filter { $0.status != .failed }.map(\.videoID))
        entries.removeAll { known.contains($0.video.id) }
        guard let reference = entries.first?.video else {
            bookmarks.toast = "«\(item.title)»: новых серий для загрузки нет"
            return
        }

        var audio: [AudioTrack] = []
        for token in list("audio") ?? [] {
            let match = Int(token).flatMap { idx in reference.audios.first { $0.index == idx } }
                ?? reference.audios.first { Language.iso639_2($0.lang) == Language.iso639_2(token) }
            if let match, !audio.contains(match) { audio.append(match) }
        }
        if audio.isEmpty, let first = reference.audios.first { audio = [first] }

        let subLangs = Set((list("subs") ?? []).compactMap { Language.iso639_2($0) })
        var seen = Set<String>()
        let subtitles = entries.flatMap(\.video.subtitles).filter {
            $0.url != nil && subLangs.contains(Language.iso639_2($0.lang) ?? "") && seen.insert($0.matchKey).inserted
        }
        let external = (list("external") ?? (fetchExternalEnglish ? ["eng"] : [])).compactMap { Language.iso639_2($0) }

        var settings = lastEncodeSettings
        if let preset = params["preset"].flatMap({ id in EncodePreset.all.first { $0.id == id } }) {
            let container = settings.container
            settings = preset.settings
            settings.container = container
        }
        if let container = params["container"].flatMap(EncodeSettings.Container.init(rawValue:)) {
            settings.container = container
        }

        let jobs = DownloadRequest.makeJobs(
            item: item, entries: entries, preferredHeight: params["quality"].flatMap(Int.init) ?? 0,
            audio: audio, subtitles: subtitles, settings: settings, root: downloadsFolder,
            externalSubtitleLanguages: external
        )
        downloads.enqueue(jobs)
        bookmarks.toast = "«\(item.title)»: в загрузки добавлено \(jobs.count) шт."
    }
}
