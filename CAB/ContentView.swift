//
//  ContentView.swift
//  CAB
//
//  Placeholder root view for the Task 1 scaffold. Replaced in later tasks
//  by the real navigation shell (Home, Resources, About, Attributions).
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            Text("Christian Audio Broadcasting")
                .font(.title2.bold())
                .multilineTextAlignment(.center)

            Text("Scaffold ready — build out begins at Task 2.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
