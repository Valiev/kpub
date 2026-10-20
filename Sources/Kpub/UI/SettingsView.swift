import AppKit
import KpubCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            DownloadSettingsView()
                .tabItem { Label("Загрузки", systemImage: "arrow.down.circle") }
            SubtitleSettingsView()
                .tabItem { Label("Субтитры", systemImage: "captions.bubble") }
            AccountSettingsView()
                .tabItem { Label("Аккаунт и сеть", systemImage: "person.crop.circle") }
        }
        .frame(width: 600, height: 460)
    }
}

private struct DownloadSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            LabeledContent("Папка для видео") {
                HStack {
                    Text(model.downloadsFolder.path(percentEncoded: false))
                        .lineLimit(1)
                        .truncationMode(.head)
                    Button("Выбрать…") { chooseFolder() }
                }
            }
            Stepper("Одновременных загрузок: \(model.maxDownloads)", value: $model.maxDownloads, in: 1...5)
            Stepper("Одновременных пережатий: \(model.maxEncodes)", value: $model.maxEncodes, in: 1...3)

            Section("ffmpeg") {
                if let tools = model.tools {
                    Label(tools.ffmpeg.path, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("Не найден. Установите: brew install ffmpeg", systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                }
                TextField("Свой путь к папке с ffmpeg (необязательно)", text: $model.ffmpegPath)
                Button("Искать заново") { model.locateTools() }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = model.downloadsFolder
        panel.prompt = "Выбрать"
        if panel.runModal() == .OK, let url = panel.url {
            model.downloadsFolder = url
        }
    }
}

private struct AccountSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Аккаунт") {
                if model.isAuthorized {
                    LabeledContent("Пользователь", value: model.user?.username ?? "—")
                    if let days = model.user?.subscription?.days {
                        LabeledContent("Подписка", value: "ещё \(Int(days)) дн.")
                    }
                    Button("Выйти") { model.logout() }
                } else {
                    Text("Не выполнен вход")
                }
            }
            Section {
                TextField("Сайт (зеркало)", text: $model.siteURL)
                TextField("API (/v1)", text: $model.apiBaseURL)
                TextField("OAuth (/oauth2)", text: $model.oauthBaseURL)
            } header: {
                Text("Адреса")
            } footer: {
                Text("Зеркало сайта проксирует API (/v1), поэтому каталог и загрузки работают через него. Вход и обновление токена идут через адрес OAuth.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct SubtitleSettingsView: View {
    var body: some View {
        Form {
            Section {
                SubtitleStyleControls()
            } footer: {
                Text("Во встроенном плеере меняется сразу (кнопка «Aa» в окне плеера). В MKV для IINA и VLC стиль записывается в дорожку при загрузке; к уже скачанному его можно применить в «Скачанном» → «Применить стиль субтитров».")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
