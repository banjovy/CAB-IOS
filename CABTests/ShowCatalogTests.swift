//
//  ShowCatalogTests.swift
//  CABTests
//
//  Task 3: aggregation (grouping, sorting, stream URLs, episodes).
//

import XCTest
@testable import CAB

final class ShowCatalogTests: XCTestCase {

    private let parser = FeedDateParser(timeZone: TimeZone(identifier: "America/Chicago")!)

    // MARK: - Helpers

    private func fixtureData(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: ShowCatalogTests.self)
            .url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    /// The live snapshot with the two captured episode feeds attached.
    private func liveCatalog() throws -> ShowCatalog {
        let shows = try Show.decodeList(from: fixtureData("shows"))
        let etw = try JSONDecoder().decode(EpisodeFeed.self, from: fixtureData("episodes_etw")).episodes
        let tcw = try JSONDecoder().decode(EpisodeFeed.self, from: fixtureData("episodes_tcw")).episodes
        return ShowCatalog(shows: shows, episodesByShowID: ["etw": etw, "tcw": tcw], dateParser: parser)
    }

    /// Builds a `Show` through its decoder, since it has no memberwise init.
    private func show(_ id: String, category: String = "afr-podcast", order: Int? = nil, url: String? = nil) throws -> Show {
        var object: [String: Any] = ["id": id, "title": id.uppercased(), "category": category]
        if let order { object["order"] = order }
        if let url { object["url"] = url }
        return try JSONDecoder().decode(Show.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func episode(_ url: String, date: String?) -> Episode {
        Episode(url: url, name: url, date: date, duration: "0:01:00", owner: nil)
    }

    // MARK: - Live snapshot

    func testLiveGroupsMatchCategories() throws {
        let catalog = try liveCatalog()
        XCTAssertEqual(catalog.shows.count, 29)
        XCTAssertEqual(catalog.showsByID.count, 29)
        XCTAssertEqual(catalog.shows(in: .afrStream).count, 2)
        XCTAssertEqual(catalog.shows(in: .afrPodcast).count, 11)
        XCTAssertEqual(catalog.shows(in: .fortisPodcast).count, 7)
        XCTAssertEqual(catalog.shows(in: .otherPodcast).count, 9)
        XCTAssertEqual(Set(catalog.groups.keys), Set(ShowCategory.allCases.map(\.rawValue)))
    }

    func testLiveGroupsKeepFeedOrderBecauseOrdersTie() throws {
        // Every live show in a category shares one `order`, so a stable sort must keep feed order.
        let catalog = try liveCatalog()
        XCTAssertEqual(catalog.shows(in: .afrStream).map(\.id), ["afr-talk", "afr-music"])
        XCTAssertEqual(catalog.shows(in: .afrPodcast).map(\.id),
                       ["etw", "adv", "jem", "aph", "atc", "thc", "sr", "taw", "idh", "ti", "ww"])
        XCTAssertEqual(catalog.shows(in: .fortisPodcast).map(\.id),
                       ["wr", "wom", "int", "fif", "fin", "fit", "tbw"])
        XCTAssertEqual(catalog.shows(in: .otherPodcast).map(\.id),
                       ["tcw", "fhh", "gty", "ar", "ams", "jtp", "lw", "bh", "rym"])
    }

    func testLiveStreamURLsOnlyForStreams() throws {
        let catalog = try liveCatalog()
        XCTAssertEqual(catalog.showsByID["afr-talk"]?.streamURL, "https://mediaserver3.afa.net/talk.mp4")
        XCTAssertEqual(catalog.showsByID["afr-music"]?.streamURL, "https://mediaserver3.afa.net/music.mp4")
        let podcasts = catalog.shows.filter { $0.show.knownCategory != .afrStream }
        XCTAssertTrue(podcasts.allSatisfy { $0.streamURL == nil }, "Podcast `url` is a source feed, not a stream")
    }

    func testLiveEpisodesAreParsedAndNewestFirst() throws {
        let catalog = try liveCatalog()

        let etw = try XCTUnwrap(catalog.showsByID["etw"]).episodes
        XCTAssertEqual(etw.count, 26)
        XCTAssertEqual(etw.first?.date, "11/10/2026")
        XCTAssertEqual(etw.first?.durationSeconds, 3050)
        XCTAssertEqual(etw.last?.date, "10/06/2026")
        XCTAssertTrue(etw.allSatisfy { $0.publishedDate != nil && $0.durationSeconds != nil })

        let tcw = try XCTUnwrap(catalog.showsByID["tcw"]).episodes
        XCTAssertEqual(tcw.first?.date, "11/07/2026")
        XCTAssertEqual(tcw.first?.durationSeconds, 3239)

        for episodes in [etw, tcw] {
            let dates = episodes.compactMap(\.publishedDate)
            XCTAssertEqual(dates, dates.sorted(by: >))
        }
    }

    func testShowsWithoutFetchedFeedsHaveNoEpisodes() throws {
        let catalog = try liveCatalog()
        XCTAssertEqual(catalog.showsByID["gty"]?.episodes, [])
        XCTAssertEqual(catalog.showsByID["afr-talk"]?.episodes, [])
    }

    // MARK: - Sorting rules

    func testOrderSortsAscendingWithMissingLastAndTiesStable() throws {
        let shows = try [show("a", order: 2), show("b"), show("c", order: 1), show("d", order: 1), show("e", order: 2)]
        let catalog = ShowCatalog(shows: shows, episodesByShowID: [:], dateParser: parser)
        XCTAssertEqual(catalog.shows(in: .afrPodcast).map(\.id), ["c", "d", "a", "e", "b"])
        XCTAssertEqual(catalog.shows.map(\.id), ["a", "b", "c", "d", "e"], "`shows` keeps feed order")
    }

    func testEpisodesSortNewestFirstWithUndatedLastAndTiesStable() throws {
        let episodes = [
            episode("undated", date: nil),
            episode("old", date: "01/02/2026"),
            episode("new-1", date: "03/04/2026"),
            episode("bad", date: "02/30/2026"),
            episode("new-2", date: "03/04/2026"),
        ]
        let catalog = ShowCatalog(shows: [try show("p")], episodesByShowID: ["p": episodes], dateParser: parser)
        XCTAssertEqual(catalog.showsByID["p"]?.episodes.map(\.url), ["new-1", "new-2", "old", "undated", "bad"])
    }

    // MARK: - Edge cases

    func testStreamURLRequiresStreamCategoryAndNonEmptyURL() throws {
        let shows = try [
            show("live", category: "afr-stream", url: "https://example.com/live.mp4"),
            show("empty", category: "afr-stream", url: ""),
            show("missing", category: "afr-stream"),
            show("podcast", category: "afr-podcast", url: "https://example.com/feed.xml"),
        ]
        let catalog = ShowCatalog(shows: shows, episodesByShowID: [:], dateParser: parser)
        XCTAssertEqual(catalog.showsByID["live"]?.streamURL, "https://example.com/live.mp4")
        XCTAssertNil(catalog.showsByID["empty"]?.streamURL)
        XCTAssertNil(catalog.showsByID["missing"]?.streamURL)
        XCTAssertNil(catalog.showsByID["podcast"]?.streamURL)
    }

    func testDuplicateShowIdsKeepFirstOccurrence() throws {
        let shows = try [show("dup", order: 1), show("other"), show("dup", category: "afr-stream", order: 9)]
        let catalog = ShowCatalog(shows: shows, episodesByShowID: [:], dateParser: parser)
        XCTAssertEqual(catalog.shows.map(\.id), ["dup", "other"])
        XCTAssertEqual(catalog.showsByID["dup"]?.show.order, 1)
        XCTAssertNil(catalog.groups["afr-stream"])
    }

    func testUnknownCategoryIsGroupedUnderItsRawValue() throws {
        let catalog = ShowCatalog(shows: [try show("n", category: "brand-new")], episodesByShowID: [:], dateParser: parser)
        XCTAssertEqual(catalog.groups["brand-new"]?.map(\.id), ["n"])
        XCTAssertTrue(ShowCategory.allCases.allSatisfy { catalog.shows(in: $0).isEmpty })
    }

    func testEmptyInputGivesEmptyCatalog() {
        let catalog = ShowCatalog(shows: [], episodesByShowID: [:], dateParser: parser)
        XCTAssertTrue(catalog.shows.isEmpty)
        XCTAssertTrue(catalog.groups.isEmpty)
        XCTAssertTrue(catalog.showsByID.isEmpty)
    }
}
