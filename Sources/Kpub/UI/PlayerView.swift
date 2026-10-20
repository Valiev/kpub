import AVKit
import CoreMedia
import KpubCore
import SwiftUI

/// Встроенный плеер для MP4: очередь серий, выбор озвучки и субтитров — в стандартном меню AVKit.
/// Запоминает позицию просмотра для каждого файла и сам переходит к следующей серии.
struct PlayerView: View {
    @Environment(AppModel.self) private var model
    let request: PlaylistRequest
    @State private var index: Int
    @State private var showSubtitleStyle = false

    init(request: PlaylistRequest) {
        self.request = request
        _index = State(initialValue: min(max(request.start, 0), max(request.files.count - 1, 0)))
    }

    private var current: URL { request.files[index] }
    private var hasPrevious: Bool { index > 0 }
    private var hasNext: Bool { index + 1 < request.files.count }

    var body: some View {
        AVPlayerViewRepresentable(url: current, subtitleStyle: model.subtitleStyle) {
            if hasNext { index += 1 }
        }
        .id(current)
        .navigationTitle(current.deletingPathExtension().lastPathComponent)
        .navigationSubtitle(request.files.count > 1 ? "\(request.title) · \(index + 1) из \(request.files.count)" : "")
        .toolbar {
            Button { showSubtitleStyle.toggle() } label: { Label("Субтитры", systemImage: "textformat.size") }
                .help("Прозрачность и размер субтитров")
                .popover(isPresented: $showSubtitleStyle) {
                    SubtitleStyleControls().environment(model).padding(16).frame(width: 300)
                }
            if request.files.count > 1 {
                Button { index -= 1 } label: { Label("Предыдущая", systemImage: "backward.end.fill") }
                    .disabled(!hasPrevious)
                    .keyboardShortcut("[", modifiers: .command)
                    .help("Предыдущая (⌘[)")
                Button { index += 1 } label: { Label("Следующая", systemImage: "forward.end.fill") }
                    .disabled(!hasNext)
                    .keyboardShortcut("]", modifiers: .command)
                    .help("Следующая (⌘])")
                Menu {
                    ForEach(request.files.indices, id: \.self) { i in
                        Button {
                            index = i
                        } label: {
                            if i == index {
                                Label(request.files[i].deletingPathExtension().lastPathComponent, systemImage: "play.fill")
                            } else {
                                Text(request.files[i].deletingPathExtension().lastPathComponent)
                            }
                        }
                    }
                } label: {
                    Label("Плейлист", systemImage: "list.bullet")
                }
            }
        }
        .ignoresSafeArea()
    }
}

private struct AVPlayerViewRepresentable: NSViewRepresentable {
    let url: URL
    let subtitleStyle: SubtitleStyle
    let onEnded: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(url: url, onEnded: onEnded) }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        view.player = context.coordinator.player
        context.coordinator.apply(subtitleStyle)
        context.coordinator.start()
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        context.coordinator.apply(subtitleStyle)
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: Coordinator) {
        coordinator.stop()
        nsView.player = nil
    }

    final class Coordinator {
        let player: AVPlayer
        private let key: String
        private let onEnded: () -> Void
        private var timeObserver: Any?
        private var endObserver: NSObjectProtocol?

        init(url: URL, onEnded: @escaping () -> Void) {
            player = AVPlayer(url: url)
            key = "position:" + url.path
            self.onEnded = onEnded
        }

        /// Полупрозрачный текст без подложки и нужного размера — правила стиля AVKit для субтитров.
        func apply(_ style: SubtitleStyle) {
            let attributes: [String: Any] = [
                kCMTextMarkupAttribute_ForegroundColorARGB as String: [style.opacity, 1.0, 1.0, 1.0],
                kCMTextMarkupAttribute_CharacterBackgroundColorARGB as String: [0.0, 0.0, 0.0, 0.0],
                kCMTextMarkupAttribute_BackgroundColorARGB as String: [0.0, 0.0, 0.0, 0.0],
                kCMTextMarkupAttribute_RelativeFontSize as String: style.scale * 100,
            ]
            player.currentItem?.textStyleRules = AVTextStyleRule(textMarkupAttributes: attributes).map { [$0] }
        }

        func start() {
            let saved = UserDefaults.standard.double(forKey: key)
            if saved > 30 {
                player.seek(to: CMTime(seconds: saved - 5, preferredTimescale: 600))
            }
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 1), queue: .main) { [weak self] time in
                self?.remember(time)
            }
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main
            ) { [weak self] _ in
                UserDefaults.standard.removeObject(forKey: self?.key ?? "")
                self?.onEnded()
            }
            player.play()
        }

        func stop() {
            remember(player.currentTime())
            player.pause()
            if let timeObserver { player.removeTimeObserver(timeObserver) }
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            timeObserver = nil
            endObserver = nil
        }

        private func remember(_ time: CMTime) {
            let seconds = time.seconds
            guard seconds.isFinite else { return }
            let duration = player.currentItem?.duration.seconds ?? 0
            // Досмотрели почти до конца — начнём сначала в следующий раз.
            if duration.isFinite, duration > 0, seconds > duration - 120 {
                UserDefaults.standard.removeObject(forKey: key)
            } else {
                UserDefaults.standard.set(seconds, forKey: key)
            }
        }
    }
}
