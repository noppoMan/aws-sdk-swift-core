#!/usr/bin/env swift sh

import AsyncHTTPClient          // swift-server/async-http-client
import Foundation
import NIO                      // apple/swift-nio
import NIOFoundationCompat
import Stencil                  // swift-aws/Stencil

struct Endpoints: Decodable {
    struct CredentialScope: Decodable {
        var region: String?
        var service: String?
    }

    struct Defaults: Decodable {
        var credentialScope: CredentialScope?
        var hostname: String?
        var protocols: [String]?
        var signatureVersions: [String]?
    }

    struct RegionDesc: Decodable {
        var description: String
    }

    struct Partition: Decodable {
        var defaults: Defaults
        var dnsSuffix: String
        var partition: String
        var partitionName: String
        var regionRegex: String
        var regions: [String: RegionDesc]
    }

    var partitions: [Partition]
}

struct RegionDesc {
    let `enum`: String
    let name: String
    let description: String?
    let dnsSuffix: String
}

func loadEndpoints(url: String) throws -> Endpoints? {
    let httpClient = HTTPClient(eventLoopGroupProvider: .createNew)
    defer {
        try? httpClient.syncShutdown()
    }
    let response = try httpClient.get(url: url, deadline: .now() + .seconds(10)).wait()
    if let body = response.body {
        let endpoints = try JSONDecoder().decode(Endpoints.self, from: body)
        return endpoints
    }
    return nil
}

print("Loading Endpoints")
guard let endpoints = try loadEndpoints(url: "https://raw.githubusercontent.com/aws/aws-sdk-go/master/models/endpoints/endpoints.json") else { exit(-1) }

var regionDescs: [RegionDesc] = []
for partition in endpoints.partitions {
    let partitionRegionDescs = partition.regions.keys.map { region in
        return RegionDesc(
            enum: region.filter { return $0.isLetter || $0.isNumber },
            name: region,
            description: partition.regions[region]?.description,
            dnsSuffix: partition.dnsSuffix
        )
    }
    regionDescs += partitionRegionDescs
}

print("Loading templates")
let fsLoader = FileSystemLoader(paths: ["./scripts/templates/generate-region"])
let environment = Environment(loader: fsLoader)

print("Creating Region.swift")

let context: [String: Any] = [
    "regions": regionDescs.sorted { $0.name < $1.name }
]

let regionsFile = try environment.renderTemplate(name: "Region.stencil", context: context)
try Data(regionsFile.utf8).write(to: URL(fileURLWithPath: "Sources/AWSSDKSwiftCore/Doc/Region.swift"))
