//
//  HomeView.swift
//  CAB
//
//  The Home screen: header, category tabs, and a grid of show cards.
//  Port of the web home page (`src/app/page.jsx`).
//
//  Cards don't open anything yet; the players arrive in Tasks 7 and 8.
//  The web's "back to top" button isn't ported: on iOS, tapping the status
//  bar scrolls to the top.
//

import SwiftUI

struct HomeView: View {
    let model: HomeViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if model.isStale {
                    Label("Couldn't refresh. Showing saved shows.", systemImage: "wifi.slash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                }

                if model.catalog != nil {
                    CategoryTabBar(selection: Binding(get: { model.selectedTab },
                                                      set: { model.selectedTab = $0 }))
                    showGrid
                } else if let message = model.errorMessage {
                    ContentUnavailableView {
                        Label("Couldn't Load Shows", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try Again") { Task { await model.retry() } }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 48)
                }
            }
            .padding(.vertical, 16)
        }
        .background(Color(.systemGroupedBackground))
        .refreshable { await model.refresh() }
        .navigationTitle("Christian Audio Broadcasting")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.loadIfNeeded() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Quality Christian Audio")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Text("Explore American Family Radio streams, podcasts, and trusted teaching from Fortis Institute and other creators.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var showGrid: some View {
        let shows = model.visibleShows
        if shows.isEmpty {
            Text("No shows found for this category.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
        } else {
            // Two columns on iPhone, more on wider screens.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 16) {
                ForEach(shows) { show in
                    ShowCardView(show: show)
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

/// Horizontally scrolling tabs with an underline on the selected one
/// (web: Radix tabs with a 3 px primary border).
struct CategoryTabBar: View {
    @Binding var selection: HomeTab

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(HomeTab.allTabs) { tab in
                    tabButton(tab)
                }
            }
        }
        .contentMargins(.horizontal, 8, for: .scrollContent)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func tabButton(_ tab: HomeTab) -> some View {
        let isSelected = tab == selection
        return Button {
            selection = tab
        } label: {
            Text(tab.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .overlay(alignment: .bottom) {
                    if isSelected {
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(height: 3)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview {
    NavigationStack {
        HomeView(model: HomeViewModel(repository: AppServices.shared.shows))
    }
}
