//
//  Resources.swift
//  CAB
//
//  Curated reading from `GET /resources/resources.json` (CONTRACT.md §3).
//

import Foundation

struct ResourcesFeed: Decodable, Equatable, Sendable {
    /// ISO-8601 timestamp of when the backend built the feed.
    let generatedAt: String?
    let categories: [ResourceCategory]
    let sources: [ResourceSource]
    let items: [ResourceItem]

    private enum CodingKeys: String, CodingKey {
        case generatedAt, categories, sources, items
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try? c.decodeIfPresent(String.self, forKey: .generatedAt)
        categories = c.decodeLossyArray(ResourceCategory.self, forKey: .categories)
        sources = c.decodeLossyArray(ResourceSource.self, forKey: .sources)
        items = c.decodeLossyArray(ResourceItem.self, forKey: .items)
    }
}

struct ResourceCategory: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let label: String
    let order: Int?

    private enum CodingKeys: String, CodingKey { case id, label, order }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        order = try? c.decodeIfPresent(Int.self, forKey: .order)
    }
}

/// A content provider (e.g. Ligonier Ministries).
struct ResourceSource: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    /// Provider website.
    let url: String?
    let category: String?
    /// Provider logo; the card image when an item has no thumbnail.
    let logo: String?
}

/// An article card.
struct ResourceItem: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    /// Matches `ResourceSource.id`.
    let sourceId: String
    let title: String
    /// External article URL ("Read at source").
    let url: String
    /// Matches `ResourceCategory.id`.
    let category: String?
    let excerpt: String?
    let author: String?
    /// ISO-8601, with or without a timezone offset (both occur in the live feed).
    let publishedAt: String?
    /// Often `null`; fall back to the source logo.
    let thumbnail: String?
}
