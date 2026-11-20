//
//  Show.swift
//  CAB
//
//  A show from `GET /audio/shows.json` (CONTRACT.md §1).
//  Raw model: values are kept as the feed sends them. Derived values
//  (stream URL, grouping, sorting) are computed in Task 3.
//

import Foundation

/// The show categories the app knows how to display.
/// `Show.category` stays a raw string so a new backend category never breaks decoding.
enum ShowCategory: String, CaseIterable, Sendable {
    case afrStream = "afr-stream"
    case afrPodcast = "afr-podcast"
    case fortisPodcast = "fortis-podcast"
    case otherPodcast = "other-podcast"
}

struct Show: Decodable, Equatable, Identifiable, Sendable {
    /// Required. Unique show id.
    let id: String
    /// Required. Display title.
    let title: String
    /// Required. Raw category string; see `knownCategory`.
    let category: String

    /// Feed source type, e.g. `afr-json`, `xml`, `afr-stream`. Informational.
    let type: String?
    /// Sort order within the category. `nil` if missing or not a number (sorts last).
    let order: Int?
    let owner: String?
    let description: String?
    /// Artwork URL.
    let image: String?
    /// Creator website.
    let link: String?
    /// For streams: the live stream URL. For podcasts: the creator's source feed (not used by the app).
    let url: String?
    /// Podcasts only: URL of the episode feed (CONTRACT.md §2).
    let jsonURL: String?
    /// Streams only: now-playing endpoint (CONTRACT.md §4).
    let currentPlayURL: String?
    /// Streams only: poll interval in seconds. Sent as a string; `nil` if missing or non-numeric.
    let updateInterval: Int?
    /// ISO-8601 timestamp of the last backend update. Informational.
    let latestUpdate: String?

    var knownCategory: ShowCategory? { ShowCategory(rawValue: category) }

    private enum CodingKeys: String, CodingKey {
        case id, title, category, type, order, owner, description, image, link, url
        case jsonURL = "json_url"
        case currentPlayURL = "current_play_url"
        case updateInterval = "update_interval"
        case latestUpdate = "latest_update"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        category = try c.decode(String.self, forKey: .category)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        // The web app sorts a non-numeric order last, so a wrong type becomes nil, not an error.
        order = try? c.decodeIfPresent(Int.self, forKey: .order)
        owner = try c.decodeIfPresent(String.self, forKey: .owner)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        image = try c.decodeIfPresent(String.self, forKey: .image)
        link = try c.decodeIfPresent(String.self, forKey: .link)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        jsonURL = try c.decodeIfPresent(String.self, forKey: .jsonURL)
        currentPlayURL = try c.decodeIfPresent(String.self, forKey: .currentPlayURL)
        updateInterval = c.decodeFlexibleInt(forKey: .updateInterval)
        latestUpdate = try c.decodeIfPresent(String.self, forKey: .latestUpdate)
    }

    /// Decodes the top-level `shows.json` array, skipping malformed shows.
    /// Throws only if the payload is not a JSON array.
    static func decodeList(from data: Data) throws -> [Show] {
        try JSONDecoder().decode(LossyArray<Show>.self, from: data).elements
    }
}
