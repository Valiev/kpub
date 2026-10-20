import AppKit
import KpubCore
import SwiftUI

struct DownloadSheetPayload: Identifiable {
    let id = UUID()
    let item: Item
    let entries: [DownloadRequest.Entry]
}

/// Карточка фильма/сериала: описание, сезоны и эпизоды с выбором для загрузки.
struct ItemDetailView: View {
    @Environment(AppModel.self) private var model
    let preview: Item

    @State private var item: Item?
    @State private var errorText: String?
    @State private var seasonIndex = 0
    @State private var selected: Set<Int> = []
    @State private var sheet: DownloadSheetPayload?

    private var current: Item { item ?? preview }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if let item {
                    if item.isSerial, let seasons = item.seasons, !seasons.isEmpty {
                        seasonsSection(item: item, seasons: seasons)
                    } else if let videos = item.videos, videos.count > 1 {
                        partsSection(item: item, videos: videos)
                    }
                } else if let errorText {
                    VStack(alignment: .leading) {
                        Text(errorText).foregroundStyle(.red)
                        Button("Повторить") { Task { await load() } }
                    }
                } else {
                    ProgressView()
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(current.title)
        .task { await load() }
        .sheet(item: $sheet) { payload in
            DownloadOptionsView(item: payload.item, entries: payload.entries)
        }
    }

    private func load() async {
        errorText = nil
        do {
            item = try await model.api.item(id: preview.id)
        } catch is CancellationError {
        } catch {
            errorText = error.localizedDescription
        }
    }

    // MARK: - Шапка

    private var header: some View {
        HStack(alignment: .top, spacing: 24) {
            PosterImage(url: current.posters?.big ?? current.posterURL)
                .frame(width: 230, height: 345)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .shadow(radius: 6)

            VStack(alignment: .leading, spacing: 10) {
                Text(current.title)
                    .font(.largeTitle.bold())
                    .textSelection(.enabled)
                if let original = current.originalTitle {
                    Text(original).font(.title3).foregroundStyle(.secondary)
                }
                Text(metaLine).foregroundStyle(.secondary)

                HStack(spacing: 14) {
                    if let r = current.kinopoiskRating, r > 0 { rating("КП", r) }
                    if let r = current.imdbRating, r > 0 { rating("IMDb", r) }
                }

                if let voice = current.voice, !voice.isEmpty {
                    infoLine("Озвучка", voice)
                }
                if let director = current.director, !director.isEmpty {
                    personLine("Режиссёр", director, role: .director)
                }
                if let cast = current.cast, !cast.isEmpty {
                    personLine("В ролях", cast, role: .actor)
                }
                if let plot = current.plot, !plot.isEmpty {
                    Text(plot)
                        .font(.body)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .frame(maxWidth: 760, alignment: .leading)
                        .padding(.top, 4)
                }

                actions.padding(.top, 8)
            }
        }
    }

    private var metaLine: String {
        var parts: [String] = []
        if let year = current.year { parts.append(String(year)) }
        let countries = current.countries.map(\.title).filter { !$0.isEmpty }
        if !countries.isEmpty { parts.append(countries.joined(separator: ", ")) }
        let genres = current.genres.map(\.title).filter { !$0.isEmpty }
        if !genres.isEmpty { parts.append(genres.prefix(4).joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    private func rating(_ name: String, _ value: Double) -> some View {
        HStack(spacing: 4) {
            Text(name).font(.caption.bold()).foregroundStyle(.secondary)
            Text(String(format: "%.1f", value)).font(.headline)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
    }

    /// Имена через запятую, каждое — ссылка на все тайтлы с этим человеком.
    private func personLine(_ title: String, _ names: String, role: PersonQuery.Role) -> some View {
        var text = AttributedString(title + ": ")
        text.foregroundColor = .secondary
        let list = names.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for (i, name) in list.enumerated() {
            var part = AttributedString(name)
            part.link = PersonQuery(role: role, name: name).url
            text += part
            if i < list.count - 1 { text += AttributedString(", ") }
        }
        return Text(text)
            .frame(maxWidth: 760, alignment: .leading)
            .help("Нажмите на имя, чтобы увидеть все фильмы и сериалы")
    }

    private func infoLine(_ title: String, _ value: String) -> some View {
        (Text(title + ": ").foregroundStyle(.secondary) + Text(value))
            .lineLimit(2)
            .frame(maxWidth: 760, alignment: .leading)
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 10) {
            if let item {
                if item.isSerial {
                    Button {
                        openSheet(item: item, ids: selected)
                    } label: {
                        Label(selected.isEmpty ? "Выберите эпизоды" : "Скачать выбранные (\(selected.count))",
                              systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(selected.isEmpty)
                } else if let videos = item.videos, !videos.isEmpty {
                    let ids = videos.count > 1 && !selected.isEmpty ? selected : Set(videos.map(\.id))
                    Button {
                        openSheet(item: item, ids: ids)
                    } label: {
                        Label(videos.count > 1 && !selected.isEmpty ? "Скачать выбранные (\(selected.count))" : "Скачать",
                              systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
                    Text("Нет доступных файлов").foregroundStyle(.secondary)
                }
            }
            Menu {
                ItemListsMenu(item: current)
            } label: {
                let inLists = model.bookmarks.folders(containing: current.id)
                Label(inLists.isEmpty ? "В список" : inLists.map(\.title).joined(separator: ", "),
                      systemImage: inLists.isEmpty ? "bookmark" : "bookmark.fill")
            }
            .menuStyle(.button)
            .fixedSize()
            .controlSize(.large)
        }
    }

    private func openSheet(item: Item, ids: Set<Int>) {
        var entries: [DownloadRequest.Entry] = []
        if let seasons = item.seasons, !seasons.isEmpty {
            for season in seasons.sorted(by: { $0.number < $1.number }) {
                for ep in season.episodes.sorted(by: { $0.number < $1.number }) where ids.contains(ep.id) {
                    entries.append(.init(season: season.number, video: ep))
                }
            }
        } else {
            for v in (item.videos ?? []).sorted(by: { $0.number < $1.number }) where ids.contains(v.id) {
                entries.append(.init(season: nil, video: v))
            }
        }
        guard !entries.isEmpty else { return }
        sheet = DownloadSheetPayload(item: item, entries: entries)
    }

    // MARK: - Сезоны и эпизоды

    private func seasonsSection(item: Item, seasons: [Season]) -> some View {
        let sorted = seasons.sorted { $0.number < $1.number }
        let index = min(seasonIndex, sorted.count - 1)
        let season = sorted[index]
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Сезоны").font(.title2.bold())
                Spacer()
                Picker("Сезон", selection: $seasonIndex) {
                    ForEach(sorted.indices, id: \.self) { i in
                        Text("Сезон \(sorted[i].number)").tag(i)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 160)
                .labelsHidden()
            }
            HStack {
                Button("Выбрать весь сезон") { selected.formUnion(season.episodes.map(\.id)) }
                Button("Непросмотренные") {
                    selected.formUnion(season.episodes.filter { ($0.watched ?? 0) <= 0 }.map(\.id))
                }
                Button("Все сезоны") { selected.formUnion(sorted.flatMap { $0.episodes.map(\.id) }) }
                Button("Снять выбор") { selected.removeAll() }
                    .disabled(selected.isEmpty)
            }
            .controlSize(.small)
            episodeList(season.episodes.sorted { $0.number < $1.number }, seasonNumber: season.number)
        }
    }

    private func partsSection(item: Item, videos: [Video]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Части").font(.title2.bold())
            episodeList(videos.sorted { $0.number < $1.number }, seasonNumber: nil)
        }
    }

    private func episodeList(_ episodes: [Video], seasonNumber: Int?) -> some View {
        VStack(spacing: 0) {
            ForEach(episodes) { ep in
                EpisodeRow(
                    episode: ep,
                    seasonNumber: seasonNumber,
                    isSelected: Binding(
                        get: { selected.contains(ep.id) },
                        set: { if $0 { selected.insert(ep.id) } else { selected.remove(ep.id) } }
                    )
                )
                Divider()
            }
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct EpisodeRow: View {
    let episode: Video
    let seasonNumber: Int?
    @Binding var isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: $isSelected)
                .toggleStyle(.checkbox)
                .labelsHidden()
            Text(code)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(episode.title?.nonEmptyTrimmed ?? "Эпизод \(episode.number)")
                .lineLimit(1)
            Spacer()
            if (episode.watched ?? 0) > 0 {
                Image(systemName: "eye.fill").foregroundStyle(.secondary).help("Просмотрено")
            }
            if let best = episode.sortedFiles.first {
                Text(best.quality).font(.caption).foregroundStyle(.secondary)
            }
            if !episode.audios.isEmpty {
                Text("\(episode.audios.count) озв.").font(.caption).foregroundStyle(.secondary)
            }
            if let d = episode.duration, d > 0 {
                Text(Formatting.duration(d)).font(.caption).foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { isSelected.toggle() }
    }

    private var code: String {
        if let seasonNumber { return String(format: "S%02dE%02d", seasonNumber, episode.number) }
        return "Часть \(episode.number)"
    }
}
