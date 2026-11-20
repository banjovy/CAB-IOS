//
//  ShowCardView.swift
//  CAB
//
//  A show card for the Home grid. Port of web `components/ShowCard.jsx`:
//  square artwork, title, owner, and a 3-line description.
//

import SwiftUI

struct ShowCardView: View {
    let show: CatalogShow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ShowArtwork(url: show.show.image.flatMap { URL(string: $0) })
                .aspectRatio(1, contentMode: .fit)

            VStack(alignment: .leading, spacing: 2) {
                Text(show.show.title)
                    .font(.subheadline.weight(.semibold))

                if let owner = show.show.owner.nonEmpty {
                    Text(owner)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let description = show.show.description.nonEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Square artwork that keeps the whole image visible (web: `object-contain p-3`).
struct ShowArtwork: View {
    let url: URL?

    var body: some View {
        ZStack {
            // Fills the square so the spinner and icon stay centered. No tint:
            // on the iOS grouped background, a tint makes the card look split.
            Color.clear

            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit().padding(12)
                    case .failure:
                        placeholderIcon
                    default:
                        ProgressView()
                    }
                }
            } else {
                placeholderIcon
            }
        }
        // Decorative: the card's title already names the show.
        .accessibilityHidden(true)
    }

    private var placeholderIcon: some View {
        Image(systemName: "waveform")
            .font(.title)
            .foregroundStyle(.tertiary)
    }
}

extension Optional where Wrapped == String {
    /// The string with surrounding whitespace removed, or `nil` if that leaves nothing.
    var nonEmpty: String? {
        guard let trimmed = self?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
