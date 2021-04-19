//===----------------------------------------------------------------------===//
//
// This source file is part of the Soto for AWS open source project
//
// Copyright (c) 2017-2021 the Soto project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Soto project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if compiler(>=5.5) && $AsyncAwait

import _Concurrency
import AsyncHTTPClient
import NIO
@testable import SotoCore
import SotoTestUtils
import XCTest

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
extension PaginateTests {
    func counter(_ input: CounterInput, logger: Logger, on eventLoop: EventLoop?) async throws -> CounterOutput {
        return try await self.counter(input, logger: logger, on: eventLoop).get()
    }

    func asyncCounterPaginator(_ input: CounterInput) -> AWSClient.PaginatorSequence<CounterInput, CounterOutput> {
        return .init(
            input: input,
            command: self.counter,
            inputKey: \CounterInput.inputToken,
            outputKey: \CounterOutput.outputToken,
            logger: TestEnvironment.logger
        )
    }

    func testAsyncIntegerTokenPaginate() throws {
        XCTRunAsyncAndBlock {
            // paginate input
            let input = CounterInput(inputToken: nil, pageSize: 4)
            let arraySize = 23

            let finalArray = try await withThrowingTaskGroup(of: [Int].self) { group -> [Int] in
                group.spawn {
                    return try await self.asyncCounterPaginator(input).reduce([]) { return $0 + $1.array }
                }
                try self.awsServer.process { (input: CounterInput) throws -> AWSTestServer.Result<CounterOutput> in
                    // send part of array of numbers based on input startIndex and pageSize
                    let startIndex = input.inputToken ?? 0
                    let endIndex = min(startIndex + input.pageSize, arraySize)
                    var array: [Int] = []
                    for i in startIndex..<endIndex {
                        array.append(i)
                    }
                    let continueProcessing = (endIndex != arraySize)
                    let output = CounterOutput(array: array, outputToken: endIndex != arraySize ? endIndex : nil)
                    return .result(output, continueProcessing: continueProcessing)
                }
                return try await group.first { _ in true }!
            }

            // verify contents of array
            XCTAssertEqual(finalArray.count, arraySize)
            for i in 0..<finalArray.count {
                XCTAssertEqual(finalArray[i], i)
            }
        }
    }

    func testAsyncStringTokenReducePaginate() throws {
        XCTRunAsyncAndBlock {
            // paginate input
            let input = StringListInput(inputToken: nil, pageSize: 5)
            let finalArray = try await withThrowingTaskGroup(of: [String].self) { group -> [String] in
                group.spawn {
                    let paginator = self.asyncStringListPaginator(input)
                    return try await paginator.reduce([]) { $0 + $1.array }
                }
                try self.awsServer.process(self.stringListServerProcess)
                return try await group.first { _ in true }!
            }
            // verify contents of array
            XCTAssertEqual(finalArray.count, self.stringList.count)
            for i in 0..<finalArray.count {
                XCTAssertEqual(finalArray[i], self.stringList[i])
            }
        }
    }

    func testAsyncPaginateError() throws {
        XCTRunAsyncAndBlock {
            // paginate input
            let input = StringListInput(inputToken: nil, pageSize: 5)
            do {
                _ = try await withThrowingTaskGroup(of: [String].self) { group -> [String] in
                    group.spawn {
                        let paginator = self.asyncStringListPaginator(input)
                        return try await paginator.reduce([]) { $0 + $1.array }
                    }
                    try self.awsServer.process { (_: StringListInput) -> AWSTestServer.Result<StringListOutput> in
                        return .error(.badRequest)
                    }
                    return try await group.first { _ in true }!
                }
            } catch {
                XCTAssertEqual((error as? AWSResponseError)?.errorCode, "BadRequest")
            }
        }
    }

    func stringList(_ input: StringListInput, logger: Logger, on eventLoop: EventLoop? = nil) async throws -> StringListOutput {
        return try await self.client.execute(
            operation: "TestOperation",
            path: "/",
            httpMethod: .POST,
            serviceConfig: self.config,
            input: input,
            logger: logger,
            on: eventLoop
        )
    }

    func asyncStringListPaginator(_ input: StringListInput) -> AWSClient.PaginatorSequence<StringListInput, StringListOutput> {
        .init(
            input: input,
            command: self.stringList,
            inputKey: \StringListInput.inputToken,
            outputKey: \StringListOutput.outputToken,
            logger: TestEnvironment.logger
        )
    }
}

#endif // compiler(>=5.5) && $AsyncAwait
