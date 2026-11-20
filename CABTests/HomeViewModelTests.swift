//
//  HomeViewModelTests.swift
//  CABTests
//
//  Task 5: Home screen state and tab filtering.
//

import XCTest
@testable import CAB

/// Hands out scripted load results in order and records each call's `forceRefresh`.
final class LoadScript: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<Loaded<ShowCatalog>, Error>]
    private var recorded: [Bool] = []

    init(_ results: [Result<Loaded<ShowCatalog>, Error>]) {
        self.results = results
    }

    var calls: [Bool] { lock.withLock { recorded } }

    func next(forceRefresh: Bool) async throws -> Loaded<ShowCatalog> {
        let result = lock.withLock { () -> Result<Loaded<ShowCatalog>, Error> in
            recorded.append(forceRefresh)
            return results.isEmpty ? .failure(URLError(.resourceUnavailable)) : results.removeFirst()
        }
        await Task.yield()
        return try result.get()
    }
}

@MainActor
final class HomeViewModelTests: XCTestCase {

    private let webShowsError = "Can't load data at this time. Please verify your network connection or try again later."

    // MARK: - Helpers

    private func fixtureData(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: HomeViewModelTests.self)
            .url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func liveCatalog() throws -> ShowCatalog {
        ShowCatalog(shows: try Show.decodeList(from: fixtureData("shows")), episodesByShowID: [:])
    }

    private func catalog(_ json: String) throws -> ShowCatalog {
        ShowCatalog(shows: try Show.decodeList(from: Data(json.utf8)), episodesByShowID: [:])
    }

    private func loaded(_ catalog: ShowCatalog, stale: Bool = false) -> Loaded<ShowCatalog> {
        Loaded(value: catalog, fetchedAt: Date(timeIntervalSince1970: 1_794_400_000), isStale: stale)
    }

    private func makeModel(_ script: LoadScript) -> HomeViewModel {
        HomeViewModel(load: { try await script.next(forceRefresh: $0) })
    }

    private func offlineError() -> FeedUnavailableError {
        FeedUnavailableError(feed: .shows, underlying: URLError(.notConnectedToInternet))
    }

    // MARK: - Tabs

    func testTabTitlesAndOrderMatchWeb() {
        XCTAssertEqual(HomeTab.allTabs.map(\.title),
                       ["All", "AFR Streams", "AFR Podcasts", "Fortis Podcasts", "Other Podcasts"])
        XCTAssertEqual(Set(HomeTab.allTabs.map(\.id)).count, HomeTab.allTabs.count, "Tab ids must be unique")
    }

    func testAllTabListsCategoriesInWebOrder() async throws {
        let catalog = try liveCatalog()
        let model = makeModel(LoadScript([.success(loaded(catalog))]))

        await model.loadIfNeeded()

        let expected = HomeTab.categoryOrder.flatMap { catalog.shows(in: $0).map(\.id) }
        XCTAssertEqual(model.visibleShows.map(\.id), expected)
        XCTAssertEqual(model.visibleShows.count, 29)
        XCTAssertEqual(Array(model.visibleShows.prefix(3).map(\.id)), ["afr-talk", "afr-music", "etw"])
    }

    func testEachCategoryTabListsOnlyItsShows() async throws {
        let model = makeModel(LoadScript([.success(loaded(try liveCatalog()))]))
        await model.loadIfNeeded()

        let expectedCounts: [ShowCategory: Int] = [.afrStream: 2, .afrPodcast: 11, .fortisPodcast: 7, .otherPodcast: 9]
        for (category, count) in expectedCounts {
            model.selectedTab = .category(category)
            XCTAssertEqual(model.visibleShows.count, count, category.rawValue)
            XCTAssertTrue(model.visibleShows.allSatisfy { $0.show.knownCategory == category }, category.rawValue)
        }
    }

    func testUnknownCategoryNeverAppearsAndEmptyTabHasNoShows() async throws {
        let catalog = try catalog(#"""
        [{"id":"new","title":"New","category":"brand-new"},
         {"id":"pod","title":"Pod","category":"afr-podcast"}]
        """#)
        let model = makeModel(LoadScript([.success(loaded(catalog))]))
        await model.loadIfNeeded()

        XCTAssertEqual(model.visibleShows.map(\.id), ["pod"])
        model.selectedTab = .category(.afrStream)
        XCTAssertEqual(model.visibleShows, [])
    }

    // MARK: - Loading

    func testStartsEmptyAndLoadsOnce() async throws {
        let script = LoadScript([.success(loaded(try liveCatalog()))])
        let model = makeModel(script)

        XCTAssertNil(model.catalog)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.visibleShows, [])

        await model.loadIfNeeded()
        await model.loadIfNeeded()

        XCTAssertNotNil(model.catalog)
        XCTAssertFalse(model.isLoading)
        XCTAssertFalse(model.isStale)
        XCTAssertEqual(script.calls, [false])
    }

    func testConcurrentFirstLoadsMakeOneCall() async throws {
        let script = LoadScript([.success(loaded(try liveCatalog()))])
        let model = makeModel(script)

        async let first: Void = model.loadIfNeeded()
        async let second: Void = model.loadIfNeeded()
        _ = await (first, second)

        XCTAssertEqual(script.calls, [false])
        XCTAssertNotNil(model.catalog)
    }

    func testFailureShowsWebMessageAndRetryRecovers() async throws {
        let script = LoadScript([.failure(offlineError()), .success(loaded(try liveCatalog()))])
        let model = makeModel(script)

        await model.loadIfNeeded()
        XCTAssertNil(model.catalog)
        XCTAssertEqual(model.errorMessage, webShowsError)
        XCTAssertFalse(model.isLoading)

        await model.retry()
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.visibleShows.count, 29)
        XCTAssertEqual(script.calls, [false, false])
    }

    func testCancellationIsNotShownAsAnError() async {
        let model = makeModel(LoadScript([.failure(CancellationError())]))

        await model.loadIfNeeded()

        XCTAssertNil(model.errorMessage)
        XCTAssertNil(model.catalog)
        XCTAssertFalse(model.isLoading)
    }

    // MARK: - Refresh

    func testRefreshForcesRefreshAndReportsStaleData() async throws {
        let catalog = try liveCatalog()
        let script = LoadScript([.success(loaded(catalog)), .success(loaded(catalog, stale: true)), .success(loaded(catalog))])
        let model = makeModel(script)

        await model.loadIfNeeded()
        await model.refresh()
        XCTAssertTrue(model.isStale)

        await model.refresh()
        XCTAssertFalse(model.isStale)
        XCTAssertEqual(script.calls, [false, true, true])
    }

    func testFailedRefreshKeepsShowingTheCatalog() async throws {
        let catalog = try liveCatalog()
        let model = makeModel(LoadScript([.success(loaded(catalog)), .failure(offlineError())]))

        await model.loadIfNeeded()
        await model.refresh()

        XCTAssertEqual(model.catalog, catalog)
        XCTAssertNil(model.errorMessage, "An error is only shown when there's nothing to show")
    }

    func testSelectedTabSurvivesRefresh() async throws {
        let catalog = try liveCatalog()
        let model = makeModel(LoadScript([.success(loaded(catalog)), .success(loaded(catalog))]))

        await model.loadIfNeeded()
        model.selectedTab = .category(.fortisPodcast)
        await model.refresh()

        XCTAssertEqual(model.selectedTab, .category(.fortisPodcast))
        XCTAssertEqual(model.visibleShows.count, 7)
    }

    // MARK: - Repository wiring

    func testRepositoryInitUsesCacheAndForcesRefreshOnPull() async throws {
        let snapshot = try PropertyListEncoder().encode(ShowsSnapshot(shows: try fixtureData("shows"), episodeFeeds: [:]))
        let fetches = LoadScript([])
        let repository = ShowsRepository(feed: .shows, cacheKey: "home-test", ttl: 300, store: nil,
                                         fetch: { _ = try? await fetches.next(forceRefresh: false); return snapshot },
                                         decode: { try ShowsFeed.decodeSnapshot($0, dateParser: FeedDateParser()) })
        let model = HomeViewModel(repository: repository)

        await model.loadIfNeeded()
        XCTAssertEqual(model.visibleShows.count, 29)
        XCTAssertEqual(fetches.calls.count, 1)

        await model.retry() // within TTL: served from cache
        XCTAssertEqual(fetches.calls.count, 1)

        await model.refresh() // pull to refresh: refetches
        XCTAssertEqual(fetches.calls.count, 2)
    }
}
