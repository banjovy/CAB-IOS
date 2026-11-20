//
//  HomeViewModel.swift
//  CAB
//
//  State for the Home screen: loading, errors, and which shows each tab
//  lists. Port of the web home page (`src/app/page.jsx`).
//

import Foundation
import Observation

/// A Home tab. Order and labels match the web home page.
enum HomeTab: Hashable, Identifiable, Sendable {
    case all
    case category(ShowCategory)

    /// Category order for the tabs and for the "All" tab's list.
    static let categoryOrder: [ShowCategory] = [.afrStream, .afrPodcast, .fortisPodcast, .otherPodcast]

    static let allTabs: [HomeTab] = [.all] + categoryOrder.map { .category($0) }

    var id: String {
        switch self {
        case .all: "all"
        case .category(let category): category.rawValue
        }
    }

    var title: String {
        switch self {
        case .all: "All"
        case .category(.afrStream): "AFR Streams"
        case .category(.afrPodcast): "AFR Podcasts"
        case .category(.fortisPodcast): "Fortis Podcasts"
        case .category(.otherPodcast): "Other Podcasts"
        }
    }
}

@MainActor
@Observable
final class HomeViewModel {
    /// Loads the catalog. `forceRefresh` bypasses a fresh cache (pull to refresh).
    typealias Load = @Sendable (_ forceRefresh: Bool) async throws -> Loaded<ShowCatalog>

    private(set) var catalog: ShowCatalog?
    private(set) var isLoading = false
    /// Set only when a load failed and there is nothing to show.
    private(set) var errorMessage: String?
    /// `true` when the catalog is saved data because a refresh failed.
    private(set) var isStale = false
    var selectedTab: HomeTab = .all

    @ObservationIgnored private let load: Load

    init(load: @escaping Load) {
        self.load = load
    }

    convenience init(repository: ShowsRepository) {
        self.init(load: { try await repository.load(forceRefresh: $0) })
    }

    /// Shows for the selected tab. "All" lists the known categories in tab
    /// order. Shows in unknown categories never appear (web parity).
    var visibleShows: [CatalogShow] {
        guard let catalog else { return [] }
        switch selectedTab {
        case .all:
            return HomeTab.categoryOrder.flatMap { catalog.shows(in: $0) }
        case .category(let category):
            return catalog.shows(in: category)
        }
    }

    /// The first load. Does nothing if data is already loaded or loading.
    func loadIfNeeded() async {
        guard catalog == nil else { return }
        await perform(forceRefresh: false)
    }

    /// "Try again" after an error. A failed load isn't cached, so a normal load retries the network.
    func retry() async {
        await perform(forceRefresh: false)
    }

    /// Pull to refresh.
    func refresh() async {
        await perform(forceRefresh: true)
    }

    private func perform(forceRefresh: Bool) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let result = try await load(forceRefresh)
            catalog = result.value
            isStale = result.isStale
        } catch is CancellationError {
            // The view went away; not an error.
        } catch {
            // Keep showing what we have. Only show an error when there's nothing.
            if catalog == nil { errorMessage = error.localizedDescription }
        }
    }
}
