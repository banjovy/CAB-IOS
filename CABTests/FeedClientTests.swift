//
//  FeedClientTests.swift
//  CABTests
//
//  Task 4: URL policy and the HTTP client.
//

import XCTest
@testable import CAB

final class FeedClientTests: XCTestCase {

    private let policy = FeedURLPolicy.cabAssets

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    private func makeClient() -> FeedClient {
        FeedClient(session: MockURLProtocol.makeSession())
    }

    // MARK: - URL policy

    func testPolicyAllowsBackendHostAndSubdomainsOverHTTPS() {
        for allowed in ["https://assets.cabroadcasting.com/audio/etw.json",
                        "HTTPS://ASSETS.CABROADCASTING.COM/audio/etw.json",
                        "https://cdn.assets.cabroadcasting.com/x.json",
                        " https://assets.cabroadcasting.com/audio/etw.json "] {
            XCTAssertNotNil(policy.allowedURL(allowed), allowed)
        }
    }

    func testPolicyRejectsOtherSchemesHostsAndTricks() {
        for rejected in [nil, "", "   ", "not a url",
                         "http://assets.cabroadcasting.com/audio/etw.json",
                         "ftp://assets.cabroadcasting.com/audio/etw.json",
                         "https://afr.net/api/v3/lineup/nowplaying/?network=talk",
                         "https://cabroadcasting.com/audio/etw.json",
                         "https://evilassets.cabroadcasting.com.evil.example/x.json",
                         "https://assets.cabroadcasting.com.evil.example/x.json",
                         "https://assets.cabroadcasting.com@evil.example/x.json",
                         "https://104.18.0.1/audio/etw.json",
                         "https://[::1]/audio/etw.json",
                         "/audio/etw.json"] {
            XCTAssertNil(policy.allowedURL(rejected), String(describing: rejected))
        }
    }

    func testPolicyAllowsTheEndpointsAndEveryLiveEpisodeFeed() throws {
        XCTAssertTrue(policy.allows(FeedEndpoints.shows))
        XCTAssertTrue(policy.allows(FeedEndpoints.resources))

        let url = try XCTUnwrap(Bundle(for: FeedClientTests.self)
            .url(forResource: "shows", withExtension: "json", subdirectory: "Fixtures"))
        let shows = try Show.decodeList(from: Data(contentsOf: url))
        let feeds = shows.compactMap(\.jsonURL)
        XCTAssertEqual(feeds.count, 27)
        XCTAssertTrue(feeds.allSatisfy { policy.allowedURL($0) != nil }, "The allowlist must not drop any live podcast")
    }

    func testCustomPolicyCanAllowAnotherHost() {
        let afr = FeedURLPolicy(allowedHosts: ["AFR.net"])
        XCTAssertNotNil(afr.allowedURL("https://afr.net/api/v3/lineup/nowplaying/?network=talk"))
        XCTAssertNil(afr.allowedURL("https://assets.cabroadcasting.com/audio/shows.json"))
    }

    // MARK: - Client

    func testReturnsBodyAndSendsExpectedRequest() async throws {
        let body = Data(#"{"ok":true}"#.utf8)
        MockURLProtocol.serve([FeedEndpoints.shows.absoluteString: (200, body)])

        let data = try await makeClient().data(from: FeedEndpoints.shows)

        XCTAssertEqual(data, body)
        let request = try XCTUnwrap(MockURLProtocol.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(request.timeoutInterval, 10)
    }

    func testNon2xxStatusThrows() async {
        MockURLProtocol.serve([FeedEndpoints.shows.absoluteString: (503, Data("down".utf8))])
        do {
            _ = try await makeClient().data(from: FeedEndpoints.shows)
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? FeedClientError, .httpStatus(503))
        }
    }

    func testDisallowedURLThrowsWithoutARequest() async {
        MockURLProtocol.serve([:])
        let url = URL(string: "https://evil.example/shows.json")!
        do {
            _ = try await makeClient().data(from: url)
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? FeedClientError, .disallowedURL(url.absoluteString))
        }
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }

    func testTransportErrorPassesThrough() async {
        MockURLProtocol.setHandler { _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await makeClient().data(from: FeedEndpoints.shows)
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
    }
}
