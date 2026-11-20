//
//  FeedRepositories.swift
//  CAB
//
//  The two repositories the UI uses:
//  - ShowsRepository: shows.json + every podcast's episode feed → ShowCatalog
//  - ResourcesRepository: resources.json → ResourcesFeed
//
//  TTLs match the web app's KV cache: 5 minutes for shows, 15 for resources.
//

import Foundation

typealias ShowsRepository = CachedFeed<ShowCatalog>
typealias ResourcesRepository = CachedFeed<ResourcesFeed>

enum FeedCacheKey {
    static let shows = "shows"
    static let resources = "resources"
}

extension CachedFeed where Value == ShowCatalog {
    static func make(client: FeedClient = .live,
                     store: FeedCacheStore? = .live,
                     url: URL = FeedEndpoints.shows,
                     ttl: TimeInterval = 5 * 60,
                     now: @escaping @Sendable () -> Date = { Date() },
                     dateParser: FeedDateParser = FeedDateParser()) -> ShowsRepository {
        CachedFeed(feed: .shows,
                   cacheKey: FeedCacheKey.shows,
                   ttl: ttl,
                   store: store,
                   now: now,
                   fetch: { try await ShowsFeed.fetchSnapshot(client: client, showsURL: url) },
                   decode: { try ShowsFeed.decodeSnapshot($0, dateParser: dateParser) })
    }
}

extension CachedFeed where Value == ResourcesFeed {
    static func make(client: FeedClient = .live,
                     store: FeedCacheStore? = .live,
                     url: URL = FeedEndpoints.resources,
                     ttl: TimeInterval = 15 * 60,
                     now: @escaping @Sendable () -> Date = { Date() }) -> ResourcesRepository {
        CachedFeed(feed: .resources,
                   cacheKey: FeedCacheKey.resources,
                   ttl: ttl,
                   store: store,
                   now: now,
                   fetch: { try await client.data(from: url) },
                   decode: { try JSONDecoder().decode(ResourcesFeed.self, from: $0) })
    }
}

// MARK: - Shows aggregation

enum ShowsFeedError: Error, Equatable {
    /// Every episode feed failed. Usually the connection dropped after
    /// shows.json loaded, so treat the whole load as failed rather than
    /// caching a catalog with no episodes.
    case noEpisodeFeedsLoaded
}

/// Everything fetched for one shows load, as raw bytes. This is what gets
/// cached, so a cached catalog is rebuilt by the same code as a fresh one.
struct ShowsSnapshot: Codable, Equatable {
    let shows: Data
    /// Episode feed bodies keyed by show id. Shows whose feed failed are absent.
    let episodeFeeds: [String: Data]
}

enum ShowsFeed {
    /// Port of the web's `fetchAndProcessShows`, minus the processing (see
    /// `decodeSnapshot`).
    ///
    /// shows.json must load and be an array, or the load fails. Each podcast's
    /// episode feed is then fetched concurrently. URLSession already limits
    /// connections per host, so there is no extra cap. A feed that fails or is
    /// not on an allowed host gives that show no episodes (web parity), unless
    /// **every** feed fails (`ShowsFeedError.noEpisodeFeedsLoaded`).
    static func fetchSnapshot(client: FeedClient, showsURL: URL) async throws -> Data {
        let showsData = try await client.data(from: showsURL)
        let shows = try Show.decodeList(from: showsData)

        struct Target: Sendable {
            let showID: String
            let url: URL
        }
        // First occurrence of an id wins, as in ShowCatalog, so a duplicate
        // id can't race to supply that show's episodes.
        var seen = Set<String>()
        let targets = shows.compactMap { show -> Target? in
            guard seen.insert(show.id).inserted,
                  let url = client.policy.allowedURL(show.jsonURL) else { return nil }
            return Target(showID: show.id, url: url)
        }

        let feeds = await withTaskGroup(of: (String, Data?).self, returning: [String: Data].self) { group in
            for target in targets {
                group.addTask { (target.showID, try? await client.data(from: target.url)) }
            }
            var loaded: [String: Data] = [:]
            for await (showID, data) in group {
                if let data { loaded[showID] = data }
            }
            return loaded
        }

        // `try?` above swallows cancellation; don't cache a partial result.
        try Task.checkCancellation()
        if !targets.isEmpty && feeds.isEmpty { throw ShowsFeedError.noEpisodeFeedsLoaded }

        return try PropertyListEncoder().encode(ShowsSnapshot(shows: showsData, episodeFeeds: feeds))
    }

    /// Builds the catalog from a snapshot. An episode feed that isn't valid
    /// JSON gives that show no episodes (web: a `res.json()` failure is caught).
    static func decodeSnapshot(_ data: Data, dateParser: FeedDateParser) throws -> ShowCatalog {
        let snapshot = try PropertyListDecoder().decode(ShowsSnapshot.self, from: data)
        let shows = try Show.decodeList(from: snapshot.shows)
        let decoder = JSONDecoder()
        let episodes = snapshot.episodeFeeds.compactMapValues {
            try? decoder.decode(EpisodeFeed.self, from: $0).episodes
        }
        return ShowCatalog(shows: shows, episodesByShowID: episodes, dateParser: dateParser)
    }
}
