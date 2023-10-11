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
import XCTest
import OpenAPIRuntime
#if canImport(Darwin)
import Foundation
#else
@preconcurrency import struct Foundation.URL
#endif
#if canImport(FoundationNetworking)
@preconcurrency import struct FoundationNetworking.URLRequest
@preconcurrency import class FoundationNetworking.URLProtocol
@preconcurrency import class FoundationNetworking.URLSession
@preconcurrency import class FoundationNetworking.HTTPURLResponse
@preconcurrency import class FoundationNetworking.URLResponse
@preconcurrency import class FoundationNetworking.URLSessionConfiguration
#endif
@testable import OpenAPIURLSession
import HTTPTypes

import NIO
import NIOHTTP1
import NIOTestUtils

class URLSessionTransportConverterTests: XCTestCase {
    func testRequestConversion() async throws {
        let request = HTTPRequest(
            method: .post,
            scheme: nil,
            authority: nil,
            path: "/hello%20world/Maria?greeting=Howdy",
            headerFields: [
                .init("x-mumble2")!: "mumble"
            ]
        )
        let urlRequest = try URLRequest(
            request,
            baseURL: URL(string: "http://example.com/api")!
        )
        XCTAssertEqual(urlRequest.url, URL(string: "http://example.com/api/hello%20world/Maria?greeting=Howdy"))
        XCTAssertEqual(urlRequest.httpMethod, "POST")
        XCTAssertEqual(urlRequest.allHTTPHeaderFields?.count, 1)
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "x-mumble2"), "mumble")
    }

    func testResponseConversion() async throws {
        let urlResponse: URLResponse = HTTPURLResponse(
            url: URL(string: "http://example.com/api/hello%20world/Maria?greeting=Howdy")!,
            statusCode: 201,
            httpVersion: "HTTP/1.1",
            headerFields: ["x-mumble3": "mumble"]
        )!
        let response = try HTTPResponse(urlResponse)
        XCTAssertEqual(response.status.code, 201)
        XCTAssertEqual(response.headerFields, [.init("x-mumble3")!: "mumble"])
    }
}

class URLSessionTransportSendTestsMockURLProtocol: XCTestCase {
    func testSend() async throws {
        let endpointURL = URL(string: "http://example.com/api/hello%20world/Maria?greeting=Howdy")!
        MockURLProtocol.mockHTTPResponses.withValue { map in
            map[endpointURL] = .success(
                HTTPURLResponse(url: endpointURL, statusCode: 201, httpVersion: nil, headerFields: [:])!,
                body: Data("👋".utf8)
            )
        }
        let transport: any ClientTransport = URLSessionTransport(
            configuration: .init(session: MockURLProtocol.mockURLSession)
        )
        let request = HTTPRequest(
            method: .post,
            scheme: nil,
            authority: nil,
            path: "/hello%20world/Maria?greeting=Howdy",
            headerFields: [
                .init("x-mumble1")!: "mumble"
            ]
        )
        let requestBody: HTTPBody = "👋"
        let (response, maybeResponseBody) = try await transport.send(
            request,
            body: requestBody,
            baseURL: URL(string: "http://example.com/api")!,
            operationID: "postGreeting"
        )
        let responseBody = try XCTUnwrap(maybeResponseBody)
        XCTAssertEqual(response.status.code, 201)
        let bufferedResponseBody = try await String(collecting: responseBody, upTo: .max)
        XCTAssertEqual(bufferedResponseBody, "👋")
    }

    // NOTE: This test doesn't really test what we want it to.
    func testSendWithRedirectMockURLSession() async throws {
        let knockKnockURL = URL(string: "http://example.com/api/knock-knock")!
        let helloURL = URL(string: "http://example.com/api/hello")!
        let knockKnockRequest = HTTPRequest(
            method: .post,
            scheme: nil,
            authority: nil,
            path: knockKnockURL.path()
        )
        let helloRequest = HTTPRequest(
            method: .post,
            scheme: nil,
            authority: nil,
            path: helloURL.path()
        )

        MockURLProtocol.mockHTTPResponses.withValue { map in
            map[knockKnockURL] = .redirect(
                to: try! URLRequest(helloRequest, baseURL: helloURL.withoutPath),
                redirectResponse: HTTPURLResponse(
                    url: knockKnockURL,
                    statusCode: 307,
                    httpVersion: nil,
                    headerFields: [
                        "Location": helloURL.absoluteString
                    ]
                )!
            )
            map[helloURL] = .success(
                HTTPURLResponse(url: helloURL, statusCode: 200, httpVersion: nil, headerFields: [:])!,
                body: Data("👋".utf8)
            )
        }
        let transport: any ClientTransport = URLSessionTransport(
            configuration: URLSessionTransport.Configuration(
                session: MockURLProtocol.mockURLSession,
                uploadBufferSize: 1
            )
        )
        let requestBody = HTTPBody(
            MockAsyncSequence(elementsToVend: ["knock", "knock"], gatingProduction: false),
            length: .known(10),
            iterationBehavior: .multiple
        )
        let (response, maybeResponseBody) = try await transport.send(
            knockKnockRequest,
            body: requestBody,
            baseURL: knockKnockURL.withoutPath,
            operationID: "unused"
        )
        XCTAssertEqual(response.status.code, 200)
        let responseBody = try XCTUnwrap(maybeResponseBody)
        let bufferedResponseBody = try await String(collecting: responseBody, upTo: .max)
        XCTAssertEqual(bufferedResponseBody, "👋")
    }
}

class URLSessionTransportSendHTTPBinTests: XCTestCase {
    static let localhostServerBaseURL = URL(string: "http://localhost:8080")!
    static var hasLocalhostServer: Bool {
        get async {
            do {
                let (bytes, response) = try await URLSession.shared.bytes(
                    from: Self.localhostServerBaseURL.appending(path: "/uuid")
                )
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    return false
                }
                struct UUIDResponse: Decodable {
                    let uuid: String
                }
                var data = Data()
                data.reserveCapacity(MemoryLayout<UUIDResponse>.size)
                for try await byte in bytes {
                    data.append(byte)
                }
                let uuidResponse = try JSONDecoder().decode(UUIDResponse.self, from: data)
                return UUID(uuidString: uuidResponse.uuid) != nil
            } catch {
                return false
            }
        }
    }

    func testSendHTTPBinRedirectRewindsStream() async throws {
        try await XCTSkipUnlessAsync(await Self.hasLocalhostServer)
        let transport = URLSessionTransport(
            configuration: URLSessionTransport.Configuration(
                session: .shared,
                uploadBufferSize: 3
            )
        )

        let requestBodyChunks = ["✊", "✊", " ", "knock", " ", "knock!"]

        let requestBody = HTTPBody(
            MockAsyncSequence(elementsToVend: requestBodyChunks, gatingProduction: false),
            length: .known(requestBodyChunks.joined().lengthOfBytes(using: .utf8)),
            iterationBehavior: .multiple
        )
        let (response, maybeResponseBody) = try await transport.send(
            HTTPRequest(
                method: .post,
                scheme: nil,
                authority: nil,
                path: "/redirect-to?url=/anything&status_code=307",
                headerFields: [
                    .contentType: "text/plain",
                    .accept: "application/json",
                ]
            ),
            body: requestBody,
            baseURL: Self.localhostServerBaseURL,
            operationID: "whatever"
        )
        XCTAssertEqual(response.status.code, 200)

        let responseBody = try XCTUnwrap(maybeResponseBody)

        // httpbin /anything returns a JSON object with many fields, incl. the request method and data.
        struct Payload: Decodable {
            var method: String
            var data: String
        }
        let responseBodyData = try await Data(collecting: responseBody, upTo: .max)
        let payload = try JSONDecoder().decode(Payload.self, from: responseBodyData)
        XCTAssertEqual(payload.data, "✊✊ knock knock!")
    }

    func testSendHTTPBinDrip() async throws {
        try await XCTSkipUnlessAsync(await Self.hasLocalhostServer)
        let transport = URLSessionTransport(
            configuration: URLSessionTransport.Configuration(
                session: .shared
            )
        )

        let (response, maybeResponseBody) = try await transport.send(
            HTTPRequest(
                method: .get,
                scheme: nil,
                authority: nil,
                path: "/drip?numbytes=10&duration=0.1",
                headerFields: [
                    .accept: "application/octet-stream"
                ]
            ),
            body: nil,
            baseURL: Self.localhostServerBaseURL,
            operationID: "unused"
        )
        XCTAssertEqual(response.status.code, 200)
        XCTAssertEqual(response.headerFields[.contentLength], "10")

        let responseBody = try XCTUnwrap(maybeResponseBody)

        // httpbin /drip returns bytes '*'.
        var numChunks = 0
        for try await chunk in responseBody {
            XCTAssertEqual(String(data: Data(chunk), encoding: .ascii), "*")
            numChunks += 1
        }
        XCTAssertEqual(numChunks, 10)
    }
}

class URLSessionTransportSendNIOHTTPTestServerTests: XCTestCase {
    func testSendToNIOHTTPTestServer() async throws {
        // Setup the test environment.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let testServer = NIOHTTP1TestServer(group: group, aggregateBody: false)
        defer {
            XCTAssertNoThrow(try testServer.stop())
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let transport = URLSessionTransport(
            configuration: URLSessionTransport.Configuration(
                session: .shared
            )
        )

        let requestBodyChunks = ["✊", "✊", " ", "knock", " ", "knock!"]
        let requestContentLength = requestBodyChunks.joined().lengthOfBytes(using: .utf8)
        let responseBodyChunks = ["🤨", "Who's", "there?"]
        let responseContentLength = responseBodyChunks.joined().lengthOfBytes(using: .utf8)

        let requestBody = HTTPBody(
            MockAsyncSequence(elementsToVend: requestBodyChunks, gatingProduction: false),
            length: .known(requestContentLength),
            iterationBehavior: .multiple
        )

        async let (responseAsync, maybeResponseBodyAsync) = try await transport.send(
            HTTPRequest(
                method: .post,
                scheme: nil,
                authority: nil,
                path: "/some/path",
                headerFields: [
                    .contentType: "text/plain",
                    .accept: "text/plain",
                ]
            ),
            body: requestBody,
            baseURL: URL(string: "http://127.0.0.1:\(testServer.serverPort)")!,
            operationID: "unused"
        )

        // Assert the server received the expected request.
        do {
            try testServer.receiveHeadAndVerify { head in
                XCTAssertEqual(head.method, .POST)
                XCTAssertEqual(head.uri, "/some/path")
                XCTAssertEqual(head.headers["Content-Type"], ["text/plain"])
                XCTAssertEqual(head.headers["Accept"], ["text/plain"])
                XCTAssertEqual(head.headers["Content-Length"], ["\(requestContentLength)"])
                XCTAssertEqual(head.headers["Transfer-Encoding"], [])
            }
            try testServer.receiveBodyAndVerify { body in
                XCTAssertEqual(body, ByteBuffer(string: requestBodyChunks.joined()))
            }
            try testServer.receiveEndAndVerify { trailers in
                XCTAssertNil(trailers)
            }
        }

        // Make the server send a response to the client.
        do {
            let headers: HTTPHeaders = ["Content-Length": "\(responseContentLength)"]
            try testServer.writeOutbound(.head(.init(version: .http1_1, status: .ok, headers: headers)))
            for chunk in responseBodyChunks {
                try testServer.writeOutbound(.body(.byteBuffer(ByteBuffer(string: chunk))))
            }
            try testServer.writeOutbound(.end(nil))
        }

        // Assert that the client received the expected response from the server.
        let response = try await responseAsync
        XCTAssertEqual(response.status, 200)

        // Assert that the client received the expected body from the server.
        let maybeResponseBody = try await maybeResponseBodyAsync
        let responseBody = try XCTUnwrap(maybeResponseBody)
        XCTAssertEqual(responseBody.length, .known(responseContentLength))
        let responseBodyData = try await Data(collecting: responseBody, upTo: .max)
        XCTAssertEqual(String(data: Data(responseBodyData), encoding: .utf8), responseBodyChunks.joined())
    }

    func testEchoOneChunkOneBuffer() async throws {
        try await testSendToEchoHTTPServer(
            requestMessage: "hello",
            chunkSize: 5,
            streaming: true,
            uploadBufferSize: 5
        )
    }

    func testEchoManyChunksSmallerThanBuffer() async throws {
        try await testSendToEchoHTTPServer(
            requestMessage: "hello",
            chunkSize: 1,
            streaming: true,
            uploadBufferSize: 5
        )
    }

    func testEchoOneChunkLargerThanBuffer() async throws {
        try await testSendToEchoHTTPServer(
            requestMessage: "hello",
            chunkSize: 5,
            streaming: true,
            uploadBufferSize: 1
        )
    }

    func testEchoManyChunksLargerThanBuffer() async throws {
        try await testSendToEchoHTTPServer(
            requestMessage: "hello",
            chunkSize: 2,
            streaming: true,
            uploadBufferSize: 1
        )
    }

    func testEcho1MChunk4kBuffer() async throws {
        try await testSendToEchoHTTPServer(
            requestMessage: String(repeating: "*", count: 1_000_000),
            chunkSize: .max,
            streaming: false,
            uploadBufferSize: 4096
        )
    }

    // TODO: This one fails... looks like the outputstreambridge gets stuck
    func testEcho4kChunks1kBuffer() async throws {
        try await testSendToEchoHTTPServer(
            requestMessage: String(repeating: "*", count: 8192),
            chunkSize: 4096,
            streaming: true,
            uploadBufferSize: 1024
        )
    }

    func testSendToEchoHTTPServer(
        requestMessage: String,
        chunkSize: Int,
        streaming: Bool = false,
        uploadBufferSize: Int
    ) async throws {
        // Setup the test server.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let testServer = NIOHTTP1TestServer(group: group, aggregateBody: !streaming)
        defer {
            XCTAssertNoThrow(try testServer.stop())
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        print(testServer.serverPort)

        // Setup the test client.
        let transport = URLSessionTransport(
            configuration: URLSessionTransport.Configuration(
                session: .shared,
                uploadBufferSize: uploadBufferSize
            )
        )

        // Set up the request body.
        let mockRequestBodySequence = MockAsyncSequence(
            elementsToVend: requestMessage.chunks(of: chunkSize),
            gatingProduction: streaming
        )
        let requestBody = HTTPBody(
            mockRequestBodySequence,
            length: .unknown,
            iterationBehavior: .multiple
        )

        // Send the request.
        async let (responseAsync, maybeResponseBodyAsync) = try await transport.send(
            HTTPRequest(
                method: .post,
                scheme: nil,
                authority: nil,
                path: "/some/path",
                headerFields: [
                    .contentType: "text/plain",
                    .accept: "text/plain",
                ]
            ),
            body: requestBody,
            baseURL: URL(string: "http://127.0.0.1:\(testServer.serverPort)")!,
            operationID: "unused"
        )

        // Assert the server received the expected request head and make it respond with a head.
        do {
            try testServer.receiveHeadAndVerify { head in
                XCTAssertEqual(head.method, .POST)
                XCTAssertEqual(head.uri, "/some/path")
                XCTAssertEqual(head.headers["Content-Type"], ["text/plain"])
                XCTAssertEqual(head.headers["Accept"], ["text/plain"])
                XCTAssertEqual(head.headers["Content-Length"], [])
                XCTAssertEqual(head.headers["Transfer-Encoding"], ["chunked"])
            }
            try testServer.writeOutbound(.head(.init(version: .http1_1, status: .ok)))
        }

        // Now send one chunk at a time, check the server receives, and make thes server send one chunk back.
        do {
            if streaming {
                for i in 0..<mockRequestBodySequence.elementsToVend.count {
                    // Let one more element through the sequence that backs the request body.
                    mockRequestBodySequence.openGate(for: 1)
                    // Have the server read and echo until it has read the whole chunk, which will take multiple reads if
                    // the buffer is smaller than the chunk.
                    var expectedByteCount = mockRequestBodySequence.elementsToVend[i].count
                    while expectedByteCount > 0 {
                        print("Still expecting to receive \(expectedByteCount) bytes at the server")
                        try testServer.receiveBodyAndVerify { buffer in
                            print("Server received \(buffer.readableBytes) bytes: \(String(buffer: buffer))")
                            XCTAssertLessThanOrEqual(buffer.readableBytes, uploadBufferSize)
                            expectedByteCount -= buffer.readableBytes
                            try testServer.writeOutbound(.body(.byteBuffer(buffer)))
                        }
                    }
                }
            } else {
                mockRequestBodySequence.openGate()
                try testServer.receiveBodyAndVerify { buffer in
                    try testServer.writeOutbound(.body(.byteBuffer(buffer)))
                }
            }
        }

        // At this point the client should have reached the end of the sequence, so shoud end the request.
        if streaming {
            mockRequestBodySequence.openGate(for: 1)
        }
        try testServer.receiveEndAndVerify { trailers in
            XCTAssertNil(trailers)
        }

        // Server can now also end the request.
        try testServer.writeOutbound(.end(nil))

        // Assert that the client received the expected response from the server.
        let response = try await responseAsync
        XCTAssertEqual(response.status, 200)

        // Assert that the client received the expected body from the server.
        let maybeResponseBody = try await maybeResponseBodyAsync
        let responseBody = try XCTUnwrap(maybeResponseBody)
        XCTAssertEqual(responseBody.length, .unknown)
        let responseBodyData = try await Data(collecting: responseBody, upTo: .max)
        XCTAssertEqual(String(data: Data(responseBodyData), encoding: .utf8), String(requestMessage))
    }
}
