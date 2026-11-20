//
//  PlaybackDriver.swift
//  CAB
//
//  The seam between `AudioEngine` (the rules) and AVFoundation (the player).
//  The app uses `AVPlaybackDriver`; tests use a fake that emits events by hand.
//

import Foundation

enum PlaybackStatus: Equatable, Sendable {
    case paused
    /// Asked to play, but waiting for data (buffering or stalled).
    case buffering
    case playing
}

enum PlaybackEvent: Equatable, Sendable {
    case status(PlaybackStatus)
    /// Current position in seconds.
    case time(Double)
    /// Duration in seconds, once known. Only finite, positive values are sent.
    case duration(Double)
    /// The item played to its end.
    case ended
    /// The item can't be played (bad URL, network failure, unsupported format).
    case failed
    /// The seek with this id (returned by `seek(to:)`) finished or was replaced by a newer one.
    case seekFinished(Int)
}

@MainActor
protocol PlaybackDriver: AnyObject {
    /// Called on the main actor with the id of the item the event belongs to.
    /// Events can arrive after the item was replaced; the engine drops those.
    var onEvent: ((_ itemID: Int, _ event: PlaybackEvent) -> Void)? { get set }

    /// Replaces the current item and returns its new id. `nil` unloads.
    @discardableResult
    func replaceItem(with url: URL?) -> Int

    func play()
    func pause()
    /// Starts a seek and returns its id. Sends `.seekFinished(id)` when done.
    @discardableResult
    func seek(to seconds: Double) -> Int
    /// Applies a playback rate. Must not start playback when paused.
    func setRate(_ rate: Float)

    /// Current position in seconds (0 when nothing is loaded). While a seek
    /// is pending, this can still be the position before the seek.
    var currentTime: Double { get }
}

enum AudioSessionEvent: Equatable, Sendable {
    /// A phone call, alarm or another app took the audio. The system has already paused us.
    case interruptionBegan
    /// The interruption is over. `shouldResume` is the system's hint to resume.
    case interruptionEnded(shouldResume: Bool)
    /// The audio output went away (headphones unplugged, Bluetooth or CarPlay
    /// disconnected). The system has already paused us; stay paused.
    case outputLost
}

@MainActor
protocol AudioSessionControlling: AnyObject {
    /// Called on the main actor.
    var onEvent: ((AudioSessionEvent) -> Void)? { get set }

    /// Makes our audio the active audio. Call before playing.
    func activate() throws
    /// Releases the audio so other apps can resume.
    func deactivate()
}
