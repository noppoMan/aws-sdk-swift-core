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

import AsyncHTTPClient
import NIO
import SotoCore
import SotoTestUtils
import XCTest

class WaiterTests: XCTestCase {
    static var awsServer: AWSTestServer!
    static var config: AWSServiceConfig!
    static var client: AWSClient!

    override class func setUp() {
        Self.awsServer = AWSTestServer(serviceProtocol: .json)
        Self.config = createServiceConfig(serviceProtocol: .json(version: "1.1"), endpoint: self.awsServer.address)
        Self.client = createAWSClient(credentialProvider: .empty, middlewares: [AWSLoggingMiddleware()])
    }

    override class func tearDown() {
        XCTAssertNoThrow(try self.client.syncShutdown())
        XCTAssertNoThrow(try self.awsServer.stop())
    }

    struct Input: AWSEncodableShape & Decodable {}

    struct Output: AWSDecodableShape & Encodable {
        let i: Int
    }

    func operation(input: Input, logger: Logger, eventLoop: EventLoop?) -> EventLoopFuture<Output> {
        Self.client.execute(operation: "Basic", path: "/", httpMethod: .POST, serviceConfig: Self.config, input: input, logger: logger, on: eventLoop)
    }

    struct ArrayOutput: AWSDecodableShape & Encodable {
        struct Element: AWSDecodableShape & Encodable, ExpressibleByBooleanLiteral {
            let status: Bool
            init(booleanLiteral: Bool) {
                self.status = booleanLiteral
            }
        }

        let array: [Element]
    }

    func arrayOperation(input: Input, logger: Logger, eventLoop: EventLoop?) -> EventLoopFuture<ArrayOutput> {
        Self.client.execute(operation: "Basic", path: "/", httpMethod: .POST, serviceConfig: Self.config, input: input, logger: logger, on: eventLoop)
    }

    func testPathWaiter() {
        let waiter = AWSClient.Waiter(
            acceptors: [
                .init(state: .success, matcher: AWSPathMatcher(path: \Output.i, expected: 3)),
            ],
            minDelayTime: .seconds(2),
            maxDelayTime: .seconds(4),
            command: self.operation
        )
        let input = Input()
        let response = Self.client.wait(input, waiter: waiter, logger: TestEnvironment.logger)

        var i = 0
        XCTAssertNoThrow(try Self.awsServer.process { (_: Input) -> AWSTestServer.Result<Output> in
            i += 1
            return .result(Output(i: i), continueProcessing: i < 3)
        })

        XCTAssertNoThrow(try response.wait())
    }

    func testAnyPathWaiter() {
        let waiter = AWSClient.Waiter(
            acceptors: [
                .init(state: .success, matcher: AWSAnyPathMatcher(arrayPath: \ArrayOutput.array, elementPath: \ArrayOutput.Element.status, expected: true)),
            ],
            minDelayTime: .seconds(2),
            maxDelayTime: .seconds(4),
            command: self.arrayOperation
        )
        let input = Input()
        let response = Self.client.wait(input, waiter: waiter, logger: TestEnvironment.logger)

        var i = 0
        XCTAssertNoThrow(try Self.awsServer.process { (_: Input) -> AWSTestServer.Result<ArrayOutput> in
            i += 1
            if i < 2 {
                return .result(ArrayOutput(array: [false, false, false]), continueProcessing: true)
            } else {
                return .result(ArrayOutput(array: [false, true, false]), continueProcessing: false)
            }
        })

        XCTAssertNoThrow(try response.wait())
    }

    func testAllPathWaiter() {
        let waiter = AWSClient.Waiter(
            acceptors: [
                .init(state: .success, matcher: AWSAllPathMatcher(arrayPath: \ArrayOutput.array, elementPath: \ArrayOutput.Element.status, expected: true)),
            ],
            minDelayTime: .seconds(2),
            maxDelayTime: .seconds(4),
            command: self.arrayOperation
        )
        let input = Input()
        let response = Self.client.wait(input, waiter: waiter, logger: TestEnvironment.logger)

        var i = 0
        XCTAssertNoThrow(try Self.awsServer.process { (_: Input) -> AWSTestServer.Result<ArrayOutput> in
            i += 1
            if i < 2 {
                return .result(ArrayOutput(array: [false, true, false]), continueProcessing: true)
            } else {
                return .result(ArrayOutput(array: [true, true, true]), continueProcessing: false)
            }
        })

        XCTAssertNoThrow(try response.wait())
    }

    func testTimeoutWaiter() {
        let waiter = AWSClient.Waiter(
            acceptors: [
                .init(state: .success, matcher: AWSPathMatcher(path: \Output.i, expected: 3)),
            ],
            minDelayTime: .seconds(2),
            maxDelayTime: .seconds(4),
            command: self.operation
        )
        let input = Input()
        let response = Self.client.wait(input, waiter: waiter, maxWaitTime: .seconds(4), logger: TestEnvironment.logger)

        var i = 0
        XCTAssertNoThrow(try Self.awsServer.process { (_: Input) -> AWSTestServer.Result<Output> in
            i += 1
            return .result(Output(i: i), continueProcessing: i < 2)
        })

        XCTAssertThrowsError(try response.wait()) { error in
            switch error {
            case let error as AWSClient.ClientError where error == .waiterTimeout:
                break
            default:
                XCTFail("\(error)")
            }
        }
    }

    func testErrorWaiter() {
        let waiter = AWSClient.Waiter(
            acceptors: [
                .init(state: .retry, matcher: AWSErrorCodeMatcher("AccessDenied")),
                .init(state: .success, matcher: AWSPathMatcher(path: \Output.i, expected: 3)),
            ],
            minDelayTime: .seconds(2),
            maxDelayTime: .seconds(4),
            command: self.operation
        )
        let input = Input()
        let response = Self.client.wait(input, waiter: waiter, logger: TestEnvironment.logger)

        var i = 0
        XCTAssertNoThrow(try Self.awsServer.process { (_: Input) -> AWSTestServer.Result<Output> in
            i += 1
            if i < 3 {
                return .error(.accessDenied, continueProcessing: true)
            } else {
                return .result(Output(i: i), continueProcessing: false)
            }
        })

        XCTAssertNoThrow(try response.wait())
    }

    func testErrorStatusWaiter() {
        let waiter = AWSClient.Waiter(
            acceptors: [
                .init(state: .retry, matcher: AWSErrorStatusMatcher(404)),
                .init(state: .success, matcher: AWSPathMatcher(path: \Output.i, expected: 3)),
            ],
            minDelayTime: .seconds(2),
            maxDelayTime: .seconds(4),
            command: self.operation
        )
        let input = Input()
        let response = Self.client.wait(input, waiter: waiter, logger: TestEnvironment.logger)

        var i = 0
        XCTAssertNoThrow(try Self.awsServer.process { (_: Input) -> AWSTestServer.Result<Output> in
            i += 1
            if i < 3 {
                return .error(.notFound, continueProcessing: true)
            } else {
                return .result(Output(i: i), continueProcessing: false)
            }
        })

        XCTAssertNoThrow(try response.wait())
    }
}