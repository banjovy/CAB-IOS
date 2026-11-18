//
//  FeedEndpoints.swift
//  CAB
//
//  Feed URLs (CONTRACT.md) and the host allowlist for fetched JSON.
//

import Foundation

enum FeedEndpoints {
    static let shows = URL(string: "https://assets.cabroadcasting.com/audio/shows.json")!
    static let resources = URL(string: "https://assets.cabroadcasting.com/resources/resources.json")!
}

/// Which URLs the app may fetch feed JSON from.
///
/// Port of the web app's `isUrlAllowed` (`/api/data`): `https` only, and the
/// host must equal an allowed host or be a subdomain of one. On the web it
/// prevents SSRF. On device it limits what a tampered `shows.json` could make
/// the app request, and matches the web: a show whose `json_url` is not
/// allowed simply gets no episodes.
///
/// Applies to JSON feeds only. Audio and artwork URLs are loaded by the
/// player and image views in later tasks.
struct FeedURLPolicy: Sendable {
    /// Lowercased host names.
    let allowedHosts: Set<String>

    init(allowedHosts: [String]) {
        self.allowedHosts = Set(allowedHosts.map { $0.lowercased() })
    }

    /// The backend's own host. Now-playing (`afr.net`) is added in Task 8.
    static let cabAssets = FeedURLPolicy(allowedHosts: ["assets.cabroadcasting.com"])

    func allows(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host(percentEncoded: false)?.lowercased(),
              !host.isEmpty else { return false }
        // A suffix match on ".host" also rules out IP literals and look-alikes
        // such as "assets.cabroadcasting.com.evil.example".
        return allowedHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Parses a URL string from a feed and returns it only if allowed.
    func allowedURL(_ text: String?) -> URL? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              let url = URL(string: trimmed),
              allows(url) else { return nil }
        return url
    }
}
