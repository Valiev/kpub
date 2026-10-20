import AppKit
import KpubCore
import SwiftUI

struct DownloadsView: View {
    @Environment(AppModel.self) private var model
    @State private var recompressRequest: RecompressRequest?

    var body: some View {
        let jobs = model.downloads.jobs
        let active = jobs.filter { $0.status != .completed }
        let done = jobs.filter { $0.status == .completed }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }

        List {
            if model.tools == nil {
                Section {
                    Label("ffmpeg не найден. Установите его командой «brew install ffmpeg» или укажите путь в настройках — без него видео не пережимается.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            if !jobs.isEmpty {
                Section {
                    HStack(spacing: 20) {
                        metric("Скачивается", jobs.filter { $0.status == .downloading }.count)
                        metric("Пережимается", jobs.filter { $0.status == .encoding }.count)
                        metric("Ожидает", jobs.filter { $0.status == .queued || $0.status == .waitingEncode }.count)
                        metric("Ошибки", jobs.filter { $0.status == .failed }.count)
                        metric("Готово", done.count)
                    }
                    .padding(.vertical, 8)
                }
            }
            ForEach(DownloadGroup.allCases) { group in
                let rows = active.filter { group.includes($0.status) }
                if !rows.isEmpty {
                    Section("\(group.title) · \(rows.count)") {
                        ForEach(rows) { job in
                            DownloadRow(job: job) { recompressRequest = RecompressRequest(jobIDs: [job.id]) }
                        }
                    }
                }
            }
            if !done.isEmpty {
                Section("Готово · \(done.count) · \(Formatting.bytes(done.compactMap(\.outputSize).reduce(0, +)))") {
                    ForEach(done) { job in
                        DownloadRow(job: job) { recompressRequest = RecompressRequest(jobIDs: [job.id]) }
                    }
                }
            }
        }
        .overlay {
            if jobs.isEmpty {
                ContentUnavailableView(
                    "Загрузок пока нет",
                    systemImage: "arrow.down.circle",
                    description: Text("Откройте фильм или сериал и нажмите «Скачать»")
                )
            }
        }
        .navigationTitle("Загрузки")
        .sheet(item: $recompressRequest) { RecompressSheet(request: $0) }
        .toolbar {
            Button { model.downloads.pauseAll() } label: { Label("Пауза для всех", systemImage: "pause.circle") }
                .disabled(active.allSatisfy { $0.status == .paused || $0.status == .failed })
            Button { model.downloads.resumeAll() } label: { Label("Продолжить все", systemImage: "play.circle") }
                .disabled(!active.contains { $0.status == .paused || $0.status == .failed })
            Button { recompressRequest = RecompressRequest(jobIDs: done.map(\.id)) } label: {
                Label("Пережать готовые…", systemImage: "arrow.down.right.and.arrow.up.left")
            }
            .help("Пережать все скачанные файлы сильнее, чтобы освободить место")
            .disabled(done.isEmpty)
            Button { model.downloads.clearCompleted() } label: { Label("Убрать готовые из списка", systemImage: "checkmark.circle.badge.xmark") }
                .disabled(done.isEmpty)
            Button {
                try? FileManager.default.createDirectory(at: model.downloadsFolder, withIntermediateDirectories: true)
                NSWorkspace.shared.open(model.downloadsFolder)
            } label: {
                Label("Открыть папку", systemImage: "folder")
            }
        }
    }

    private func metric(_ title: String, _ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(count)").font(.title2.monospacedDigit().bold())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum DownloadGroup: String, CaseIterable, Identifiable {
    case running, queued, paused, failed
    var id: Self { self }
    var title: String {
        switch self {
        case .running: "Сейчас выполняется"
        case .queued: "В очереди"
        case .paused: "На паузе"
        case .failed: "Требуют внимания"
        }
    }
    func includes(_ status: DownloadJob.Status) -> Bool {
        switch self {
        case .running: status == .downloading || status == .encoding
        case .queued: status == .queued || status == .waitingEncode
        case .paused: status == .paused
        case .failed: status == .failed
        }
    }
}

struct DownloadRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let job: DownloadJob
    var onRecompress: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            PosterImage(url: job.posterURL)
                .frame(width: 44, height: 66)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 4) {
                Text(job.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(job.status == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(job.status == .failed ? nil : 2)
                    .textSelection(.enabled)
                if showsProgress {
                    ProgressView(value: job.progress)
                        .tint(job.status == .encoding ? .purple : .accentColor)
                }
            }
            Spacer(minLength: 8)
            buttons
        }
        .padding(.vertical, 4)
        .contextMenu { menu }
        .onTapGesture(count: 2) { if job.status == .completed { play() } }
    }

    private var showsProgress: Bool {
        switch job.status {
        case .downloading, .encoding: true
        case .paused, .failed: job.progress > 0
        default: false
        }
    }

    private var summary: String {
        var parts: [String] = []
        let s = job.settings
        switch s.videoCodec {
        case .copy: parts.append("\(job.sourceHeight)p без пережатия")
        case .hevcHardware, .hevcSoftware: parts.append("HEVC \(s.maxHeight == 0 ? "\(job.sourceHeight)" : "\(min(s.maxHeight, job.sourceHeight))")p")
        case .h264Hardware: parts.append("H.264 \(s.maxHeight == 0 ? "\(job.sourceHeight)" : "\(min(s.maxHeight, job.sourceHeight))")p")
        }
        parts.append("\(max(job.audio.count, 1)) озв.")
        let subs = job.subtitles.count + (job.externalSubtitleLanguages?.count ?? 0)
        if subs > 0 { parts.append("\(subs) суб.") }
        parts.append(s.container.rawValue.uppercased())
        return parts.joined(separator: " · ")
    }

    private var statusLine: String {
        switch job.status {
        case .queued:
            return "В очереди · \(summary)"
        case .downloading:
            var parts = ["Скачивание \(Int(job.progress * 100))%"]
            if let total = job.bytesTotal {
                parts.append("\(Formatting.bytes(job.bytesReceived)) из \(Formatting.bytes(total))")
            } else if job.bytesReceived > 0 {
                parts.append("Получено " + Formatting.bytes(job.bytesReceived))
            }
            if let speed = job.speedText { parts.append(speed) }
            return parts.joined(separator: " · ")
        case .waitingEncode:
            return (model.tools == nil ? "Нужен ffmpeg для обработки" : "Скачано, ждёт обработки") + " · " + summary
        case .encoding:
            var parts = [job.recompress != nil ? "Повторное пережатие" : job.settings.videoCodec == .copy ? "Сборка файла" : "Пережатие",
                         "\(Int(job.progress * 100))%"]
            if let speed = job.speedText { parts.append(speed) }
            return parts.joined(separator: " · ")
        case .completed:
            let size = job.outputSize.map(Formatting.bytes) ?? ""
            return ["Готово", size, summary, job.note ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        case .failed:
            return "Ошибка: \(job.errorMessage ?? "неизвестно")"
        case .paused:
            return "Пауза · \(summary)"
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: 6) {
            switch job.status {
            case .completed:
                iconButton("play.fill", "Смотреть") { play() }
                iconButton("magnifyingglass", "Показать в Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([job.outputURL])
                }
                iconButton("arrow.down.right.and.arrow.up.left", "Пережать, чтобы занимало меньше") { onRecompress() }
            case .paused, .failed:
                iconButton("arrow.clockwise", "Продолжить") { model.downloads.resume(job.id) }
                iconButton("xmark", "Отменить") { cancel() }
            default:
                iconButton("pause.fill", "Пауза") { model.downloads.pause(job.id) }
                iconButton("xmark", "Отменить") { cancel() }
            }
        }
    }

    private func iconButton(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    @ViewBuilder
    private var menu: some View {
        if job.status == .completed {
            Button("Смотреть во встроенном плеере") { play() }
            Button("Открыть в приложении по умолчанию") { NSWorkspace.shared.open(job.outputURL) }
            Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([job.outputURL]) }
            Button("Пережать, чтобы занимало меньше…") { onRecompress() }
            Divider()
            Button("Убрать из списка") { model.downloads.remove(job.id) }
            Button("Удалить файл в Корзину", role: .destructive) { model.downloads.remove(job.id, deleteFile: true) }
        } else {
            if job.status == .paused || job.status == .failed {
                Button("Продолжить") { model.downloads.resume(job.id) }
            } else {
                Button("Пауза") { model.downloads.pause(job.id) }
            }
            if job.recompress != nil {
                Button("Отменить пережатие (оставить исходный файл)") { cancel() }
            } else {
                Button("Отменить и удалить временные файлы", role: .destructive) { cancel() }
            }
        }
    }

    /// Для повторного пережатия отмена возвращает исходный файл, для загрузки — убирает задание.
    private func cancel() {
        if job.recompress != nil {
            model.downloads.cancelRecompress(job.id)
        } else {
            model.downloads.remove(job.id)
        }
    }

    private func play() {
        Playback.play([job.outputURL], title: job.displayTitle, openWindow: openWindow)
    }
}
