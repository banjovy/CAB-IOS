//
//  AudioEngine.swift
//  CAB
//
//  The app's one audio player: what's loaded, whether it's playing, where it
//  is, and the transport controls. Shared by the player screens (Tasks 7 and
//  8), the mini-player (Task 10) and CarPlay (Task 13).
//
//  Port of the transport parts of web `providers/AudioProvider.jsx`. Resume
//  positions (Task 7), streams (Task 8) and lock-screen controls (Task 9)
//  build on this.
//

import Foundation
import Observation

@MainActor
@Observable
final class AudioEngine {
    /// Seconds skipped by the skip buttons (web: 30).
    static let skipInterval: Double = 30
    /// The speed button cycles through these (web: `SPEED_OPTIONS`).
    static let playbackRates: [Float] = [1, 1.25, 1.5, 1.75, 2]
    static let playbackFailedMessage = "Can't play this episode right now. Please check your connection and try again."

    private(set) var currentTrack: AudioTrack?
    /// Playing, or trying to (see `isBuffering`).
    private(set) var isPlaying = false
    /// Asked to play but waiting for audio data.
    private(set) var isBuffering = false
    private(set) var elapsedSeconds: Double = 0
    /// The feed's duration until the real one is known; `nil` if neither is.
    private(set) var durationSeconds: Double?
    /// Kept across tracks, like the web.
    private(set) var playbackRate: Float = 1
    /// Set when the current track fails to play. Cleared by `load` and `play`.
    private(set) var errorMessage: String?
    /// A seek or skip is in progress. `elapsedSeconds` already shows the target.
    private(set) var isSeeking = false

    /// 0...1, or 0 when the duration is unknown.
    var progress: Double {
        guard let durationSeconds, durationSeconds > 0 else { return 0 }
        return min(1, max(0, elapsedSeconds / durationSeconds))
    }

    @ObservationIgnored private let driver: PlaybackDriver
    @ObservationIgnored private let session: AudioSessionControlling
    @ObservationIgnored private var itemID = 0
    @ObservationIgnored private var reachedEnd = false
    /// What the user last asked for: `true` after play, `false` after pause,
    /// stop, the end of the track, or a failure. Unlike `isPlaying`, the
    /// system pausing us (for a call, or a lost output) doesn't change it.
    @ObservationIgnored private var playRequested = false
    @ObservationIgnored private var resumeAfterInterruption = false
    /// The latest seek, until the player finishes it. While it's pending,
    /// the player still reports the old position, so skips build on the
    /// target instead and position updates are ignored.
    @ObservationIgnored private var pendingSeek: (id: Int, target: Double)?

    init(driver: PlaybackDriver, session: AudioSessionControlling) {
        self.driver = driver
        self.session = session
        driver.onEvent = { [weak self] itemID, event in self?.handle(event, itemID: itemID) }
        session.onEvent = { [weak self] event in self?.handle(event) }
    }

    /// The engine the app uses.
    static func live() -> AudioEngine {
        AudioEngine(driver: AVPlaybackDriver(), session: SystemAudioSession())
    }

    // MARK: - Loading

    /// Loads a track, replacing whatever was loaded. Web: `loadPodcastEpisode`.
    func load(_ track: AudioTrack, autoplay: Bool = false) {
        currentTrack = track
        // AVPlayer keeps playing when given a new item; only play it if asked.
        driver.pause()
        itemID = driver.replaceItem(with: track.audioURL)
        driver.setRate(playbackRate)
        elapsedSeconds = 0
        durationSeconds = track.feedDurationSeconds.map(Double.init)
        isPlaying = false
        isBuffering = false
        errorMessage = nil
        reachedEnd = false
        playRequested = false
        resumeAfterInterruption = false
        clearPendingSeek()
        if autoplay { play() }
    }

    /// Unloads the track and releases the audio session. Web: `dismiss`.
    func dismiss() {
        driver.pause()
        itemID = driver.replaceItem(with: nil)
        currentTrack = nil
        isPlaying = false
        isBuffering = false
        elapsedSeconds = 0
        durationSeconds = nil
        errorMessage = nil
        reachedEnd = false
        playRequested = false
        resumeAfterInterruption = false
        clearPendingSeek()
        session.deactivate()
    }

    // MARK: - Transport

    func play() {
        guard currentTrack != nil else { return }
        errorMessage = nil
        // At the end, play starts over (as HTML audio does). AVPlayer would stay at the end.
        if reachedEnd {
            reachedEnd = false
            seek(to: 0)
        }
        playRequested = true
        // If this fails, playback still works while the app is in the foreground.
        try? session.activate()
        driver.play()
    }

    func pause() {
        guard currentTrack != nil else { return }
        playRequested = false
        resumeAfterInterruption = false
        driver.pause()
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    /// Pauses and goes back to the start. The track stays loaded. Web: `stop`.
    func stop() {
        guard currentTrack != nil else { return }
        playRequested = false
        resumeAfterInterruption = false
        driver.pause()
        seek(to: 0)
    }

    /// Skips forward (positive) or back (negative), staying within the episode.
    /// Quick repeated taps add up: two taps of +30 skip 60 seconds.
    func skip(by seconds: Double) {
        guard currentTrack != nil else { return }
        seek(to: (pendingSeek?.target ?? driver.currentTime) + seconds)
    }

    /// Jumps to a position, clamped to the episode. Web: `seekTo`.
    func seek(to seconds: Double) {
        guard currentTrack != nil, seconds.isFinite else { return }
        var target = max(0, seconds)
        if let durationSeconds { target = min(target, durationSeconds) }
        if target < (durationSeconds ?? .infinity) { reachedEnd = false }
        elapsedSeconds = target
        pendingSeek = (driver.seek(to: target), target)
        isSeeking = true
    }

    private func clearPendingSeek() {
        pendingSeek = nil
        isSeeking = false
    }

    // MARK: - Speed

    func setPlaybackRate(_ rate: Float) {
        guard rate.isFinite, rate > 0 else { return }
        playbackRate = rate
        driver.setRate(rate)
    }

    /// 1 → 1.25 → 1.5 → 1.75 → 2 → 1. An unlisted rate goes to 1 (web parity).
    func cyclePlaybackRate() {
        let rates = Self.playbackRates
        let next = rates.firstIndex(of: playbackRate).map { (rates.index(after: $0)) % rates.count } ?? 0
        setPlaybackRate(rates[next])
    }

    // MARK: - Events

    private func handle(_ event: PlaybackEvent, itemID: Int) {
        // Ignore late events from an item that has since been replaced.
        guard itemID == self.itemID, currentTrack != nil else { return }

        switch event {
        case .status(let status):
            isPlaying = status != .paused
            isBuffering = status == .buffering
        case .time(let seconds):
            // While seeking, the player can still report the old position.
            if seconds.isFinite, pendingSeek == nil { elapsedSeconds = max(0, seconds) }
        case .seekFinished(let id):
            // An older seek finishing doesn't mean the latest one has.
            if id == pendingSeek?.id { clearPendingSeek() }
        case .duration(let seconds):
            if seconds.isFinite, seconds > 0 { durationSeconds = seconds }
        case .ended:
            reachedEnd = true
            playRequested = false
            isPlaying = false
            isBuffering = false
            if let durationSeconds { elapsedSeconds = durationSeconds }
        case .failed:
            playRequested = false
            isPlaying = false
            isBuffering = false
            errorMessage = Self.playbackFailedMessage
        }
    }

    private func handle(_ event: AudioSessionEvent) {
        guard currentTrack != nil else { return }
        switch event {
        case .interruptionBegan:
            // The system has already paused the player. Use the user's intent,
            // not `isPlaying`, which the pause may already have cleared.
            resumeAfterInterruption = playRequested
        case .interruptionEnded(let shouldResume):
            let resume = shouldResume && resumeAfterInterruption
            resumeAfterInterruption = false
            if resume { play() }
        case .outputLost:
            // Unplugged headphones: stay paused, even after a later interruption ends.
            // The system already paused the player; this keeps the player's own record in step.
            playRequested = false
            resumeAfterInterruption = false
            driver.pause()
        }
    }
}
