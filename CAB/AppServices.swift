//
//  AppServices.swift
//  CAB
//
//  App-wide services, created once. Every screen (and CarPlay in Task 13)
//  uses the same repository, so they share its cache and in-flight fetch,
//  and the same audio engine, so there is only ever one thing playing.
//

import Foundation

@MainActor
final class AppServices {
    static let shared = AppServices()

    let shows: ShowsRepository
    let audio: AudioEngine

    init(shows: ShowsRepository = ShowsRepository.make(), audio: AudioEngine? = nil) {
        self.shows = shows
        self.audio = audio ?? AudioEngine.live()
    }
}
