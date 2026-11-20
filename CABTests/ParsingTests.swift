//
//  ParsingTests.swift
//  CABTests
//
//  Task 3: duration and date parsing.
//
//  Expected epoch values were computed independently with Python's datetime
//  and zoneinfo, not with the code under test.
//

import XCTest
@testable import CAB

final class ParsingTests: XCTestCase {

    private let utc = TimeZone(identifier: "UTC")!
    private let chicago = TimeZone(identifier: "America/Chicago")!

    private func fixture<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        let url = try XCTUnwrap(Bundle(for: ParsingTests.self)
            .url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    // MARK: - Durations

    func testDurationFormats() {
        XCTAssertEqual(EpisodeDuration.seconds(from: "0:50:50"), 3050)
        XCTAssertEqual(EpisodeDuration.seconds(from: "1:02:33"), 3753)
        XCTAssertEqual(EpisodeDuration.seconds(from: "12:05"), 725)
        XCTAssertEqual(EpisodeDuration.seconds(from: "45"), 45)
        XCTAssertEqual(EpisodeDuration.seconds(from: " 0:01:00 "), 60)
        XCTAssertEqual(EpisodeDuration.seconds(from: "0:75:00"), 4500, "Web accepts minutes over 59; so do we")
    }

    func testMalformedDurationsAreNil() {
        for bad in [nil, "", "   ", "abc", "1:2:3:4", "1::3", ":30", "-1:00", "+1:00", "1.5", "1:30s", "٣:٠٠"] {
            XCTAssertNil(EpisodeDuration.seconds(from: bad), "Expected nil for \(String(describing: bad))")
        }
        XCTAssertNil(EpisodeDuration.seconds(from: "99999999999999999999:00"), "Overflow must not trap")
    }

    func testEveryFixtureEpisodeDurationParses() throws {
        for name in ["episodes_etw", "episodes_tcw"] {
            let feed = try fixture(name, as: EpisodeFeed.self)
            for episode in feed.episodes {
                XCTAssertNotNil(EpisodeDuration.seconds(from: episode.duration), "\(name): \(episode.duration ?? "nil")")
            }
        }
    }

    // MARK: - Episode dates

    func testEpisodeDateIsLocalMidnight() {
        let date = FeedDateParser(timeZone: chicago).episodeDate("11/10/2026")
        XCTAssertEqual(date?.timeIntervalSince1970, 1794290400)

        let utcDate = FeedDateParser(timeZone: utc).episodeDate("11/10/2026")
        XCTAssertEqual(utcDate?.timeIntervalSince1970, 1794268800)
    }

    func testEpisodeDateAcceptsUnpaddedAndLeapDays() {
        let parser = FeedDateParser(timeZone: utc)
        XCTAssertEqual(parser.episodeDate("1/5/2026"), parser.episodeDate("01/05/2026"))
        XCTAssertNotNil(parser.episodeDate("02/29/2028"))
    }

    func testInvalidEpisodeDatesAreNil() {
        let parser = FeedDateParser(timeZone: utc)
        for bad in [nil, "", "13/01/2026", "00/10/2026", "02/30/2026", "02/29/2026", "11/31/2026",
                    "11-10-2026", "11/10/26", "2026/11/10", "11/10", "aa/bb/cccc"] {
            XCTAssertNil(parser.episodeDate(bad), "Expected nil for \(String(describing: bad))")
        }
    }

    func testEveryFixtureEpisodeDateParses() throws {
        let parser = FeedDateParser(timeZone: chicago)
        for name in ["episodes_etw", "episodes_tcw"] {
            let feed = try fixture(name, as: EpisodeFeed.self)
            for episode in feed.episodes {
                XCTAssertNotNil(parser.episodeDate(episode.date), "\(name): \(episode.date ?? "nil")")
            }
        }
    }

    // MARK: - Timestamps

    func testTimestampWithOffsets() throws {
        let parser = FeedDateParser(timeZone: chicago) // must be ignored when an offset is present
        XCTAssertEqual(parser.timestamp("2026-11-11T18:58:17+00:00")?.timeIntervalSince1970, 1794423497)
        XCTAssertEqual(parser.timestamp("2026-11-11T18:58:17Z")?.timeIntervalSince1970, 1794423497)
        XCTAssertEqual(parser.timestamp("2026-11-11T18:58:17+05:30")?.timeIntervalSince1970, 1794403697)
        XCTAssertEqual(parser.timestamp("2026-11-11T18:58:17+0530")?.timeIntervalSince1970, 1794403697)
    }

    func testTimestampWithFractionalSeconds() throws {
        let date = try XCTUnwrap(FeedDateParser(timeZone: chicago).timestamp("2026-11-11T14:16:10.780883Z"))
        XCTAssertEqual(date.timeIntervalSince1970, 1794406570.780883, accuracy: 0.000_01)
    }

    func testTimestampWithoutOffsetUsesParserTimeZone() {
        // Web parity: JavaScript reads an offset-less date-time as local time.
        XCTAssertEqual(FeedDateParser(timeZone: chicago).timestamp("2026-11-11T18:58:17")?.timeIntervalSince1970,
                       1794445097, "CST in November")
        XCTAssertEqual(FeedDateParser(timeZone: chicago).timestamp("2026-07-04T09:00:00")?.timeIntervalSince1970,
                       1783173600, "CDT in July")
        XCTAssertEqual(FeedDateParser(timeZone: utc).timestamp("2026-11-11T18:58:17")?.timeIntervalSince1970,
                       1794423497)
    }

    func testOffsetlessMidnightEasternKeepsItsCalendarDateForUSReaders() throws {
        // These look like midnight US Eastern written in UTC without the "Z".
        // Reading them as local time (web parity) keeps the intended date.
        let date = try XCTUnwrap(FeedDateParser(timeZone: chicago).timestamp("2026-11-11T05:00:00"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = chicago
        XCTAssertEqual(calendar.dateComponents([.month, .day], from: date), DateComponents(month: 11, day: 11))
    }

    func testInvalidTimestampsAreNil() {
        let parser = FeedDateParser(timeZone: utc)
        for bad in [nil, "", "not a date", "2026-11-11", "2026-11-11 18:58:17", "2026-13-11T18:58:17Z",
                    "2026-02-30T00:00:00Z", "2026-11-11T24:00:00Z", "2026-11-11T18:60:00Z",
                    "2026-11-11T18:58:17+25:00", "2026-11-11T18:58:17+05:3"] {
            XCTAssertNil(parser.timestamp(bad), "Expected nil for \(String(describing: bad))")
        }
    }

    func testDSTSkippedLocalTimeIsNil() {
        // 2:30 AM on 8 Mar 2026 doesn't exist in Chicago (clocks jump 2:00 → 3:00).
        XCTAssertNil(FeedDateParser(timeZone: chicago).timestamp("2026-03-08T02:30:00"))
    }

    func testEveryLiveTimestampParses() throws {
        let parser = FeedDateParser(timeZone: chicago)

        let resources = try fixture("resources", as: ResourcesFeed.self)
        XCTAssertNotNil(parser.timestamp(resources.generatedAt))
        for item in resources.items {
            XCTAssertNotNil(parser.timestamp(item.publishedAt), "publishedAt \(item.publishedAt ?? "nil")")
        }

        let showsURL = try XCTUnwrap(Bundle(for: ParsingTests.self)
            .url(forResource: "shows", withExtension: "json", subdirectory: "Fixtures"))
        for show in try Show.decodeList(from: Data(contentsOf: showsURL)) {
            XCTAssertNotNil(parser.timestamp(show.latestUpdate), "latest_update for \(show.id)")
        }
    }
}
