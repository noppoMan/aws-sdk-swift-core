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

#if os(Linux)
import Glibc
#else
import Darwin.C
#endif

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
        .package(url: "https://github.com/apple/swift-nio.git", .upToNextMajor(from: "2.16.1")),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", .upToNextMajor(from: "2.7.2")),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", .upToNextMajor(from: "1.0.0")),
        .package(url: "https://github.com/swift-server/async-http-client.git", .upToNextMajor(from: "1.3.0")),
    ],
    targets: [
        .target(name: "SotoCore", dependencies: [
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
        ]),
        .target(name: "SotoCrypto", dependencies: []),
        .target(name: "SotoSignerV4", dependencies: [
            .byName(name: "SotoCrypto"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
        ]),
        .target(name: "SotoTestUtils", dependencies: [
            .byName(name: "SotoCore"),
            .product(name: "NIO", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOFoundationCompat", package: "swift-nio"),
            .product(name: "NIOTestUtils", package: "swift-nio"),
        ]),
        .target(name: "SotoXML", dependencies: [
            .byName(name: "CSotoExpat"),
        ]),
        .target(name: "CSotoExpat", dependencies: [], exclude: ["AUTHORS", "COPYING"]),
        .target(name: "INIParser", dependencies: []),

        .testTarget(name: "SotoCryptoTests", dependencies: [
            .byName(name: "SotoCrypto"),
        ]),
        .testTarget(name: "SotoCoreTests", dependencies: [
            .byName(name: "SotoCore"),
            .byName(name: "SotoTestUtils"),
        ]),
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

enum Environment {
    static subscript(_ name: String) -> String? {
        guard let value = getenv(name) else {
            return nil
        }
        return String(cString: value)
    }
}

// Use Swift cypto on Linux. This is a hack which would be fixed by `condition: .when(platforms: [.linux])` on the "Crypto" dependency of SotoCrypto,
// but without https://bugs.swift.org/browse/SR-13761 being fixed this doesn't work. So this if statement is still required.
//
// When running cross compilation this fails as the Package.swift is being read with macOS and not Linux. I have added a test for the environment
// variable SOTO_CROSS_COMPILE. If you want to cross compile for a Linux OS set environment variable SOTO_CROSS_COMPILE to true. Remember to clear
// this variable if you go back to compiling for macOS.
if useSwiftCrypto || Environment["SOTO_CROSS_COMPILE"] == "true" {
    package.dependencies.append(.package(url: "https://github.com/apple/swift-crypto.git", from: "1.0.0"))
    package.targets.first { $0.name == "SotoCrypto" }?.dependencies.append(.product(name: "Crypto", package: "swift-crypto"))
}
