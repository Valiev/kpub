import AppKit
import KpubCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.isAuthorized {
                MainView()
                    .modifier(BookmarksUI())
            } else {
                LoginView()
            }
        }
        .onChange(of: model.downloads.activeCount, initial: true) { _, count in
            NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        }
    }
}

enum SidebarItem: Hashable {
    case search
    case fresh
    case catalog(type: String, title: String)
    case watching
    case bookmarks(id: Int, title: String)
    case library
    case downloads

    var title: String {
        switch self {
        case .search: "Поиск"
        case .fresh: "Новинки"
        case .catalog(_, let title): title
        case .watching: "Я смотрю"
        case .bookmarks(_, let title): title
        case .library: "Скачанное"
        case .downloads: "Загрузки"
        }
    }

    var icon: String {
        switch self {
        case .search: "magnifyingglass"
        case .fresh: "sparkles"
        case .catalog(let type, _):
            switch type {
            case "movie": "film"
            case "serial": "tv"
            case "tvshow": "sparkles.tv"
            case "documovie", "docuserial": "globe.europe.africa"
            case "concert": "music.mic"
            case "4k": "4k.tv"
            default: "square.grid.2x2"
            }
        case .watching: "eye"
        case .bookmarks: "bookmark"
        case .library: "film.stack"
        case .downloads: "arrow.down.circle"
        }
    }

    static let catalogs: [SidebarItem] = [
        .catalog(type: "movie", title: "Фильмы"),
        .catalog(type: "serial", title: "Сериалы"),
        .catalog(type: "tvshow", title: "ТВ-шоу"),
        .catalog(type: "documovie", title: "Документальные фильмы"),
        .catalog(type: "docuserial", title: "Документальные сериалы"),
        .catalog(type: "concert", title: "Концерты"),
        .catalog(type: "4k", title: "4K"),
        .catalog(type: "3d", title: "3D"),
    ]
}

struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem? = .fresh
    @State private var path = NavigationPath()

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Каталог") {
                    row(.search)
                    row(.fresh)
                    ForEach(SidebarItem.catalogs, id: \.self) { row($0) }
                }
                Section("Моё") {
                    row(.watching)
                    ForEach(model.bookmarks.folders) { folder in
                        row(.bookmarks(id: folder.id, title: folder.title))
                    }
                }
                Section {
                    row(.library)
                    row(.downloads)
                        .badge(model.downloads.activeCount)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            NavigationStack(path: $path) {
                detail(for: selection ?? .fresh)
                    .navigationDestination(for: Item.self) { item in
                        ItemDetailView(preview: item)
                    }
                    .navigationDestination(for: PersonQuery.self) { query in
                        PersonView(query: query)
                    }
            }
            .id(selection)
            // Имена актёров и режиссёров в карточке — ссылки kpub-person://…
            .environment(\.openURL, OpenURLAction { url in
                guard let query = PersonQuery(url: url) else { return .systemAction }
                path.append(query)
                return .handled
            })
            .onChange(of: selection) { path = NavigationPath() }
        }
    }

    private func row(_ item: SidebarItem) -> some View {
        Button {
            path = NavigationPath()
            selection = item
        } label: {
            Label(item.title, systemImage: item.icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tag(item)
    }

    @ViewBuilder
    private func detail(for item: SidebarItem) -> some View {
        switch item {
        case .search:
            SearchView()
        case .fresh:
            CatalogView(title: "Новинки", sortable: false, typePicker: true) { api, page, _, type in
                try await api.shortcut("fresh", type: type ?? "serial", page: page)
            }
        case .catalog(let type, let title):
            CatalogView(title: title, sortable: true) { api, page, sort, _ in
                try await api.items(type: type, sort: sort, page: page)
            }
        case .watching:
            CatalogView(title: "Я смотрю", sortable: false) { api, page, _, _ in
                page == 1 ? try await api.watchingSerials() : ItemsResponse(items: [], pagination: nil)
            }
        case .bookmarks(let id, let title):
            CatalogView(title: title, sortable: false, isVisible: { model.bookmarks.contains(item: $0.id, folder: id) || !model.bookmarks.isLoaded }) { api, page, _, _ in
                try await api.bookmarks(folder: id, page: page)
            }
        case .library:
            LibraryView()
        case .downloads:
            DownloadsView()
        }
    }
}
