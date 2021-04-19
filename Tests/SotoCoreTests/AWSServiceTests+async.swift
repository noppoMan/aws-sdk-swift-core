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

#if compiler(>=5.5) && $AsyncAwait

import _Concurrency
@testable import SotoCore
import SotoTestUtils
import XCTest

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
final class AWSServiceAsyncTests: XCTestCase {
    struct TestService: AWSService {
        var client: AWSClient
        var config: AWSServiceConfig

        /// init
        init(client: AWSClient, config: AWSServiceConfig) {
            self.client = client
            self.config = config
        }

        /// patch init
        init(from: Self, patch: AWSServiceConfig.Patch) {
            self.client = from.client
            self.config = from.config.with(patch: patch)
        }
    }

    func testSignURL() throws {
        XCTRunAsyncAndBlock {
            let client = createAWSClient(credentialProvider: .static(accessKeyId: "foo", secretAccessKey: "bar"))
            defer { XCTAssertNoThrow(try client.syncShutdown()) }
            let serviceConfig = createServiceConfig()
            let service = TestService(client: client, config: serviceConfig)
            let url = URL(string: "https://test.amazonaws.com?test2=true&space=sp%20ace&percent=addi+tion")!
            let signedURL = try await service.signURL(url: url, httpMethod: .GET, expires: .minutes(15))
            // remove signed query params
            let query = try XCTUnwrap(signedURL.query)
            let queryItems = query
                .split(separator: "&")
                .compactMap {
                    guard !$0.hasPrefix("X-Amz") else { return nil }
                    return String($0)
                }
                .joined(separator: "&")
            XCTAssertEqual(queryItems, "percent=addi%2Btion&space=sp%20ace&test2=true")
        }
    }

    func testSignHeaders() throws {
        XCTRunAsyncAndBlock {
            let client = createAWSClient(credentialProvider: .static(accessKeyId: "foo", secretAccessKey: "bar"))
            defer { XCTAssertNoThrow(try client.syncShutdown()) }
            let serviceConfig = createServiceConfig()
            let service = TestService(client: client, config: serviceConfig)
            let url = URL(string: "https://test.amazonaws.com?test2=true&space=sp%20ace&percent=addi+tion")!
            let headers = try await service.signHeaders(
                url: url,
                httpMethod: .GET,
                headers: ["Content-Type": "application/json"],
                body: .string("Test payload")
            )
            // remove signed query params
            XCTAssertNotNil(headers["Authorization"].first)
        }
    }
}

#endif // compiler(>=5.5) && $AsyncAwait
