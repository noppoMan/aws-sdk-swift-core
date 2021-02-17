//===----------------------------------------------------------------------===//
//
// This source file is part of the Soto for AWS open source project
//
// Copyright (c) 2017-2020 the Soto project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Soto project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Logging
import NIO

extension AWSClient {
    /// Used to access paginated results.
    public struct PaginatorSequence<Input: AWSPaginateToken, Output: AWSShape>: AsyncSequence where Input.Token: Equatable {
        public typealias Element = Output
        let input: Input
        let command: ((Input, Logger, EventLoop?) async throws -> Output)
        let inputKey: KeyPath<Input, Input.Token?>
        let outputKey: KeyPath<Output, Input.Token?>
        let logger: Logger
        let eventLoop: EventLoop?

        /// Initialize PaginatorSequence
        /// - Parameters:
        ///   - input: Initial Input value
        ///   - command: Command to be paginated
        ///   - tokenKey: KeyPath for Output token used to setup new Input
        ///   - logger: Logger
        ///   - eventLoop: EventLoop to run everything on
        public init(
            input: Input,
            command: @escaping ((Input, Logger, EventLoop?) async throws -> Output),
            inputKey: KeyPath<Input, Input.Token?>,
            outputKey: KeyPath<Output, Input.Token?>,
            logger: Logger = AWSClient.loggingDisabled,
            on eventLoop: EventLoop? = nil
        ) {
            self.input = input
            self.command = command
            self.outputKey = outputKey
            self.inputKey = inputKey
            self.logger = AWSClient.loggingDisabled
            self.eventLoop = eventLoop
        }

        /// Iterator for iterating over `PaginatorSequence`
        public struct AsyncIterator: AsyncIteratorProtocol {
            var input: Input?
            let sequence: PaginatorSequence

            init(sequence: PaginatorSequence) {
                self.sequence = sequence
                self.input = sequence.input
            }
            public mutating func next() async throws -> Output? {
                if let input = input {
                    let output = try await sequence.command(input, sequence.logger, sequence.eventLoop)
                    if let token = output[keyPath: sequence.outputKey],
                       token != input[keyPath: sequence.inputKey] {
                        self.input = input.usingPaginationToken(token)
                    } else {
                        self.input = nil
                    }
                    return output
                }
                return nil
            }
        }

        /// Make async iterator
        public func makeAsyncIterator() -> AsyncIterator {
            return AsyncIterator(sequence: self)
        }

        /// while AsyncSequence doesn't provide a `reduce` function, here is my implementation
        public func reduce<Result>(_ initialResult: Result, _ nextPartialResult: (Result, Element) throws -> Result) async throws -> Result {
            var result = initialResult
            for try await element in self {
                result = try nextPartialResult(result, element)
            }
            return result
        }
    }

}
