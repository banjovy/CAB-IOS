//
//  AVPlaybackDriver.swift
//  CAB
//
//  `PlaybackDriver` on top of AVPlayer, plus the real audio session.
//

import AVFoundation

@MainActor
final class AVPlaybackDriver: PlaybackDriver {
    var onEvent: ((Int, PlaybackEvent) -> Void)?

    private let player = AVPlayer()
    private var itemID = 0
    private var seekID = 0
    /// `true` after `play()`, `false` after `pause()`.
    private var playRequested = false
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?

    /// How often the player started running while it should have been paused
    /// (see `enforcePause`). For tests and diagnostics.
    private(set) var unexpectedRestartCount = 0
    private var itemObservations: [NSKeyValueObservation] = []
    private var itemNotifications: [NSObjectProtocol] = []

    /// For tests that play real audio without making noise.
    var isMuted: Bool {
        get { player.isMuted }
        set { player.isMuted = newValue }
    }

    /// The rate AVPlayer is running at right now. For tests.
    var actualRate: Float { player.rate }

    init() {
        // Twice a second is enough for a progress bar (the web's timeupdate fires about 4 times a second).
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
                                                      queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.player.currentItem != nil else { return }
                let seconds = time.seconds
                if seconds.isFinite { self.emit(.time(max(0, seconds))) }
            }
        }

        statusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let status: PlaybackStatus
            switch player.timeControlStatus {
            case .playing: status = .playing
            case .waitingToPlayAtSpecifiedRate: status = .buffering
            default: status = .paused
            }
            Self.onMain { self?.emit(.status(status)) }
        }

        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] player, _ in
            let rate = player.rate
            Self.onMain { self?.enforcePause(observedRate: rate) }
        }
    }

    /// Safety net: if the player runs while the last request was pause, pause it again.
    ///
    /// AVPlayer can undo a pause by itself. Seen in Task 6 live tests: change
    /// the speed while a seek is pending, pause before the seek lands, and
    /// when the seek finishes the player may go back to the earlier speed
    /// with no call from the app. It doesn't happen every time; once it kept
    /// playing for at least 0.1 s until a test noticed. This catches it within
    /// milliseconds. Users can trigger it with quick taps (skip, speed, pause),
    /// and lock-screen or CarPlay controls (Tasks 9 and 13) make it more likely.
    private func enforcePause(observedRate: Float) {
        rateChangeObserverForTesting?(observedRate, player.rate, playRequested)
        guard !playRequested, observedRate != 0, player.rate != 0 else { return }
        unexpectedRestartCount += 1
        player.pause()
    }

    /// Called for every rate notification with (notified rate, rate now, play requested). For live-test traces.
    var rateChangeObserverForTesting: ((Float, Float, Bool) -> Void)?

    /// Starts the player behind the driver's back, to test `enforcePause`.
    func simulateUnexpectedRestartForTesting() {
        player.rate = 1
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        itemNotifications.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: - PlaybackDriver

    @discardableResult
    func replaceItem(with url: URL?) -> Int {
        itemID += 1
        itemObservations = []
        itemNotifications.forEach(NotificationCenter.default.removeObserver)
        itemNotifications = []

        guard let url else {
            player.replaceCurrentItem(with: nil)
            return itemID
        }

        let item = AVPlayerItem(url: url)
        // Keeps voices natural at 1.25x–2x.
        item.audioTimePitchAlgorithm = .timeDomain
        observe(item, id: itemID)
        player.replaceCurrentItem(with: item)
        return itemID
    }

    func play() {
        playRequested = true
        player.play()
    }

    func pause() {
        playRequested = false
        player.pause()
    }

    @discardableResult
    func seek(to seconds: Double) -> Int {
        seekID += 1
        let id = seekID
        let item = itemID
        guard player.currentItem != nil, seconds.isFinite else {
            Self.onMain { [weak self] in self?.emit(.seekFinished(id), for: item) }
            return id
        }
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600)) { [weak self] _ in
            // Called with `false` when a newer seek replaced this one; either way it's over.
            Self.onMain { self?.emit(.seekFinished(id), for: item) }
        }
        return id
    }

    func setRate(_ rate: Float) {
        // `play()` uses defaultRate. Setting `rate` directly while paused would start playback.
        player.defaultRate = rate
        if player.timeControlStatus != .paused { player.rate = rate }
    }

    var currentTime: Double {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? max(0, seconds) : 0
    }

    // MARK: - Private

    private func observe(_ item: AVPlayerItem, id: Int) {
        itemObservations = [
            item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                let failed = item.status == .failed
                Self.onMain { if failed { self?.emit(.failed, for: id) } }
            },
            item.observe(\.duration, options: [.initial, .new]) { [weak self] item, _ in
                let seconds = item.duration.seconds
                Self.onMain {
                    if seconds.isFinite, seconds > 0 { self?.emit(.duration(seconds), for: id) }
                }
            },
        ]

        let center = NotificationCenter.default
        itemNotifications = [
            center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.emit(.ended, for: id) }
            },
            center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.emit(.failed, for: id) }
            },
        ]
    }

    /// Player-level events belong to whatever item is current when they fire.
    private func emit(_ event: PlaybackEvent) {
        onEvent?(itemID, event)
    }

    private func emit(_ event: PlaybackEvent, for id: Int) {
        onEvent?(id, event)
    }

    /// KVO can call back on any thread. Hop to the main queue, which is the main actor.
    private nonisolated static func onMain(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated(work) }
    }
}

// MARK: - Audio session

@MainActor
final class SystemAudioSession: AudioSessionControlling {
    var onEvent: ((AudioSessionEvent) -> Void)?

    private let session = AVAudioSession.sharedInstance()
    private var observers: [NSObjectProtocol] = []

    init() {
        configure()
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
                let event = Self.interruptionEvent(from: note)
                MainActor.assumeIsolated { if let event { self?.onEvent?(event) } }
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] note in
                let event = Self.routeChangeEvent(from: note)
                MainActor.assumeIsolated { if let event { self?.onEvent?(event) } }
            },
        ]
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// `.playback` keeps audio going with the screen locked or the silent
    /// switch on, and in the background (with the `audio` background mode).
    /// `.spokenAudio` suits podcasts and talk radio: navigation prompts, for
    /// example in CarPlay, pause us instead of talking over us.
    private func configure() {
        do {
            try session.setCategory(.playback, mode: .spokenAudio)
        } catch {
            // Playback still works in the default category, just without background audio.
        }
    }

    func activate() throws {
        try session.setActive(true)
    }

    func deactivate() {
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    private nonisolated static func routeChangeEvent(from note: Notification) -> AudioSessionEvent? {
        guard let rawReason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              AVAudioSession.RouteChangeReason(rawValue: rawReason) == .oldDeviceUnavailable else { return nil }
        return .outputLost
    }

    private nonisolated static func interruptionEvent(from note: Notification) -> AudioSessionEvent? {
        guard let info = note.userInfo,
              let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return nil }

        switch type {
        case .began:
            // (Before iOS 16, "began" was also sent when the app was merely suspended.
            // Our minimum is iOS 17, where that no longer happens.)
            return .interruptionBegan
        case .ended:
            let rawOptions = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            return .interruptionEnded(shouldResume: options.contains(.shouldResume))
        @unknown default:
            return nil
        }
    }
}
