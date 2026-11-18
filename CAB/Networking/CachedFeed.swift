//
//  CachedFeed.swift
//  CAB
//
//  Loads a feed with a time-to-live cache in memory and on disk. Shared by
//  the shows and resources repositories (FeedRepositories.swift).
//

import Foundation

/// A loaded value and how old it is.
struct Loaded<Value: Sendable>: Sendable {
    let value: Value
    let fetchedAt: Date
    /// `true` when the value is older than the feed's TTL. This only happens
    /// when a refresh failed and cached data was returned instead of an error.
    let isStale: Bool
}

extension Loaded: Equatable where Value: Equatable {}

/// A user-facing load failure, with the web app's wording.
struct FeedUnavailableError: LocalizedError {
    enum Feed: Sendable {
        case shows
        case resources
    }

    let feed: Feed
    /// The cause, for logging and debugging. Not shown to users.
    let underlying: Error

    var errorDescription: String? {
        switch feed {
        case .shows:
            return "Can't load data at this time. Please verify your network connection or try again later."
        case .resources:
            return "Can't load resources at this time. Please try again later."
        }
    }
}

/// Loads one feed and caches it.
///
/// `load()`:
/// 1. Returns cached data if it's younger than `ttl` (memory first, then disk).
/// 2. Otherwise fetches and decodes. Only data that decodes is cached, and
///    concurrent callers share a single fetch.
/// 3. If the fetch fails and older cached data exists, returns it with
///    `isStale == true`. With no cached data, throws `FeedUnavailableError`.
///
/// Step 3 goes beyond the web app, which shows an error when its fetch fails.
/// On a phone, especially in a car, old data beats an error screen.
actor CachedFeed<Value: Sendable> {
    typealias Fetch = @Sendable () async throws -> Data
    typealias Decode = @Sendable (Data) throws -> Value

    private struct Entry: Sendable {
        let value: Value
        let fetchedAt: Date
    }

    private let feed: FeedUnavailableError.Feed
    private let cacheKey: String
    private let ttl: TimeInterval
    private let store: FeedCacheStore?
    private let now: @Sendable () -> Date
    private let fetch: Fetch
    private let decode: Decode

    private var memory: Entry?
    private var didReadDisk = false
    private var inFlight: Task<Entry, Error>?

    /// - Parameters:
    ///   - store: on-disk cache; `nil` keeps the cache in memory only.
    ///   - fetch: returns the raw payload to decode and cache.
    ///   - decode: turns a payload into a value; a throw means the payload is unusable.
    init(feed: FeedUnavailableError.Feed,
         cacheKey: String,
         ttl: TimeInterval,
         store: FeedCacheStore?,
         now: @escaping @Sendable () -> Date = { Date() },
         fetch: @escaping Fetch,
         decode: @escaping Decode) {
        self.feed = feed
        self.cacheKey = cacheKey
        self.ttl = ttl
        self.store = store
        self.now = now
        self.fetch = fetch
        self.decode = decode
    }

    /// - Parameter forceRefresh: fetch even if the cache is fresh (e.g. pull to refresh).
    ///   A failed forced refresh still falls back to cached data.
    func load(forceRefresh: Bool = false) async throws -> Loaded<Value> {
        if !forceRefresh, let cached = cachedEntry(), isFresh(cached) {
            return loaded(cached)
        }

        let task = inFlight ?? startRefresh()
        do {
            let entry = try await task.value
            finish(task)
            return loaded(entry)
        } catch {
            finish(task)
            if error is CancellationError { throw error }
            if let fallback = memory { return loaded(fallback) }
            throw FeedUnavailableError(feed: feed, underlying: error)
        }
    }

    // MARK: - Private

    private func startRefresh() -> Task<Entry, Error> {
        let task = Task { try await self.refresh() }
        inFlight = task
        return task
    }

    private func refresh() async throws -> Entry {
        let payload = try await fetch()
        let value = try decode(payload)
        let entry = Entry(value: value, fetchedAt: now())
        memory = entry
        store?.write(FeedCacheRecord(fetchedAt: entry.fetchedAt, payload: payload), forKey: cacheKey)
        return entry
    }

    private func finish(_ task: Task<Entry, Error>) {
        if inFlight == task { inFlight = nil }
    }

    /// Memory first; on first use, fall back to the disk cache.
    private func cachedEntry() -> Entry? {
        if let memory { return memory }
        guard !didReadDisk else { return nil }
        didReadDisk = true

        guard let store, let record = store.read(forKey: cacheKey) else { return nil }
        guard let value = try? decode(record.payload) else {
            store.remove(forKey: cacheKey)
            return nil
        }
        let entry = Entry(value: value, fetchedAt: record.fetchedAt)
        memory = entry
        return entry
    }

    /// A `fetchedAt` in the future (the clock moved back) counts as expired.
    private func isFresh(_ entry: Entry) -> Bool {
        let age = now().timeIntervalSince(entry.fetchedAt)
        return age >= 0 && age < ttl
    }

    private func loaded(_ entry: Entry) -> Loaded<Value> {
        Loaded(value: entry.value, fetchedAt: entry.fetchedAt, isStale: !isFresh(entry))
    }
}
