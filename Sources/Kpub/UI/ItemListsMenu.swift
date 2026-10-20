import AppKit
import KpubCore
import SwiftUI

/// Пункты «в какой список положить»: для контекстного меню постера и кнопки в карточке.
struct ItemListsMenu: View {
    @Environment(AppModel.self) private var model
    let item: Item

    var body: some View {
        let store = model.bookmarks
        Section("Списки") {
            if !store.isLoaded {
                Text("Списки загружаются…")
            }
            ForEach(store.folders) { folder in
                Toggle(folder.title, isOn: Binding(
                    get: { store.contains(item: item.id, folder: folder.id) },
                    set: { on in Task { await store.set(item: item, folder: folder, included: on) } }
                ))
            }
            Button("Новый список…") { model.newListRequest = NewListRequest(item: item) }
        }
        Divider()
        if let url = URL(string: model.siteURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/item/view/\(item.id)") {
            Button("Открыть на сайте") { NSWorkspace.shared.open(url) }
        }
    }
}

/// Диалог нового списка и всплывающие подсказки о добавлении.
struct BookmarksUI: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var title = ""

    func body(content: Content) -> some View {
        @Bindable var model = model
        @Bindable var store = model.bookmarks
        content
            .alert(
                "Новый список",
                isPresented: Binding(get: { model.newListRequest != nil }, set: { if !$0 { model.newListRequest = nil } }),
                presenting: model.newListRequest
            ) { request in
                TextField("Название", text: $title)
                Button("Создать") {
                    let name = title
                    title = ""
                    Task { await model.bookmarks.createFolder(title: name, adding: request.item) }
                }
                Button("Отмена", role: .cancel) { title = "" }
            } message: { request in
                if let item = request.item { Text("«\(item.title)» сразу попадёт в него") }
            }
            .overlay(alignment: .bottom) {
                if let toast = store.toast {
                    Text(toast)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .shadow(radius: 4)
                        .padding(.bottom, 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .task(id: toast) {
                            try? await Task.sleep(for: .seconds(2.5))
                            withAnimation { store.toast = nil }
                        }
                }
            }
            .animation(.easeOut(duration: 0.2), value: store.toast)
    }
}
