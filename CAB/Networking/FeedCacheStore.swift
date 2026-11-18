//
//  FeedCacheStore.swift
//  CAB
//
//  On-disk cache of raw feed payloads. The web app caches in Cloudflare KV;
//  the app keeps one file per feed in the Caches directory, which the system
//  may purge and which isn't backed up.
//

import Foundation

struct FeedCacheRecord: Codable, Equatable, Sendable {
    /// Bump when the payload format changes so old files are ignored.
    static let currentVersion = 1

    let version: Int
    let fetchedAt: Date
    /// Raw bytes, decoded on read by the feed that owns the record.
    let payload: Data

    init(fetchedAt: Date, payload: Data, version: Int = FeedCacheRecord.currentVersion) {
        self.version = version
        self.fetchedAt = fetchedAt
        self.payload = payload
    }
}

struct FeedCacheStore: Sendable {
    let directory: URL

    static let live = FeedCacheStore(directory: URL.cachesDirectory.appending(path: "FeedCache", directoryHint: .isDirectory))

    func fileURL(forKey key: String) -> URL {
        directory.appending(path: "\(key).plist", directoryHint: .notDirectory)
    }

    /// `nil` when the file is missing, unreadable, or from another format version.
    func read(forKey key: String) -> FeedCacheRecord? {
        guard let data = try? Data(contentsOf: fileURL(forKey: key)),
              let record = try? PropertyListDecoder().decode(FeedCacheRecord.self, from: data),
              record.version == FeedCacheRecord.currentVersion else { return nil }
        return record
    }

    /// Best effort, like the web's KV write: a failed write is ignored.
    func write(_ record: FeedCacheRecord, forKey key: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try PropertyListEncoder().encode(record)
            try data.write(to: fileURL(forKey: key), options: .atomic)
        } catch {
            // Not critical; the next successful load writes again.
        }
    }

    func remove(forKey key: String) {
        try? FileManager.default.removeItem(at: fileURL(forKey: key))
    }
}
