import Foundation
import KpubCore
import SwiftUI

/// Актёр или режиссёр, по которому показываем фильмографию.
struct PersonQuery: Hashable {
    enum Role: String {
        case actor
        case director

        var title: String { self == .actor ? "Актёр" : "Режиссёр" }
    }

    let role: Role
    let name: String

    static let scheme = "kpub-person"

    var url: URL? {
        var c = URLComponents()
        c.scheme = Self.scheme
        c.host = role.rawValue
        c.queryItems = [URLQueryItem(name: "name", value: name)]
        return c.url
    }

    init(role: Role, name: String) {
        self.role = role
        self.name = name
    }

    init?(url: URL) {
        guard url.scheme == Self.scheme,
              let role = Role(rawValue: url.host() ?? ""),
              let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "name" })?.value,
              !name.isEmpty
        else { return nil }
        self.init(role: role, name: name)
    }
}

/// Все тайтлы с актёром или режиссёром.
struct PersonView: View {
    let query: PersonQuery

    var body: some View {
        CatalogView(title: query.name, sortable: true, defaultSort: .year) { api, page, sort, _ in
            try await api.items(person: query.name, role: query.role.rawValue, sort: sort, page: page)
        }
        .navigationSubtitle(query.role.title)
    }
}
