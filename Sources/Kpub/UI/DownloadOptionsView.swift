import KpubCore
import SwiftUI

/// Выбор качества, озвучек, субтитров и параметров пережатия перед загрузкой.
struct DownloadOptionsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let item: Item
    let entries: [DownloadRequest.Entry]

    @State private var quality = 0
    @State private var audioKeys: Set<String> = []
    @State private var subtitleKeys: Set<String> = []
    @State private var settings = EncodePreset.default.settings
    @State private var showAdvanced = false
    @State private var didLoadDefaults = false

    private var reference: Video { entries[0].video }

    private var qualityOptions: [MediaFile] {
        var seen = Set<Int>()
        return reference.sortedFiles.filter { seen.insert($0.height).inserted }
    }

    private var audioOptions: [AudioTrack] {
        var seen = Set<String>()
        return reference.audios.filter { seen.insert($0.matchKey).inserted }
    }

    private var subtitleOptions: [SubtitleTrack] {
        var seen = Set<String>()
        return entries.flatMap(\.video.subtitles).filter { $0.url != nil && seen.insert($0.matchKey).inserted }
    }

    private var selectedAudio: [AudioTrack] { audioOptions.filter { audioKeys.contains($0.matchKey) } }
    private var selectedSubtitles: [SubtitleTrack] { subtitleOptions.filter { subtitleKeys.contains($0.matchKey) } }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Скачать «\(item.title)»").font(.title2.bold())
                Text(subtitleText).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 8)

            Form {
                sourceSection
                audioSection
                subtitlesSection
                encodeSection
                summarySection
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Отмена", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(entries.count > 1 ? "Скачать \(entries.count) эп." : "Скачать") { enqueue() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 600, height: 720)
        .onAppear(perform: loadDefaults)
    }

    private var subtitleText: String {
        if entries.count > 1 {
            let total = entries.compactMap(\.video.duration).reduce(0, +)
            return "\(entries.count) эпизодов" + (total > 0 ? " · " + Formatting.duration(total) : "")
        }
        if let d = reference.duration, d > 0 { return Formatting.duration(d) }
        return ""
    }

    // MARK: - Секции

    private var sourceSection: some View {
        Section("Источник") {
            Picker("Качество", selection: $quality) {
                Text("Авто — \(autoQualityTitle)").tag(0)
                ForEach(qualityOptions, id: \.height) { file in
                    Text(fileTitle(file)).tag(file.height)
                }
            }
            if entries.count > 1 {
                Text("Дорожки выбираются по первому эпизоду; в остальных подбираются такие же по языку и автору.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var audioSection: some View {
        Section {
            if audioOptions.isEmpty {
                Text("Сервер не сообщил список дорожек — будет взята дорожка из файла.")
                    .foregroundStyle(.secondary)
            }
            ForEach(audioOptions) { track in
                Toggle(isOn: Binding(
                    get: { audioKeys.contains(track.matchKey) },
                    set: { on in if on { audioKeys.insert(track.matchKey) } else { audioKeys.remove(track.matchKey) } }
                )) {
                    HStack {
                        Text(track.displayName)
                        if selectedAudio.first == track {
                            Text("по умолчанию").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text("Озвучка")
                Spacer()
                if audioOptions.count > 1 {
                    Button("Все") { audioKeys = Set(audioOptions.map(\.matchKey)) }.buttonStyle(.link)
                }
            }
        } footer: {
            if !audioOptions.isEmpty && audioKeys.isEmpty {
                Text("Выберите хотя бы одну дорожку").foregroundStyle(.red)
            }
        }
    }

    /// Сколько выбранных видео без английских субтитров на кинопабе.
    private var missingEnglishCount: Int {
        entries.filter { entry in !entry.video.subtitles.contains { Language.iso639_2($0.lang) == "eng" } }.count
    }

    private var subtitlesSection: some View {
        @Bindable var model = model
        return Section {
            if subtitleOptions.isEmpty {
                Text("На кинопабе субтитров нет").foregroundStyle(.secondary)
            }
            ForEach(subtitleOptions, id: \.matchKey) { sub in
                Toggle(sub.displayName, isOn: Binding(
                    get: { subtitleKeys.contains(sub.matchKey) },
                    set: { on in if on { subtitleKeys.insert(sub.matchKey) } else { subtitleKeys.remove(sub.matchKey) } }
                ))
            }
            Toggle(isOn: $model.fetchExternalEnglish) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Английские из OpenSubtitles, если на кинопабе нет")
                    Text(externalEnglishHint).font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(item.imdb == nil)
        } header: {
            Text("Субтитры")
        }
    }

    private var externalEnglishHint: String {
        if item.imdb == nil { return "У этого тайтла нет IMDb-id — искать не по чему" }
        let missing = missingEnglishCount
        if missing == 0 { return "Английские есть на кинопабе — внешние не понадобятся" }
        let scope = entries.count > 1 ? "Для \(missing) из \(entries.count) эп. " : ""
        return scope + "подберутся по IMDb и длительности серии; синхронность не гарантируется"
    }

    private var encodeSection: some View {
        Section("Пережатие") {
            EncodeSettingsEditor(settings: $settings, showAdvanced: $showAdvanced, allowCopy: true)
        }
    }

    private var summarySection: some View {
        Section {
            LabeledContent("Примерный размер", value: estimateText)
            LabeledContent("Папка") {
                Text(model.downloadsFolder.path(percentEncoded: false))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(.secondary)
            }
            if model.tools == nil {
                Label("ffmpeg не найден — файлы скачаются, но пережатие начнётся только после установки (brew install ffmpeg).",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Логика

    private var autoQualityTitle: String {
        DownloadRequest.pickFile(reference.files, preferredHeight: 0, settings: settings)?.quality ?? "лучшее"
    }

    private func fileTitle(_ file: MediaFile) -> String {
        var parts = [file.quality]
        if let codec = file.codec { parts.append(codec.uppercased()) }
        if let w = file.w, let h = file.h { parts.append("\(w)×\(h)") }
        return parts.joined(separator: " · ")
    }

    private var estimateText: String {
        if settings.videoCodec == .copy { return "как у источника" }
        let tracks = max(selectedAudio.count, 1)
        let total = entries.compactMap { entry -> Int64? in
            guard let d = entry.video.duration else { return nil }
            return settings.estimatedBytes(duration: d, audioTracks: tracks)
        }.reduce(0, +)
        return total > 0 ? "≈ " + Formatting.bytes(total) : "неизвестно"
    }

    private func loadDefaults() {
        guard !didLoadDefaults else { return }
        didLoadDefaults = true
        settings = model.lastEncodeSettings
        if let first = audioOptions.first { audioKeys = [first.matchKey] }
    }

    private func enqueue() {
        if !audioOptions.isEmpty && audioKeys.isEmpty { return }
        model.lastEncodeSettings = settings
        let jobs = DownloadRequest.makeJobs(
            item: item, entries: entries, preferredHeight: quality,
            audio: selectedAudio, subtitles: selectedSubtitles,
            settings: settings, root: model.downloadsFolder,
            externalSubtitleLanguages: model.fetchExternalEnglish ? ["eng"] : []
        )
        model.downloads.enqueue(jobs)
        dismiss()
    }
}

extension EncodeSettings {
    /// Совпадение по параметрам кодирования (без контейнера и сохранения .srt).
    func sameEncoding(as other: EncodeSettings) -> Bool {
        var a = self
        var b = other
        a.container = .mp4
        b.container = .mp4
        a.saveSubtitleFiles = false
        b.saveSubtitleFiles = false
        if a.videoCodec == .copy && b.videoCodec == .copy {
            a.maxHeight = 0; b.maxHeight = 0
            a.videoBitrateKbps = 0; b.videoBitrateKbps = 0
            a.crf = 0; b.crf = 0
        } else if a.videoCodec.usesCRF {
            a.videoBitrateKbps = 0; b.videoBitrateKbps = 0
        } else {
            a.crf = 0; b.crf = 0
        }
        if a.audioMode == .copy && b.audioMode == .copy {
            a.audioBitrateKbps = 0; b.audioBitrateKbps = 0
        }
        return a == b
    }
}
