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
/// Revends an array as an async sequence, one element at a time, with an optional manual trigger.
struct MockAsyncSequence<Element>: AsyncSequence, Sendable where Element: Sendable {
    var elementsToVend: [Element]
    private(set) var elementsVended: ElementRecorder
    private var semaphore: DispatchSemaphore?

    init(elementsToVend: [Element], gatingProduction: Bool) {
        self.elementsToVend = elementsToVend
        self.elementsVended = ElementRecorder()
        self.semaphore = gatingProduction ? DispatchSemaphore(value: 0) : nil
    }

    func openGate(for count: Int) {
        for _ in 0..<count {
            semaphore?.signal()
        }
    }

    func openGate() {
        openGate(for: elementsToVend.count + 1)  // + 1 for the nil
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(
            elementsToVend: elementsToVend[...],
            semaphore: semaphore,
            elementsVended: elementsVended
        )
    }

    final class AsyncIterator: AsyncIteratorProtocol {
        var elementsToVend: ArraySlice<Element>
        var semaphore: DispatchSemaphore?
        var elementsVended: ElementRecorder

        init(
            elementsToVend: ArraySlice<Element>,
            semaphore: DispatchSemaphore?,
            elementsVended: ElementRecorder
        ) {
            self.elementsToVend = elementsToVend
            self.semaphore = semaphore
            self.elementsVended = elementsVended
        }

        func next() async throws -> Element? {
            await withCheckedContinuation { continuation in
                semaphore?.wait()
                continuation.resume()
            }
            guard let element = elementsToVend.popFirst() else {
                return nil
            }
            elementsVended.recordedElements.append(element)
            return element
        }
    }

    final class ElementRecorder: @unchecked /* uses lock */ Sendable {
        private let _lock = NSLock()
        private var _recorededElements: [Element] = []
        var recordedElements: [Element] {
            get { _lock.withLock { _recorededElements } }
            set { _lock.withLock { _recorededElements = newValue } }
        }
    }
}
