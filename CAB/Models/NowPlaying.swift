//
//  NowPlaying.swift
//  CAB
//
//  Stream now-playing payload from a show's `current_play_url` (CONTRACT.md §4).
//  Turning this into display text (music vs. talk) happens in Task 8.
//

import Foundation

struct NowPlayingFeed: Decodable, Equatable, Sendable {
    let items: [NowPlayingItem]

    /// Only the first item is used, matching the web app.
    var current: NowPlayingItem? { items.first }

    private enum CodingKeys: String, CodingKey { case items }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = c.decodeLossyArray(NowPlayingItem.self, forKey: .items)
    }
}

struct NowPlayingItem: Decodable, Equatable, Sendable {
    /// `false` means talk programming: show `showName` and the time range.
    /// Anything else (including missing) means music: show the song.
    let playsMusic: Bool?
    let showName: String?
    /// e.g. `6:30PM`.
    let startTime: String?
    let endTime: String?
    let song: NowPlayingSong?
}

struct NowPlayingSong: Decodable, Equatable, Sendable {
    let title: String?
    let artist: String?
    let album: String?
    /// Album artwork URL. Not used by the web app; a candidate for lock-screen art (Task 9).
    let albumArt: String?
}
