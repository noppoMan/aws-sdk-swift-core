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

import AsyncHTTPClient
import Dispatch
import Logging
import NIO
import NIOConcurrencyHelpers
import NIOFoundationCompat
import NIOHTTP1
@testable import SotoCore
import SotoTestUtils
import SotoXML
import XCTest

class AWSClientAsyncTests: XCTestCase {
    func runDetached(_ process: @escaping () async throws -> ()) -> DispatchGroup {
        let dg = DispatchGroup()
        dg.enter()
        _ = Task.runDetached {
            do {
                try await process()
            } catch {
                XCTFail("\(error)")
            }
            dg.leave()
        }
        return dg
    }

    func testClientNoInputNoOutput() {
        let awsServer = AWSTestServer(serviceProtocol: .json)
        defer { XCTAssertNoThrow(try awsServer.stop()) }
        let dg = runDetached {
            let config = createServiceConfig(serviceProtocol: .json(version: "1.1"), endpoint: awsServer.address)
            let client = createAWSClient(credentialProvider: .empty, middlewares: [AWSLoggingMiddleware()])
            defer { XCTAssertNoThrow(try client.syncShutdown()) }
            try await client.execute(operation: "test", path: "/", httpMethod: .POST, serviceConfig: config, logger: TestEnvironment.logger)
        }
        XCTAssertNoThrow(try awsServer.processRaw { _ in
            let response = AWSTestServer.Response(httpStatus: .ok, headers: [:], body: nil)
            return .result(response)
        })
        dg.wait()
    }

    func testClientWithInputNoOutput() {
        enum InputEnum: String, Codable {
            case first
            case second
        }
        struct Input: AWSEncodableShape & Decodable {
            let e: InputEnum
            let i: [Int64]
        }

        let awsServer = AWSTestServer(serviceProtocol: .json)
        defer { XCTAssertNoThrow(try awsServer.stop()) }
        let dg = runDetached {
            let config = createServiceConfig(serviceProtocol: .json(version: "1.1"), endpoint: awsServer.address)
            let client = createAWSClient(credentialProvider: .empty, middlewares: [AWSLoggingMiddleware()])
            defer { XCTAssertNoThrow(try client.syncShutdown()) }
            let input = Input(e: .second, i: [1, 2, 4, 8])
            try await client.execute(operation: "test", path: "/", httpMethod: .POST, serviceConfig: config, input: input, logger: TestEnvironment.logger)
        }
        XCTAssertNoThrow(try awsServer.processRaw { request in
            let receivedInput = try JSONDecoder().decode(Input.self, from: request.body)
            XCTAssertEqual(receivedInput.e, .second)
            XCTAssertEqual(receivedInput.i, [1, 2, 4, 8])
            let response = AWSTestServer.Response(httpStatus: .ok, headers: [:], body: nil)
            return .result(response)
        })

        dg.wait()
    }

    func testClientNoInputWithOutput() {
        struct Output: AWSDecodableShape & Encodable {
            let s: String
            let i: Int64
        }
        let awsServer = AWSTestServer(serviceProtocol: .json)
        defer { XCTAssertNoThrow(try awsServer.stop()) }
        let dg = runDetached {
            let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            defer { XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully()) }
            let config = createServiceConfig(serviceProtocol: .json(version: "1.1"), endpoint: awsServer.address)
            let client = createAWSClient(
                credentialProvider: .empty,
                httpClientProvider: .createNewWithEventLoopGroup(eventLoopGroup)
            )
            defer { XCTAssertNoThrow(try client.syncShutdown()) }
            let output: Output = try await client.execute(operation: "test", path: "/", httpMethod: .POST, serviceConfig: config, logger: TestEnvironment.logger)

            XCTAssertEqual(output.s, "TestOutputString")
            XCTAssertEqual(output.i, 547)
        }

        XCTAssertNoThrow(try awsServer.processRaw { _ in
            let output = Output(s: "TestOutputString", i: 547)
            let byteBuffer = try JSONEncoder().encodeAsByteBuffer(output, allocator: ByteBufferAllocator())
            let response = AWSTestServer.Response(httpStatus: .ok, headers: [:], body: byteBuffer)
            return .result(response)
        })

        dg.wait()
    }
}
