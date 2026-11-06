import Foundation

/// The identity of one page for same-link tab reuse.
///
/// Two addresses name the same page when their normalized forms match:
/// scheme and host compared case-insensitively, a default port dropped, an
/// empty web path read as `/`, file paths standardized, and any `#fragment`
/// ignored. `url` keeps the address exactly as given, so loading it still
/// honours the fragment.
package struct BrowserPageAddress: Hashable, Sendable {
    package let url: URL
    private let normalizedIdentity: String

    package init(url: URL) {
        self.url = url
        self.normalizedIdentity = Self.normalizedIdentity(of: url)
    }

    package static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.normalizedIdentity == rhs.normalizedIdentity
    }

    package func hash(into hasher: inout Hasher) {
        hasher.combine(normalizedIdentity)
    }

    private static func normalizedIdentity(of url: URL) -> String {
        if url.isFileURL {
            return "file://" + url.standardizedFileURL.path(percentEncoded: false)
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            return url.absoluteString
        }
        components.fragment = nil
        let scheme = components.scheme?.lowercased()
        components.scheme = scheme
        components.host = components.host?.lowercased()
        if let port = components.port, port == defaultPort(forScheme: scheme) {
            components.port = nil
        }
        if scheme == "http" || scheme == "https", components.path.isEmpty {
            components.path = "/"
        }
        return components.string ?? url.absoluteString
    }

    private static func defaultPort(forScheme scheme: String?) -> Int? {
        switch scheme {
        case "http": 80
        case "https": 443
        default: nil
        }
    }
}
