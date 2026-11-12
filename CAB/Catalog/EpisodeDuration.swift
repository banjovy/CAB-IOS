//
//  EpisodeDuration.swift
//  CAB
//
//  Port of `parseDurationSeconds` from the web app's `/api/data` route.
//

import Foundation

enum EpisodeDuration {
    /// Parses an episode duration string into whole seconds.
    ///
    /// - `H:MM:SS` → `h*3600 + m*60 + s` (every live episode uses this form)
    /// - `MM:SS`   → `m*60 + s`
    /// - `SS`      → `s`
    ///
    /// Returns `nil` for missing or malformed input. This is slightly stricter
    /// than the web app, which uses JavaScript `Number()` and so accepts empty
    /// parts (`"1::3"`), decimals and signs, and returns the first part for
    /// 4+ parts. None of those occur in the live feeds.
    static func seconds(from text: String?) -> Int? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }

        var total = 0
        for part in parts {
            let digits = part.trimmingCharacters(in: .whitespaces)
            guard !digits.isEmpty,
                  digits.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(digits) else { return nil }
            // Horner's method: [h, m, s] → ((h * 60) + m) * 60 + s.
            let (shifted, overflow1) = total.multipliedReportingOverflow(by: 60)
            let (sum, overflow2) = shifted.addingReportingOverflow(value)
            guard !overflow1, !overflow2 else { return nil }
            total = sum
        }
        return total
    }
}
