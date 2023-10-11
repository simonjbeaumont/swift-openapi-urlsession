//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftOpenAPIGenerator open source project
//
// Copyright (c) 2023 Apple Inc. and the SwiftOpenAPIGenerator project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftOpenAPIGenerator project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
import Foundation
import OpenAPIRuntime
import XCTest

func XCTAssertThrowsError<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (_ error: any Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("expression did not throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}

func XCTSkipUnlessAsync(
    _ expression: @autoclosure () async throws -> Bool,
    _ message: @autoclosure () -> String? = nil,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws {
    let result = try await expression()
    try XCTSkipUnless(result, message(), file: file, line: line)
}

func XCTUnwrapAsync<T>(
    _ expression: @autoclosure () async throws -> T?,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) async throws -> T {
    let maybeValue = try await expression()
    return try XCTUnwrap(maybeValue, message(), file: file, line: line)
}

extension URL {
    var withoutPath: URL {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)!
        components.path = ""
        return components.url!
    }
}

extension Collection where Index == Int {
    func chunks(of size: Int) -> [[Element]] {
        precondition(size > 0)
        return stride(from: startIndex, to: endIndex, by: size)
            .map {
                Array(self[$0..<Swift.min($0 + size, count)])
            }
    }
}

extension String {
    func chunks(of size: Int) -> [String] {
        precondition(size > 0)
        var chunkStart = startIndex
        var results = [Substring]()
        results.reserveCapacity((count - 1) / size + 1)
        while chunkStart < endIndex {
            let chunkEnd = index(chunkStart, offsetBy: size, limitedBy: endIndex) ?? endIndex
            results.append(self[chunkStart..<chunkEnd])
            chunkStart = chunkEnd
        }
        return results.map { String($0) }
    }
}

extension Stream.Event: CustomStringConvertible {
    public var description: String {
        switch self {
        case .hasBytesAvailable:
            return "code=\(rawValue) (hasBytesAvailable)"
        case .hasSpaceAvailable:
            return "code=\(rawValue) (hasSpaceAvailable)"
        case .endEncountered:
            return "code=\(rawValue) (endEncountered)"
        case .errorOccurred:
            return "code=\(rawValue) (errorEncountered)"
        case .openCompleted:
            return "code=\(rawValue) (openCompleted)"
        default:
            return "code=\(rawValue) (unknown)"
        }
    }
}

extension Stream.Status: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notOpen:
            return "notOpen"
        case .opening:
            return "opening"
        case .open:
            return "open"
        case .reading:
            return "reading"
        case .writing:
            return "writing"
        case .atEnd:
            return "atEnd"
        case .closed:
            return "closed"
        case .error:
            return "error"
        @unknown default:
            return "unknown"
        }
    }
}

class TestHelperTests: XCTestCase {
    func testArrayChunks() {
        for (array, chunkSize, expectedChunks) in [
            ([1, 2], 1, [[1], [2]]),
            ([1, 2, 3], 1, [[1], [2], [3]]),
            ([1, 2, 3], 2, [[1, 2], [3]]),
        ] {
            XCTAssertEqual(array.chunks(of: chunkSize), expectedChunks)
        }
    }

    func testStringChunks() {
        for (string, chunkSize, expectedChunks) in [
            ("hello", 1, ["h", "e", "l", "l", "o"]),
            ("hello", 2, ["he", "ll", "o"]),
            ("hello", 5, ["hello"]),
            ("hello", 6, ["hello"]),
        ] {
            XCTAssertEqual(string.chunks(of: chunkSize), expectedChunks)
        }

    }
}

extension HTTPBody.Length: Equatable {
    public static func == (lhs: HTTPBody.Length, rhs: HTTPBody.Length) -> Bool {
        switch (lhs, rhs) {
        case (.unknown, .unknown): return true
        case (.known(let lhsLength), .known(let rhsLength)): return lhsLength == rhsLength
        case (_, _): return false
        }
    }
}
