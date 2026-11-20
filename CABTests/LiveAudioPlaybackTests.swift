//
//  LiveAudioPlaybackTests.swift
//  CABTests
//
//  Task 6: plays real episodes through the real AVPlayer, muted. Needs the
//  network, so it only runs when asked:
//
//    TEST_RUNNER_CAB_LIVE_AUDIO=1 xcodebuild test -project CAB.xcodeproj -scheme CAB \
//      -destination 'platform=iOS Simulator,name=iPhone 17' \
//      -only-testing:CABTests/LiveAudioPlaybackTests
//

import XCTest
@testable import CAB

@MainActor
final class LiveAudioPlaybackTests: XCTestCase {

    private func requireLiveRun() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CAB_LIVE_AUDIO"] == "1",
                          "Live audio test. Run with TEST_RUNNER_CAB_LIVE_AUDIO=1.")
    }

    /// Polls until `condition` holds, failing after `timeout` seconds.
    private func waitUntil(_ what: String, timeout: TimeInterval = 30,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out after \(Int(timeout)) s waiting for: \(what)", file: file, line: line)
                throw CancellationError()
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func liveCatalog() async throws -> ShowCatalog {
        try await ShowsRepository.make(store: nil).load().value
    }

    private func newestTrack(_ showID: String, in catalog: ShowCatalog) throws -> AudioTrack {
        let show = try XCTUnwrap(catalog.showsByID[showID], "No show \(showID)")
        let episode = try XCTUnwrap(show.episodes.first, "\(showID) has no episodes")
        return try XCTUnwrap(AudioTrack(episode: episode, show: show))
    }

    /// Every event the engine receives, with the player's rate at that moment.
    /// Printed at the end of each test to diagnose failures.
    private var trace: [String] = []
    private var traceStart = Date()

    /// The last driver made, so tearDown can report the safety net firing.
    private var lastDriver: AVPlaybackDriver?

    override func tearDown() async throws {
        if !trace.isEmpty {
            print("LIVE-TRACE \(name)\n" + trace.joined(separator: "\n"))
        }
        // Expected in tests that pause during seeks (see AVPlaybackDriver.enforcePause). Noted for the record.
        if let count = lastDriver?.unexpectedRestartCount, count > 0 {
            print("LIVE-NOTE \(name): the pause safety net fired \(count) time(s)")
        }
        trace = []
        lastDriver = nil
        try await super.tearDown()
    }

    private func note(_ text: String, rate: Float) {
        trace.append(String(format: "LIVE-TRACE %7.3f s  rate=%.2f  %@", Date().timeIntervalSince(traceStart), rate, text))
    }

    private func makeEngine() -> (AudioEngine, AVPlaybackDriver) {
        let driver = AVPlaybackDriver()
        driver.isMuted = true
        let session = SystemAudioSession()
        let engine = AudioEngine(driver: driver, session: session)
        lastDriver = driver
        traceStart = Date()

        // Wrap the engine's handlers so each event is recorded before the engine sees it.
        let engineDriverHandler = driver.onEvent
        driver.onEvent = { [weak self, weak driver] itemID, event in
            self?.note("player item \(itemID): \(event)", rate: driver?.actualRate ?? -1)
            engineDriverHandler?(itemID, event)
        }
        let engineSessionHandler = session.onEvent
        session.onEvent = { [weak self, weak driver] event in
            self?.note("session: \(event)", rate: driver?.actualRate ?? -1)
            engineSessionHandler?(event)
        }
        driver.rateChangeObserverForTesting = { [weak self] notified, now, playRequested in
            self?.note(String(format: "rate notification: %.2f (play requested: %@)", notified, playRequested ? "yes" : "no"), rate: now)
        }
        return (engine, driver)
    }

    /// Records a test step in the trace.
    private func step(_ text: String, _ driver: AVPlaybackDriver) {
        note("STEP \(text)", rate: driver.actualRate)
    }

    /// Full transport check on one real episode.
    func testTransportOnARealEpisode() async throws {
        try requireLiveRun()
        let track = try newestTrack("etw", in: try await liveCatalog())
        let (engine, driver) = makeEngine()
        defer { engine.dismiss() }

        engine.load(track, autoplay: true)
        try await waitUntil("playing past 2 s") { engine.isPlaying && !engine.isBuffering && engine.elapsedSeconds > 2 }

        let duration = try XCTUnwrap(engine.durationSeconds)
        let feedDuration = Double(try XCTUnwrap(track.feedDurationSeconds))
        XCTAssertEqual(duration, feedDuration, accuracy: 60, "Real duration should be close to the feed's")
        XCTAssertNil(engine.errorMessage)

        /// Playing for real: the seek is done and the position has moved on from `target`.
        func playingPast(_ target: Double) -> Bool {
            !engine.isSeeking && engine.isPlaying && !engine.isBuffering && engine.elapsedSeconds > target + 0.4
        }

        let start = engine.elapsedSeconds
        step("skip +30", driver)
        engine.skip(by: AudioEngine.skipInterval)
        try await waitUntil("skip forward lands and plays on") { playingPast(start + 30) }

        let afterForward = engine.elapsedSeconds
        step("skip -30", driver)
        engine.skip(by: -AudioEngine.skipInterval)
        try await waitUntil("skip back lands and plays on") { playingPast(afterForward - 30) }
        XCTAssertLessThan(engine.elapsedSeconds, afterForward - 20)

        let beforeDouble = engine.elapsedSeconds
        step("skip +30 twice, quickly", driver)
        engine.skip(by: 30)
        engine.skip(by: 30)
        try await waitUntil("two quick skips land 60 s on") { playingPast(beforeDouble + 60) }
        XCTAssertLessThan(engine.elapsedSeconds, beforeDouble + 66)

        step("cycle rate", driver)
        engine.cyclePlaybackRate()
        XCTAssertEqual(engine.playbackRate, 1.25)
        try await waitUntil("player running at 1.25x") { driver.actualRate == 1.25 }

        // Pausing while a skip is still in flight: the player must stay paused when the skip lands.
        step("skip +30, then pause before it lands", driver)
        engine.skip(by: 30)
        engine.pause()
        step("after pause call", driver)
        try await waitUntil("seek done and paused") { !engine.isSeeking && !engine.isPlaying }
        step("engine reports paused", driver)
        let paused = engine.elapsedSeconds
        try await Task.sleep(nanoseconds: 1_500_000_000)
        step("1.5 s later", driver)
        XCTAssertEqual(driver.actualRate, 0, "The player restarted on its own")
        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(engine.elapsedSeconds, paused, accuracy: 0.6, "Position holds while paused")

        step("cycle rate while paused", driver)
        engine.cyclePlaybackRate()
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(engine.isPlaying, "Changing speed while paused must not start playback")
        XCTAssertEqual(driver.actualRate, 0)

        step("stop", driver)
        engine.stop()
        XCTAssertEqual(engine.elapsedSeconds, 0)

        step("play", driver)
        engine.play()
        try await waitUntil("playing again at 1.5x from the start") {
            playingPast(0) && driver.actualRate == 1.5 && engine.elapsedSeconds < 10
        }
    }

    /// Rapid taps: skips, a speed change and pause, all before the skips land.
    /// This sequence once left the player running after pause.
    func testPauseHoldsAfterRapidSkipsAndSpeedChange() async throws {
        try requireLiveRun()
        let track = try newestTrack("etw", in: try await liveCatalog())
        let (engine, driver) = makeEngine()
        defer { engine.dismiss() }

        engine.load(track, autoplay: true)
        var restarts = 0
        for round in 1...6 {
            step("round \(round): play", driver)
            engine.play()
            try await waitUntil("playing (round \(round))") {
                !engine.isSeeking && engine.isPlaying && !engine.isBuffering && engine.elapsedSeconds > 1
            }

            step("round \(round): skip +30, skip -30, speed, pause", driver)
            engine.skip(by: 30)
            engine.skip(by: -30)
            engine.cyclePlaybackRate()
            engine.pause()

            try await waitUntil("seek done and paused (round \(round))") { !engine.isSeeking && !engine.isPlaying }
            try await Task.sleep(nanoseconds: 1_000_000_000)
            step("round \(round): 1 s after pause", driver)
            if driver.actualRate != 0 || engine.isPlaying { restarts += 1 }
        }
        XCTAssertEqual(restarts, 0, "The player restarted on its own after pause in \(restarts) of 6 rounds")
    }

    /// The safety net: if the player starts running while it should be paused, it's paused again.
    func testSafetyNetRepausesAnUnexpectedRestart() async throws {
        try requireLiveRun()
        let track = try newestTrack("etw", in: try await liveCatalog())
        let (engine, driver) = makeEngine()
        defer { engine.dismiss() }

        engine.load(track, autoplay: true)
        try await waitUntil("playing") { engine.isPlaying && !engine.isBuffering && engine.elapsedSeconds > 1 }
        engine.pause()
        try await waitUntil("paused") { !engine.isPlaying && driver.actualRate == 0 }
        XCTAssertEqual(driver.unexpectedRestartCount, 0)

        step("start the player behind the engine's back", driver)
        driver.simulateUnexpectedRestartForTesting()
        // It fires once per rate notification, which can be more than once per restart.
        try await waitUntil("re-paused", timeout: 5) { driver.actualRate == 0 && driver.unexpectedRestartCount >= 1 }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(driver.actualRate, 0)
        XCTAssertFalse(engine.isPlaying)
        let fired = driver.unexpectedRestartCount

        // Normal play is unaffected.
        engine.play()
        try await waitUntil("playing again") { engine.isPlaying && !engine.isBuffering && driver.actualRate == 1 }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(driver.actualRate, 1, "The safety net must not pause requested playback")
        XCTAssertEqual(driver.unexpectedRestartCount, fired)
    }

    /// Loading without autoplay while something plays must leave the new track paused.
    func testLoadWithoutAutoplayWhilePlayingStaysPaused() async throws {
        try requireLiveRun()
        let catalog = try await liveCatalog()
        let (engine, driver) = makeEngine()
        defer { engine.dismiss() }

        engine.load(try newestTrack("etw", in: catalog), autoplay: true)
        try await waitUntil("first track playing") { engine.isPlaying && !engine.isBuffering && engine.elapsedSeconds > 1 }

        step("load another track without autoplay", driver)
        engine.load(try newestTrack("tcw", in: catalog), autoplay: false)
        try await Task.sleep(nanoseconds: 2_000_000_000)
        step("2 s after load", driver)
        XCTAssertEqual(driver.actualRate, 0)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(engine.elapsedSeconds, 0)
        XCTAssertEqual(engine.currentTrack?.showID, "tcw")
        XCTAssertEqual(driver.unexpectedRestartCount, 0, "Paused by load itself, not by the safety net")
    }

    /// Stop pauses and seeks to 0. The player must stay stopped once the seek lands.
    func testStopHolds() async throws {
        try requireLiveRun()
        let track = try newestTrack("etw", in: try await liveCatalog())
        let (engine, driver) = makeEngine()
        defer { engine.dismiss() }

        engine.load(track, autoplay: true)
        var restarts = 0
        for round in 1...6 {
            if round == 4 { engine.cyclePlaybackRate() } // also try at 1.25x
            step("round \(round): play", driver)
            engine.play()
            try await waitUntil("playing past 2 s (round \(round))") {
                !engine.isSeeking && engine.isPlaying && !engine.isBuffering && engine.elapsedSeconds > 2
            }

            step("round \(round): stop", driver)
            engine.stop()
            try await waitUntil("seek done and stopped (round \(round))") { !engine.isSeeking && !engine.isPlaying }
            try await Task.sleep(nanoseconds: 1_500_000_000)
            step("round \(round): 1.5 s after stop", driver)
            if driver.actualRate != 0 || engine.isPlaying || engine.elapsedSeconds > 1 { restarts += 1 }
        }
        XCTAssertEqual(restarts, 0, "The player restarted on its own after stop in \(restarts) of 6 rounds")
    }

    /// One newest episode from each of several hosts, including redirect trackers.
    func testEpisodesFromDifferentHostsPlay() async throws {
        try requireLiveRun()
        let catalog = try await liveCatalog()
        let (engine, _) = makeEngine()
        defer { engine.dismiss() }

        // etw: streamer1.afa.net. tcw: buzzsprout. fhh: podtrac redirect. gty: feeds.gty.org.
        for showID in ["etw", "tcw", "fhh", "gty"] {
            let track = try newestTrack(showID, in: catalog)
            engine.load(track, autoplay: true)
            try await waitUntil("\(showID) playing past 1 s (\(track.audioURL.host() ?? "?"))") {
                engine.errorMessage == nil && engine.isPlaying && engine.elapsedSeconds > 1
            }
            XCTAssertNotNil(engine.durationSeconds, showID)
        }
    }

    func testABrokenURLReportsAnError() async throws {
        try requireLiveRun()
        let catalog = try await liveCatalog()
        let show = try XCTUnwrap(catalog.showsByID["etw"])
        let episodeJSON = #"{"episodes":[{"name":"Missing","url":"https://assets.cabroadcasting.com/audio/does-not-exist.mp3"}]}"#
        let missing = try XCTUnwrap(try JSONDecoder().decode(EpisodeFeed.self, from: Data(episodeJSON.utf8)).episodes.first)
        let track = try XCTUnwrap(AudioTrack(episode: PodcastEpisode(missing, dateParser: FeedDateParser()), show: show))
        let (engine, _) = makeEngine()
        defer { engine.dismiss() }

        engine.load(track, autoplay: true)
        try await waitUntil("an error") { engine.errorMessage != nil }
        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(engine.errorMessage, AudioEngine.playbackFailedMessage)
    }
}
