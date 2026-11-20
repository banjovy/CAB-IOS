//
//  CABTests.swift
//  CABTests
//
//  Task 1 scaffold: a single trivial test to prove the test target builds
//  and runs green via `xcodebuild test`. Real decoding/logic tests arrive
//  in Task 2+.
//

import XCTest
@testable import CAB

final class CABTests: XCTestCase {

    func testScaffoldSanity() throws {
        // Trivial assertion to confirm the test target is wired up correctly.
        XCTAssertEqual(2 + 2, 4)
    }
}
