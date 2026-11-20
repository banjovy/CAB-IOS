//
//  ContentView.swift
//  CAB
//
//  Root view. For now it shows only Home; Task 10 replaces it with the
//  full navigation shell (Home, Resources, About, Attributions) and the
//  mini-player.
//

import SwiftUI

struct ContentView: View {
    @State private var home = HomeViewModel(repository: AppServices.shared.shows)

    var body: some View {
        NavigationStack {
            HomeView(model: home)
        }
    }
}

#Preview {
    ContentView()
}
