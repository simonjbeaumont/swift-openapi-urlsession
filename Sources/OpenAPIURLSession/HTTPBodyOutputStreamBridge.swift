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
import OpenAPIRuntime
import HTTPTypes
#if canImport(Darwin)
import Foundation
#else
@preconcurrency import struct Foundation.URL
@preconcurrency import struct Foundation.URLComponents
@preconcurrency import struct Foundation.Data
@preconcurrency import protocol Foundation.LocalizedError
#endif
#if canImport(FoundationNetworking)
@preconcurrency import struct FoundationNetworking.URLRequest
@preconcurrency import class FoundationNetworking.URLSession
@preconcurrency import class FoundationNetworking.URLResponse
@preconcurrency import class FoundationNetworking.HTTPURLResponse
#endif

final class HTTPBodyOutputStreamBridge: NSObject, StreamDelegate {
    static let streamQueue = DispatchQueue(label: "HTTPBodyStreamDelegate", autoreleaseFrequency: .workItem)

    let httpBody: HTTPBody
    let outputStream: OutputStream
    private(set) var bytesToWrite: ArraySlice<UInt8> = []
    private(set) var continuation: CheckedContinuation<Void, any Error>? = nil
    private var task: Task<Void, any Error>? = nil

    init(_ outputStream: OutputStream, _ httpBody: HTTPBody, openOutputStream: Bool = true) {
        self.httpBody = httpBody
        self.outputStream = outputStream
        super.init()
        self.outputStream.delegate = self
        CFWriteStreamSetDispatchQueue(self.outputStream as CFWriteStream, Self.streamQueue)
        if openOutputStream {
            self.outputStream.open()
        }
    }

    deinit {
        debug("Output stream delegate deinit")
    }

    func startWriterTask() {
        // Spin up a task that reads the async sequence and writes to the output stream.
        self.task = Task {
            for try await chunk in httpBody {
                print("Output stream delegate read chunk from async sequence")
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { continuation in
                    Self.streamQueue.async {
                        precondition(self.continuation == nil)
                        precondition(self.bytesToWrite.isEmpty)
                        self.continuation = continuation
                        self.bytesToWrite = chunk
                        self.writePendingBytes()
                    }
                }
            }
            Self.streamQueue.async {
                print("Output stream delegate done sending chunks; will close stream")
                self.close(withError: nil)
            }
        }
    }

    private func close(withError error: (any Error)? = nil) {
        dispatchPrecondition(condition: .onQueue(Self.streamQueue))
        if let error {
            self.continuation?.resume(throwing: error)
        }
        self.task?.cancel()
        self.outputStream.close()
        debug("Output stream delegate closed stream")
    }

    private func writePendingBytes() {
        dispatchPrecondition(condition: .onQueue(Self.streamQueue))
        while outputStream.hasSpaceAvailable && !bytesToWrite.isEmpty {
            switch bytesToWrite.withUnsafeBytes({ outputStream.write($0.baseAddress!, maxLength: bytesToWrite.count) })
            {
            case 0:
                debug("Output stream delegate reached end of stream; will close stream")
                self.close()
            case -1:
                debug(
                    "Output stream delegate error writing to stream: \(String(describing: outputStream.streamError)); will close stream"
                )
                self.close(withError: outputStream.streamError)
            case let written where written > 0:
                debug("Output stream delegate wrote \(written) bytes to stream")
                bytesToWrite = bytesToWrite.dropFirst(written)
            default:
                preconditionFailure()
            }
        }
    }

    func stream(_ stream: Stream, handle event: Stream.Event) {
        dispatchPrecondition(condition: .onQueue(Self.streamQueue))
        debug("Output stream delegate received event: \(event)")
        switch event {
        case .openCompleted:
            guard self.task == nil else {
                debug("Output stream delegate ignroing duplicate openCompleted event.")
                return
            }
            startWriterTask()
        case .hasSpaceAvailable:
            if bytesToWrite.isEmpty, let continuation {
                debug("Output stream delegate needs more bytes")
                self.continuation = nil
                continuation.resume()
            } else {
                self.writePendingBytes()
            }
        case .errorOccurred:
            self.close(withError: stream.streamError)
        case .endEncountered:
            self.close()
        default:
            debug("Output stream ignoring event: \(event)")
            break
        }
    }
}
