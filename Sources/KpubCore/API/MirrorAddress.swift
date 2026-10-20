import Foundation

public enum MirrorAddress {
    /// A mirror must be an HTTPS origin, not a login URL or a URL containing credentials.
    public static func normalize(_ input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let candidate = text.contains("://") ? text : "https://" + text
        guard var components = URLComponents(string: candidate),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/"
        else { return nil }
        components.path = ""
        return components.url
    }
}
