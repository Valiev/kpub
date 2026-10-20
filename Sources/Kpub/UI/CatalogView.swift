import KpubCore
import SwiftUI

typealias PageLoader = @Sendable (KpubAPI, Int, ItemSort, String?) async throws -> ItemsResponse

/// Типы контента kino.pub (значения `type` в API).
let contentTypes: [(id: String, title: String)] = [
    ("serial", "Сериалы"), ("movie", "Фильмы"), ("tvshow", "ТВ-шоу"), ("4k", "4K"), ("3d", "3D"),
    ("concert", "Концерты"), ("documovie", "Документальные фильмы"), ("docuserial", "Документальные сериалы"),
]

private struct QueryKey: Hashable {
    var sort: ItemSort
    var type: String?
}

/// Сетка постеров с подгрузкой страниц.
struct CatalogView: View {
    @Environment(AppModel.self) private var model
    let title: String
    let sortable: Bool
    /// Показать переключатель типа контента (для разделов, где API требует `type`).
    let typePicker: Bool
    /// Скрывать тайтлы (например, убранные из открытого списка).
    let isVisible: ((Item) -> Bool)?
    let loader: PageLoader

    @State private var items: [Item] = []
    @State private var page = 0
    @State private var hasMore = true
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var sort: ItemSort = .updated
    @State private var type: String?

    init(title: String, sortable: Bool, typePicker: Bool = false, defaultSort: ItemSort = .updated,
         isVisible: ((Item) -> Bool)? = nil, loader: @escaping PageLoader) {
        _sort = State(initialValue: defaultSort)
        self.title = title
        self.sortable = sortable
        self.typePicker = typePicker
        self.isVisible = isVisible
        self.loader = loader
        _type = State(initialValue: typePicker ? contentTypes[0].id : nil)
    }

    var body: some View {
        ScrollView {
            PosterGrid(items: isVisible.map { filter in items.filter(filter) } ?? items) { item in
                if item.id == items.last?.id { Task { await loadMore() } }
            }
            footer
        }
        .navigationTitle(title)
        .toolbar {
            PosterSizeSlider()
            if typePicker {
                Picker("Тип", selection: $type) {
                    ForEach(contentTypes, id: \.id) { Text($0.title).tag(Optional($0.id)) }
                }
                .pickerStyle(.menu)
            }
            if sortable {
                Picker("Сортировка", selection: $sort) {
                    ForEach(ItemSort.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
            }
            Button {
                Task { await reload() }
            } label: {
                Label("Обновить", systemImage: "arrow.clockwise")
            }
        }
        .task(id: QueryKey(sort: sort, type: type)) { await reload() }
    }

    @ViewBuilder
    private var footer: some View {
        if isLoading {
            ProgressView().padding()
        } else if let errorText {
            VStack(spacing: 8) {
                Text(errorText).foregroundStyle(.red)
                Button("Повторить") { Task { await loadMore() } }
            }
            .padding()
        } else if items.isEmpty {
            ContentUnavailableView("Пусто", systemImage: "film.stack")
                .padding(.top, 80)
        }
    }

    private func reload() async {
        items = []
        page = 0
        hasMore = true
        await loadMore()
    }

    private func loadMore() async {
        guard !isLoading, hasMore else { return }
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        do {
            let response = try await loader(model.api, page + 1, sort, type)
            page += 1
            let known = Set(items.map(\.id))
            items += response.items.filter { !known.contains($0.id) }
            hasMore = response.pagination?.hasMore ?? false
        } catch is CancellationError {
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// Ширина постера в сетке — общая для всех разделов, меняется слайдером и ⌘= / ⌘−.
enum PosterSize {
    static let key = "posterWidth"
    static let range: ClosedRange<Double> = 100...320
    static let defaultWidth: Double = 160
    static let step: Double = 20
}

struct PosterSizeSlider: View {
    @AppStorage(PosterSize.key) private var width = PosterSize.defaultWidth

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.grid.3x3").imageScale(.small).foregroundStyle(.secondary)
            Slider(value: $width, in: PosterSize.range)
                .frame(width: 120)
                .controlSize(.small)
            Image(systemName: "square.grid.2x2").imageScale(.medium).foregroundStyle(.secondary)
        }
        .help("Размер карточек (⌘= крупнее, ⌘− мельче)")
    }
}

struct PosterGrid: View {
    @AppStorage(PosterSize.key) private var width = PosterSize.defaultWidth
    let items: [Item]
    var onAppear: (Item) -> Void = { _ in }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: width, maximum: width * 1.25), spacing: width * 0.11)],
                  spacing: width * 0.14) {
            ForEach(items) { item in
                NavigationLink(value: item) {
                    PosterCard(item: item)
                }
                .buttonStyle(.plain)
                .contextMenu { ItemListsMenu(item: item) }
                .onAppear { onAppear(item) }
            }
        }
        .padding(20)
    }
}

struct PosterCard: View {
    let item: Item
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PosterImage(url: item.posterURL)
                .aspectRatio(2 / 3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(radius: hovering ? 8 : 2)
                .scaleEffect(hovering ? 1.03 : 1)
                .animation(.easeOut(duration: 0.15), value: hovering)
            Text(item.title)
                .font(.callout.weight(.medium))
                .lineLimit(2)
            HStack(spacing: 6) {
                if let year = item.year { Text(String(year)) }
                if let r = item.kinopoiskRating ?? item.imdbRating, r > 0 {
                    Label(String(format: "%.1f", r), systemImage: "star.fill")
                        .labelStyle(.titleAndIcon)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

struct PosterImage: View {
    let url: URL?
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
                    .overlay(Image(systemName: "film").font(.title).foregroundStyle(.tertiary))
            }
        }
        .task(id: url) {
            image = nil
            guard let url else { return }
            let data = await PosterCache.shared.data(for: url)
            guard !Task.isCancelled, let data else { return }
            image = NSImage(data: data)
        }
    }
}

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var items: [Item] = []
    @State private var isLoading = false
    @State private var errorText: String?

    var body: some View {
        ScrollView {
            if isLoading {
                ProgressView().padding(40)
            } else if let errorText {
                Text(errorText).foregroundStyle(.red).padding(40)
            } else if items.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? "Что будем смотреть?" : "Ничего не нашлось",
                    systemImage: "magnifyingglass",
                    description: Text(query.isEmpty ? "Введите название фильма или сериала" : "Попробуйте другое название")
                )
                .padding(.top, 80)
            }
            PosterGrid(items: items)
        }
        .navigationTitle("Поиск")
        .toolbar { PosterSizeSlider() }
        .searchable(text: $query, placement: .toolbar, prompt: "Название фильма или сериала")
        .task(id: query) {
            let text = query.trimmingCharacters(in: .whitespaces)
            guard text.count >= 2 else {
                items = []
                return
            }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            isLoading = true
            errorText = nil
            defer { isLoading = false }
            do {
                items = try await model.api.search(text).items
            } catch is CancellationError {
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}
