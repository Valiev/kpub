import Foundation
import Observation

/// Очередь загрузок: скачивание источника (параллельно до N штук) → пережатие (по одному).
@MainActor
@Observable
public final class DownloadManager {
    public private(set) var jobs: [DownloadJob] = []
    public var maxConcurrentDownloads = 2 { didSet { schedule() } }
    public var maxConcurrentEncodes = 1 { didSet { schedule() } }
    public var tools: FFmpegTools? {
        didSet {
            guard tools != oldValue else { return }
            Task { await loadEncoders() }
            schedule()
        }
    }

    @ObservationIgnored public var downloadsRoot: URL
    /// Стиль субтитров для MKV (полупрозрачные, поменьше) — записывается в дорожку как ASS.
    @ObservationIgnored public var subtitleStyle = SubtitleStyle()
    @ObservationIgnored private let api: KpubAPI
    @ObservationIgnored private var encoders: Set<String> = []
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var saveScheduled = false
    @ObservationIgnored private var activity: NSObjectProtocol?

    private static var stateURL: URL { AppPaths.supportDirectory.appendingPathComponent("downloads.json") }

    public init(api: KpubAPI, downloadsRoot: URL, tools: FFmpegTools?) {
        self.api = api
        self.downloadsRoot = downloadsRoot
        self.tools = tools
        load()
        let posters = jobs.compactMap(\.posterURL)
        Task { await PosterCache.shared.prefetch(posters) }
        Task {
            await loadEncoders()
            schedule()
        }
    }

    // MARK: - Публичные действия

    /// Число незавершённых заданий — отдельное свойство, меняется только при смене статусов,
    /// чтобы боковая панель не перерисовывалась на каждый процент прогресса (иначе теряются клики).
    public private(set) var activeCount = 0

    private func refreshCounters() {
        let count = jobs.filter { !$0.status.isFinished && $0.status != .failed && $0.status != .paused }.count
        if count != activeCount { activeCount = count }
    }

    @ObservationIgnored private var lastProgressUpdate: [UUID: Date] = [:]

    /// Прогресс в интерфейс — не чаще двух раз в секунду (и всегда на 100%).
    private func shouldPublishProgress(_ id: UUID, final: Bool) -> Bool {
        let now = Date()
        if !final, let last = lastProgressUpdate[id], now.timeIntervalSince(last) < 0.5 { return false }
        lastProgressUpdate[id] = now
        return true
    }

    public func enqueue(_ newJobs: [DownloadJob]) {
        let posters = newJobs.compactMap(\.posterURL)
        Task { await PosterCache.shared.prefetch(posters) }
        let pendingOutputs = Set(jobs.filter { $0.status != .completed }.map(\.outputPath))
        jobs.append(contentsOf: newJobs.filter { !pendingOutputs.contains($0.outputPath) })
        save()
        schedule()
    }

    public func pause(_ id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        update(id) {
            guard $0.status != .completed else { return }
            $0.status = .paused
            $0.speedText = nil
        }
        schedule()
    }

    public func resume(_ id: UUID) {
        update(id) {
            guard $0.status == .paused || $0.status == .failed else { return }
            $0.status = $0.sourceComplete ? .waitingEncode : .queued
            $0.errorMessage = nil
        }
        schedule()
    }

    public func pauseAll() {
        for job in jobs where !job.status.isFinished && job.status != .failed { pause(job.id) }
    }

    public func resumeAll() {
        for job in jobs where job.status == .paused || job.status == .failed { resume(job.id) }
    }

    public func remove(_ id: UUID, deleteFile: Bool = false) {
        tasks[id]?.cancel()
        tasks[id] = nil
        if let job = job(id) {
            try? FileManager.default.removeItem(at: workDir(for: job))
            if deleteFile, job.status == .completed {
                try? FileManager.default.trashItem(at: job.outputURL, resultingItemURL: nil)
            }
        }
        jobs.removeAll { $0.id == id }
        lastProgressUpdate[id] = nil
        refreshCounters()
        save()
        schedule()
    }

    /// Пережать уже скачанные файлы с другими настройками (локально, без повторной загрузки).
    public func recompress(_ ids: [UUID], settings: EncodeSettings) {
        for id in ids {
            update(id) { job in
                guard job.status == .completed, job.recompress == nil,
                      FileManager.default.fileExists(atPath: job.outputPath)
                else { return }
                job.recompress = RecompressInfo(originalPath: job.outputPath, originalSettings: job.settings, originalSize: job.outputSize)
                job.settings = settings
                job.sourceComplete = true
                job.status = .waitingEncode
                job.progress = 0
                job.note = nil
                job.errorMessage = nil
            }
        }
        save()
        schedule()
    }

    /// Отмечает, что в готовый файл добавлены внешние субтитры (для подписи в списках).
    public func markExternalSubtitle(_ id: UUID, language: String) {
        update(id) {
            var langs = $0.externalSubtitleLanguages ?? []
            if !langs.contains(language) { langs.append(language) }
            $0.externalSubtitleLanguages = langs
        }
    }

    /// Отменяет повторное пережатие: исходный файл не трогался, просто возвращаем запись.
    public func cancelRecompress(_ id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        if let job = job(id) { try? FileManager.default.removeItem(at: workDir(for: job)) }
        update(id) {
            guard let info = $0.recompress else { return }
            $0.settings = info.originalSettings
            $0.outputPath = info.originalPath
            $0.outputSize = info.originalSize
            $0.recompress = nil
            $0.status = .completed
            $0.progress = 1
            $0.speedText = nil
            $0.errorMessage = nil
        }
        schedule()
    }

    public func clearCompleted() {
        jobs.removeAll { $0.status == .completed }
        refreshCounters()
        save()
    }

    // MARK: - Планировщик

    private func schedule() {
        var downloading = jobs.filter { $0.status == .downloading }.count
        var encoding = jobs.filter { $0.status == .encoding }.count
        for i in jobs.indices {
            if jobs[i].status == .queued {
                if jobs[i].sourceComplete {
                    jobs[i].status = .waitingEncode
                } else if downloading < maxConcurrentDownloads {
                    downloading += 1
                    startDownload(jobs[i].id)
                }
            }
            if jobs[i].status == .waitingEncode, encoding < maxConcurrentEncodes, tools != nil {
                encoding += 1
                startEncode(jobs[i].id)
            }
        }
        updateActivity()
        refreshCounters()
    }

    /// Не даём маку уснуть, пока что-то качается или пережимается.
    private func updateActivity() {
        let busy = jobs.contains { $0.status.isActive }
        if busy, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated],
                reason: "Загрузка и пережатие видео"
            )
        } else if !busy, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    private func startDownload(_ id: UUID) {
        update(id) {
            $0.status = .downloading
            $0.errorMessage = nil
            $0.speedText = "Подключение…"
        }
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.performDownload(id)
                self.update(id) {
                    $0.sourceComplete = true
                    $0.status = .waitingEncode
                    $0.speedText = nil
                    $0.progress = 0
                }
            } catch is CancellationError {
                // Пауза или удаление — состояние уже выставлено.
            } catch {
                self.fail(id, error)
            }
            self.tasks[id] = nil
            self.schedule()
        }
    }

    private func startEncode(_ id: UUID) {
        update(id) {
            $0.status = .encoding
            $0.progress = 0
            $0.errorMessage = nil
            $0.speedText = "Подготовка…"
        }
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.performEncode(id)
            } catch is CancellationError {
            } catch {
                self.fail(id, error)
            }
            self.tasks[id] = nil
            self.schedule()
        }
    }

    // MARK: - Скачивание

    private func performDownload(_ id: UUID) async throws {
        guard let job = job(id) else { return }
        let dir = workDir(for: job)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await fetchSubtitles(for: job, into: dir)

        var networkFailures = 0
        var linkRefreshes = 0
        while true {
            try Task.checkCancellation()
            do {
                // Ссылки живут ~сутки и привязаны к IP — перед каждой попыткой берём свежие.
                let source = (try? await refreshSource(id)) ?? self.job(id)?.sourceURL.map { ($0, job.sourceKind) }
                guard let (url, kind) = source else { throw APIError.http(404, "нет ссылки на видео") }
                switch kind {
                case .file:
                    try await HTTPFileDownloader.download(from: url, to: dir.appendingPathComponent("source.mp4"),
                                                          onProgress: progressHandler(id))
                    update(id) { $0.downloadedAudio = nil }
                case .hls:
                    guard let current = self.job(id) else { return }
                    let (tracks, audio) = try await resolveHLS(current, masterURL: await api.manifestURL(url))
                    _ = try await HLSDownloader.download(tracks: tracks, into: dir, onProgress: progressHandler(id))
                    update(id) { $0.downloadedAudio = audio }
                }
                return
            } catch let error as DownloadError where error.isLinkExpired && linkRefreshes < 2 {
                linkRefreshes += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard Self.isRetryable(error), networkFailures < 8 else { throw error }
                networkFailures += 1
                let delay = min(5 * networkFailures, 60)
                update(id) { $0.speedText = "Нет связи, повтор через \(delay) с" }
                try await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private func progressHandler(_ id: UUID) -> @Sendable (DownloadProgress) -> Void {
        { [weak self] p in
            Task { @MainActor in
                guard let self, self.shouldPublishProgress(id, final: (p.fraction ?? 0) >= 1) else { return }
                self.update(id) {
                    guard $0.status == .downloading else { return }
                    $0.bytesReceived = p.received
                    $0.bytesTotal = p.total
                    $0.progress = p.fraction ?? 0
                    $0.speedText = p.bytesPerSecond > 0 ? Formatting.bytes(Int64(p.bytesPerSecond)) + "/с" : nil
                }
            }
        }
    }

    /// Выбирает в master-плейлисте вариант нужного качества и выбранные озвучки.
    private func resolveHLS(_ job: DownloadJob, masterURL: URL) async throws -> ([HLSDownloader.Track], [SelectedAudio]) {
        let text = try await HLSDownloader.fetchText(masterURL)
        let master = HLSMaster.parse(text, baseURL: masterURL)
        guard !master.variants.isEmpty else {
            // Ссылка сразу на media-плейлист: звук внутри видео.
            return ([.init(name: "video", playlistURL: masterURL, bandwidth: 3_000_000)], [])
        }
        guard let variant = master.pickVariant(preferredHeight: job.sourceHeight) else {
            throw APIError.http(404, "в плейлисте нет видео")
        }
        var tracks = [HLSDownloader.Track(name: "video", playlistURL: variant.url, bandwidth: max(variant.bandwidth, 500_000))]
        var audio: [SelectedAudio] = []
        let picked = master.pickAudio(
            for: variant,
            apiIndices: job.audio.map(\.apiIndex),
            positions: job.audio.map(\.streamPosition),
            preferAC3: job.settings.audioMode == .copy
        )
        for (k, pair) in picked.enumerated() {
            guard let url = pair.rendition.url else { continue }
            tracks.append(.init(name: "audio_\(k)", playlistURL: url, bandwidth: 192_000))
            if let selection = pair.selection {
                audio.append(job.audio[selection])
            } else {
                audio.append(SelectedAudio(streamPosition: 0, language: Language.iso639_2(pair.rendition.language),
                                           title: pair.rendition.name))
            }
        }
        return (tracks, audio)
    }

    private static func isRetryable(_ error: Error) -> Bool {
        if error is URLError { return true }
        if let error = error as? DownloadError {
            if case .incomplete = error { return true }
            if case .badStatus(let code) = error { return code >= 500 || code == 429 }
        }
        if case APIError.network = error { return true }
        return (error as NSError).domain == NSURLErrorDomain
    }

    /// Запрашивает свежую ссылку того же качества.
    private func refreshSource(_ id: UUID) async throws -> (URL, DownloadJob.SourceKind) {
        guard let job = job(id) else { throw CancellationError() }
        let files = try await api.freshFiles(itemID: job.itemID, videoID: job.videoID)
        guard let file = DownloadRequest.pickFile(files, preferredHeight: job.sourceHeight, settings: job.settings),
              let source = DownloadRequest.sourceURL(of: file)
        else {
            throw APIError.http(404, "видео больше недоступно")
        }
        update(id) {
            $0.sourceURL = source.url
            $0.sourceKind = source.kind
        }
        return (source.url, source.kind)
    }

    private func fetchSubtitles(for job: DownloadJob, into dir: URL) async throws {
        for (i, sub) in job.subtitles.enumerated() {
            let dest = subtitleURL(job: job, index: i, dir: dir)
            if FileManager.default.fileExists(atPath: dest.path) { continue }
            do {
                try await SubtitleFetcher.fetch(sub.url, to: dest)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Субтитры не критичны: без них видео всё равно сохраним.
                NSLog("Kpub: не удалось скачать субтитры \(sub.url): \(error)")
            }
        }
        try await fetchExternalSubtitles(for: job, into: dir, attempts: 3)
    }

    /// Субтитры с OpenSubtitles. Старый API иногда отказывает (лимиты при параллельных запросах), поэтому с повторами.
    private func fetchExternalSubtitles(for job: DownloadJob, into dir: URL, attempts: Int) async throws {
        guard let imdb = job.imdbID else { return }
        for lang in job.externalSubtitleLanguages ?? [] {
            let dest = externalSubtitleURL(lang: lang, dir: dir)
            for attempt in 1...attempts {
                if FileManager.default.fileExists(atPath: dest.path) { break }
                do {
                    let found = try await OpenSubtitles.fetch(
                        imdbID: imdb,
                        season: job.isSerial ? (job.seasonNumber ?? 1) : nil,
                        episode: job.isSerial ? job.episodeNumber : nil,
                        language: lang, duration: job.duration, to: dest
                    )
                    if found { break }
                    NSLog("Kpub: OpenSubtitles, попытка \(attempt): нет подходящих \(lang) для \(job.displayTitle)")
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    NSLog("Kpub: OpenSubtitles, попытка \(attempt): \(error)")
                }
                if attempt < attempts { try await Task.sleep(for: .seconds(5 * attempt * attempt)) }
            }
        }
    }

    private func externalSubtitleURL(lang: String, dir: URL) -> URL {
        dir.appendingPathComponent("ext_\(lang).srt")
    }

    private func subtitleURL(job: DownloadJob, index: Int, dir: URL) -> URL {
        dir.appendingPathComponent("sub_\(index).\(SubtitleFetcher.fileExtension(for: job.subtitles[index].url))")
    }

    // MARK: - Пережатие

    private func performEncode(_ id: UUID) async throws {
        guard let tools else { throw TranscodeError.ffmpegNotFound }
        guard let job = job(id) else { return }
        let dir = workDir(for: job)
        if let info = job.recompress {
            try await performRecompress(id, job: job, info: info, tools: tools)
            return
        }

        let mainInput: TranscodePlan.Input
        let probe: ProbeResult
        var audio: [TranscodePlan.Audio]
        switch job.sourceKind {
        case .file:
            let path = dir.appendingPathComponent("source.mp4").path
            probe = try await FFprobe.probe(tools, input: path)
            mainInput = .init(path: path)
            audio = Self.mapAudio(job.audio, sourceCount: probe.audio.count)
        case .hls:
            let path = dir.appendingPathComponent("video.m3u8").path
            probe = try await FFprobe.probe(tools, input: path, isHLSPlaylist: true)
            mainInput = .init(path: path, isHLSPlaylist: true, startTime: probe.startTime ?? 0)
            if let downloaded = job.downloadedAudio, !downloaded.isEmpty {
                audio = []
                for (k, a) in downloaded.enumerated() {
                    let audioPath = dir.appendingPathComponent("audio_\(k).m3u8").path
                    let audioProbe = try await FFprobe.probe(tools, input: audioPath, isHLSPlaylist: true)
                    guard !audioProbe.audio.isEmpty else { continue }
                    let input = TranscodePlan.Input(path: audioPath, isHLSPlaylist: true, startTime: audioProbe.startTime ?? 0)
                    audio.append(.init(source: .separate(input), language: a.language, title: a.title))
                }
            } else {
                audio = Self.mapAudio(job.audio, sourceCount: probe.audio.count)
            }
        }
        guard let video = probe.video else { throw TranscodeError.noVideoStream }

        // Последняя попытка достать внешние субтитры, если при скачивании не вышло.
        try? await fetchExternalSubtitles(for: job, into: dir, attempts: 1)
        var subtitles = job.subtitles.indices.compactMap { i -> TranscodePlan.Subtitle? in
            let path = subtitleURL(job: job, index: i, dir: dir).path
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            let sub = job.subtitles[i]
            return TranscodePlan.Subtitle(path: path, language: sub.language, title: sub.title, forced: sub.forced, shift: sub.shift)
        }
        for lang in job.externalSubtitleLanguages ?? [] {
            let path = externalSubtitleURL(lang: lang, dir: dir).path
            guard FileManager.default.fileExists(atPath: path) else { continue }
            subtitles.append(.init(path: path, language: lang, title: "\(Language.displayName(lang)) (OpenSubtitles)",
                                   forced: false, shift: 0))
        }

        let styled = job.settings.container == .mkv && !subtitleStyle.isDefault && !subtitles.isEmpty
        if styled {
            for i in subtitles.indices {
                let ass = dir.appendingPathComponent("styled_\(i).ass").path
                try await SubtitleStyler.makeStyledASS(tools, input: subtitles[i].path, style: subtitleStyle, output: ass)
                subtitles[i].path = ass
            }
        }

        let temp = dir.appendingPathComponent("output.\(job.settings.container.fileExtension)")
        let title = job.isSerial ? job.displayTitle : [job.showTitle, job.year.map(String.init)].compactMap { $0 }.joined(separator: " ")
        var plan = TranscodePlan(
            input: mainInput, audio: audio, subtitles: subtitles, settings: job.settings,
            sourceVideoCodec: video.codecName, title: title, output: temp.path, encoders: encoders
        )
        plan.subtitlesAreStyledASS = styled

        update(id) { $0.speedText = nil }
        try await FFmpegRunner.run(tools, plan: plan, duration: job.duration ?? probe.duration) { [weak self] p in
            Task { @MainActor in
                guard let self, self.shouldPublishProgress(id, final: p.fraction >= 1) else { return }
                self.update(id) {
                    guard $0.status == .encoding else { return }
                    $0.progress = p.fraction
                    $0.speedText = p.speed.map { "скорость \($0)" }
                }
            }
        }

        // Переносим результат на место.
        let fm = FileManager.default
        let finalPath = OutputNaming.uniquePath(job.outputPath)
        let finalURL = URL(fileURLWithPath: finalPath)
        try fm.createDirectory(at: finalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: temp, to: finalURL)

        if job.settings.saveSubtitleFiles {
            for (i, sub) in subtitles.enumerated() {
                let src = URL(fileURLWithPath: sub.path)
                let suffix = [sub.language ?? "sub\(i)", sub.forced ? "forced" : nil].compactMap { $0 }.joined(separator: ".")
                let dest = finalURL.deletingPathExtension().appendingPathExtension("\(suffix).\(src.pathExtension)")
                try? fm.removeItem(at: dest)
                try? fm.copyItem(at: src, to: dest)
            }
        }

        let size = (try? fm.attributesOfItem(atPath: finalPath)[.size] as? Int64) ?? nil
        try? fm.removeItem(at: dir)
        update(id) {
            $0.outputPath = finalPath
            $0.outputSize = size
            $0.status = .completed
            $0.completedAt = Date()
            $0.progress = 1
            $0.speedText = nil
        }
        save()
    }

    /// Пережимает готовый файл; заменяет его, только если результат меньше.
    private func performRecompress(_ id: UUID, job: DownloadJob, info: RecompressInfo, tools: FFmpegTools) async throws {
        let fm = FileManager.default
        let dir = workDir(for: job)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let input = info.originalPath
        guard fm.fileExists(atPath: input) else { throw APIError.http(404, "файл \(input) не найден") }

        let probe = try await FFprobe.probe(tools, input: input)
        guard let video = probe.video else { throw TranscodeError.noVideoStream }
        // Сохраняем все дорожки и субтитры файла с их подписями.
        let audio = probe.audio.enumerated().map { i, s in
            TranscodePlan.Audio(source: .main(i), language: s.language, title: s.title)
        }
        let styled = job.settings.container == .mkv && !subtitleStyle.isDefault && !probe.subtitles.isEmpty
        var subtitles: [TranscodePlan.Subtitle] = []
        for (i, s) in probe.subtitles.enumerated() {
            if styled {
                let ass = dir.appendingPathComponent("styled_\(i).ass").path
                try await SubtitleStyler.makeStyledASS(tools, input: input, streamIndex: i, style: subtitleStyle, output: ass)
                subtitles.append(.init(path: ass, language: s.language, title: s.title, forced: false, shift: 0))
            } else {
                subtitles.append(.init(embeddedIndex: i, language: s.language, title: s.title))
            }
        }
        let temp = dir.appendingPathComponent("output.\(job.settings.container.fileExtension)")
        var plan = TranscodePlan(
            input: .init(path: input), audio: audio, subtitles: subtitles, settings: job.settings,
            sourceVideoCodec: video.codecName, title: job.isSerial ? job.displayTitle : job.showTitle,
            output: temp.path, encoders: encoders
        )
        plan.subtitlesAreStyledASS = styled
        try await FFmpegRunner.run(tools, plan: plan, duration: probe.duration ?? job.duration) { [weak self] p in
            Task { @MainActor in
                guard let self, self.shouldPublishProgress(id, final: p.fraction >= 1) else { return }
                self.update(id) {
                    guard $0.status == .encoding else { return }
                    $0.progress = p.fraction
                    $0.speedText = p.speed.map { "скорость \($0)" }
                }
            }
        }

        let size = { (path: String) in (try? fm.attributesOfItem(atPath: path)[.size] as? Int64) ?? nil }
        let oldSize = size(input) ?? info.originalSize ?? 0
        let newSize = size(temp.path) ?? 0
        var finalPath = input
        var note: String
        var settings = job.settings
        if newSize > 0, newSize < oldSize {
            finalPath = (input as NSString).deletingPathExtension + "." + job.settings.container.fileExtension
            if finalPath == input {
                _ = try fm.replaceItemAt(URL(fileURLWithPath: input), withItemAt: temp)
            } else {
                try? fm.removeItem(atPath: finalPath)
                try fm.moveItem(at: temp, to: URL(fileURLWithPath: finalPath))
                try? fm.removeItem(atPath: input)
            }
            note = "пережато: было \(Formatting.bytes(oldSize))"
        } else {
            settings = info.originalSettings
            note = "пережатый файл не меньше (\(Formatting.bytes(newSize))) — оставлен исходный"
        }
        try? fm.removeItem(at: dir)
        update(id) {
            $0.outputPath = finalPath
            $0.outputSize = size(finalPath)
            $0.settings = settings
            $0.note = note
            $0.recompress = nil
            $0.status = .completed
            $0.completedAt = Date()
            $0.progress = 1
            $0.speedText = nil
        }
        save()
    }

    /// Выбранные дорожки → номера аудиопотоков в файле. Если в файле меньше дорожек, чем в API, берём что есть.
    nonisolated static func mapAudio(_ selected: [SelectedAudio], sourceCount: Int) -> [TranscodePlan.Audio] {
        guard sourceCount > 0 else { return [] }
        var result: [TranscodePlan.Audio] = []
        var used = Set<Int>()
        for a in selected where a.streamPosition < sourceCount && !used.contains(a.streamPosition) {
            used.insert(a.streamPosition)
            result.append(TranscodePlan.Audio(sourceAudioIndex: a.streamPosition, language: a.language, title: a.title))
        }
        if result.isEmpty {
            // В файле одна дорожка (или выбор не совпал) — берём первую, подписываем, только если это она.
            let first = selected.first { $0.streamPosition == 0 }
            result = [TranscodePlan.Audio(sourceAudioIndex: 0, language: first?.language, title: first?.title)]
        }
        return result
    }

    // MARK: - Состояние

    public func job(_ id: UUID) -> DownloadJob? {
        jobs.first { $0.id == id }
    }

    private func update(_ id: UUID, _ change: (inout DownloadJob) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        let oldStatus = jobs[i].status
        change(&jobs[i])
        if jobs[i].status != oldStatus {
            refreshCounters()
            save()
        } else {
            scheduleSave()
        }
    }

    private func fail(_ id: UUID, _ error: Error) {
        update(id) {
            $0.status = .failed
            $0.errorMessage = error.localizedDescription
            $0.speedText = nil
        }
    }

    private func workDir(for job: DownloadJob) -> URL {
        downloadsRoot.appendingPathComponent(".kpub-tmp", isDirectory: true)
            .appendingPathComponent(job.id.uuidString, isDirectory: true)
    }

    private func loadEncoders() async {
        encoders = await tools?.availableEncoders() ?? []
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.stateURL),
              var saved = try? JSONDecoder.kpub.decode([DownloadJob].self, from: data)
        else { return }
        for i in saved.indices where saved[i].status.isActive || saved[i].status == .waitingEncode {
            saved[i].status = .queued
            saved[i].speedText = nil
        }
        jobs = saved
        refreshCounters()
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        Task {
            try? await Task.sleep(for: .seconds(3))
            saveScheduled = false
            save()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder.kpub.encode(jobs) else { return }
        try? data.write(to: Self.stateURL, options: .atomic)
    }
}

enum SubtitleFetcher {
    static func fileExtension(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        return ["srt", "vtt", "ass", "ssa"].contains(ext) ? ext : "srt"
    }

    /// Скачивает субтитры и сохраняет в UTF-8 (русские .srt нередко в cp1251).
    static func fetch(_ url: URL, to destination: URL) async throws {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue(KpubAPI.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw DownloadError.badStatus(status) }
        try normalizeEncoding(data).write(to: destination, options: .atomic)
    }

    static func normalizeEncoding(_ data: Data) -> Data {
        var text: String?
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            text = String(data: data, encoding: .utf16)
        }
        text = text ?? String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1251)
        guard var text else { return data }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return Data(text.utf8)
    }
}
