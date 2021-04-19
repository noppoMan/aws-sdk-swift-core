// swift-tools-version:5.2
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

import PackageDescription

let package = Package(
    name: "soto-core",
    products: [
        .library(name: "SotoCore", targets: ["SotoCore"]),
        .library(name: "SotoTestUtils", targets: ["SotoTestUtils"]),
        .library(name: "SotoSignerV4", targets: ["SotoSignerV4"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.4.0"),
        .package(url: "https://github.com/apple/swift-metrics.git", "1.0.0"..<"3.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.16.1"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.7.2"),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.0.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.3.0"),
        .package(url: "https://github.com/adam-fowler/jmespath.swift.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "SotoCore",
            dependencies: [
                .byName(name: "SotoSignerV4"),
                .byName(name: "SotoXML"),
                .byName(name: "INIParser"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "Metrics", package: "swift-metrics"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "JMESPath", package: "jmespath.swift"),
            ]
        ),
        .target(name: "SotoCrypto", dependencies: []),
        .target(name: "SotoSignerV4", dependencies: [
            .byName(name: "SotoCrypto"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
        ]),
        .target(
            name: "SotoTestUtils",
            dependencies: [
                .byName(name: "SotoCore"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOTestUtils", package: "swift-nio"),
            ]
        ),
        .target(name: "SotoXML", dependencies: [
            .byName(name: "CSotoExpat"),
        ]),
        .target(name: "CSotoExpat", dependencies: []),
        .target(name: "INIParser", dependencies: []),

        .testTarget(name: "SotoCryptoTests", dependencies: [
            .byName(name: "SotoCrypto"),
        ]),
        .testTarget(
            name: "SotoCoreTests",
            dependencies: [
                .byName(name: "SotoCore"),
                .byName(name: "SotoTestUtils"),
            ]
        ),
        .testTarget(name: "SotoSignerV4Tests", dependencies: [
            .byName(name: "SotoSignerV4"),
        ]),
        .testTarget(name: "SotoXMLTests", dependencies: [
            .byName(name: "SotoXML"),
            .byName(name: "SotoCore"),
        ]),
        .testTarget(name: "INIParserTests", dependencies: [
            .byName(name: "INIParser"),
        ]),
    ]
)

// switch for whether to use swift crypto. Swift crypto requires macOS10.15 or iOS13.I'd rather not pass this requirement on
#if os(Linux)
let useSwiftCrypto = true
#else
let useSwiftCrypto = false
#endif

// Use Swift cypto on Linux.
if useSwiftCrypto {
    package.dependencies.append(.package(url: "https://github.com/apple/swift-crypto.git", from: "1.0.0"))
    package.targets.first { $0.name == "SotoCrypto" }?.dependencies.append(.product(name: "Crypto", package: "swift-crypto"))
}
