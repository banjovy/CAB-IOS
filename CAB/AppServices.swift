//
//  AppServices.swift
//  CAB
//
//  App-wide services, created once. Every screen (and CarPlay in Task 13)
//  uses the same repository, so they share its cache and in-flight fetch.
//

import Foundation

final class AppServices: Sendable {
    static let shared = AppServices()

    let shows: ShowsRepository

    init(shows: ShowsRepository = ShowsRepository.make()) {
        self.shows = shows
    }
}
