import AppKit
import KpubCore
import Observation
import WebKit

/// Общее состояние приложения: настройки, API, очередь загрузок.
@MainActor
@Observable
final class AppModel {

    private enum Keys {
        static let site = "siteURL"
        static let apiBase = "apiBaseURL"
        static let oauthBase = "oauthBaseURL"
        static let downloads = "downloadsFolder"
        static let ffmpeg = "ffmpegPath"
        static let maxDownloads = "maxDownloads"
        static let maxEncodes = "maxEncodes"
        static let encodeSettings = "lastEncodeSettings"
        static let externalEnglish = "fetchExternalEnglishSubtitles"
        static let subtitleOpacity = "subtitleOpacity"
        static let subtitleScale = "subtitleScale"
    }

    private let defaults = UserDefaults.standard

    /// Зеркало сайта — для страницы активации устройства и ссылок.
    var siteURL: String {
        didSet {
            defaults.set(siteURL, forKey: Keys.site)
            // Follow the mirror unless the user configured a separate API address.
            if apiBaseURL.isEmpty || apiBaseURL == oldValue { apiBaseURL = siteURL }
        }
    }

    var mirrorURL: URL? { MirrorAddress.normalize(siteURL) }

    func prepareWebsiteLogin() async {
        guard let url = mirrorURL else { return }
        siteURL = url.absoluteString
        await api.setConfig(Self.makeConfig(apiBase: apiBaseURL, oauthBase: oauthBaseURL))
    }
    /// Откуда брать /v1/*. Зеркало проксирует API, поэтому по умолчанию то же зеркало.
    var apiBaseURL: String { didSet { defaults.set(apiBaseURL, forKey: Keys.apiBase); applyConfig() } }
    /// Откуда брать /oauth2/* (вход и обновление токена).
    var oauthBaseURL: String { didSet { defaults.set(oauthBaseURL, forKey: Keys.oauthBase); applyConfig() } }
    var downloadsFolder: URL {
        didSet {
            defaults.set(downloadsFolder.path, forKey: Keys.downloads)
            downloads.downloadsRoot = downloadsFolder
        }
    }
    var ffmpegPath: String { didSet { defaults.set(ffmpegPath, forKey: Keys.ffmpeg); locateTools() } }
    var maxDownloads: Int {
        didSet {
            defaults.set(maxDownloads, forKey: Keys.maxDownloads)
            downloads.maxConcurrentDownloads = maxDownloads
        }
    }
    var maxEncodes: Int {
        didSet {
            defaults.set(maxEncodes, forKey: Keys.maxEncodes)
            downloads.maxConcurrentEncodes = maxEncodes
        }
    }
    /// Последние выбранные настройки пережатия — подставляются в следующий раз.
    var lastEncodeSettings: EncodeSettings {
        didSet {
            if let data = try? JSONEncoder().encode(lastEncodeSettings) { defaults.set(data, forKey: Keys.encodeSettings) }
        }
    }

    /// Насколько заметны субтитры: во встроенном плеере на лету, в MKV — стилем дорожки.
    var subtitleStyle: SubtitleStyle {
        didSet {
            defaults.set(subtitleStyle.opacity, forKey: Keys.subtitleOpacity)
            defaults.set(subtitleStyle.scale, forKey: Keys.subtitleScale)
            downloads.subtitleStyle = subtitleStyle
        }
    }
    private(set) var restyleProgress: String?

    /// Докачивать английские субтитры с OpenSubtitles, если на кинопабе их нет.
    var fetchExternalEnglish: Bool { didSet { defaults.set(fetchExternalEnglish, forKey: Keys.externalEnglish) } }

    private(set) var isAuthorized: Bool
    private(set) var user: UserInfo?
    private(set) var tools: FFmpegTools?
    /// Запрос на создание нового списка (из контекстного меню): тайтл, который туда положить.
    var newListRequest: NewListRequest?

    let api: KpubAPI
    let downloads: DownloadManager
    let bookmarks: BookmarksStore

    init() {
        let site = defaults.string(forKey: Keys.site) ?? ""
        let apiBase = defaults.string(forKey: Keys.apiBase) ?? site
        let oauthBase = defaults.string(forKey: Keys.oauthBase) ?? APIConfig.officialAPI.absoluteString
        let folder = defaults.string(forKey: Keys.downloads).map { URL(fileURLWithPath: $0) } ?? AppPaths.defaultDownloadsDirectory
        let ffmpeg = defaults.string(forKey: Keys.ffmpeg) ?? ""
        let maxDl = defaults.object(forKey: Keys.maxDownloads) as? Int ?? 2
        let maxEnc = defaults.object(forKey: Keys.maxEncodes) as? Int ?? 1
        let encode = defaults.data(forKey: Keys.encodeSettings).flatMap { try? JSONDecoder().decode(EncodeSettings.self, from: $0) }
            ?? EncodePreset.default.settings

        siteURL = site
        apiBaseURL = apiBase
        oauthBaseURL = oauthBase
        downloadsFolder = folder
        ffmpegPath = ffmpeg
        maxDownloads = maxDl
        maxEncodes = maxEnc
        lastEncodeSettings = encode
        fetchExternalEnglish = defaults.object(forKey: Keys.externalEnglish) as? Bool ?? true
        let style = SubtitleStyle(
            opacity: defaults.object(forKey: Keys.subtitleOpacity) as? Double ?? 1,
            scale: defaults.object(forKey: Keys.subtitleScale) as? Double ?? 1
        )
        subtitleStyle = style

        let tokens = TokenStore.load()
        isAuthorized = tokens != nil
        // Cookie веб-сессии кладём в общее хранилище — их подхватят все URLSession приложения.
        for cookie in tokens?.cookies ?? [] {
            if let c = cookie.httpCookie { HTTPCookieStorage.shared.setCookie(c) }
        }
        let tools = FFmpegTools.locate(customPath: ffmpeg)
        self.tools = tools

        let api = KpubAPI(config: Self.makeConfig(apiBase: apiBase, oauthBase: oauthBase), tokens: tokens)
        self.api = api
        downloads = DownloadManager(api: api, downloadsRoot: folder, tools: tools)
        bookmarks = BookmarksStore(api: api)
        downloads.subtitleStyle = style
        downloads.maxConcurrentDownloads = maxDl
        downloads.maxConcurrentEncodes = maxEnc

        Task { [weak self] in
            await api.observeTokens { tokens in
                TokenStore.save(tokens)
                Task { @MainActor in self?.isAuthorized = tokens != nil }
            }
            if tokens != nil { await self?.refreshAccount() }
        }
    }

    var deviceActivationURL: URL? {
        mirrorURL?.appendingPathComponent("device")
    }

    func didLogin() async {
        isAuthorized = true
        await api.notifyDevice()
        await refreshAccount()
    }

    func refreshAccount() async {
        user = try? await api.user()
        await bookmarks.reload()
        await saveSessionCookies()
    }

    private var apiHost: String? {
        URL(string: apiBaseURL.trimmingCharacters(in: .whitespaces))?.host()
    }

    private func sessionCookies(from cookies: [HTTPCookie]) -> [HTTPCookie] {
        guard let host = apiHost else { return [] }
        return cookies.filter { StoredCookie.matches(domain: $0.domain, host: host) }
    }

    /// Вход по cookie сайта: зеркало пускает в /v1 с той же сессией, что и веб-версию.
    func loginWithWebSession(_ cookies: [HTTPCookie]) async throws {
        let relevant = sessionCookies(from: cookies)
        guard !relevant.isEmpty else { throw APIError.unauthorized }
        relevant.forEach { HTTPCookieStorage.shared.setCookie($0) }
        let tokens = AuthTokens.webSession(relevant.map(StoredCookie.init))
        await api.setTokens(tokens)
        do {
            user = try await api.user()
        } catch {
            await api.setTokens(nil)
            throw error
        }
        TokenStore.save(tokens)
        isAuthorized = true
        await refreshAccount()
    }

    /// Сервер может обновить cookie сессии — сохраняем актуальные.
    private func saveSessionCookies() async {
        guard let current = await api.currentTokens, current.isWebSession else { return }
        let cookies = sessionCookies(from: HTTPCookieStorage.shared.cookies ?? [])
        guard !cookies.isEmpty else { return }
        let updated = AuthTokens.webSession(cookies.map(StoredCookie.init))
        guard updated != current else { return }
        await api.setTokens(updated)
        TokenStore.save(updated)
    }

    func loginWithToken(access: String, refresh: String?) async throws {
        let tokens = AuthTokens(accessToken: access, refreshToken: refresh?.nonEmptyTrimmed, expiresAt: nil)
        await api.setTokens(tokens)
        do {
            user = try await api.user()
        } catch {
            await api.setTokens(nil)
            throw error
        }
        TokenStore.save(tokens)
        await didLogin()
    }

    func logout() {
        let host = apiHost
        Task {
            await api.logout()
            user = nil
            bookmarks.clear()
            guard let host else { return }
            for cookie in HTTPCookieStorage.shared.cookies ?? [] where StoredCookie.matches(domain: cookie.domain, host: host) {
                HTTPCookieStorage.shared.deleteCookie(cookie)
            }
            let store = WKWebsiteDataStore.default().httpCookieStore
            for cookie in await store.allCookies() where StoredCookie.matches(domain: cookie.domain, host: host) {
                await store.deleteCookie(cookie)
            }
        }
    }

    /// Переписывает стиль субтитров в уже скачанных файлах (видео и звук копируются, без пережатия).
    func restyleSubtitles(_ files: [URL]) {
        guard restyleProgress == nil else {
            bookmarks.toast = "Уже применяю стиль, дождитесь окончания"
            return
        }
        guard let tools else {
            bookmarks.toast = "ffmpeg не найден"
            return
        }
        let style = subtitleStyle
        let existing = files.filter { FileManager.default.fileExists(atPath: $0.path) }
        Task {
            var done = 0
            var skipped = 0
            for (i, file) in existing.enumerated() {
                restyleProgress = "Стиль субтитров: \(i + 1) из \(existing.count)"
                bookmarks.toast = restyleProgress
                do {
                    if try await SubtitleStyler.restyle(tools, file: file, style: style) { done += 1 } else { skipped += 1 }
                } catch {
                    bookmarks.toast = "\(file.lastPathComponent): \(error.localizedDescription)"
                }
            }
            restyleProgress = nil
            bookmarks.toast = "Стиль субтитров применён к \(done) файл." + (skipped > 0 ? " (без субтитров: \(skipped))" : "")
        }
    }

    /// Находит на OpenSubtitles субтитры для готовых файлов, где их нет, и добавляет в файл без пережатия.
    func fetchMissingSubtitles(_ jobs: [DownloadJob], language: String = "eng") {
        guard restyleProgress == nil else {
            bookmarks.toast = "Дождитесь окончания предыдущей операции с файлами"
            return
        }
        guard let tools else {
            bookmarks.toast = "ffmpeg не найден"
            return
        }
        let style = subtitleStyle
        let targets = jobs.filter { $0.status == .completed && FileManager.default.fileExists(atPath: $0.outputPath) }
        Task {
            var added = 0
            var already = 0
            var notFound: [String] = []
            for (i, job) in targets.enumerated() {
                restyleProgress = "Субтитры: \(i + 1) из \(targets.count)"
                bookmarks.toast = restyleProgress
                do {
                    let probe = try await FFprobe.probe(tools, input: job.outputPath)
                    if probe.subtitles.contains(where: { Language.iso639_2($0.language) == language }) {
                        already += 1
                        continue
                    }
                    var imdb = job.imdbID
                    if imdb == nil { imdb = try? await api.item(id: job.itemID).imdb }
                    guard let imdb else {
                        notFound.append(job.displayTitle)
                        continue
                    }
                    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("kpub-sub-\(UUID().uuidString).srt")
                    defer { try? FileManager.default.removeItem(at: tmp) }
                    let found = try await OpenSubtitles.fetch(
                        imdbID: imdb, season: job.isSerial ? (job.seasonNumber ?? 1) : nil,
                        episode: job.isSerial ? job.episodeNumber : nil, language: language,
                        duration: job.duration ?? probe.duration, to: tmp
                    )
                    guard found else {
                        notFound.append(job.displayTitle)
                        continue
                    }
                    try await SubtitleStyler.addSubtitle(
                        tools, file: job.outputURL, subtitle: tmp, language: language,
                        title: "\(Language.displayName(language)) (OpenSubtitles)", style: style
                    )
                    downloads.markExternalSubtitle(job.id, language: language)
                    added += 1
                } catch {
                    notFound.append(job.displayTitle)
                    NSLog("Kpub: субтитры для \(job.displayTitle): \(error)")
                }
            }
            restyleProgress = nil
            var parts = ["Субтитры добавлены: \(added)"]
            if already > 0 { parts.append("уже были: \(already)") }
            if !notFound.isEmpty { parts.append("не нашлись: \(notFound.count)") }
            bookmarks.toast = parts.joined(separator: ", ")
        }
    }

    func locateTools() {
        tools = FFmpegTools.locate(customPath: ffmpegPath)
        downloads.tools = tools
    }

    private func applyConfig() {
        let config = Self.makeConfig(apiBase: apiBaseURL, oauthBase: oauthBaseURL)
        Task { await api.setConfig(config) }
    }

    private static func makeConfig(apiBase: String, oauthBase: String) -> APIConfig {
        APIConfig(
            apiBase: URL(string: apiBase.trimmingCharacters(in: .whitespaces)) ?? APIConfig.officialAPI,
            oauthBase: URL(string: oauthBase.trimmingCharacters(in: .whitespaces)) ?? APIConfig.officialAPI
        )
    }
}

extension String {
    var nonEmptyTrimmed: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

struct NewListRequest: Identifiable {
    let id = UUID()
    let item: Item?
}
