//
//  FeedDateParser.swift
//  CAB
//
//  Date parsing for the backend feeds (CONTRACT.md §2, §3).
//
//  Built on Calendar + DateComponents rather than DateFormatter or
//  ISO8601DateFormatter so both input shapes behave the same way and the
//  time zone can be injected in tests.
//

import Foundation

struct FeedDateParser {
    /// The zone used when a string has no offset of its own: episode dates
    /// and offset-less timestamps. Defaults to the device zone, matching the
    /// web app (JavaScript treats both as local time).
    let timeZone: TimeZone

    init(timeZone: TimeZone = .current) {
        self.timeZone = timeZone
    }

    // MARK: - Episode dates

    /// Parses an episode `date` (`MM/DD/YYYY`) into local midnight.
    ///
    /// Port of web `parseEpisodeDate`. Unlike JavaScript's `new Date(y, m, d)`,
    /// impossible dates such as `02/30/2026` return `nil` instead of rolling
    /// over into the next month. A 4-digit year is required.
    func episodeDate(_ text: String?) -> Date? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[2].count == 4,
              let month = Int(parts[0]),
              let day = Int(parts[1]),
              let year = Int(parts[2]) else { return nil }

        return validatedDate(year: year, month: month, day: day, in: timeZone)
    }

    // MARK: - Timestamps

    /// `YYYY-MM-DDTHH:MM:SS`, optional fractional seconds, optional `Z` or `±HH:MM` / `±HHMM`.
    private static let timestampPattern = try! Regex(
        #"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(\.\d+)?(Z|[+-]\d{2}:?\d{2})?$"#
    )

    /// Parses an ISO-8601 timestamp such as `publishedAt`, `generatedAt` or
    /// `latest_update`.
    ///
    /// Accepts all three shapes in the live feeds:
    /// - with offset: `2026-11-11T18:58:17+00:00`
    /// - UTC with fractional seconds: `2026-11-11T14:16:10.780883Z`
    /// - no offset: `2026-11-11T04:00:00`, read in `timeZone` (web parity)
    func timestamp(_ text: String?) -> Date? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              let match = try? Self.timestampPattern.wholeMatch(in: trimmed) else { return nil }

        func int(_ index: Int) -> Int? {
            match.output[index].substring.flatMap { Int($0) }
        }
        guard let year = int(1), let month = int(2), let day = int(3),
              let hour = int(4), let minute = int(5), let second = int(6) else { return nil }

        let zone: TimeZone
        if let offset = match.output[8].substring {
            guard let parsed = Self.fixedZone(offset: offset) else { return nil }
            zone = parsed
        } else {
            zone = timeZone
        }

        guard let date = validatedDate(year: year, month: month, day: day,
                                       hour: hour, minute: minute, second: second, in: zone) else { return nil }

        // Fractional seconds, e.g. ".780883" → 0.780883.
        let fraction = match.output[7].substring.flatMap { Double("0" + $0) } ?? 0
        return date.addingTimeInterval(fraction)
    }

    // MARK: - Helpers

    /// Builds a date and rejects anything the calendar had to adjust
    /// (month 13, Feb 30, hour 24, or a local time skipped by a DST change).
    private func validatedDate(year: Int, month: Int, day: Int,
                               hour: Int = 0, minute: Int = 0, second: Int = 0,
                               in zone: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone

        let components = DateComponents(year: year, month: month, day: day,
                                        hour: hour, minute: minute, second: second)
        guard let date = calendar.date(from: components) else { return nil }

        let check = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard check.year == year, check.month == month, check.day == day,
              check.hour == hour, check.minute == minute, check.second == second else { return nil }
        return date
    }

    /// `Z` → UTC; `+05:30` or `+0530` → a fixed-offset zone.
    private static func fixedZone(offset: Substring) -> TimeZone? {
        if offset == "Z" { return TimeZone(secondsFromGMT: 0) }

        let sign = offset.first == "-" ? -1 : 1
        let digits = offset.dropFirst().filter { $0 != ":" }
        guard digits.count == 4,
              let hours = Int(digits.prefix(2)),
              let minutes = Int(digits.suffix(2)),
              hours <= 18, minutes < 60 else { return nil }
        return TimeZone(secondsFromGMT: sign * (hours * 3600 + minutes * 60))
    }
}
