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

import struct Foundation.CharacterSet
import struct Foundation.Date
import struct Foundation.URL
import struct Foundation.URLComponents
import NIO
import NIOHTTP1
import SotoSignerV4

/// Object encapsulating all the information needed to generate a raw HTTP request to AWS
public struct AWSRequest {
    public let region: Region
    public var url: URL
    public let serviceProtocol: ServiceProtocol
    public let operation: String
    public let httpMethod: HTTPMethod
    public var httpHeaders: HTTPHeaders
    public var body: Body

    /// Create HTTP Client request from AWSRequest.
    /// If the signer's credentials are available the request will be signed. Otherwise defaults to an unsigned request
    func createHTTPRequest(signer: AWSSigner, byteBufferAllocator: ByteBufferAllocator) -> AWSHTTPRequest {
        // if credentials are empty don't sign request
        if signer.credentials.isEmpty() {
            return self.toHTTPRequest(byteBufferAllocator: byteBufferAllocator)
        }

        return self.toHTTPRequestWithSignedHeader(signer: signer, byteBufferAllocator: byteBufferAllocator)
    }

    /// Create HTTP Client request from AWSRequest
    func toHTTPRequest(byteBufferAllocator: ByteBufferAllocator) -> AWSHTTPRequest {
        return AWSHTTPRequest(url: url, method: httpMethod, headers: httpHeaders, body: body.asPayload(byteBufferAllocator: byteBufferAllocator))
    }

    /// Create HTTP Client request with signed headers from AWSRequest
    func toHTTPRequestWithSignedHeader(signer: AWSSigner, byteBufferAllocator: ByteBufferAllocator) -> AWSHTTPRequest {
        let payload = self.body.asPayload(byteBufferAllocator: byteBufferAllocator)
        let bodyDataForSigning: AWSSigner.BodyData?
        switch payload.payload {
        case .byteBuffer(let buffer):
            bodyDataForSigning = .byteBuffer(buffer)
        case .stream(let reader):
            if signer.name == "s3" {
                assert(reader.size != nil, "S3 stream requires size")
                var headers = httpHeaders
                // need to add this header here as it needs to be included in the signed headers
                headers.add(name: "x-amz-decoded-content-length", value: reader.size!.description)
                let (signedHeaders, seedSigningData) = signer.startSigningChunks(url: url, method: httpMethod, headers: headers, date: Date())
                let s3Reader = S3ChunkedStreamReader(
                    size: reader.size!,
                    seedSigningData: seedSigningData,
                    signer: signer,
                    byteBufferAllocator: reader.byteBufferAllocator,
                    read: reader.read
                )
                let payload = AWSPayload.streamReader(s3Reader)
                return AWSHTTPRequest(url: url, method: httpMethod, headers: signedHeaders, body: payload)
            } else {
                bodyDataForSigning = .unsignedPayload
            }
        case .empty:
            bodyDataForSigning = nil
        }
        let signedHeaders = signer.signHeaders(url: url, method: httpMethod, headers: httpHeaders, body: bodyDataForSigning, date: Date())
        return AWSHTTPRequest(url: url, method: httpMethod, headers: signedHeaders, body: payload)
    }

    // return new request with middleware applied
    func applyMiddlewares(_ middlewares: [AWSServiceMiddleware], config: AWSServiceConfig) throws -> AWSRequest {
        var awsRequest = self
        // apply middleware to request
        let context = AWSMiddlewareContext(options: config.options)
        for middleware in middlewares {
            awsRequest = try middleware.chain(request: awsRequest, context: context)
        }
        return awsRequest
    }
}

extension AWSRequest {
    internal init(operation operationName: String, path: String, httpMethod: HTTPMethod, configuration: AWSServiceConfig) throws {
        var headers = HTTPHeaders()

        guard let url = URL(string: "\(configuration.endpoint)\(path)"), let _ = url.host else {
            throw AWSClient.ClientError.invalidURL
        }

        // set x-amz-target header
        if let target = configuration.amzTarget {
            headers.replaceOrAdd(name: "x-amz-target", value: "\(target).\(operationName)")
        }

        self.region = configuration.region
        self.url = url
        self.serviceProtocol = configuration.serviceProtocol
        self.operation = operationName
        self.httpMethod = httpMethod
        self.httpHeaders = headers
        self.body = .empty

        addStandardHeaders()
    }

    internal init<Input: AWSEncodableShape>(
        operation operationName: String,
        path: String,
        httpMethod: HTTPMethod,
        input: Input,
        hostPrefix: String? = nil,
        configuration: AWSServiceConfig
    ) throws {
        var headers = HTTPHeaders()
        var path = path
        var hostPrefix = hostPrefix
        var body: Body = .empty
        var queryParams: [(key: String, value: Any)] = []

        // validate input parameters
        try input.validate()

        // set x-amz-target header
        if let target = configuration.amzTarget {
            headers.replaceOrAdd(name: "x-amz-target", value: "\(target).\(operationName)")
        }

        // TODO: should replace with Encodable
        let mirror = Mirror(reflecting: input)
        var memberVariablesCount = mirror.children.count - Input._encoding.count

        // extract header, query and uri params
        for encoding in Input._encoding {
            if let value = mirror.getAttribute(forKey: encoding.label) {
                switch encoding.location {
                case .header(let location):
                    switch value {
                    case let string as AWSRequestEncodableString:
                        string.encoded.map { headers.replaceOrAdd(name: location, value: $0) }
                    case let dictionary as AWSRequestEncodableDictionary:
                        dictionary.encoded.forEach { headers.replaceOrAdd(name: "\(location)\($0.key)", value: $0.value) }
                    default:
                        headers.replaceOrAdd(name: location, value: "\(value)")
                    }

                case .querystring(let location):
                    switch value {
                    case let string as AWSRequestEncodableString:
                        string.encoded.map { queryParams.append((key: location, value: $0)) }
                    case let array as AWSRequestEncodableArray:
                        array.encoded.forEach { queryParams.append((key: location, value: $0)) }
                    case let dictionary as AWSRequestEncodableDictionary:
                        dictionary.encoded.forEach { queryParams.append($0) }
                    default:
                        queryParams.append((key: location, value: "\(value)"))
                    }

                case .uri(let location):
                    path = path
                        .replacingOccurrences(of: "{\(location)}", with: Self.urlEncodePathComponent(String(describing: value)))
                        .replacingOccurrences(of: "{\(location)+}", with: Self.urlEncodePath(String(describing: value)))
                    hostPrefix = hostPrefix?
                        .replacingOccurrences(of: "{\(location)}", with: Self.urlEncodePathComponent(String(describing: value)))
                default:
                    memberVariablesCount += 1
                }
            }
        }

        switch configuration.serviceProtocol {
        case .json, .restjson:
            if let shapeWithPayload = Input.self as? AWSShapeWithPayload.Type {
                let payload = shapeWithPayload._payloadPath
                if let payloadBody = mirror.getAttribute(forKey: payload) {
                    switch payloadBody {
                    case let awsPayload as AWSPayload:
                        Self.verifyStream(operation: operationName, payload: awsPayload, input: shapeWithPayload)
                        body = .raw(awsPayload)
                    case let shape as AWSEncodableShape:
                        body = .json(try shape.encodeAsJSON(byteBufferAllocator: configuration.byteBufferAllocator))
                    default:
                        preconditionFailure("Cannot add this as a payload")
                    }
                } else {
                    body = .empty
                }
            } else {
                // only include the body if there are members that are output in the body.
                if memberVariablesCount > 0 {
                    body = .json(try input.encodeAsJSON(byteBufferAllocator: configuration.byteBufferAllocator))
                } else if httpMethod == .PUT || httpMethod == .POST {
                    // PUT and POST requests require a body even if it is empty. This is not the case with XML
                    body = .json(configuration.byteBufferAllocator.buffer(string: "{}"))
                }
            }

        case .restxml:
            if let shapeWithPayload = Input.self as? AWSShapeWithPayload.Type {
                let payload = shapeWithPayload._payloadPath
                if let payloadBody = mirror.getAttribute(forKey: payload) {
                    switch payloadBody {
                    case let awsPayload as AWSPayload:
                        Self.verifyStream(operation: operationName, payload: awsPayload, input: shapeWithPayload)
                        body = .raw(awsPayload)
                    case let shape as AWSEncodableShape:
                        var rootName: String?
                        // extract custom payload name
                        if let encoding = Input.getEncoding(for: payload), case .body(let locationName) = encoding.location {
                            rootName = locationName
                        }
                        body = .xml(try shape.encodeAsXML(rootName: rootName))
                    default:
                        preconditionFailure("Cannot add this as a payload")
                    }
                } else {
                    body = .empty
                }
            } else {
                // only include the body if there are members that are output in the body.
                if memberVariablesCount > 0 {
                    body = .xml(try input.encodeAsXML())
                }
            }

        case .query:
            if let query = try input.encodeAsQuery(with: ["Action": operationName, "Version": configuration.apiVersion]) {
                body = .text(query)
            }

        case .ec2:
            if let query = try input.encodeAsQueryForEC2(with: ["Action": operationName, "Version": configuration.apiVersion]) {
                body = .text(query)
            }
        }

        guard var urlComponents = URLComponents(string: "\(configuration.endpoint)\(path)") else {
            throw AWSClient.ClientError.invalidURL
        }

        if let hostPrefix = hostPrefix, let host = urlComponents.host {
            urlComponents.host = hostPrefix + host
        }

        // add queries from the parsed path to the query params list
        if let pathQueryItems = urlComponents.queryItems {
            for item in pathQueryItems {
                queryParams.append((key: item.name, value: item.value ?? ""))
            }
        }

        // Set query params. Percent encode these ourselves as Foundation and AWS disagree on what should be percent encoded in the query values
        // Also the signer doesn't percent encode the queries so they need to be encoded here
        if queryParams.count > 0 {
            let urlQueryString = queryParams
                .map { (key: $0.key, value: "\($0.value)") }
                .sorted {
                    // sort by key. if key are equal then sort by value
                    if $0.key < $1.key { return true }
                    if $0.key > $1.key { return false }
                    return $0.value < $1.value
                }
                .map { "\($0.key)=\(Self.urlEncodeQueryParam($0.value))" }
                .joined(separator: "&")
            urlComponents.percentEncodedQuery = urlQueryString
        }

        guard let url = urlComponents.url else {
            throw AWSClient.ClientError.invalidURL
        }

        self.region = configuration.region
        self.url = url
        self.serviceProtocol = configuration.serviceProtocol
        self.operation = operationName
        self.httpMethod = httpMethod
        self.httpHeaders = headers
        self.body = body

        addStandardHeaders()
    }

    /// Add headers standard to all requests "content-type" and "user-agent"
    private mutating func addStandardHeaders() {
        httpHeaders.replaceOrAdd(name: "user-agent", value: "Soto/5.0")
        guard httpHeaders["content-type"].first == nil else {
            return
        }
        guard httpMethod != .GET, httpMethod != .HEAD else {
            return
        }

        if case .restjson = serviceProtocol, case .raw = body {
            httpHeaders.replaceOrAdd(name: "content-type", value: "binary/octet-stream")
        } else {
            httpHeaders.replaceOrAdd(name: "content-type", value: serviceProtocol.contentType)
        }
    }

    /// this list of query allowed characters comes from https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-header-based-auth.html
    static let queryAllowedCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    static let pathAllowedCharacters = CharacterSet.urlPathAllowed.subtracting(.init(charactersIn: "+"))
    static let pathComponentAllowedCharacters = CharacterSet.urlPathAllowed.subtracting(.init(charactersIn: "+/"))

    /// percent encode query parameter value.
    private static func urlEncodeQueryParam(_ value: String) -> String {
        return value.addingPercentEncoding(withAllowedCharacters: AWSRequest.queryAllowedCharacters) ?? value
    }

    /// percent encode path value.
    private static func urlEncodePath(_ value: String) -> String {
        return value.addingPercentEncoding(withAllowedCharacters: AWSRequest.pathAllowedCharacters) ?? value
    }

    /// percent encode path component value. ie also encode "/"
    private static func urlEncodePathComponent(_ value: String) -> String {
        return value.addingPercentEncoding(withAllowedCharacters: AWSRequest.pathComponentAllowedCharacters) ?? value
    }

    /// verify  streaming is allowed for this operation
    internal static func verifyStream(operation: String, payload: AWSPayload, input: AWSShapeWithPayload.Type) {
        guard case .stream(let reader) = payload.payload else { return }
        precondition(input._payloadOptions.contains(.allowStreaming), "\(operation) does not allow streaming of data")
        precondition(reader.size != nil || input._payloadOptions.contains(.allowChunkedStreaming), "\(operation) does not allow chunked streaming of data. Please supply a data size.")
    }
}

private protocol AWSRequestEncodableArray {
    var encoded: [String] { get }
}

extension Array: AWSRequestEncodableArray {
    var encoded: [String] { return self.map { "\($0)" }}
}

private protocol AWSRequestEncodableDictionary {
    var encoded: [(key: String, value: String)] { get }
}

extension Dictionary: AWSRequestEncodableDictionary {
    var encoded: [(key: String, value: String)] {
        return self.map { (key: "\($0.key)", value: "\($0.value)") }
    }
}

private protocol AWSRequestEncodableString {
    var encoded: String? { get }
}

extension CustomCoding: AWSRequestEncodableString where Coder: CustomEncoder {
    var encoded: String? {
        return Coder.string(from: self.wrappedValue)
    }
}

extension OptionalCustomCoding: AWSRequestEncodableString where Coder: CustomEncoder {
    var encoded: String? {
        guard let value = self.wrappedValue else { return nil }
        return Coder.string(from: value)
    }
}
