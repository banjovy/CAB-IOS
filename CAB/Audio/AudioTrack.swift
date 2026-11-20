//
//  AudioTrack.swift
//  CAB
//
//  What the audio engine is playing. Web equivalent: `currentTrack` in
//  `providers/AudioProvider.jsx`. Task 8 extends this for live streams.
//

import Foundation

struct AudioTrack: Equatable, Sendable {
    let showID: String
    let showTitle: String
    let showOwner: String?
    let artworkURL: URL?
    /// The episode title, if the feed has one.
    let episodeName: String?
    /// The audio file. Also the resume-position key (Task 7).
    let audioURL: URL
    /// Duration from the feed, shown until the real duration is known.
    let feedDurationSeconds: Int?

    /// Builds a track for a podcast episode.
    ///
    /// Returns `nil` unless the audio URL is `https`. Every live episode URL
    /// is `https` (checked in Task 6), and iOS blocks plain `http` by default.
    /// Audio hosts are not allowlisted: episodes are served by many podcast
    /// hosts and redirect trackers.
    init?(episode: PodcastEpisode, show: CatalogShow) {
        guard let url = URL(string: episode.url.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https",
              url.host(percentEncoded: false)?.isEmpty == false else { return nil }

        showID = show.id
        showTitle = show.show.title
        showOwner = show.show.owner.nonEmpty
        artworkURL = show.show.image.nonEmpty.flatMap { URL(string: $0) }
        episodeName = episode.name.nonEmpty
        audioURL = url
        feedDurationSeconds = episode.durationSeconds
    }
}
