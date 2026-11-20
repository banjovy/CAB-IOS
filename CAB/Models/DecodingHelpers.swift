//
//  DecodingHelpers.swift
//  CAB
//
//  Lenient decoding helpers for the backend JSON feeds (see CONTRACT.md).
//
//  The app has no server of its own, so a single malformed entry from the
//  backend pipeline must not blank an entire screen. These helpers skip bad
//  array elements and accept loosely-typed numbers instead of failing.
//

import Foundation

/// Decodes a JSON array, skipping elements that fail to decode (including
/// `null`) instead of failing the whole array.
struct LossyArray<Element: Decodable>: Decodable {
    let elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var result: [Element] = []
        while !container.isAtEnd {
            // decodeNil() only advances the index when the value is null.
            if (try? container.decodeNil()) == true { continue }
            if let element = try? container.decode(Element.self) {
                result.append(element)
            } else {
                // A failed decode does not advance the index, so consume the
                // bad element explicitly to avoid an infinite loop.
                _ = try? container.decode(SkippedElement.self)
            }
        }
        elements = result
    }

    /// Decodes successfully from any JSON value. Used to step past bad elements.
    private struct SkippedElement: Decodable {
        init(from decoder: Decoder) throws {}
    }
}

extension KeyedDecodingContainer {
    /// Decodes an array leniently. A missing key, `null`, or a non-array value
    /// yields `[]`; bad elements are skipped.
    func decodeLossyArray<T: Decodable>(_ type: T.Type, forKey key: Key) -> [T] {
        (try? decodeIfPresent(LossyArray<T>.self, forKey: key))?.elements ?? []
    }

    /// Decodes an integer sent as either a JSON number or a numeric string
    /// (e.g. `update_interval` arrives as `"45"`). Anything else yields `nil`.
    func decodeFlexibleInt(forKey key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let text = try? decodeIfPresent(String.self, forKey: key) {
            return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }
}
