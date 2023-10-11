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
// NOTE: On Linux, URLProtocol does not have access to the request body:
//       https://github.com/apple/swift-corelibs-foundation/issues/3199
final class MockURLProtocol: URLProtocol {
    enum MockURLResponse {
        case success(HTTPURLResponse, body: Data?)
        case redirect(to: URLRequest, redirectResponse: HTTPURLResponse)
        case failure(any Error)
    }
    typealias MockHTTPResponseMap = [URL: MockURLResponse]
    static let mockHTTPResponses = LockedValueBox<MockHTTPResponseMap>([:])

    static let recordedHTTPRequests = LockedValueBox<[URLRequest]>([])

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func stopLoading() {}

    private static var streamDelegate: MockInputStreamDelegate? = nil

    override func startLoading() {
        print("MockURLProtocol: request URL: \(String(describing: request.url))")
        print("MockURLProtocol: request method: \(String(describing: request.httpMethod))")
        print("MockURLProtocol: request body: \(String(describing: request.httpBody))")
        print("MockURLProtocol: request body stream: \(String(describing: request.httpBodyStream))")
        Self.recordedHTTPRequests.withValue { $0.append(self.request) }
        guard let url = self.request.url else { return }
        guard let mockResponse = Self.mockHTTPResponses.withValue({ $0[url] }) else {
            return
        }
        let s = DispatchSemaphore(value: 0)
        MockURLProtocol.mockURLSession.getAllTasks(completionHandler: { tasks in
            print(tasks)
            s.signal()
        })
        s.wait()

        if let requestBodyStream = self.request.httpBodyStream {
            Self.streamDelegate = MockInputStreamDelegate(inputStream: requestBodyStream)
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                while try await Self.streamDelegate?.waitForBytes(maxBytes: 4096) != nil {
                    continue
                }
                semaphore.signal()
            }
            semaphore.wait()
        }
        switch mockResponse {
        case .success(let response, let body):
            // Unfortunately there's no APIs for mocking a streamed response in URLProtocol.
            // The only thing we can do is call `urlProtocol(_:didLoad:)`. Calling this  multiple
            // times will just buffer until `urlProtocolDidFinishLoading` is called.
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let body {
                client?.urlProtocol(self, didLoad: body)
            }
            client?.urlProtocolDidFinishLoading(self)
        case .redirect(let newRequest, let redirectResponse):
            // Oh, this is sad... this only triggers `willPerfromHTTPRedirection` but _NOT_ `needNewBodyStreamForTask`, so the next request comes back with `nil` stream. Sad, sad, sad.
            client?.urlProtocol(self, wasRedirectedTo: newRequest, redirectResponse: redirectResponse)
            client?.urlProtocolDidFinishLoading(self)
        case let .failure(error):
            client?.urlProtocol(self, didFailWithError: error)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    static var mockURLSession: URLSession {
        let configuration: URLSessionConfiguration = .ephemeral
        configuration.protocolClasses = [Self.self]
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: configuration)
    }
}
