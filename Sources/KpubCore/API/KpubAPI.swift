import Foundation

public struct APIConfig: Sendable, Equatable {
    /// База для /v1/* (сам API или зеркало сайта, которое его проксирует).
    public var apiBase: URL
    /// База для /oauth2/* (вход по коду устройства и обновление токена).
    public var oauthBase: URL

    public init(apiBase: URL, oauthBase: URL) {
        self.apiBase = apiBase
        self.oauthBase = oauthBase
    }

    public static let officialAPI = URL(string: "https://api.service-kp.com")!
}

public enum APIError: LocalizedError {
    case unauthorized
    case http(Int, String?)
    case decoding(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized: "Нужно войти заново"
        case .http(let code, let msg): "Ошибка API (\(code))" + (msg.map { ": \($0)" } ?? "")
        case .decoding(let msg): "Не удалось разобрать ответ API: \(msg)"
        case .network(let msg): "Сеть недоступна: \(msg)"
        }
    }
}

public struct DeviceCode: Decodable, Sendable {
    public let code: String
    public let userCode: String
    public let verificationURI: String
    public let interval: Int
    public let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case code
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case interval
        case expiresIn = "expires_in"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decode(String.self, forKey: .code)
        userCode = try c.decode(String.self, forKey: .userCode)
        verificationURI = (try? c.decodeIfPresent(String.self, forKey: .verificationURI)) ?? "https://kino.pub/device"
        interval = c.flexibleInt(.interval) ?? 5
        expiresIn = c.flexibleInt(.expiresIn) ?? 300
    }
}

public enum DevicePollResult: Sendable {
    case pending
    case authorized(AuthTokens)
}

public enum ItemSort: String, CaseIterable, Identifiable, Sendable {
    // Направление задаётся суффиксом: "rating-" — по убыванию.
    case updated = "updated-"
    case created = "created-"
    case rating = "rating-"
    case views = "views-"
    case year = "year-"
    case title = "title"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .updated: "Обновлённые"
        case .created: "Новые"
        case .rating: "По рейтингу"
        case .views: "Популярные"
        case .year: "По году"
        case .title: "По алфавиту"
        }
    }
}

/// Клиент API kino.pub. Сам обновляет токен при 401.
public actor KpubAPI {
    // Аддон Kodi перешёл на браузерный User-Agent, потому что API отвечал 403 на нестандартные.
    public static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    // Публичные client_id/secret, которыми пользуются открытые клиенты (аддон Kodi и др.).
    static let clientID = "xbmc"
    static let clientSecret = "cgg3gtifu46urtfp2zp1nqtba0k2ezxh"

    private var config: APIConfig
    private var tokens: AuthTokens?
    private var refreshTask: Task<AuthTokens, Error>?
    private let session: URLSession
    private var tokensObserver: (@Sendable (AuthTokens?) -> Void)?

    public init(config: APIConfig, tokens: AuthTokens?) {
        self.config = config
        self.tokens = tokens
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.httpAdditionalHeaders = ["User-Agent": Self.userAgent, "Accept": "application/json"]
        session = URLSession(configuration: cfg)
    }

    public func setConfig(_ config: APIConfig) { self.config = config }
    public func setTokens(_ tokens: AuthTokens?) { self.tokens = tokens }
    public func observeTokens(_ observer: @escaping @Sendable (AuthTokens?) -> Void) { tokensObserver = observer }
    public var isAuthorized: Bool { tokens != nil }
    public var currentTokens: AuthTokens? { tokens }

    // MARK: - Вход по коду устройства

    public func requestDeviceCode() async throws -> DeviceCode {
        try await oauthPost(path: "oauth2/device", params: [
            "grant_type": "device_code",
            "client_id": Self.clientID,
            "client_secret": Self.clientSecret,
        ])
    }

    public func pollDeviceToken(code: String) async throws -> DevicePollResult {
        let (data, status) = try await oauthRaw(path: "oauth2/device", params: [
            "grant_type": "device_token",
            "client_id": Self.clientID,
            "client_secret": Self.clientSecret,
            "code": code,
        ])
        if let token = try? JSONDecoder().decode(TokenResponse.self, from: data), let access = token.accessToken {
            let tokens = token.authTokens(access: access)
            setTokensAndNotify(tokens)
            return .authorized(tokens)
        }
        let error = (try? JSONDecoder().decode(OAuthErrorResponse.self, from: data))?.error ?? ""
        if error == "authorization_pending" || error == "slow_down" || status == 400 && error.isEmpty {
            return .pending
        }
        throw APIError.http(status, error.isEmpty ? String(decoding: data.prefix(200), as: UTF8.self) : error)
    }

    /// Сообщает серверу имя устройства — оно появится в списке устройств на сайте.
    public func notifyDevice() async {
        guard tokens?.isWebSession != true else { return }
        let host = Host.current().localizedName ?? "Mac"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        _ = try? await send(path: "v1/device/notify", method: "POST", form: [
            "title": "Kpub для macOS (\(host))",
            "hardware": "Mac",
            "software": "macOS \(os)",
        ]) as EmptyResponse
    }

    public func logout() {
        setTokensAndNotify(nil)
    }

    /// Манифесты hls4/hls2 API отдаёт на api.srvkp.com, который часто заблокирован;
    /// зеркало проксирует тот же путь /manifest/…, поэтому переписываем хост на базу API.
    public func manifestURL(_ url: URL) -> URL {
        guard url.path.hasPrefix("/manifest/"), url.host() != config.apiBase.host(),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let base = URLComponents(url: config.apiBase, resolvingAgainstBaseURL: false)
        else { return url }
        components.scheme = base.scheme
        components.host = base.host
        components.port = base.port
        return components.url ?? url
    }

    // MARK: - Каталог

    public func items(type: String?, sort: ItemSort, page: Int, perPage: Int = 40) async throws -> ItemsResponse {
        var q = [URLQueryItem(name: "sort", value: sort.rawValue), URLQueryItem(name: "page", value: "\(page)"),
                 URLQueryItem(name: "perpage", value: "\(perPage)")]
        if let type { q.append(URLQueryItem(name: "type", value: type)) }
        return try await send(path: "v1/items", query: q)
    }

    /// Все тайтлы с актёром (`role` = "actor") или режиссёром ("director").
    public func items(person name: String, role: String, sort: ItemSort, page: Int, perPage: Int = 40) async throws -> ItemsResponse {
        try await send(path: "v1/items", query: [
            URLQueryItem(name: role, value: name), URLQueryItem(name: "sort", value: sort.rawValue),
            URLQueryItem(name: "page", value: "\(page)"), URLQueryItem(name: "perpage", value: "\(perPage)"),
        ])
    }

    /// shortcut: fresh | hot | popular
    public func shortcut(_ name: String, type: String?, page: Int, perPage: Int = 40) async throws -> ItemsResponse {
        var q = [URLQueryItem(name: "page", value: "\(page)"), URLQueryItem(name: "perpage", value: "\(perPage)")]
        if let type { q.append(URLQueryItem(name: "type", value: type)) }
        return try await send(path: "v1/items/\(name)", query: q)
    }

    public func search(_ text: String, type: String? = nil, page: Int = 1) async throws -> ItemsResponse {
        var q = [URLQueryItem(name: "q", value: text), URLQueryItem(name: "field", value: "title"),
                 URLQueryItem(name: "page", value: "\(page)"), URLQueryItem(name: "perpage", value: "50")]
        if let type { q.append(URLQueryItem(name: "type", value: type)) }
        return try await send(path: "v1/items/search", query: q)
    }

    public func item(id: Int) async throws -> Item {
        let response: ItemResponse = try await send(path: "v1/items/\(id)")
        return response.item
    }

    public func watchingSerials() async throws -> ItemsResponse {
        try await send(path: "v1/watching/serials", query: [URLQueryItem(name: "subscribed", value: "1")])
    }

    public func bookmarkFolders() async throws -> [BookmarkFolder] {
        let response: BookmarkFoldersResponse = try await send(path: "v1/bookmarks")
        return response.items
    }

    /// id всех тайтлов в списке (проходит по всем страницам).
    public func bookmarkItemIDs(folder: Int) async throws -> [Int] {
        var ids: [Int] = []
        var page = 1
        while page <= 100 {
            let response = try await bookmarks(folder: folder, page: page)
            ids += response.items.map(\.id)
            guard response.pagination?.hasMore == true, !response.items.isEmpty else { break }
            page += 1
        }
        return ids
    }

    public func addBookmark(item: Int, folder: Int) async throws {
        let _: StatusResponse = try await send(path: "v1/bookmarks/add", method: "POST",
                                               form: ["item": "\(item)", "folder": "\(folder)"])
    }

    public func removeBookmark(item: Int, folder: Int) async throws {
        let _: StatusResponse = try await send(path: "v1/bookmarks/remove-item", method: "POST",
                                               form: ["item": "\(item)", "folder": "\(folder)"])
    }

    /// Создаёт список; возвращает его, если сервер прислал (иначе вызывающий перечитает списки).
    public func createBookmarkFolder(title: String) async throws -> BookmarkFolder? {
        let response: CreateFolderResponse = try await send(path: "v1/bookmarks/create", method: "POST", form: ["title": title])
        return response.folder
    }

    public func bookmarks(folder: Int, page: Int) async throws -> ItemsResponse {
        try await send(path: "v1/bookmarks/\(folder)", query: [URLQueryItem(name: "page", value: "\(page)")])
    }

    public func types() async throws -> [ContentType] {
        let response: TypesResponse = try await send(path: "v1/types")
        return response.items
    }

    public func user() async throws -> UserInfo {
        let response: UserResponse = try await send(path: "v1/user")
        return response.user
    }

    /// Свежие ссылки на файлы конкретного видео (ссылки CDN живут ~сутки и, похоже, привязаны к IP).
    public func freshFiles(itemID: Int, videoID: Int) async throws -> [MediaFile] {
        if let links: MediaLinksResponse = try? await send(path: "v1/items/media-links", query: [URLQueryItem(name: "mid", value: "\(videoID)")]),
           !links.files.isEmpty {
            return links.files
        }
        let item = try await item(id: itemID)
        if let v = item.videos?.first(where: { $0.id == videoID }) { return v.files }
        for season in item.seasons ?? [] {
            if let e = season.episodes.first(where: { $0.id == videoID }) { return e.files }
        }
        return []
    }

    private struct MediaLinksResponse: Decodable {
        let files: [MediaFile]
    }

    // MARK: - Транспорт

    private struct TokenResponse: Decodable {
        let accessToken: String?
        let refreshToken: String?
        let expiresIn: Double?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }

        func authTokens(access: String) -> AuthTokens {
            AuthTokens(accessToken: access, refreshToken: refreshToken,
                       expiresAt: expiresIn.map { Date().addingTimeInterval($0) })
        }
    }

    private struct OAuthErrorResponse: Decodable {
        let error: String?
    }

    private struct EmptyResponse: Decodable {}

    private struct StatusResponse: Decodable {
        let status: Int?
    }

    private struct CreateFolderResponse: Decodable {
        let folder: BookmarkFolder?

        enum CodingKeys: String, CodingKey { case folder }

        init(from decoder: Decoder) throws {
            let c = try? decoder.container(keyedBy: CodingKeys.self)
            folder = try? c?.decodeIfPresent(BookmarkFolder.self, forKey: .folder)
        }
    }

    private func setTokensAndNotify(_ tokens: AuthTokens?) {
        self.tokens = tokens
        tokensObserver?(tokens)
    }

    /// Запасные адреса OAuth: если основной недоступен по сети, пробуем следующий.
    static let fallbackOAuthBases = [URL(string: "https://api.service-kp.com")!, URL(string: "https://api.srvkp.com")!]

    private func oauthRaw(path: String, params: [String: String]) async throws -> (Data, Int) {
        let bases = [config.oauthBase] + Self.fallbackOAuthBases.filter { $0.host() != config.oauthBase.host() }
        var failures: [String] = []
        for base in bases {
            var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
            components.queryItems = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            var request = URLRequest(url: components.url!, timeoutInterval: 15)
            request.httpMethod = "POST"
            do {
                let (data, response) = try await session.data(for: request)
                return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
            } catch {
                if Task.isCancelled { throw CancellationError() }
                failures.append("\(base.host() ?? "?"): \(error.localizedDescription)")
            }
        }
        throw APIError.network(failures.joined(separator: "; "))
    }

    private func oauthPost<T: Decodable>(path: String, params: [String: String]) async throws -> T {
        let (data, status) = try await oauthRaw(path: path, params: params)
        guard (200..<300).contains(status) else {
            let err = (try? JSONDecoder().decode(OAuthErrorResponse.self, from: data))?.error
            throw APIError.http(status, err)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decoding("\(error)")
        }
    }

    private func refreshTokens() async throws -> AuthTokens {
        if let refreshTask { return try await refreshTask.value }
        guard let refresh = tokens?.refreshToken else { throw APIError.unauthorized }
        let task = Task<AuthTokens, Error> {
            let (data, status) = try await oauthRaw(path: "oauth2/token", params: [
                "grant_type": "refresh_token",
                "client_id": Self.clientID,
                "client_secret": Self.clientSecret,
                "refresh_token": refresh,
            ])
            guard (200..<300).contains(status),
                  let token = try? JSONDecoder().decode(TokenResponse.self, from: data),
                  let access = token.accessToken
            else {
                // 400/401 — refresh-токен больше не годится. Сетевые ошибки пробрасываются выше без выхода.
                if [400, 401].contains(status) { throw APIError.unauthorized }
                throw APIError.http(status, "не удалось обновить токен")
            }
            var newTokens = token.authTokens(access: access)
            if newTokens.refreshToken == nil { newTokens.refreshToken = refresh }
            return newTokens
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let newTokens = try await task.value
            setTokensAndNotify(newTokens)
            return newTokens
        } catch APIError.unauthorized {
            setTokensAndNotify(nil)
            throw APIError.unauthorized
        }
    }

    private func send<T: Decodable>(
        path: String,
        method: String = "GET",
        query: [URLQueryItem] = [],
        form: [String: String]? = nil,
        isRetry: Bool = false
    ) async throws -> T {
        guard var current = tokens else { throw APIError.unauthorized }
        if !current.isWebSession, current.isExpired, current.refreshToken != nil, !isRetry {
            current = try await refreshTokens()
        }

        var components = URLComponents(url: config.apiBase.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        // Веб-сессия: cookie зеркала подставляет URLSession из общего хранилища.
        if !current.isWebSession {
            request.setValue("Bearer \(current.accessToken)", forHTTPHeaderField: "Authorization")
        }
        if let form {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var body = URLComponents()
            body.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
            // "+" в form-urlencoded означает пробел — экранируем явно.
            request.httpBody = body.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 {
            guard !isRetry, !current.isWebSession, current.refreshToken != nil else {
                setTokensAndNotify(nil)
                throw APIError.unauthorized
            }
            _ = try await refreshTokens()
            return try await send(path: path, method: method, query: query, form: form, isRetry: true)
        }
        guard (200..<300).contains(status) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0["error"] as? String ?? $0["message"] as? String }
            throw APIError.http(status, message)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decoding("\(path): \(error)")
        }
    }
}
