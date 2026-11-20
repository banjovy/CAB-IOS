//
//  MockURLProtocol.swift
//  CABTests
//
//  Intercepts URLSession requests so networking tests never touch the
//  network. State is static and lock-protected; tests run serially, and each
//  test calls `reset()` in setUp.
//

import Foundation

final class MockURLProtocol: URLProtocol {
    /// Returns a status code and body for a request, or throws to simulate a
    /// transport failure (e.g. `URLError(.notConnectedToInternet)`).
    typealias Handler = @Sendable (URLRequest) throws -> (status: Int, body: Data)

    private static let lock = NSLock()
    private static var handler: Handler?
    private static var recorded: [URLRequest] = []

    static func reset() {
        lock.withLock {
            handler = nil
            recorded = []
        }
    }

    static func setHandler(_ newHandler: @escaping Handler) {
        lock.withLock { handler = newHandler }
    }

    /// Serves fixed responses by absolute URL string; anything else is a 404.
    static func serve(_ routes: [String: (status: Int, body: Data)]) {
        setHandler { request in
            routes[request.url?.absoluteString ?? ""] ?? (404, Data())
        }
    }

    static var requests: [URLRequest] {
        lock.withLock { recorded }
    }

    static var requestedURLs: [String] {
        requests.compactMap { $0.url?.absoluteString }
    }

    /// A session that routes every request through this class.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler = Self.lock.withLock { () -> Handler? in
            Self.recorded.append(request)
            return Self.handler
        }
        guard let handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (status, body) = try handler(request)
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
