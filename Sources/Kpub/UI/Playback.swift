import AppKit
import KpubCore
import SwiftUI

/// Что открыть во встроенном плеере: очередь файлов и с какого начать.
struct PlaylistRequest: Codable, Hashable {
    var title: String
    var files: [URL]
    var start: Int = 0
}

/// Запуск просмотра: встроенный плеер для MP4, иначе плеер по умолчанию (IINA, VLC…), плейлисты .m3u8.
enum Playback {
    /// Встроенный AVPlayer не умеет MKV.
    static func isBuiltInPlayable(_ url: URL) -> Bool {
        ["mp4", "m4v", "mov"].contains(url.pathExtension.lowercased())
    }

    private static let knownPlayers: Set<String> = [
        "com.colliderli.iina", "org.videolan.vlc", "com.firecore.infuse", "io.mpv", "com.apple.QuickTimePlayerX",
        "com.movist.MovistPro", "com.Eltima.ElmediaPlayer", "tv.plex.desktop", "com.wholeway.Movist",
    ]

    /// Плееры, которые могут открыть файл: плеер по умолчанию первым, затем известные видеоплееры.
    static func players(for file: URL) -> [URL] {
        let ws = NSWorkspace.shared
        let isMKV = file.pathExtension.lowercased() == "mkv"
        var result: [URL] = []
        if let def = ws.urlForApplication(toOpen: file) { result.append(def) }
        for app in ws.urlsForApplications(toOpen: file) where !result.contains(app) {
            guard let id = Bundle(url: app)?.bundleIdentifier, knownPlayers.contains(id) else { continue }
            if isMKV, id == "com.apple.QuickTimePlayerX" { continue }
            result.append(app)
        }
        return result
    }

    static func appName(_ app: URL) -> String {
        FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }

    /// Пишет плейлист .m3u8 рядом с файлами (если они в одной папке), иначе в Application Support.
    @discardableResult
    static func writePlaylist(title: String, files: [URL]) throws -> URL {
        let parents = Set(files.map { $0.deletingLastPathComponent().standardizedFileURL })
        let sameDir = parents.count == 1 ? parents.first : nil
        let dir = sameDir ?? AppPaths.supportDirectory.appendingPathComponent("Playlists", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var lines = ["#EXTM3U"]
        for file in files {
            lines.append("#EXTINF:-1,\(file.deletingPathExtension().lastPathComponent)")
            lines.append(sameDir != nil ? file.lastPathComponent : file.path)
        }
        let url = dir.appendingPathComponent(OutputNaming.sanitize(title) + ".m3u8")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Открывает файлы во внешнем плеере; несколько файлов — через плейлист.
    static func openExternally(_ files: [URL], title: String, app: URL? = nil) {
        guard let first = files.first else { return }
        let ws = NSWorkspace.shared
        guard let player = app ?? ws.urlForApplication(toOpen: first) else {
            ws.open(first)
            return
        }
        let target: URL
        if files.count == 1 {
            target = first
        } else if let playlist = try? writePlaylist(title: title, files: files) {
            target = playlist
        } else {
            ws.open(files, withApplicationAt: player, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        ws.open([target], withApplicationAt: player, configuration: NSWorkspace.OpenConfiguration())
    }

    /// «Смотреть»: всё MP4 — встроенный плеер с очередью, иначе плеер по умолчанию с плейлиста.
    @MainActor
    static func play(_ files: [URL], title: String, start: Int = 0, openWindow: OpenWindowAction) {
        guard !files.isEmpty else { return }
        let start = min(max(start, 0), files.count - 1)
        if files.allSatisfy(isBuiltInPlayable) {
            openWindow(value: PlaylistRequest(title: title, files: files, start: start))
        } else {
            openExternally(Array(files[start...]), title: title)
        }
    }
}

/// Меню «Открыть в…»: встроенный плеер, установленные плееры, сохранить плейлист.
struct OpenInMenu: View {
    @Environment(\.openWindow) private var openWindow
    let files: [URL]
    let title: String
    var start: Int = 0
    var label: String = "Открыть в…"

    var body: some View {
        Menu {
            if files.allSatisfy(Playback.isBuiltInPlayable) {
                Button("Встроенный плеер") { openWindow(value: PlaylistRequest(title: title, files: files, start: start)) }
            }
            if let first = files.first {
                ForEach(Playback.players(for: first), id: \.self) { app in
                    Button(Playback.appName(app)) { Playback.openExternally(Array(files[start...]), title: title, app: app) }
                }
            }
            if files.count > 1 {
                Divider()
                Button("Сохранить плейлист .m3u8") {
                    if let url = try? Playback.writePlaylist(title: title, files: files) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            }
        } label: {
            Label(label, systemImage: "list.and.film")
        }
        .fixedSize()
    }
}
