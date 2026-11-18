//
//  CachedFeedTests.swift
//  CABTests
//
//  Task 4: cache rules (TTL, stale fallback, disk persistence, sharing one
//  fetch), tested with a String feed and a scripted fetch.
//

import XCTest
@testable import CAB

/// A clock the test moves by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_794_400_000)) { current = start }

    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

/// Hands out scripted fetch results in order and counts the calls.
final class FetchScript: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<String, Error>]
    private var count = 0
    private let delay: UInt64

    init(_ results: [Result<String, Error>], delayNanoseconds: UInt64 = 0) {
        self.results = results
        self.delay = delayNanoseconds
    }

    var calls: Int { lock.withLock { count } }

    func next() async throws -> Data {
        let result = lock.withLock { () -> Result<String, Error> in
            count += 1
            return results.isEmpty ? .failure(URLError(.resourceUnavailable)) : results.removeFirst()
        }
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        return Data(try result.get().utf8)
    }
}

private struct UnusablePayload: Error {}

final class CachedFeedTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appending(path: "CachedFeedTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    private var store: FeedCacheStore { FeedCacheStore(directory: tempDirectory) }

    /// The payload "bad" fails to decode; anything else decodes to itself.
    private func makeFeed(_ script: FetchScript, clock: TestClock, store: FeedCacheStore? = nil,
                          feed: FeedUnavailableError.Feed = .shows) -> CachedFeed<String> {
        CachedFeed(feed: feed, cacheKey: "test", ttl: 300, store: store,
                   now: { clock.now },
                   fetch: { try await script.next() },
                   decode: { data in
                       let text = String(decoding: data, as: UTF8.self)
                       if text == "bad" { throw UnusablePayload() }
                       return text
                   })
    }

    // MARK: - TTL

    func testFreshCacheIsReusedWithinTTL() async throws {
        let clock = TestClock()
        let script = FetchScript([.success("one")])
        let feed = makeFeed(script, clock: clock)

        let first = try await feed.load()
        XCTAssertEqual(first, Loaded(value: "one", fetchedAt: clock.now, isStale: false))

        clock.advance(299)
        let second = try await feed.load()
        XCTAssertEqual(second.value, "one")
        XCTAssertFalse(second.isStale)
        XCTAssertEqual(script.calls, 1)
    }

    func testExpiredCacheIsRefetched() async throws {
        let clock = TestClock()
        let script = FetchScript([.success("one"), .success("two")])
        let feed = makeFeed(script, clock: clock)

        _ = try await feed.load()
        clock.advance(300)
        let refreshed = try await feed.load()

        XCTAssertEqual(refreshed, Loaded(value: "two", fetchedAt: clock.now, isStale: false))
        XCTAssertEqual(script.calls, 2)
    }

    func testClockMovingBackwardsCountsAsExpired() async throws {
        let clock = TestClock()
        let script = FetchScript([.success("one"), .success("two")])
        let feed = makeFeed(script, clock: clock)

        _ = try await feed.load()
        clock.advance(-60)
        let value = try await feed.load().value

        XCTAssertEqual(value, "two")
    }

    func testForceRefreshIgnoresFreshCache() async throws {
        let clock = TestClock()
        let script = FetchScript([.success("one"), .success("two")])
        let feed = makeFeed(script, clock: clock)

        _ = try await feed.load()
        let value = try await feed.load(forceRefresh: true).value

        XCTAssertEqual(value, "two")
        XCTAssertEqual(script.calls, 2)
    }

    // MARK: - Failures

    func testFailureWithoutCacheThrowsWebMessage() async {
        let feed = makeFeed(FetchScript([.failure(URLError(.notConnectedToInternet))]), clock: TestClock())
        do {
            _ = try await feed.load()
            XCTFail("Expected an error")
        } catch let error as FeedUnavailableError {
            XCTAssertEqual(error.feed, .shows)
            XCTAssertEqual((error.underlying as? URLError)?.code, .notConnectedToInternet)
            XCTAssertEqual(error.localizedDescription,
                           "Can't load data at this time. Please verify your network connection or try again later.")
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testResourcesFeedUsesResourcesMessage() async {
        let feed = makeFeed(FetchScript([.failure(URLError(.timedOut))]), clock: TestClock(), feed: .resources)
        do {
            _ = try await feed.load()
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Can't load resources at this time. Please try again later.")
        }
    }

    func testFailedRefreshFallsBackToStaleDataAndRetriesNextTime() async throws {
        let clock = TestClock()
        let firstFetch = clock.now
        let script = FetchScript([.success("one"), .failure(URLError(.timedOut)), .success("three")])
        let feed = makeFeed(script, clock: clock)

        _ = try await feed.load()
        clock.advance(301)

        let fallback = try await feed.load()
        XCTAssertEqual(fallback, Loaded(value: "one", fetchedAt: firstFetch, isStale: true))

        let retried = try await feed.load()
        XCTAssertEqual(retried, Loaded(value: "three", fetchedAt: clock.now, isStale: false))
        XCTAssertEqual(script.calls, 3, "A failure must not be cached")
    }

    func testFailedForceRefreshReturnsFreshCacheAsNotStale() async throws {
        let clock = TestClock()
        let feed = makeFeed(FetchScript([.success("one"), .failure(URLError(.timedOut))]), clock: clock)

        _ = try await feed.load()
        let result = try await feed.load(forceRefresh: true)

        XCTAssertEqual(result.value, "one")
        XCTAssertFalse(result.isStale, "Still within TTL")
    }

    func testUndecodablePayloadIsNotCached() async throws {
        let script = FetchScript([.success("bad"), .success("good")])
        let feed = makeFeed(script, clock: TestClock(), store: store)

        do {
            _ = try await feed.load()
            XCTFail("Expected an error")
        } catch {
            XCTAssertTrue((error as? FeedUnavailableError)?.underlying is UnusablePayload)
        }
        XCTAssertNil(store.read(forKey: "test"), "Nothing should be written to disk")

        let value = try await feed.load().value
        XCTAssertEqual(value, "good")
    }

    func testCancellationIsNotWrapped() async {
        let feed = makeFeed(FetchScript([.failure(CancellationError())]), clock: TestClock())
        do {
            _ = try await feed.load()
            XCTFail("Expected an error")
        } catch {
            XCTAssertTrue(error is CancellationError, "Got \(error)")
        }
    }

    // MARK: - Concurrency

    func testConcurrentLoadsShareOneFetch() async throws {
        let script = FetchScript([.success("one"), .success("two")], delayNanoseconds: 200_000_000)
        let feed = makeFeed(script, clock: TestClock())

        async let a = feed.load()
        async let b = feed.load()
        async let c = feed.load(forceRefresh: true)
        let values = try await [a.value, b.value, c.value]

        XCTAssertEqual(values, ["one", "one", "one"])
        XCTAssertEqual(script.calls, 1)
    }

    // MARK: - Disk cache

    func testDiskCacheServesANewInstanceWithoutFetching() async throws {
        let clock = TestClock()
        let firstFetch = clock.now
        _ = try await makeFeed(FetchScript([.success("one")]), clock: clock, store: store).load()

        clock.advance(100)
        let script = FetchScript([.success("unused")])
        let result = try await makeFeed(script, clock: clock, store: store).load()

        XCTAssertEqual(result, Loaded(value: "one", fetchedAt: firstFetch, isStale: false))
        XCTAssertEqual(script.calls, 0)
    }

    func testExpiredDiskCacheIsRefetchedAndIsTheOfflineFallback() async throws {
        let clock = TestClock()
        let firstFetch = clock.now
        _ = try await makeFeed(FetchScript([.success("one")]), clock: clock, store: store).load()

        clock.advance(400)
        let offline = makeFeed(FetchScript([.failure(URLError(.notConnectedToInternet))]), clock: clock, store: store)
        let result = try await offline.load()

        XCTAssertEqual(result, Loaded(value: "one", fetchedAt: firstFetch, isStale: true))
    }

    func testSuccessfulFetchOverwritesDiskCache() async throws {
        let clock = TestClock()
        let feed = makeFeed(FetchScript([.success("one"), .success("two")]), clock: clock, store: store)

        _ = try await feed.load()
        clock.advance(300)
        _ = try await feed.load()

        let record = try XCTUnwrap(store.read(forKey: "test"))
        XCTAssertEqual(record, FeedCacheRecord(fetchedAt: clock.now, payload: Data("two".utf8)))
    }

    func testCorruptDiskFileIsIgnored() async throws {
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: store.fileURL(forKey: "test"))

        let script = FetchScript([.success("fresh")])
        let value = try await makeFeed(script, clock: TestClock(), store: store).load().value

        XCTAssertEqual(value, "fresh")
        XCTAssertEqual(store.read(forKey: "test")?.payload, Data("fresh".utf8))
    }

    func testUndecodableDiskPayloadIsRemoved() async throws {
        let clock = TestClock()
        store.write(FeedCacheRecord(fetchedAt: clock.now, payload: Data("bad".utf8)), forKey: "test")

        let feed = makeFeed(FetchScript([.failure(URLError(.notConnectedToInternet))]), clock: clock, store: store)
        do {
            _ = try await feed.load()
            XCTFail("An unusable cache must not be served")
        } catch {
            XCTAssertTrue(error is FeedUnavailableError)
        }
        XCTAssertNil(store.read(forKey: "test"))
    }

    // MARK: - Store

    func testStoreRoundTripsAndIgnoresMissingOrOldVersions() {
        XCTAssertNil(store.read(forKey: "missing"))

        let record = FeedCacheRecord(fetchedAt: Date(timeIntervalSince1970: 1_794_400_000.5), payload: Data([0, 1, 2]))
        store.write(record, forKey: "a")
        XCTAssertEqual(store.read(forKey: "a"), record)

        store.write(FeedCacheRecord(fetchedAt: Date(), payload: Data(), version: 0), forKey: "old")
        XCTAssertNil(store.read(forKey: "old"))

        store.remove(forKey: "a")
        XCTAssertNil(store.read(forKey: "a"))
    }
}
