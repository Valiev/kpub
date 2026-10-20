import KpubCore
import SwiftUI

/// Выбор профиля пережатия и тонкая настройка — общий для загрузки и повторного пережатия.
struct EncodeSettingsEditor: View {
    @Binding var settings: EncodeSettings
    @Binding var showAdvanced: Bool
    /// Разрешать ли «без пережатия» (для повторного пережатия смысла нет).
    let allowCopy: Bool

    private var presets: [EncodePreset] {
        EncodePreset.all.filter { allowCopy || $0.settings.videoCodec != .copy }
    }

    private var activePresetID: String? {
        presets.first { $0.settings.sameEncoding(as: settings) }?.id
    }

    var body: some View {
        Picker("Профиль", selection: Binding(
            get: { activePresetID ?? "custom" },
            set: { id in
                guard let preset = presets.first(where: { $0.id == id }) else { return }
                let keepContainer = settings.container
                let keepSrt = settings.saveSubtitleFiles
                settings = preset.settings
                settings.container = keepContainer
                settings.saveSubtitleFiles = keepSrt
            }
        )) {
            ForEach(presets) { preset in
                VStack(alignment: .leading, spacing: 1) {
                    Text(preset.title)
                    Text(preset.subtitle).font(.caption).foregroundStyle(.secondary)
                }
                .tag(preset.id)
            }
            if activePresetID == nil {
                Text("Свои настройки").tag("custom")
            }
        }
        .pickerStyle(.radioGroup)

        // DisclosureGroup внутри Form(.grouped) в модальном окне на macOS иногда не раскрывается —
        // поэтому обычная кнопка-строка и условные строки формы.
        ExpandableRow(title: "Тонкая настройка", isExpanded: $showAdvanced)

        if showAdvanced {
            Picker("Видеокодек", selection: $settings.videoCodec) {
                ForEach(EncodeSettings.VideoCodec.allCases.filter { allowCopy || $0 != .copy }) { Text($0.title).tag($0) }
            }
            if settings.videoCodec != .copy {
                Picker("Разрешение не выше", selection: $settings.maxHeight) {
                    ForEach(EncodeSettings.heightOptions, id: \.self) { Text(EncodeSettings.heightTitle($0)).tag($0) }
                }
                if settings.videoCodec.usesCRF {
                    LabeledContent("Качество (CRF \(settings.crf))") {
                        Slider(value: Binding(get: { Double(settings.crf) }, set: { settings.crf = Int($0) }), in: 18...32, step: 1) {
                            EmptyView()
                        } minimumValueLabel: { Text("лучше").font(.caption) } maximumValueLabel: { Text("меньше").font(.caption) }
                    }
                } else {
                    LabeledContent("Битрейт видео (\(settings.videoBitrateKbps) кбит/с)") {
                        Slider(value: Binding(get: { Double(settings.videoBitrateKbps) },
                                              set: { settings.videoBitrateKbps = Int($0 / 50) * 50 }),
                               in: 300...8000)
                    }
                }
            }
            Picker("Звук", selection: $settings.audioMode) {
                ForEach(EncodeSettings.AudioMode.allCases) { Text($0.title).tag($0) }
            }
            if settings.audioMode == .aacStereo {
                Picker("Битрейт звука", selection: $settings.audioBitrateKbps) {
                    ForEach([64, 96, 128, 160, 192], id: \.self) { Text("\($0) кбит/с").tag($0) }
                }
            }
            Picker("Контейнер", selection: $settings.container) {
                ForEach(EncodeSettings.Container.allCases) { Text($0.title).tag($0) }
            }
            if allowCopy {
                Toggle("Сохранить субтитры ещё и отдельными файлами", isOn: $settings.saveSubtitleFiles)
            }
        }
    }
}

/// Заголовок раскрывающегося блока: нажимается вся строка — надпись, пустое место и стрелка.
struct ExpandableRow: View {
    let title: String
    @Binding var isExpanded: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
            Text(title)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { isExpanded.toggle() }
    }
}

/// Стиль DisclosureGroup, в котором раскрывает клик по всей строке заголовка, а не только по стрелке.
struct WholeRowDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                configuration.label
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) { configuration.isExpanded.toggle() }
            }
            if configuration.isExpanded {
                configuration.content
            }
        }
    }
}

struct RecompressRequest: Identifiable {
    let id = UUID()
    let jobIDs: [UUID]
}

/// Повторное пережатие уже скачанных файлов, чтобы освободить место.
struct RecompressSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: RecompressRequest

    @State private var settings = EncodePreset.all.first { $0.id == "tiny480" }!.settings
    @State private var showAdvanced = false

    private var jobs: [DownloadJob] {
        request.jobIDs.compactMap { model.downloads.job($0) }.filter { $0.status == .completed }
    }

    private var currentSize: Int64 { jobs.compactMap(\.outputSize).reduce(0, +) }

    private var estimatedSize: Int64 {
        jobs.compactMap { job -> Int64? in
            guard let d = job.duration else { return nil }
            let tracks = max(job.downloadedAudio?.count ?? job.audio.count, 1)
            return settings.estimatedBytes(duration: d, audioTracks: tracks)
        }.reduce(0, +)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(jobs.count == 1 ? "Пережать «\(jobs[0].displayTitle)»" : "Пережать \(jobs.count) файлов")
                    .font(.title2.bold())
                    .lineLimit(2)
                Text("Сейчас занимает \(Formatting.bytes(currentSize))").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 8)

            Form {
                Section("Новый профиль") {
                    EncodeSettingsEditor(settings: $settings, showAdvanced: $showAdvanced, allowCopy: false)
                }
                Section {
                    LabeledContent("Примерно будет", value: estimatedSize > 0 ? "≈ " + Formatting.bytes(estimatedSize) : "неизвестно")
                    Text("Пережимается уже скачанный файл, без повторной загрузки; озвучки и субтитры сохраняются. Качество немного падает (повторное сжатие). Если результат не окажется меньше, останется исходный файл.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if model.tools == nil {
                        Label("ffmpeg не найден — установите: brew install ffmpeg", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Отмена", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Пережать") {
                    model.downloads.recompress(jobs.map(\.id), settings: settings)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(jobs.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 580, height: 640)
    }
}
