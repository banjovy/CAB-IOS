//
//  AudioEngineTests.swift
//  CABTests
//
//  Task 6: the audio engine's rules, with a fake player and audio session.
//

import AVFoundation
import XCTest
@testable import CAB

/// Everything the engine asked the player and audio session to do, in order.
@MainActor
final class AudioCallLog {
    enum Call: Equatable {
        case replace(URL?)
        case play
        case pause
        case seek(Double)
        case rate(Float)
        case activate
        case deactivate
    }

    var calls: [Call] = []
}

@MainActor
final class FakePlaybackDriver: PlaybackDriver {
    var onEvent: ((Int, PlaybackEvent) -> Void)?
    var currentTime: Double = 0
    private(set) var itemID = 0
    private let log: AudioCallLog

    init(log: AudioCallLog) { self.log = log }

    func replaceItem(with url: URL?) -> Int {
        log.calls.append(.replace(url))
        itemID += 1
        currentTime = 0
        return itemID
    }

    func play() { log.calls.append(.play) }
    func pause() { log.calls.append(.pause) }
    func setRate(_ rate: Float) { log.calls.append(.rate(rate)) }

    /// Seeks not yet finished. Like AVPlayer, `currentTime` keeps the old
    /// position until a seek finishes.
    private(set) var pendingSeeks: [(id: Int, target: Double)] = []
    private var seekID = 0

    func seek(to seconds: Double) -> Int {
        log.calls.append(.seek(seconds))
        seekID += 1
        pendingSeeks.append((seekID, seconds))
        return seekID
    }

    /// Finishes every pending seek, oldest first, as the player would.
    func finishSeeks() {
        let seeks = pendingSeeks
        pendingSeeks = []
        for seek in seeks {
            currentTime = seek.target
            send(.seekFinished(seek.id))
        }
    }

    /// Sends an event as the player would. Defaults to the current item.
    func send(_ event: PlaybackEvent, itemID: Int? = nil) {
        onEvent?(itemID ?? self.itemID, event)
    }
}

@MainActor
final class FakeAudioSession: AudioSessionControlling {
    var onEvent: ((AudioSessionEvent) -> Void)?
    private let log: AudioCallLog

    init(log: AudioCallLog) { self.log = log }

    func activate() throws { log.calls.append(.activate) }
    func deactivate() { log.calls.append(.deactivate) }

    func send(_ event: AudioSessionEvent) { onEvent?(event) }
}

@MainActor
final class AudioEngineTests: XCTestCase {

    private var log: AudioCallLog!
    private var driver: FakePlaybackDriver!
    private var session: FakeAudioSession!
    private var engine: AudioEngine!

    override func setUp() async throws {
        log = AudioCallLog()
        driver = FakePlaybackDriver(log: log)
        session = FakeAudioSession(log: log)
        engine = AudioEngine(driver: driver, session: session)
    }

    // MARK: - Helpers

    private let episodeURL = URL(string: "https://streamer1.afa.net/afr-aod/exploretheword/ETW_20261110.mp3")!

    /// An episode and its show, built through the real decoders and catalog.
    private func episode(url: String, feedDuration: String?) throws -> (PodcastEpisode, CatalogShow) {
        let feed = #"{"episodes":[{"name":"Sharing the Gospel","url":"\#(url)","date":"11/10/2026"\#(feedDuration.map { #","duration":"\#($0)""# } ?? "")}]}"#
        let episodes = try JSONDecoder().decode(EpisodeFeed.self, from: Data(feed.utf8)).episodes
        let shows = try Show.decodeList(from: Data(#"""
        [{"id":"etw","title":"Exploring the Word","category":"afr-podcast","owner":"American Family Radio",
          "image":"https://assets.cabroadcasting.com/images/etw.jpg"}]
        """#.utf8))
        let catalog = ShowCatalog(shows: shows, episodesByShowID: ["etw": episodes])
        let show = try XCTUnwrap(catalog.showsByID["etw"])
        return (try XCTUnwrap(show.episodes.first), show)
    }

    private func track(url: String = "https://streamer1.afa.net/afr-aod/exploretheword/ETW_20261110.mp3",
                       feedDuration: String? = "0:50:50") throws -> AudioTrack {
        let (episode, show) = try episode(url: url, feedDuration: feedDuration)
        return try XCTUnwrap(AudioTrack(episode: episode, show: show))
    }

    /// Loads a track and starts it, as a player screen would.
    private func loadAndPlay(feedDuration: String? = "0:50:50") throws {
        engine.load(try track(feedDuration: feedDuration), autoplay: true)
        driver.send(.status(.playing))
        log.calls = []
    }

    // MARK: - Tracks

    func testTrackCopiesShowAndEpisodeDetails() throws {
        let track = try track()
        XCTAssertEqual(track.showID, "etw")
        XCTAssertEqual(track.showTitle, "Exploring the Word")
        XCTAssertEqual(track.showOwner, "American Family Radio")
        XCTAssertEqual(track.artworkURL?.absoluteString, "https://assets.cabroadcasting.com/images/etw.jpg")
        XCTAssertEqual(track.episodeName, "Sharing the Gospel")
        XCTAssertEqual(track.audioURL, episodeURL)
        XCTAssertEqual(track.feedDurationSeconds, 3050)
    }

    func testTrackRequiresAnHTTPSAudioURL() throws {
        let (good, show) = try episode(url: "HTTPS://media.blubrry.com/x/episode.mp3", feedDuration: nil)
        XCTAssertNotNil(AudioTrack(episode: good, show: show))
        for bad in ["http://streamer1.afa.net/x.mp3", "ftp://example.com/x.mp3", "file:///etc/passwd", "not a url", "https://"] {
            let (episode, show) = try episode(url: bad, feedDuration: nil)
            XCTAssertNil(AudioTrack(episode: episode, show: show), bad)
        }
    }

    func testEveryLiveFixtureEpisodeMakesATrack() throws {
        for (name, showID) in [("episodes_etw", "etw"), ("episodes_tcw", "tcw")] {
            let url = try XCTUnwrap(Bundle(for: AudioEngineTests.self)
                .url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
            let episodes = try JSONDecoder().decode(EpisodeFeed.self, from: Data(contentsOf: url)).episodes
            let show = try Show.decodeList(from: Data(#"[{"id":"\#(showID)","title":"T","category":"afr-podcast"}]"#.utf8))
            let catalogShow = try XCTUnwrap(ShowCatalog(shows: show, episodesByShowID: [showID: episodes]).showsByID[showID])
            XCTAssertTrue(catalogShow.episodes.allSatisfy { AudioTrack(episode: $0, show: catalogShow) != nil }, name)
        }
    }

    // MARK: - Loading

    func testLoadResetsStateAndSeedsTheFeedDuration() throws {
        try loadAndPlay()
        driver.send(.time(600))
        engine.setPlaybackRate(1.5)

        engine.load(try track(feedDuration: "0:24:57"))

        XCTAssertEqual(engine.currentTrack?.showID, "etw")
        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(engine.elapsedSeconds, 0)
        XCTAssertEqual(engine.durationSeconds, 1497, "The feed's duration until the real one arrives")
        XCTAssertEqual(engine.playbackRate, 1.5, "Speed is kept across tracks (web parity)")
        XCTAssertEqual(log.calls, [.rate(1.5), .pause, .replace(episodeURL), .rate(1.5)])
    }

    func testLoadWithoutAutoplayPausesBeforeReplacing() throws {
        // Pausing first matters when something is playing: AVPlayer keeps playing a replaced item.
        try loadAndPlay()
        engine.load(try track())
        XCTAssertEqual(log.calls, [.pause, .replace(episodeURL), .rate(1)])
        XCTAssertFalse(engine.isPlaying)
    }

    func testAutoplayActivatesTheSessionBeforePlaying() throws {
        engine.load(try track(), autoplay: true)
        XCTAssertEqual(log.calls, [.pause, .replace(episodeURL), .rate(1), .activate, .play])
    }

    func testUnknownFeedDurationLeavesDurationNil() throws {
        engine.load(try track(feedDuration: nil))
        XCTAssertNil(engine.durationSeconds)
        XCTAssertEqual(engine.progress, 0)
    }

    func testTransportDoesNothingWithoutATrack() {
        engine.play()
        engine.pause()
        engine.togglePlayPause()
        engine.stop()
        engine.skip(by: 30)
        engine.seek(to: 10)
        XCTAssertEqual(log.calls, [])
        XCTAssertNil(engine.currentTrack)
    }

    // MARK: - Player events

    func testStatusEventsDriveIsPlayingAndIsBuffering() throws {
        engine.load(try track())

        driver.send(.status(.buffering))
        XCTAssertTrue(engine.isPlaying)
        XCTAssertTrue(engine.isBuffering)

        driver.send(.status(.playing))
        XCTAssertTrue(engine.isPlaying)
        XCTAssertFalse(engine.isBuffering)

        driver.send(.status(.paused))
        XCTAssertFalse(engine.isPlaying)
        XCTAssertFalse(engine.isBuffering)
    }

    func testTimeAndDurationEventsUpdateProgress() throws {
        try loadAndPlay(feedDuration: nil)
        driver.send(.time(30))
        XCTAssertEqual(engine.elapsedSeconds, 30)
        XCTAssertEqual(engine.progress, 0, "No duration yet")

        driver.send(.duration(120))
        XCTAssertEqual(engine.progress, 0.25, accuracy: 0.0001)

        driver.send(.time(500))
        XCTAssertEqual(engine.progress, 1, "Capped at 1")
    }

    func testRealDurationReplacesFeedDurationAndBadValuesAreIgnored() throws {
        try loadAndPlay()
        driver.send(.duration(3047.5))
        XCTAssertEqual(engine.durationSeconds, 3047.5)

        driver.send(.duration(.nan))
        driver.send(.duration(0))
        driver.send(.time(.infinity))
        XCTAssertEqual(engine.durationSeconds, 3047.5)
        XCTAssertEqual(engine.elapsedSeconds, 0)
    }

    func testEventsFromAReplacedItemAreIgnored() throws {
        try loadAndPlay()
        let oldItem = driver.itemID
        engine.load(try track())

        driver.send(.time(900), itemID: oldItem)
        driver.send(.status(.playing), itemID: oldItem)
        driver.send(.failed, itemID: oldItem)

        XCTAssertEqual(engine.elapsedSeconds, 0)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertNil(engine.errorMessage)
    }

    // MARK: - Transport

    func testPauseAndToggle() throws {
        try loadAndPlay()
        engine.togglePlayPause()
        XCTAssertEqual(log.calls, [.pause])

        driver.send(.status(.paused))
        engine.togglePlayPause()
        XCTAssertEqual(log.calls, [.pause, .activate, .play])
    }

    func testStopRewindsAndKeepsTheTrack() throws {
        try loadAndPlay()
        driver.send(.time(600))

        engine.stop()

        XCTAssertEqual(log.calls, [.pause, .seek(0)])
        XCTAssertEqual(engine.elapsedSeconds, 0)
        XCTAssertNotNil(engine.currentTrack)
    }

    func testSkipUsesThePlayerPositionAndStaysInTheEpisode() throws {
        try loadAndPlay() // feed duration 3050 s
        driver.currentTime = 100

        engine.skip(by: AudioEngine.skipInterval)
        driver.finishSeeks()
        engine.skip(by: -AudioEngine.skipInterval)
        driver.finishSeeks()
        driver.currentTime = 10
        engine.skip(by: -30)
        driver.finishSeeks()
        driver.currentTime = 3040
        engine.skip(by: 30)

        XCTAssertEqual(log.calls, [.seek(130), .seek(100), .seek(0), .seek(3050)])
        XCTAssertEqual(engine.elapsedSeconds, 3050)
    }

    func testQuickRepeatedSkipsAddUp() throws {
        try loadAndPlay()
        driver.currentTime = 100

        // Three taps before the player has moved: it still reports 100.
        engine.skip(by: 30)
        engine.skip(by: 30)
        engine.skip(by: -30)

        XCTAssertEqual(log.calls, [.seek(130), .seek(160), .seek(130)])
        XCTAssertEqual(engine.elapsedSeconds, 130)
    }

    func testPositionUpdatesWaitForTheSeekToFinish() throws {
        try loadAndPlay()
        engine.seek(to: 500)
        XCTAssertTrue(engine.isSeeking)

        driver.send(.time(12)) // the old position, reported before the seek lands
        XCTAssertEqual(engine.elapsedSeconds, 500)

        driver.finishSeeks()
        XCTAssertFalse(engine.isSeeking)
        driver.send(.time(500.5))
        XCTAssertEqual(engine.elapsedSeconds, 500.5)
    }

    func testOnlyTheLatestSeekFinishingEndsSeeking() throws {
        try loadAndPlay()
        engine.seek(to: 100)
        let first = try XCTUnwrap(driver.pendingSeeks.first?.id)
        engine.seek(to: 200)

        driver.send(.seekFinished(first))
        XCTAssertTrue(engine.isSeeking, "The older seek finishing isn't enough")
        XCTAssertEqual(engine.elapsedSeconds, 200)

        driver.finishSeeks()
        XCTAssertFalse(engine.isSeeking)
    }

    func testLoadingANewTrackEndsAPendingSeek() throws {
        try loadAndPlay()
        engine.seek(to: 100)
        let oldItem = driver.itemID
        let oldSeek = try XCTUnwrap(driver.pendingSeeks.last?.id)

        engine.load(try track())
        XCTAssertFalse(engine.isSeeking)

        driver.send(.time(42))
        XCTAssertEqual(engine.elapsedSeconds, 42, "Position updates work again for the new track")
        driver.send(.seekFinished(oldSeek), itemID: oldItem)
        XCTAssertFalse(engine.isSeeking)
    }

    func testSkipWithUnknownDurationHasNoUpperLimit() throws {
        try loadAndPlay(feedDuration: nil)
        driver.currentTime = 5000
        engine.skip(by: 30)
        XCTAssertEqual(log.calls, [.seek(5030)])
    }

    func testSeekClampsAndIgnoresNonFiniteValues() throws {
        try loadAndPlay()
        engine.seek(to: -5)
        engine.seek(to: 99_999)
        engine.seek(to: .nan)
        engine.seek(to: 1234.5)
        XCTAssertEqual(log.calls, [.seek(0), .seek(3050), .seek(1234.5)])
        XCTAssertEqual(engine.elapsedSeconds, 1234.5, "Updated right away for the UI")
    }

    func testPlayAfterTheEndStartsOver() throws {
        try loadAndPlay()
        driver.send(.ended)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(engine.elapsedSeconds, 3050)

        engine.play()
        XCTAssertEqual(log.calls, [.seek(0), .activate, .play])

        engine.pause()
        engine.play()
        XCTAssertEqual(log.calls.suffix(3), [.pause, .activate, .play], "Only the first play after the end rewinds")
    }

    // MARK: - Speed

    func testCyclePlaybackRateMatchesWebOrder() throws {
        engine.load(try track())
        var seen: [Float] = []
        for _ in 0..<6 {
            engine.cyclePlaybackRate()
            seen.append(engine.playbackRate)
        }
        XCTAssertEqual(seen, [1.25, 1.5, 1.75, 2, 1, 1.25])
        XCTAssertEqual(log.calls.last, .rate(1.25))
    }

    func testUnlistedRateCyclesToOneAndInvalidRatesAreIgnored() {
        engine.setPlaybackRate(0.8)
        engine.cyclePlaybackRate()
        XCTAssertEqual(engine.playbackRate, 1)

        engine.setPlaybackRate(0)
        engine.setPlaybackRate(-1)
        engine.setPlaybackRate(.nan)
        XCTAssertEqual(engine.playbackRate, 1)
        XCTAssertEqual(log.calls, [.rate(0.8), .rate(1)])
    }

    // MARK: - Errors

    func testFailureShowsAMessageAndPlayOrLoadClearsIt() throws {
        try loadAndPlay()
        driver.send(.failed)
        XCTAssertEqual(engine.errorMessage, AudioEngine.playbackFailedMessage)
        XCTAssertFalse(engine.isPlaying)

        engine.play()
        XCTAssertNil(engine.errorMessage)

        driver.send(.failed)
        engine.load(try track())
        XCTAssertNil(engine.errorMessage)
    }

    // MARK: - Dismiss

    func testDismissUnloadsAndReleasesTheSession() throws {
        try loadAndPlay()
        driver.send(.time(42))

        engine.dismiss()

        XCTAssertEqual(log.calls, [.pause, .replace(nil), .deactivate])
        XCTAssertNil(engine.currentTrack)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(engine.elapsedSeconds, 0)
        XCTAssertNil(engine.durationSeconds)

        driver.send(.status(.playing))
        XCTAssertFalse(engine.isPlaying, "Nothing is loaded, so events are ignored")
    }

    // MARK: - Interruptions and output changes

    func testInterruptionResumesWhenThePauseEventArrivesFirst() throws {
        try loadAndPlay()
        // The system pauses the player, and that event can beat the interruption notice.
        driver.send(.status(.paused))
        session.send(.interruptionBegan)
        session.send(.interruptionEnded(shouldResume: true))

        XCTAssertEqual(log.calls, [.activate, .play])
    }

    func testInterruptionDoesNotResumeWithoutTheSystemHint() throws {
        try loadAndPlay()
        session.send(.interruptionBegan)
        driver.send(.status(.paused))
        session.send(.interruptionEnded(shouldResume: false))
        XCTAssertEqual(log.calls, [])
    }

    func testInterruptionDoesNotResumeWhatTheUserPaused() throws {
        try loadAndPlay()
        engine.pause()
        driver.send(.status(.paused))
        session.send(.interruptionBegan)
        session.send(.interruptionEnded(shouldResume: true))
        XCTAssertEqual(log.calls, [.pause])
    }

    func testPausingDuringAnInterruptionCancelsTheResume() throws {
        try loadAndPlay()
        session.send(.interruptionBegan)
        engine.pause()
        session.send(.interruptionEnded(shouldResume: true))
        XCTAssertEqual(log.calls, [.pause])
    }

    func testLostOutputStaysPausedAfterALaterInterruption() throws {
        try loadAndPlay()
        session.send(.outputLost)
        driver.send(.status(.paused))
        session.send(.interruptionBegan)
        session.send(.interruptionEnded(shouldResume: true))
        XCTAssertEqual(log.calls, [.pause])
    }

    func testEachInterruptionResumesOnlyOnce() throws {
        try loadAndPlay()
        session.send(.interruptionBegan)
        session.send(.interruptionEnded(shouldResume: true))
        session.send(.interruptionEnded(shouldResume: true))
        XCTAssertEqual(log.calls, [.activate, .play])
    }

    // MARK: - App configuration

    func testAppDeclaresTheAudioBackgroundMode() {
        // Unit tests run inside the app, so Bundle.main is the built CAB.app.
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        XCTAssertEqual(modes, ["audio"])
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.cabroadcasting.cab", "The generated keys survive the merge")
    }

    func testSystemAudioSessionUsesPlaybackForSpokenAudio() {
        _ = SystemAudioSession()
        let session = AVAudioSession.sharedInstance()
        XCTAssertEqual(session.category, .playback)
        XCTAssertEqual(session.mode, .spokenAudio)
    }
}
