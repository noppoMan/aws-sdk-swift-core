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

import Benchmark
import Dispatch
import Foundation
import NIO
import SotoCore

struct RequestThrowMiddleware: AWSServiceMiddleware {
    struct Error: Swift.Error {}

    func chain(request: AWSRequest, context: AWSMiddlewareContext) throws -> AWSRequest {
        _ = request.body.asByteBuffer(byteBufferAllocator: ByteBufferAllocator())
        throw Error()
    }
}

struct HeaderShape: AWSEncodableShape {
    static let _encoding: [AWSMemberEncoding] = [
        .init(label: "a", location: .header(locationName: "A")),
        .init(label: "b", location: .header(locationName: "B")),
    ]
    let a: String
    let b: Int
}

struct QueryShape: AWSEncodableShape {
    static let _encoding: [AWSMemberEncoding] = [
        .init(label: "a", location: .querystring(locationName: "A")),
        .init(label: "b", location: .querystring(locationName: "B")),
    ]
    let a: String
    let b: Int
}

struct Shape1: AWSEncodableShape {
    let a: String
    let b: Int
}

struct Shape: AWSEncodableShape {
    let a: String
    let b: Int
    let c: [String]
    let d: [String: Int]
}

let awsClientSuite = BenchmarkSuite(name: "AWSClient", settings: Iterations(1000), WarmupIterations(2)) { suite in
    // time request construction by throwing an error in request middleware. This means waiting on client.execute should
    // take the amount of time it took to construct the request
    let threadPool = NIOThreadPool(numberOfThreads: System.coreCount)
    let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    threadPool.start()
    let client = AWSClient(
        credentialProvider: .static(accessKeyId: "MYACCESSKEY", secretAccessKey: "MYSECRETACCESSKEY"),
        //middlewares: [RequestThrowMiddleware()],
        options: .init(threadPool: threadPool),
        httpClientProvider: .createNewWithEventLoopGroup(eventLoopGroup)
    )
    let jsonService = AWSServiceConfig(
        region: .useast1, partition: .aws, service: "test-service", serviceProtocol: .json(version: "1.1"), apiVersion: "10-10-2010"
    )
    let xmlService = AWSServiceConfig(
        region: .useast1, partition: .aws, service: "test-service", serviceProtocol: .restxml, apiVersion: "10-10-2010"
    )
    let queryService = AWSServiceConfig(
        region: .useast1, partition: .aws, service: "test-service", serviceProtocol: .query, apiVersion: "10-10-2010"
    )

    suite.benchmark("empty-request") {
        try? client.execute(operation: "TestOperation", path: "/", httpMethod: .GET, serviceConfig: jsonService).wait()
    }

    let headerInput = HeaderShape(a: "TestString", b: 345_348)
    suite.benchmark("header-request") {
        try? client.execute(operation: "TestOperation", path: "/", httpMethod: .GET, serviceConfig: jsonService, input: headerInput).wait()
    }

    let queryInput = QueryShape(a: "TestString", b: 345_348)
    suite.benchmark("querystring-request") {
        try? client.execute(operation: "TestOperation", path: "/", httpMethod: .GET, serviceConfig: jsonService, input: queryInput).wait()
    }

    // test json, xml and query generation timing
    let input = Shape(
        a: """
        TestString
        """,
        b: 345_348,
        c: ["one", "two", "three"],
        d: ["one": 1, "two": 2, "three": 3]
    )
    suite.benchmark("json-request") {
        try? client.execute(operation: "TestOperation", path: "/", httpMethod: .GET, serviceConfig: jsonService, input: input).wait()
    }
    suite.benchmark("xml-request") {
        try? client.execute(operation: "TestOperation", path: "/", httpMethod: .GET, serviceConfig: xmlService, input: input).wait()
    }
    suite.benchmark("query-request") {
        try? client.execute(operation: "TestOperation", path: "/", httpMethod: .GET, serviceConfig: queryService, input: input).wait()
    }
    suite.benchmark("multiple-request") {
        let futures: [EventLoopFuture<Void>] = (0..<16).map { _ in
            client.execute(operation: "TestOperation", path: "/", httpMethod: .GET, serviceConfig: queryService, input: input)
        }
        try? EventLoopFuture.andAllComplete(futures, on: client.eventLoopGroup.next()).wait()
    }
}
