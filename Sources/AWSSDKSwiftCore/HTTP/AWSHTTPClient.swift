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

import Foundation
import NIO
import NIOHTTP1

/// HTTP Request
public struct AWSHTTPRequest {
    public let url: URL
    public let method: HTTPMethod
    public let headers: HTTPHeaders
    public let body: ByteBuffer?
}

/// HTTP Response
public protocol AWSHTTPResponse {
    var status: HTTPResponseStatus { get }
    var headers: HTTPHeaders { get }
    var body: ByteBuffer? { get }
}

/// Protocol defining requirements for a HTTPClient
public protocol AWSHTTPClient {
    /// Execute HTTP request and return a future holding a HTTP Response
    func execute(request: AWSHTTPRequest, timeout: TimeAmount) -> EventLoopFuture<AWSHTTPResponse>
    
    /// This should be called before an HTTP Client can be de-initialised
    func syncShutdown() throws
    
    /// Event loop group used by client
    var eventLoopGroup: EventLoopGroup { get }
}
