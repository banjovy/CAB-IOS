//
//  Episode.swift
//  CAB
//
//  A podcast episode from a show's `json_url` feed (CONTRACT.md §2).
//  Raw model: `date` (MM/DD/YYYY) and `duration` (H:MM:SS) stay strings here;
//  they are parsed into Date / seconds in Task 3.
//

import Foundation

struct Episode: Decodable, Equatable, Sendable {
    /// Required. Direct audio URL; also the resume-position key.
    let url: String
    let name: String?
    /// `MM/DD/YYYY`.
    let date: String?
    /// `H:MM:SS` (or `MM:SS`).
    let duration: String?
    let owner: String?
}

/// The per-show episode feed: `{ "episodes": [...] }`.
struct EpisodeFeed: Decodable, Equatable, Sendable {
    /// Malformed episodes are skipped. A missing `episodes` key yields `[]`,
    /// matching the web app's `payload.episodes || []`.
    let episodes: [Episode]

    private enum CodingKeys: String, CodingKey { case episodes }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        episodes = c.decodeLossyArray(Episode.self, forKey: .episodes)
    }
}
