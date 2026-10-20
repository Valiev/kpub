import KpubCore
import Observation

/// Списки (закладки) пользователя и в каких из них лежит каждый тайтл — для галочек в меню.
@MainActor
@Observable
final class BookmarksStore {
    private(set) var folders: [BookmarkFolder] = []
    private(set) var isLoaded = false
    /// itemID → id списков, где он лежит.
    private var membership: [Int: Set<Int>] = [:]
    /// Короткое сообщение для всплывающей подсказки.
    var toast: String?

    @ObservationIgnored private let api: KpubAPI

    init(api: KpubAPI) {
        self.api = api
    }

    func reload() async {
        guard let loaded = try? await api.bookmarkFolders() else { return }
        var map: [Int: Set<Int>] = [:]
        for folder in loaded {
            for id in (try? await api.bookmarkItemIDs(folder: folder.id)) ?? [] {
                map[id, default: []].insert(folder.id)
            }
        }
        folders = loaded
        membership = map
        isLoaded = true
    }

    func clear() {
        folders = []
        membership = [:]
        isLoaded = false
    }

    func contains(item: Int, folder: Int) -> Bool {
        membership[item]?.contains(folder) == true
    }

    func folders(containing item: Int) -> [BookmarkFolder] {
        folders.filter { contains(item: item, folder: $0.id) }
    }

    /// Добавляет или убирает тайтл из списка (сразу в интерфейсе, откатывает при ошибке).
    func set(item: Item, folder: BookmarkFolder, included: Bool) async {
        let was = contains(item: item.id, folder: folder.id)
        guard was != included else { return }
        update(item.id, folder.id, included)
        do {
            if included {
                try await api.addBookmark(item: item.id, folder: folder.id)
                toast = "«\(item.title)» добавлен в «\(folder.title)»"
            } else {
                try await api.removeBookmark(item: item.id, folder: folder.id)
                toast = "«\(item.title)» убран из «\(folder.title)»"
            }
        } catch {
            update(item.id, folder.id, was)
            toast = "Не получилось: \(error.localizedDescription)"
        }
    }

    func createFolder(title: String, adding item: Item?) async {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            let created = try await api.createBookmarkFolder(title: name)
            if let reloaded = try? await api.bookmarkFolders() { folders = reloaded }
            let folder = created ?? folders.last { $0.title == name }
            if let item, let folder {
                await set(item: item, folder: folder, included: true)
            } else {
                toast = "Список «\(name)» создан"
            }
        } catch {
            toast = "Не удалось создать список: \(error.localizedDescription)"
        }
    }

    private func update(_ item: Int, _ folder: Int, _ included: Bool) {
        if included {
            membership[item, default: []].insert(folder)
        } else {
            membership[item]?.remove(folder)
        }
    }
}
