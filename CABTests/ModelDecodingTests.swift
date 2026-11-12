//
//  ModelDecodingTests.swift
//  CABTests
//
//  Task 2: decoding tests for the feed models.
//
//  Fixture tests use snapshots of the live feeds captured into
//  CABTests/Fixtures (counts and values below match that snapshot, not the
//  live feeds, so refreshing fixtures means updating these assertions).
//  Edge-case tests use inline JSON for shapes the live data doesn't
//  currently contain.
//

import XCTest
@testable import CAB

final class ModelDecodingTests: XCTestCase {

    // MARK: - Helpers

    private func fixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: ModelDecodingTests.self)
        let url = try XCTUnwrap(
            bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "Missing fixture \(name).json in the test bundle"
        )
        return try Data(contentsOf: url)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // MARK: - Shows (live fixture)

    func testDecodesLiveShowsFixture() throws {
        let shows = try Show.decodeList(from: fixture("shows"))

        XCTAssertEqual(shows.count, 29)
        XCTAssertEqual(Set(shows.map(\.id)).count, shows.count, "Show ids should be unique")
        XCTAssertTrue(shows.allSatisfy { $0.knownCategory != nil }, "Every live category should be known")

        let counts = Dictionary(grouping: shows, by: \.category).mapValues(\.count)
        XCTAssertEqual(counts["afr-stream"], 2)
        XCTAssertEqual(counts["afr-podcast"], 11)
        XCTAssertEqual(counts["fortis-podcast"], 7)
        XCTAssertEqual(counts["other-podcast"], 9)
    }

    func testLiveStreamShowsHaveStreamFields() throws {
        let shows = try Show.decodeList(from: fixture("shows"))

        let talk = try XCTUnwrap(shows.first { $0.id == "afr-talk" })
        XCTAssertEqual(talk.knownCategory, .afrStream)
        XCTAssertEqual(talk.url, "https://mediaserver3.afa.net/talk.mp4")
        XCTAssertEqual(talk.currentPlayURL, "https://afr.net/api/v3/lineup/nowplaying/?network=talk")
        XCTAssertEqual(talk.updateInterval, 45, "String \"45\" should decode as 45")
        XCTAssertNil(talk.jsonURL)

        let music = try XCTUnwrap(shows.first { $0.id == "afr-music" })
        XCTAssertEqual(music.updateInterval, 15)
    }

    func testLivePodcastShowsHaveEpisodeFeeds() throws {
        let shows = try Show.decodeList(from: fixture("shows"))
        let podcasts = shows.filter { $0.knownCategory != .afrStream }

        XCTAssertEqual(podcasts.count, 27)
        XCTAssertTrue(podcasts.allSatisfy { $0.jsonURL != nil }, "Every podcast needs a json_url")
        XCTAssertTrue(podcasts.allSatisfy { $0.updateInterval == nil && $0.currentPlayURL == nil })

        let etw = try XCTUnwrap(shows.first { $0.id == "etw" })
        XCTAssertEqual(etw.title, "Exploring the Word")
        XCTAssertEqual(etw.owner, "American Family Radio")
        XCTAssertEqual(etw.order, 2)
        XCTAssertEqual(etw.type, "afr-json")
        XCTAssertEqual(etw.jsonURL, "https://assets.cabroadcasting.com/audio/etw.json")
        XCTAssertEqual(etw.image, "https://assets.cabroadcasting.com/images/etw.jpg")
        XCTAssertEqual(etw.link, "https://afr.net")
        XCTAssertEqual(etw.latestUpdate, "2026-11-11T14:06:01.112349")
        XCTAssertFalse(etw.description?.isEmpty ?? true)
    }

    // MARK: - Shows (edge cases)

    func testShowWithOnlyRequiredFieldsDecodes() throws {
        let show = try decode(Show.self, #"{"id":"x","title":"X","category":"afr-podcast"}"#)
        XCTAssertEqual(show.id, "x")
        XCTAssertNil(show.order)
        XCTAssertNil(show.owner)
        XCTAssertNil(show.jsonURL)
        XCTAssertNil(show.updateInterval)
    }

    func testUpdateIntervalAcceptsNumberOrNumericStringOnly() throws {
        func interval(_ raw: String) throws -> Int? {
            try decode(Show.self, #"{"id":"x","title":"X","category":"afr-stream","update_interval":\#(raw)}"#)
                .updateInterval
        }
        XCTAssertEqual(try interval("30"), 30)
        XCTAssertEqual(try interval(#"" 20 ""#), 20)
        XCTAssertNil(try interval(#""abc""#))
        XCTAssertNil(try interval("null"))
    }

    func testNonNumericOrderBecomesNil() throws {
        let show = try decode(Show.self, #"{"id":"x","title":"X","category":"afr-podcast","order":"2"}"#)
        XCTAssertNil(show.order, "Web sorts a non-number order last; it must not fail decoding")
    }

    func testUnknownCategoryIsKeptButNotKnown() throws {
        let show = try decode(Show.self, #"{"id":"x","title":"X","category":"brand-new"}"#)
        XCTAssertEqual(show.category, "brand-new")
        XCTAssertNil(show.knownCategory)
    }

    func testMalformedShowsAreSkipped() throws {
        let json = #"""
        [
          {"id":"good1","title":"One","category":"afr-podcast"},
          {"title":"Missing id","category":"afr-podcast"},
          null,
          42,
          {"id":"good2","title":"Two","category":"afr-stream","extra":{"nested":true}}
        ]
        """#
        let shows = try Show.decodeList(from: Data(json.utf8))
        XCTAssertEqual(shows.map(\.id), ["good1", "good2"])
    }

    func testShowsPayloadThatIsNotAnArrayThrows() {
        XCTAssertThrowsError(try Show.decodeList(from: Data(#"{"error":"nope"}"#.utf8)))
    }

    // MARK: - Episodes

    func testDecodesAfrJsonEpisodeFeed() throws {
        let feed = try JSONDecoder().decode(EpisodeFeed.self, from: fixture("episodes_etw"))

        XCTAssertEqual(feed.episodes.count, 26)
        let first = try XCTUnwrap(feed.episodes.first)
        XCTAssertEqual(first.name, "Sharing the Gospel One Conversation at a Time")
        XCTAssertEqual(first.url, "https://streamer1.afa.net/tracking/streamer1.afa.net/afr-aod/exploretheword/ETW_20261110.mp3")
        XCTAssertEqual(first.date, "11/10/2026")
        XCTAssertEqual(first.duration, "0:50:50")
        XCTAssertEqual(first.owner, "American Family Radio")
    }

    func testDecodesXmlEpisodeFeedWithoutOwner() throws {
        let feed = try JSONDecoder().decode(EpisodeFeed.self, from: fixture("episodes_tcw"))

        XCTAssertEqual(feed.episodes.count, 26)
        XCTAssertTrue(feed.episodes.allSatisfy { $0.date != nil && $0.duration != nil })
        let first = try XCTUnwrap(feed.episodes.first)
        XCTAssertEqual(first.date, "11/07/2026")
        XCTAssertEqual(first.duration, "0:53:59")
        XCTAssertNil(first.owner, "XML-sourced feeds don't include owner")
    }

    func testEpisodeFeedMissingEpisodesKeyIsEmpty() throws {
        XCTAssertEqual(try decode(EpisodeFeed.self, "{}").episodes, [])
        XCTAssertEqual(try decode(EpisodeFeed.self, #"{"episodes":null}"#).episodes, [])
    }

    func testEpisodeWithoutURLIsSkipped() throws {
        let feed = try decode(EpisodeFeed.self, #"""
        {"episodes":[
          {"name":"No url","date":"01/01/2026"},
          {"name":"Has url","url":"https://example.com/a.mp3","unknown":1}
        ]}
        """#)
        XCTAssertEqual(feed.episodes.map(\.name), ["Has url"])
    }

    // MARK: - Resources

    func testDecodesLiveResourcesFixture() throws {
        let feed = try JSONDecoder().decode(ResourcesFeed.self, from: fixture("resources"))

        XCTAssertEqual(feed.generatedAt, "2026-11-11T14:16:10.780883Z")
        XCTAssertEqual(feed.categories.map(\.id), ["news", "teaching", "apologetics"])
        XCTAssertEqual(feed.sources.count, 7)
        XCTAssertEqual(feed.items.count, 70)
        XCTAssertTrue(feed.sources.allSatisfy { $0.logo != nil })
        XCTAssertEqual(feed.items.filter { $0.thumbnail == nil }.count, 38)

        let sourceIds = Set(feed.sources.map(\.id))
        XCTAssertTrue(feed.items.allSatisfy { sourceIds.contains($0.sourceId) }, "Every item should reference a known source")

        let item = try XCTUnwrap(feed.items.first { $0.id == "alex-mcfarland-8c63939d8b7a" })
        XCTAssertEqual(item.sourceId, "alex-mcfarland")
        XCTAssertEqual(item.category, "apologetics")
        XCTAssertEqual(item.title, "Standing for Truth with Courage and Grace")
        XCTAssertEqual(item.url, "https://alexmcfarland.com/standing-for-truth-with-courage-and-grace/")
        XCTAssertEqual(item.author, "Alex McFarland")
        XCTAssertEqual(item.publishedAt, "2026-11-11T18:58:17+00:00")
        XCTAssertNil(item.thumbnail)
    }

    func testResourcesWithMissingSectionsDecodeAsEmpty() throws {
        let feed = try decode(ResourcesFeed.self, #"{"items":[{"id":"a","sourceId":"s","title":"T","url":"https://x"}]}"#)
        XCTAssertNil(feed.generatedAt)
        XCTAssertEqual(feed.categories, [])
        XCTAssertEqual(feed.sources, [])
        XCTAssertEqual(feed.items.count, 1)
        XCTAssertNil(feed.items.first?.category)
    }

    func testMalformedResourceItemsAreSkipped() throws {
        let feed = try decode(ResourcesFeed.self, #"""
        {"items":[{"id":"a","title":"No source or url"},{"id":"b","sourceId":"s","title":"OK","url":"https://x"}]}
        """#)
        XCTAssertEqual(feed.items.map(\.id), ["b"])
    }

    // MARK: - Now playing

    func testDecodesLiveTalkNowPlaying() throws {
        let feed = try JSONDecoder().decode(NowPlayingFeed.self, from: fixture("nowplaying_talk"))
        let item = try XCTUnwrap(feed.current)
        XCTAssertEqual(item.playsMusic, false)
        XCTAssertEqual(item.showName, "Grace to You with John MacArthur")
        XCTAssertEqual(item.startTime, "6:30PM")
        XCTAssertEqual(item.endTime, "7:00PM")
        XCTAssertNil(item.song)
    }

    func testDecodesLiveMusicNowPlaying() throws {
        let feed = try JSONDecoder().decode(NowPlayingFeed.self, from: fixture("nowplaying_music"))
        let item = try XCTUnwrap(feed.current)
        XCTAssertEqual(item.playsMusic, true)
        XCTAssertEqual(item.song?.title, "Reflection")
        XCTAssertEqual(item.song?.artist, "Ryan Stevenson")
        XCTAssertEqual(item.song?.album, "Flying")
        XCTAssertNotNil(item.song?.albumArt)
    }

    func testEmptyNowPlayingHasNoCurrentItem() throws {
        XCTAssertNil(try decode(NowPlayingFeed.self, "{}").current)
        XCTAssertNil(try decode(NowPlayingFeed.self, #"{"items":[]}"#).current)
    }

    func testNowPlayingWithoutPlaysMusicStillDecodes() throws {
        let item = try XCTUnwrap(try decode(NowPlayingFeed.self, #"{"items":[{"song":{"title":"T"}}]}"#).current)
        XCTAssertNil(item.playsMusic)
        XCTAssertEqual(item.song?.title, "T")
    }
}
