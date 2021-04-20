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
final class PaginateAsyncTests: XCTestCase {
    enum Error: Swift.Error {
        case didntFindToken
    }

    var awsServer: AWSTestServer!
    var eventLoopGroup: EventLoopGroup!
    var httpClient: HTTPClient!
    var client: AWSClient!
    var config: AWSServiceConfig!

    override func setUp() {
        // create server and client
        self.awsServer = AWSTestServer(serviceProtocol: .json)
        self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 3)
        self.httpClient = AsyncHTTPClient.HTTPClient(eventLoopGroupProvider: .shared(self.eventLoopGroup))
        self.config = createServiceConfig(serviceProtocol: .json(version: "1.1"), endpoint: self.awsServer.address)
        self.client = createAWSClient(credentialProvider: .empty, retryPolicy: .noRetry, httpClientProvider: .shared(self.httpClient))
    }

    override func tearDown() {
        XCTAssertNoThrow(try self.awsServer.stop())
        XCTAssertNoThrow(try self.client.syncShutdown())
        XCTAssertNoThrow(try self.httpClient.syncShutdown())
        XCTAssertNoThrow(try self.eventLoopGroup.syncShutdownGracefully())
    }

    // test structures/functions
    struct CounterInput: AWSEncodableShape, AWSPaginateToken, Decodable {
        let inputToken: Int?
        let pageSize: Int

        init(inputToken: Int?, pageSize: Int) {
            self.inputToken = inputToken
            self.pageSize = pageSize
        }

        func usingPaginationToken(_ token: Int) -> CounterInput {
            return .init(inputToken: token, pageSize: self.pageSize)
        }
    }

    // conform to Encodable so server can encode these
    struct CounterOutput: AWSDecodableShape, Encodable {
        let array: [Int]
        let outputToken: Int?
    }

    func counter(_ input: CounterInput, logger: Logger, on eventLoop: EventLoop?) async throws -> CounterOutput {
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

    func asyncCounterPaginator(_ input: CounterInput) -> AWSClient.PaginatorSequence<CounterInput, CounterOutput> {
        return .init(
            input: input,
            command: self.counter,
            inputKey: \CounterInput.inputToken,
            outputKey: \CounterOutput.outputToken,
            logger: TestEnvironment.logger
        )
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

    // test structures/functions
    struct StringListInput: AWSEncodableShape, AWSPaginateToken, Decodable {
        let inputToken: String?
        let pageSize: Int

        init(inputToken: String?, pageSize: Int) {
            self.inputToken = inputToken
            self.pageSize = pageSize
        }

        func usingPaginationToken(_ token: String) -> StringListInput {
            return .init(inputToken: token, pageSize: self.pageSize)
        }
    }

    // conform to Encodable so server can encode these
    struct StringListOutput: AWSDecodableShape, Encodable {
        let array: [String]
        let outputToken: String?
    }

    // create list of unique strings
    let stringList = Set("Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum.".split(separator: " ").map { String($0) }).map { $0 }

    func stringListServerProcess(_ input: StringListInput) throws -> AWSTestServer.Result<StringListOutput> {
        // send part of array of numbers based on input startIndex and pageSize
        var startIndex = 0
        if let inputToken = input.inputToken {
            guard let stringIndex = stringList.firstIndex(of: inputToken) else { throw Error.didntFindToken }
            startIndex = stringIndex
        }
        let endIndex = min(startIndex + input.pageSize, self.stringList.count)
        var array: [String] = []
        for i in startIndex..<endIndex {
            array.append(self.stringList[i])
        }
        var outputToken: String?
        var continueProcessing = false
        if endIndex < self.stringList.count {
            outputToken = self.stringList[endIndex]
            continueProcessing = true
        } else {
            outputToken = input.inputToken
        }
        let output = StringListOutput(array: array, outputToken: outputToken)
        return .result(output, continueProcessing: continueProcessing)
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
                return try await group.next()!
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
                return try await group.next()!
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
                    return try await group.next()!
                }
            } catch {
                XCTAssertEqual((error as? AWSResponseError)?.errorCode, "BadRequest")
            }
        }
    }
}

#endif // compiler(>=5.5) && $AsyncAwait
