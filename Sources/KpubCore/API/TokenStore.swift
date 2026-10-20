import Foundation

/// Учётные данные: OAuth-токены либо cookie веб-сессии зеркала (зеркало пускает в /v1 по cookie сайта).
public struct AuthTokens: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var cookies: [StoredCookie]?

    public init(accessToken: String, refreshToken: String?, expiresAt: Date?, cookies: [StoredCookie]? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.cookies = cookies
    }

    public static func webSession(_ cookies: [StoredCookie]) -> AuthTokens {
        AuthTokens(accessToken: "", refreshToken: nil, expiresAt: nil, cookies: cookies)
    }

    public var isWebSession: Bool { accessToken.isEmpty && !(cookies ?? []).isEmpty }

    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSinceNow < 60
    }
}

public struct StoredCookie: Codable, Sendable, Equatable {
    public var name: String
    public var value: String
    public var domain: String
    public var path: String
    public var expires: Date?
    public var secure: Bool

    public init(_ cookie: HTTPCookie) {
        name = cookie.name
        value = cookie.value
        domain = cookie.domain
        path = cookie.path
        expires = cookie.expiresDate
        secure = cookie.isSecure
    }

    public var httpCookie: HTTPCookie? {
        var props: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
        if let expires { props[.expires] = expires }
        if secure { props[.secure] = "TRUE" }
        return HTTPCookie(properties: props)
    }

    /// Подходит ли cookie для хоста (с учётом ".domain").
    public static func matches(domain: String, host: String) -> Bool {
        let d = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        return host == d || host.hasSuffix("." + d)
    }
}

/// Хранит токены в Application Support с правами 0600.
/// Keychain не используем: у самоподписанной сборки после каждой пересборки он просит доступ заново.
public enum TokenStore {
    static var fileURL: URL { AppPaths.supportDirectory.appendingPathComponent("auth.json") }

    public static func load() -> AuthTokens? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder.kpub.decode(AuthTokens.self, from: data)
    }

    public static func save(_ tokens: AuthTokens?) {
        guard let tokens else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        guard let data = try? JSONEncoder.kpub.encode(tokens) else { return }
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

public enum AppPaths {
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Kpub", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static var defaultDownloadsDirectory: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kpub", isDirectory: true)
    }
}

extension JSONDecoder {
    static let kpub: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

extension JSONEncoder {
    static let kpub: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}
