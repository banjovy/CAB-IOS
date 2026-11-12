//
//  ShowCatalog.swift
//  CAB
//
//  On-device port of the aggregation in the web app's `/api/data` route
//  (`fetchAndProcessShows`), minus the networking (Task 4) and caching.
//
//  Input: the decoded `shows.json` plus whatever episode feeds were fetched.
//  Output: shows with parsed episodes, grouped by category and sorted.
//

import Foundation

/// An episode with its derived values (web: `durationSeconds`, `dateParsed`).
struct PodcastEpisode: Equatable, Identifiable, Sendable {
    /// Audio URL; also the identity and resume-position key.
    let url: String
    let name: String?
    /// Raw `MM/DD/YYYY` string. The web app displays this as-is.
    let date: String?
    /// Raw `H:MM:SS` string.
    let duration: String?
    /// Parsed from `duration`; `nil` if malformed.
    let durationSeconds: Int?
    /// Parsed from `date` (local midnight); `nil` if malformed. Used for sorting.
    let publishedDate: Date?

    var id: String { url }

    init(_ episode: Episode, dateParser: FeedDateParser) {
        url = episode.url
        name = episode.name
        date = episode.date
        duration = episode.duration
        durationSeconds = EpisodeDuration.seconds(from: episode.duration)
        publishedDate = dateParser.episodeDate(episode.date)
    }
}

/// A show plus its derived values.
struct CatalogShow: Equatable, Identifiable, Sendable {
    let show: Show
    /// The live stream URL. Set only for `afr-stream` shows with a non-empty `url`
    /// (web: `category === 'afr-stream' ? show.url || null : null`).
    let streamURL: String?
    /// Newest first. Empty for streams and for podcasts whose feed is missing or failed.
    let episodes: [PodcastEpisode]

    var id: String { show.id }
}

struct ShowCatalog: Equatable, Sendable {
    /// All shows in feed order.
    let shows: [CatalogShow]
    /// Shows keyed by raw category string, each group sorted by `order`.
    let groups: [String: [CatalogShow]]
    let showsByID: [String: CatalogShow]

    /// - Parameters:
    ///   - shows: decoded `shows.json`.
    ///   - episodesByShowID: episode feeds that loaded, keyed by show id. A show
    ///     with no entry gets no episodes (web: a failed feed becomes `[]`).
    ///
    /// Differences from the web app, both for edge cases absent from the live data:
    /// - A repeated show id is ignored after its first occurrence. The web keeps
    ///   both in lists and lets the last one win in `showsById`; SwiftUI lists
    ///   need unique ids.
    /// - Undated episodes sort after all dated ones. The web sorts them as
    ///   1 Jan 1970, which only differs for dates before 1970.
    init(shows: [Show], episodesByShowID: [String: [Episode]], dateParser: FeedDateParser = FeedDateParser()) {
        var seen = Set<String>()
        let uniqueShows = shows.filter { seen.insert($0.id).inserted }

        let catalogShows = uniqueShows.map { show -> CatalogShow in
            let episodes = (episodesByShowID[show.id] ?? []).map { PodcastEpisode($0, dateParser: dateParser) }
            let streamURL = show.knownCategory == .afrStream ? show.url.flatMap { $0.isEmpty ? nil : $0 } : nil
            return CatalogShow(show: show,
                               streamURL: streamURL,
                               episodes: Self.newestFirst(episodes))
        }

        self.shows = catalogShows
        self.groups = Dictionary(grouping: catalogShows, by: \.show.category)
            .mapValues(Self.sortedByOrder)
        // Ids are unique after the filter above, so this can't trap.
        self.showsByID = Dictionary(uniqueKeysWithValues: catalogShows.map { ($0.id, $0) })
    }

    /// The sorted shows for one Home tab.
    func shows(in category: ShowCategory) -> [CatalogShow] {
        groups[category.rawValue] ?? []
    }

    // MARK: - Sorting

    /// Ascending `order`; a missing order sorts last. **Stable:** live shows in a
    /// category all share one `order`, so feed order is what users actually see.
    static func sortedByOrder(_ shows: [CatalogShow]) -> [CatalogShow] {
        shows.stableSorted { $0.show.order ?? .max }
    }

    /// Newest first; undated last. Stable, so same-day episodes keep feed order.
    static func newestFirst(_ episodes: [PodcastEpisode]) -> [PodcastEpisode] {
        episodes.stableSorted(descending: true) { $0.publishedDate ?? .distantPast }
    }
}

private extension Array {
    /// Sorts by a key, keeping the original order of elements with equal keys.
    /// Swift's `sorted(by:)` is not documented as stable, so ties are broken by index.
    func stableSorted<Key: Comparable>(descending: Bool = false, by key: (Element) -> Key) -> [Element] {
        enumerated()
            .map { (offset: $0.offset, key: key($0.element), element: $0.element) }
            .sorted { a, b in
                if a.key != b.key { return descending ? a.key > b.key : a.key < b.key }
                return a.offset < b.offset
            }
            .map(\.element)
    }
}
