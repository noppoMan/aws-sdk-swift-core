//===----------------------------------------------------------------------===//
//
// This source file is part of the AWSSDKSwift open source project
//
// Copyright (c) 2017-2020 the AWSSDKSwift project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AWSSDKSwift project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO
import NIOFoundationCompat
import NIOHTTP1
import NIOTestUtils
import XCTest
import AWSXML
@testable import AWSSDKSwiftCore

/// Test server for AWSClient. Input and Output shapes are defined by process function
public class AWSTestServer {

    public enum Error: Swift.Error {
        case notHead
        case notBody
        case notEnd
        case emptyBody
        case noXMLBody
        case corruptChunkedData
    }
    // what are we returning
    public enum ServiceProtocol {
        case restjson
        case json
        case xml
    }
    // http incoming request
    public struct Request {
        public let method: HTTPMethod
        public let uri: String
        public let headers: [String: String]
        public let body: ByteBuffer
        
        public init(method: HTTPMethod, uri: String, headers: [String : String], body: ByteBuffer) {
            self.method = method
            self.uri = uri
            self.headers = headers
            self.body = body
        }
    }
    
    // http outgoing response
    public struct Response {
        public let httpStatus: HTTPResponseStatus
        public let headers: [String: String]
        public let body: ByteBuffer?

        public init(httpStatus: HTTPResponseStatus, headers: [String: String] = [:], body: ByteBuffer? = nil) {
            self.httpStatus = httpStatus
            self.headers = headers
            self.body = body
        }

        public static let ok = Response(httpStatus: .ok)
    }

    /// Error type
    public struct ErrorType {
        public let status: Int
        public let errorCode: String
        public let message: String

        public var json: String { return "{\"__type\":\"\(errorCode)\", \"message\": \"\(message)\"}"}
        public var xml: String { return "<Error><Code>\(errorCode)</Code><Message>\(message)</Message></Error>"}

        public static let badRequest = ErrorType(status: 400, errorCode: "BadRequest", message: "AWSTestServer_ErrorType_BadRequest")
        public static let accessDenied = ErrorType(status: 401, errorCode: "AccessDenied", message: "AWSTestServer_ErrorType_AccessDenied")
        public static let notFound = ErrorType(status: 404, errorCode: "NotFound", message: "AWSTestServer_ErrorType_NotFound")
        public static let tooManyRequests = ErrorType(status: 429, errorCode: "TooManyRequests", message: "AWSTestServer_ErrorType_TooManyRequests")

        public static let `internal` = ErrorType(status: 500, errorCode: "InternalFailure", message: "AWSTestServer_ErrorType_InternalFailure")
        public static let notImplemented = ErrorType(status: 501, errorCode: "NotImplemented", message: "AWSTestServer_ErrorType_NotImplemented")
        public static let serviceUnavailable = ErrorType(status: 503, errorCode: "ServiceUnavailable", message: "AWSTestServer_ErrorType_ServiceUnavailable")
    }

    /// result from process
    public enum Result<Output> {
        case result(Output, continueProcessing: Bool = false)
        case error(ErrorType, continueProcessing: Bool = false)
    }
    
    // httpBin function response
    public struct HTTPBinResponse: AWSDecodableShape & Encodable {
        public let method: String?
        public let data: String?
        public let headers: [String: String]
        public let url: String
    }

    public var addressURL: URL { return URL(string: self.address)!}
    public var address: String { return "http://\(self.host):\(web.serverPort)"}
    public var host: String { return "localhost" }
    public var serverPort: Int { return web.serverPort }
    public let serviceProtocol: ServiceProtocol

    let eventLoopGroup: EventLoopGroup
    let web: NIOHTTP1TestServer
    let byteBufferAllocator: ByteBufferAllocator


    public init(serviceProtocol: ServiceProtocol) {
        self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.web = NIOHTTP1TestServer(group: self.eventLoopGroup)
        self.serviceProtocol = serviceProtocol
        self.byteBufferAllocator = ByteBufferAllocator()
        print("Starting serving on localhost:\(serverPort)")
    }

    /// run server reading request, convert from to an input shape processing them and converting the result back to a response.
    public func process<Input: Decodable, Output: Encodable>(_ process: (Input) throws -> Result<Output>) throws {
        while(try processSingleRequest(process)) { }
    }

    /// run server reading requests, processing them and returning responses
    public func processRaw(_ process: (Request) throws -> Result<Response>) throws {
        while(try processSingleRawRequest(process)) { }
    }

    /// read one request and return details back in body
    public func httpBin() throws {
        let request = try readRequest()

        let data = request.body.getString(at: 0, length: request.body.readableBytes, encoding: .utf8)
        let httpBinResponse = HTTPBinResponse(
            method: request.method.rawValue,
            data: data,
            headers: request.headers,
            url: request.uri)
        let responseBody = try JSONEncoder().encodeAsByteBuffer(httpBinResponse, allocator: ByteBufferAllocator())
        let headers = [
            "Content-Type":"application/json",
            "Content-Length":responseBody.readableBytes.description
        ]
        try writeResponse(Response(httpStatus: .ok, headers: headers, body: responseBody))
    }

    public func stop() throws {
        print("Stop serving on localhost:\(serverPort)")
        try web.stop()
        try eventLoopGroup.syncShutdownGracefully()
    }
}

extension AWSTestServer {
    /// read one request, process it then return the respons
    func processSingleRawRequest(_ process: (Request) throws -> Result<Response>) throws -> Bool {
        let request = try readRequest()
        let result = try process(request)
        switch result {
        case .result(let response, let continueProcessing):
            try writeResponse(response)
            return continueProcessing
        case .error(let error, let continueProcessing):
            try writeError(error)
            return continueProcessing
        }
    }

    /// read one request, convert it from to an input shape, processing it and convert the result back to a response.
    func processSingleRequest<Input: Decodable, Output: Encodable>(_ process: (Input) throws -> Result<Output>) throws -> Bool {
        let request = try readRequest()

        // Convert to Input AWSShape
        guard let inputData = request.body.getData(at: 0, length: request.body.readableBytes) else {throw Error.emptyBody}
        let input: Input
        switch serviceProtocol {
        case .json, .restjson:
            input = try JSONDecoder().decode(Input.self, from: inputData)
        case .xml:
            guard let xmlNode = try XML.Document(data: inputData).rootElement() else {throw Error.noXMLBody}
            input = try XMLDecoder().decode(Input.self, from: xmlNode)
        }

        // process
        let result = try process(input)

        switch result {
        case .result(let response, let continueProcessing):
            // Convert to Output AWSShape
            let outputData: Data
            switch serviceProtocol {
            case .json, .restjson:
                outputData = try JSONEncoder().encode(response)
            case .xml:
                outputData = try XMLEncoder().encode(response).xmlString.data(using: .utf8) ?? Data()
            }
            var byteBuffer = byteBufferAllocator.buffer(capacity: 0)
            byteBuffer.writeBytes(outputData)

            try writeResponse(Response(httpStatus: .ok, headers: [:], body: byteBuffer))
            return continueProcessing
        case .error(let error, let continueProcessing):
            try writeError(error)
            return continueProcessing
        }
    }

    enum ReadChunkStatus {
        case none
        case readingSize(String = "")
        case readingSignature(Int, Int)
        case readingChunk(Int)
        case readingEnd(String = "")
        case finishing(String = "")
        case finished
    }

    /// read chunked data see
    func readChunkedData(status: ReadChunkStatus, input: inout ByteBuffer, output: inout ByteBuffer) throws -> ReadChunkStatus {
        var status = status

        func _readChunkSize(chunkSize: String, input: inout ByteBuffer) throws -> ReadChunkStatus {
            var chunkSize = chunkSize
            while(input.readableBytes > 0) {
                guard let char = input.readString(length: 1) else { throw Error.corruptChunkedData }
                chunkSize += char
                if chunkSize.hasSuffix(";") {
                    let hexChunkSize = String(chunkSize.dropLast(1))
                    guard let chunkSize = Int(hexChunkSize, radix: 16) else { throw Error.corruptChunkedData }
                    return .readingSignature(16 + 64 + 2, chunkSize) // "chunk-signature=" + hex(sha256) + "\r\n"
                }
            }
            return .readingSize(chunkSize)
        }

        func _readChunkEnd(chunkEnd: String, input: inout ByteBuffer) throws -> ReadChunkStatus {
            var chunkEnd = chunkEnd
            while(input.readableBytes > 0) {
                guard let char = input.readString(length: 1) else { throw Error.corruptChunkedData }
                chunkEnd += char
                if chunkEnd == "\r\n" {
                    return .none
                } else if chunkEnd.count > 2 {
                    throw Error.corruptChunkedData
                }
            }
            return .readingEnd(chunkEnd)
        }

        while(input.readableBytes > 0) {
            switch status {
            case .none:
                status = try _readChunkSize(chunkSize: "", input: &input)

            case .readingSize(let chunkSize):
                status = try _readChunkSize(chunkSize: chunkSize, input: &input)

            case .readingSignature(let size, let chunkSize):
                let blockSize = min(size, input.readableBytes)
                _ = input.readSlice(length: blockSize)
                if blockSize == size {
                    if chunkSize == 0 {
                        status = .finishing()
                    } else {
                        status = .readingChunk(chunkSize)
                    }
                } else {
                    status = .readingSignature(size - blockSize, chunkSize)
                }

            case .readingChunk(let size):
                let blockSize = min(size, input.readableBytes)
                var slice = input.readSlice(length: blockSize)!
                output.writeBuffer(&slice)
                if blockSize == size {
                    status = .readingEnd()
                } else {
                    status = .readingChunk(size - blockSize)
                }

            case .readingEnd(let chunkEnd):
                status = try _readChunkEnd(chunkEnd: chunkEnd, input: &input)

            case .finishing(let chunkEnd):
                status = try _readChunkEnd(chunkEnd: chunkEnd, input: &input)
                if case .none = status {
                    status = .finished
                }
            case .finished:
                throw Error.corruptChunkedData
            }
        }
        return status
    }

    /// read inbound request
    func readRequest() throws -> Request {
        var byteBuffer = byteBufferAllocator.buffer(capacity: 0)

        // read inbound
        guard case .head(let head) = try web.readInbound() else {throw Error.notHead}
        // is content-encoding: aws-chunked header set
        let isChunked = head.headers["Content-Encoding"].filter { $0 == "aws-chunked" }.count > 0
        var chunkStatus: ReadChunkStatus = .none
        // read body
        while(true) {
            let inbound = try web.readInbound()
            if case .body(var buffer) = inbound {
                if isChunked == true {
                     chunkStatus = try readChunkedData(status: chunkStatus, input: &buffer, output: &byteBuffer)
                 } else {
                     byteBuffer.writeBuffer(&buffer)
                 }
            } else if case .end(_) = inbound {
                if isChunked == true {
                    switch chunkStatus {
                    case .finished:
                        break
                    default:
                        throw Error.corruptChunkedData
                    }
                }
                break
            } else {
                throw Error.notEnd
            }
        }
        var requestHeaders: [String: String] = [:]
        for (key, value) in head.headers {
            requestHeaders[key.description] = value
        }
        return Request(method: head.method, uri: head.uri, headers: requestHeaders, body: byteBuffer)
    }

    /// write outbound response
    func writeResponse(_ response: Response) throws {
        XCTAssertNoThrow(try web.writeOutbound(.head(.init(version: .init(major: 1, minor: 1),
                                                           status: response.httpStatus,
                                                           headers: HTTPHeaders(response.headers.map { ($0,$1) })))))
        if var body = response.body {
            while body.readableBytes > 0 {
                let slice: ByteBuffer?
                if body.readableBytes > 16384 {
                    slice = body.readSlice(length: 16384)
                } else {
                    slice = body.readSlice(length: body.readableBytes)
                }
                XCTAssertNoThrow(try web.writeOutbound(.body(.byteBuffer(slice!))))
            }
        }
        do {
            try web.writeOutbound(.end(nil))
        } catch {
            print("Failed to write \(error)")
        }
//        XCTAssertNoThrow(try web.writeOutbound(.end(nil)))
    }

    /// write error
    func writeError(_ error: ErrorType) throws {
        let errorString: String
        var headers: [String: String] = [:]
        switch serviceProtocol {
        case .json:
            errorString = error.json
        case .restjson:
            errorString = error.json
            headers["x-amzn-ErrorType"] = error.errorCode
        case .xml:
            errorString = error.xml
        }

        var byteBuffer = byteBufferAllocator.buffer(capacity: 0)
        byteBuffer.writeString(errorString)

        try writeResponse(Response(httpStatus: HTTPResponseStatus(statusCode:error.status), headers: headers, body: byteBuffer))
    }
}
