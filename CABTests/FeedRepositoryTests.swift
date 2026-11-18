//
//  FeedRepositoryTests.swift
//  CABTests
//
//  Task 4: the shows and resources repositories end to end, with the
//  network replaced by MockURLProtocol.
//

import XCTest
@testable import CAB

final class FeedRepositoryTests: XCTestCase {

    private let showsURL = FeedEndpoints.shows.absoluteString
    private let etwURL = "https://assets.cabroadcasting.com/audio/etw.json"
    private let tcwURL = "https://assets.cabroadcasting.com/audio/tcw.json"
    private let parser = FeedDateParser(timeZone: TimeZone(identifier: "America/Chicago")!)

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    // MARK: - Helpers

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: FeedRepositoryTests.self)
            .url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private var client: FeedClient { FeedClient(session: MockURLProtocol.makeSession()) }

    private func showsRepository(store: FeedCacheStore? = nil, clock: TestClock = TestClock()) -> ShowsRepository {
        ShowsRepository.make(client: client, store: store, now: { clock.now }, dateParser: parser)
    }

    private func json(_ text: String) -> Data { Data(text.utf8) }

    private func showJSON(_ id: String, category: String = "afr-podcast", jsonURL: String? = nil) -> String {
        let feed = jsonURL.map { #","json_url":"\#($0)""# } ?? ""
        return #"{"id":"\#(id)","title":"\#(id)","category":"\#(category)"\#(feed)}"#
    }

    private func assertFails(_ repository: ShowsRepository, underlying check: (Error) -> Bool,
                             file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await repository.load()
            XCTFail("Expected an error", file: file, line: line)
        } catch let error as FeedUnavailableError {
            XCTAssertEqual(error.feed, .shows, file: file, line: line)
            XCTAssertEqual(error.localizedDescription,
                           "Can't load data at this time. Please verify your network connection or try again later.",
                           file: file, line: line)
            XCTAssertTrue(check(error.underlying), "Underlying: \(error.underlying)", file: file, line: line)
        } catch {
            XCTFail("Unexpected error \(error)", file: file, line: line)
        }
    }

    // MARK: - Shows

    func testBuildsCatalogFromLiveFixturesAndToleratesMissingFeeds() async throws {
        // Only two of the 27 episode feeds are served; the rest return 404.
        MockURLProtocol.serve([
            showsURL: (200, try fixture("shows")),
            etwURL: (200, try fixture("episodes_etw")),
            tcwURL: (200, try fixture("episodes_tcw")),
        ])

        let loaded = try await showsRepository().load()
        let catalog = loaded.value

        XCTAssertFalse(loaded.isStale)
        XCTAssertEqual(catalog.shows.count, 29)
        XCTAssertEqual(catalog.showsByID["etw"]?.episodes.count, 26)
        XCTAssertEqual(catalog.showsByID["etw"]?.episodes.first?.date, "11/10/2026")
        XCTAssertEqual(catalog.showsByID["tcw"]?.episodes.count, 26)
        XCTAssertEqual(catalog.showsByID["gty"]?.episodes, [], "A 404 feed gives that show no episodes")
        XCTAssertEqual(catalog.showsByID["afr-talk"]?.streamURL, "https://mediaserver3.afa.net/talk.mp4")
        XCTAssertEqual(catalog.shows(in: .afrStream).map(\.id), ["afr-talk", "afr-music"])
    }

    func testRequestsShowsOnceAndEachEpisodeFeedOnce() async throws {
        MockURLProtocol.serve([showsURL: (200, try fixture("shows")), etwURL: (200, try fixture("episodes_etw"))])

        _ = try await showsRepository().load()

        let urls = MockURLProtocol.requestedURLs
        XCTAssertEqual(urls.count, 28, "shows.json + 27 podcast feeds")
        XCTAssertEqual(urls.filter { $0 == showsURL }.count, 1)
        XCTAssertEqual(Set(urls).count, urls.count, "No URL is requested twice")
        XCTAssertFalse(urls.contains { $0.contains("mediaserver3") }, "Stream URLs are not fetched")
    }

    func testEpisodeFeedsOnDisallowedHostsAreNotRequested() async throws {
        let allowed = "https://assets.cabroadcasting.com/audio/ok.json"
        let shows = "[\(showJSON("evil", jsonURL: "https://evil.example/feed.json")),\(showJSON("plain", jsonURL: "http://assets.cabroadcasting.com/audio/x.json")),\(showJSON("ok", jsonURL: allowed))]"
        MockURLProtocol.serve([showsURL: (200, json(shows)), allowed: (200, try fixture("episodes_etw"))])

        let catalog = try await showsRepository().load().value

        XCTAssertEqual(Set(MockURLProtocol.requestedURLs), [showsURL, allowed])
        XCTAssertEqual(catalog.showsByID["evil"]?.episodes, [])
        XCTAssertEqual(catalog.showsByID["plain"]?.episodes, [])
        XCTAssertEqual(catalog.showsByID["ok"]?.episodes.count, 26)
    }

    func testInvalidEpisodeFeedOnlyEmptiesThatShow() async throws {
        let good = "https://assets.cabroadcasting.com/audio/good.json"
        let broken = "https://assets.cabroadcasting.com/audio/broken.json"
        let shows = "[\(showJSON("good", jsonURL: good)),\(showJSON("broken", jsonURL: broken))]"
        MockURLProtocol.serve([
            showsURL: (200, json(shows)),
            good: (200, try fixture("episodes_tcw")),
            broken: (200, json("<html>not json</html>")),
        ])

        let catalog = try await showsRepository().load().value

        XCTAssertEqual(catalog.showsByID["good"]?.episodes.count, 26)
        XCTAssertEqual(catalog.showsByID["broken"]?.episodes, [])
    }

    func testDuplicateShowIdFetchesOnlyTheFirstFeed() async throws {
        let first = "https://assets.cabroadcasting.com/audio/first.json"
        let second = "https://assets.cabroadcasting.com/audio/second.json"
        let shows = "[\(showJSON("dup", jsonURL: first)),\(showJSON("dup", jsonURL: second))]"
        MockURLProtocol.serve([showsURL: (200, json(shows)), first: (200, try fixture("episodes_etw"))])

        let catalog = try await showsRepository().load().value

        XCTAssertFalse(MockURLProtocol.requestedURLs.contains(second))
        XCTAssertEqual(catalog.showsByID["dup"]?.episodes.count, 26)
    }

    func testStreamsOnlyCatalogNeedsNoEpisodeFeeds() async throws {
        let shows = "[\(showJSON("live", category: "afr-stream"))]"
        MockURLProtocol.serve([showsURL: (200, json(shows))])

        let catalog = try await showsRepository().load().value

        XCTAssertEqual(catalog.shows.map(\.id), ["live"])
        XCTAssertEqual(MockURLProtocol.requestedURLs, [showsURL])
    }

    func testAllEpisodeFeedsFailingFailsTheLoad() async throws {
        MockURLProtocol.serve([showsURL: (200, try fixture("shows"))])
        await assertFails(showsRepository()) { ($0 as? ShowsFeedError) == .noEpisodeFeedsLoaded }
    }

    func testShowsHTTPErrorFailsTheLoad() async {
        MockURLProtocol.serve([showsURL: (500, json("oops"))])
        await assertFails(showsRepository()) { ($0 as? FeedClientError) == .httpStatus(500) }
        XCTAssertEqual(MockURLProtocol.requestedURLs, [showsURL])
    }

    func testShowsPayloadThatIsNotAnArrayFailsTheLoad() async {
        MockURLProtocol.serve([showsURL: (200, json(#"{"error":"nope"}"#))])
        await assertFails(showsRepository()) { $0 is DecodingError }
    }

    func testOfflineFallsBackToCachedCatalog() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "FeedRepositoryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FeedCacheStore(directory: directory)
        let clock = TestClock()

        MockURLProtocol.serve([showsURL: (200, try fixture("shows")), etwURL: (200, try fixture("episodes_etw"))])
        let online = try await showsRepository(store: store, clock: clock).load().value

        // Next launch, 10 minutes later, with no connection.
        clock.advance(600)
        MockURLProtocol.setHandler { _ in throw URLError(.notConnectedToInternet) }
        let offline = try await showsRepository(store: store, clock: clock).load()

        XCTAssertTrue(offline.isStale)
        XCTAssertEqual(offline.value, online, "The cached snapshot rebuilds the same catalog")
    }

    func testSnapshotRoundTrip() throws {
        let snapshot = ShowsSnapshot(shows: try fixture("shows"), episodeFeeds: ["etw": try fixture("episodes_etw")])
        let data = try PropertyListEncoder().encode(snapshot)
        XCTAssertEqual(try PropertyListDecoder().decode(ShowsSnapshot.self, from: data), snapshot)

        let catalog = try ShowsFeed.decodeSnapshot(data, dateParser: parser)
        XCTAssertEqual(catalog.showsByID["etw"]?.episodes.count, 26)
    }

    // MARK: - Resources

    func testResourcesRepositoryDecodesLiveFixture() async throws {
        MockURLProtocol.serve([FeedEndpoints.resources.absoluteString: (200, try fixture("resources"))])

        let feed = try await ResourcesRepository.make(client: client, store: nil).load().value

        XCTAssertEqual(feed.items.count, 70)
        XCTAssertEqual(feed.categories.map(\.id), ["news", "teaching", "apologetics"])
    }

    func testResourcesErrorsUseResourcesMessage() async {
        for body in [(502, json("bad gateway")), (200, json("[1,2,3]"))] {
            MockURLProtocol.reset()
            MockURLProtocol.serve([FeedEndpoints.resources.absoluteString: body])
            do {
                _ = try await ResourcesRepository.make(client: client, store: nil).load()
                XCTFail("Expected an error for status \(body.0)")
            } catch {
                XCTAssertEqual((error as? FeedUnavailableError)?.feed, .resources)
                XCTAssertEqual(error.localizedDescription, "Can't load resources at this time. Please try again later.")
            }
        }
    }

    func testRepositoriesUseWebTTLs() async throws {
        let clock = TestClock()
        MockURLProtocol.serve([
            showsURL: (200, try fixture("shows")),
            etwURL: (200, try fixture("episodes_etw")),
            FeedEndpoints.resources.absoluteString: (200, try fixture("resources")),
        ])
        let shows = showsRepository(clock: clock)
        let resources = ResourcesRepository.make(client: client, store: nil, now: { clock.now })
        _ = try await shows.load()
        _ = try await resources.load()

        clock.advance(5 * 60 - 1)
        let showsBeforeExpiry = try await shows.load()
        XCTAssertFalse(showsBeforeExpiry.isStale)
        clock.advance(1)
        let showsRequestsBefore = MockURLProtocol.requestedURLs.filter { $0 == showsURL }.count
        _ = try await shows.load()
        XCTAssertEqual(MockURLProtocol.requestedURLs.filter { $0 == showsURL }.count, showsRequestsBefore + 1,
                       "Shows expire after 5 minutes")

        let resourcesURL = FeedEndpoints.resources.absoluteString
        clock.advance(10 * 60 - 1) // 15 min minus 1 s since the resources load
        _ = try await resources.load()
        XCTAssertEqual(MockURLProtocol.requestedURLs.filter { $0 == resourcesURL }.count, 1, "Still fresh")
        clock.advance(1)
        _ = try await resources.load()
        XCTAssertEqual(MockURLProtocol.requestedURLs.filter { $0 == resourcesURL }.count, 2,
                       "Resources expire after 15 minutes")
    }
}
