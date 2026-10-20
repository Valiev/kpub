import AppKit
import KpubCore
import SwiftUI

/// Скачанный тайтл: фильм или сериал с готовыми сериями.
struct LibraryTitle: Identifiable {
    struct SeasonGroup: Identifiable {
        let number: Int?
        let jobs: [DownloadJob]
        var id: Int { number ?? -1 }
    }

    let id: Int
    let title: String
    let year: Int?
    let poster: URL?
    let isSerial: Bool
    let jobs: [DownloadJob]
    let latest: Date

    var size: Int64 { jobs.compactMap(\.outputSize).reduce(0, +) }
    var files: [URL] { jobs.map(\.outputURL) }

    var seasons: [SeasonGroup] {
        Dictionary(grouping: jobs, by: \.seasonNumber)
            .map { SeasonGroup(number: $0.key, jobs: $0.value) }
            .sorted { ($0.number ?? 0) < ($1.number ?? 0) }
    }

    var item: Item { Item(stubID: id, title: title, year: year, poster: poster, isSerial: isSerial) }

    static func group(_ jobs: [DownloadJob]) -> [LibraryTitle] {
        Dictionary(grouping: jobs.filter { $0.status == .completed }, by: \.itemID)
            .compactMap { id, list -> LibraryTitle? in
                guard let first = list.first else { return nil }
                let sorted = list.sorted {
                    ($0.seasonNumber ?? 0, $0.episodeNumber ?? 0) < ($1.seasonNumber ?? 0, $1.episodeNumber ?? 0)
                }
                return LibraryTitle(
                    id: id, title: first.showTitle, year: first.year, poster: first.posterURL, isSerial: first.isSerial,
                    jobs: sorted, latest: list.compactMap(\.completedAt).max() ?? first.createdAt
                )
            }
            .sorted { $0.latest > $1.latest }
    }
}

/// Раздел «Скачанное»: что есть на диске, просмотр, плейлисты, переход к файлам.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""

    private var titles: [LibraryTitle] {
        let all = LibraryTitle.group(model.downloads.jobs)
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { title in
            title.title.lowercased().contains(q) || title.jobs.contains { ($0.episodeTitle ?? "").lowercased().contains(q) }
        }
    }

    var body: some View {
        let titles = titles
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(titles) { LibraryTitleCard(title: $0) }
            }
            .padding(20)
        }
        .overlay {
            if titles.isEmpty {
                ContentUnavailableView(
                    search.isEmpty ? "Пока ничего не скачано" : "Ничего не нашлось",
                    systemImage: "film.stack",
                    description: Text(search.isEmpty ? "Готовые фильмы и серии появятся здесь" : "")
                )
            }
        }
        .navigationTitle("Скачанное")
        .navigationSubtitle(subtitle(titles))
        .searchable(text: $search, placement: .toolbar, prompt: "Найти в скачанном")
        .toolbar {
            Button {
                try? FileManager.default.createDirectory(at: model.downloadsFolder, withIntermediateDirectories: true)
                NSWorkspace.shared.open(model.downloadsFolder)
            } label: {
                Label("Открыть папку", systemImage: "folder")
            }
        }
    }

    private func subtitle(_ titles: [LibraryTitle]) -> String {
        let files = titles.reduce(0) { $0 + $1.jobs.count }
        guard files > 0 else { return "" }
        return "\(titles.count) тайтл. · \(files) файл. · \(Formatting.bytes(titles.reduce(0) { $0 + $1.size }))"
    }
}

private struct LibraryTitleCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let title: LibraryTitle

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                NavigationLink(value: title.item) {
                    PosterImage(url: title.poster)
                        .frame(width: 72, height: 108)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("Открыть карточку")

                VStack(alignment: .leading, spacing: 6) {
                    NavigationLink(value: title.item) {
                        Text(title.title).font(.title3.bold())
                    }
                    .buttonStyle(.plain)
                    Text(meta).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button {
                            Playback.play(title.files, title: title.title, openWindow: openWindow)
                        } label: {
                            Label(title.jobs.count > 1 ? "Смотреть всё" : "Смотреть", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        OpenInMenu(files: title.files, title: title.title)
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting(title.files)
                        } label: {
                            Label("Показать в Finder", systemImage: "folder")
                        }
                    }
                    .controlSize(.small)
                    .padding(.top, 2)
                }
                Spacer()
            }

            if title.isSerial || title.jobs.count > 1 {
                ForEach(title.seasons) { season in
                    if title.isSerial {
                        seasonHeader(season)
                    }
                    VStack(spacing: 0) {
                        ForEach(Array(season.jobs.enumerated()), id: \.element.id) { offset, job in
                            LibraryFileRow(job: job) {
                                Playback.play(season.jobs.map(\.outputURL), title: seasonTitle(season), start: offset, openWindow: openWindow)
                            }
                            if offset < season.jobs.count - 1 { Divider() }
                        }
                    }
                    .background(.background, in: RoundedRectangle(cornerRadius: 8))
                }
            } else if let job = title.jobs.first {
                LibraryFileRow(job: job) {
                    Playback.play([job.outputURL], title: title.title, openWindow: openWindow)
                }
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .contextMenu {
            Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting(title.files) }
            Button("Применить стиль субтитров") { model.restyleSubtitles(title.files) }
            Button("Найти английские субтитры, где их нет") { model.fetchMissingSubtitles(title.jobs) }
            Divider()
            Button("Удалить всё в Корзину", role: .destructive) {
                for job in title.jobs { model.downloads.remove(job.id, deleteFile: true) }
            }
        }
    }

    private var meta: String {
        var parts: [String] = []
        if let year = title.year { parts.append(String(year)) }
        if title.isSerial {
            let n = title.jobs.count
            parts.append("\(n) \(n % 10 == 1 && n % 100 != 11 ? "серия" : (2...4).contains(n % 10) && !(12...14).contains(n % 100) ? "серии" : "серий")")
        }
        parts.append(Formatting.bytes(title.size))
        return parts.joined(separator: " · ")
    }

    private func seasonTitle(_ season: LibraryTitle.SeasonGroup) -> String {
        season.number.map { "\(title.title) — Сезон \($0)" } ?? title.title
    }

    private func seasonHeader(_ season: LibraryTitle.SeasonGroup) -> some View {
        let files = season.jobs.map(\.outputURL)
        let size = season.jobs.compactMap(\.outputSize).reduce(0, +)
        return HStack(spacing: 8) {
            Text(season.number.map { "Сезон \($0)" } ?? "Без сезона").font(.headline)
            Text("\(season.jobs.count) эп. · \(Formatting.bytes(size))").foregroundStyle(.secondary)
            Spacer()
            Button {
                Playback.play(files, title: seasonTitle(season), openWindow: openWindow)
            } label: {
                Label("Смотреть сезон", systemImage: "play.fill")
            }
            OpenInMenu(files: files, title: seasonTitle(season), label: "Плейлист в…")
            Menu {
                Button("Применить стиль субтитров к сезону") { model.restyleSubtitles(files) }
                Button("Найти английские субтитры, где их нет") { model.fetchMissingSubtitles(season.jobs) }
                Button("Удалить сезон в Корзину", role: .destructive) {
                    for job in season.jobs { model.downloads.remove(job.id, deleteFile: true) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Button {
                if let folder = files.first?.deletingLastPathComponent() { NSWorkspace.shared.open(folder) }
            } label: {
                Label("Папка", systemImage: "folder")
            }
        }
        .controlSize(.small)
        .padding(.top, 4)
    }
}

private struct LibraryFileRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let job: DownloadJob
    let onPlay: () -> Void

    private var exists: Bool { FileManager.default.fileExists(atPath: job.outputPath) }

    var body: some View {
        HStack(spacing: 10) {
            if job.isSerial {
                Text(String(format: "S%02dE%02d", job.seasonNumber ?? 1, job.episodeNumber ?? 1))
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            } else if let n = job.episodeNumber {
                Text("Часть \(n)").foregroundStyle(.secondary)
            }
            Text(job.isSerial ? (job.episodeTitle?.nonEmptyTrimmed ?? "Эпизод \(job.episodeNumber ?? 0)") : job.outputURL.deletingPathExtension().lastPathComponent)
                .lineLimit(1)
            Spacer(minLength: 8)
            if exists {
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button(action: onPlay) { Image(systemName: "play.fill") }
                    .buttonStyle(.borderless)
                    .help("Смотреть (дальше — следующие серии)")
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([job.outputURL])
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("Показать в Finder")
            } else {
                Label("файл не найден", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button("Убрать") { model.downloads.remove(job.id) }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if exists { onPlay() } }
        .contextMenu {
            if exists {
                Button("Смотреть") { onPlay() }
                OpenInMenu(files: [job.outputURL], title: job.displayTitle)
                Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([job.outputURL]) }
                Button("Применить стиль субтитров") { model.restyleSubtitles([job.outputURL]) }
                Button("Найти английские субтитры на OpenSubtitles") { model.fetchMissingSubtitles([job]) }
                Divider()
                Button("Удалить в Корзину", role: .destructive) { model.downloads.remove(job.id, deleteFile: true) }
            } else {
                Button("Убрать из списка") { model.downloads.remove(job.id) }
            }
        }
    }

    private var details: String {
        var parts: [String] = []
        if let d = job.duration, d > 0 { parts.append(Formatting.duration(d)) }
        if let size = job.outputSize { parts.append(Formatting.bytes(size)) }
        let s = job.settings
        switch s.videoCodec {
        case .copy: parts.append("\(job.sourceHeight)p")
        case .hevcHardware, .hevcSoftware: parts.append("HEVC \(s.maxHeight == 0 ? job.sourceHeight : min(s.maxHeight, job.sourceHeight))p")
        case .h264Hardware: parts.append("H.264 \(s.maxHeight == 0 ? job.sourceHeight : min(s.maxHeight, job.sourceHeight))p")
        }
        let audio = (job.downloadedAudio?.isEmpty == false ? job.downloadedAudio! : job.audio)
            .compactMap { $0.language?.uppercased() }
        if !audio.isEmpty { parts.append("🔊 " + audio.joined(separator: ", ")) }
        let subs = job.subtitles.compactMap { $0.language?.uppercased() } + (job.externalSubtitleLanguages ?? []).map { $0.uppercased() }
        if !subs.isEmpty { parts.append("💬 " + subs.joined(separator: ", ")) }
        parts.append(job.outputURL.pathExtension.uppercased())
        return parts.joined(separator: " · ")
    }
}
