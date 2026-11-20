//
//  FeedClient.swift
//  CAB
//
//  Fetches raw feed bytes over HTTPS. Port of the web app's `loadJson`
//  without the JSON parsing, which callers do with the Task 2 models.
//

import Foundation

enum FeedClientError: Error, Equatable {
    /// The URL failed `FeedURLPolicy`; no request was made.
    case disallowedURL(String)
    /// The server answered with a non-2xx status (web: `!res.ok`).
    case httpStatus(Int)
    case notHTTPResponse
}

struct FeedClient: Sendable {
    let session: URLSession
    let policy: FeedURLPolicy
    /// Seconds. Matches the web's 10 s `FETCH_TIMEOUT_MS`. Note that
    /// `URLRequest.timeoutInterval` is an idle timeout, not a total one; for
    /// feeds of a few dozen KB the difference doesn't matter.
    let timeout: TimeInterval

    init(session: URLSession, policy: FeedURLPolicy = .cabAssets, timeout: TimeInterval = 10) {
        self.session = session
        self.policy = policy
        self.timeout = timeout
    }

    static let live = FeedClient(session: .shared)

    /// Returns the response body for a 2xx response.
    ///
    /// Throws `FeedClientError` for a disallowed URL or a bad status, and
    /// passes `URLError` through for transport failures. Redirects are
    /// followed (web: `redirect: 'follow'`).
    func data(from url: URL) async throws -> Data {
        guard policy.allows(url) else { throw FeedClientError.disallowedURL(url.absoluteString) }

        // Our own TTL cache decides freshness, so bypass the HTTP cache
        // (web: `cache: 'no-store'`).
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FeedClientError.notHTTPResponse }
        guard (200..<300).contains(http.statusCode) else { throw FeedClientError.httpStatus(http.statusCode) }
        return data
    }
}
