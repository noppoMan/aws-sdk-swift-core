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

#if compiler(>=5.5)

import _Concurrency
@testable import SotoCore
import SotoTestUtils
import XCTest

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
final class WaiterAsyncTests: XCTestCase {
    var awsServer: AWSTestServer!
    var config: AWSServiceConfig!
    var client: AWSClient!

    override func setUp() {
        self.awsServer = AWSTestServer(serviceProtocol: .json)
        self.config = createServiceConfig(serviceProtocol: .json(version: "1.1"), endpoint: self.awsServer.address)
        self.client = createAWSClient(credentialProvider: .empty, middlewares: [AWSLoggingMiddleware()])
    }

    override func tearDown() {
        XCTAssertNoThrow(try self.client.syncShutdown())
        XCTAssertNoThrow(try self.awsServer.stop())
    }

    struct Input: AWSEncodableShape & Decodable {}

    struct ArrayOutput: AWSDecodableShape & Encodable {
        struct Element: AWSDecodableShape & Encodable, ExpressibleByBooleanLiteral {
            let status: Bool
            init(booleanLiteral: Bool) {
                self.status = booleanLiteral
            }

            init(_ status: Bool) {
                self.status = status
            }
        }

        let array: [Element]
    }

    func arrayOperation(input: Input, logger: Logger, eventLoop: EventLoop?) -> EventLoopFuture<ArrayOutput> {
        self.client.execute(operation: "Basic", path: "/", httpMethod: .POST, serviceConfig: self.config, input: input, logger: logger, on: eventLoop)
    }

    func testJMESPathWaiter() {
        let waiter = AWSClient.Waiter(
            acceptors: [
                .init(state: .success, matcher: try! JMESPathMatcher("array[*].status", expected: [true, true, true])),
            ],
            minDelayTime: .seconds(2),
            command: self.arrayOperation
        )
        let input = Input()
        XCTRunAsyncAndBlock {
            try await withThrowingTaskGroup(of: Bool.self) { group in
                group.async {
                    try await self.client.waitUntil(input, waiter: waiter, logger: TestEnvironment.logger)
                    return true
                }
                var i = 0
                try self.awsServer.process { (_: Input) -> AWSTestServer.Result<ArrayOutput> in
                    i += 1
                    return .result(ArrayOutput(array: [.init(i >= 3), .init(i >= 2), .init(i >= 1)]), continueProcessing: i < 3)
                }
                _ = try await group.next()
            }
        }
    }
}

#endif // compiler(>=5.5)
