import AppKit
import KpubCore
import SwiftUI

@main
struct KpubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @AppStorage(PosterSize.key) private var posterWidth = PosterSize.defaultWidth

    var body: some Scene {
        WindowGroup("kpub", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 620)
                .onOpenURL { url in Task { await model.handleDeepLink(url) } }
        }
        // Ссылки kpub://… открываем в уже существующем окне, а не в новом.
        .handlesExternalEvents(matching: ["*"])
        .commands {
            CommandGroup(replacing: .newItem) {}
            DownloadsCommands()
            CommandGroup(after: .toolbar) {
                Button("Крупнее карточки") {
                    posterWidth = min(PosterSize.range.upperBound, posterWidth + PosterSize.step)
                }
                .keyboardShortcut("=", modifiers: .command)
                Button("Мельче карточки") {
                    posterWidth = max(PosterSize.range.lowerBound, posterWidth - PosterSize.step)
                }
                .keyboardShortcut("-", modifiers: .command)
                Button("Обычный размер карточек") { posterWidth = PosterSize.defaultWidth }
                    .keyboardShortcut("0", modifiers: .command)
                Divider()
            }
        }

        Window("Загрузки", id: "downloads") {
            DownloadsView()
                .environment(model)
                .frame(minWidth: 780, minHeight: 480)
        }

        WindowGroup("Плеер", for: PlaylistRequest.self) { $request in
            if let request, !request.files.isEmpty {
                PlayerView(request: request)
                    .environment(model)
                    .frame(minWidth: 640, minHeight: 360)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // При запуске голого бинарника (swift run) окно иначе не получает фокус.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

struct DownloadsCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Button("Загрузки") { openWindow(id: "downloads") }
                .keyboardShortcut("j", modifiers: .command)
        }
    }
}
