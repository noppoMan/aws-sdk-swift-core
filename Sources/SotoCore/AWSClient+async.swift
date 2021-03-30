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

#if compiler(>=5.4) && $AsyncAwait

import Dispatch
import Foundation
import Logging
import Metrics
import SotoSignerV4

extension AWSClient {
    /// execute a request with an input object and return a future with an empty response
    /// - parameters:
    ///     - operationName: Name of the AWS operation
    ///     - path: path to append to endpoint URL
    ///     - httpMethod: HTTP method to use ("GET", "PUT", "PUSH" etc)
    ///     - input: Input object
    ///     - config: AWS service configuration used in request creation and signing
    ///     - context: additional context for call
    /// - returns:
    ///     Empty Future that completes when response is received
    public func execute<Input: AWSEncodableShape>(
        operation operationName: String,
        path: String,
        httpMethod: HTTPMethod,
        serviceConfig: AWSServiceConfig,
        input: Input,
        logger: Logger = AWSClient.loggingDisabled,
        on eventLoop: EventLoop? = nil
    ) async throws {
        return try await execute(
            operation: operationName,
            createRequest: {
                try AWSRequest(
                    operation: operationName,
                    path: path,
                    httpMethod: httpMethod,
                    input: input,
                    configuration: serviceConfig
                )
            },
            execute: { request, eventLoop, logger in
                return self.httpClient.execute(request: request, timeout: serviceConfig.timeout, on: eventLoop, logger: logger)
            },
            processResponse: { _ in
                return
            },
            config: serviceConfig,
            logger: logger,
            on: eventLoop
        )
    }

    /// Execute an empty request and return a future with an empty response
    /// - parameters:
    ///     - operationName: Name of the AWS operation
    ///     - path: path to append to endpoint URL
    ///     - httpMethod: HTTP method to use ("GET", "PUT", "PUSH" etc)
    ///     - config: AWS service configuration used in request creation and signing
    ///     - context: additional context for call
    /// - returns:
    ///     Empty Future that completes when response is received
    public func execute(
        operation operationName: String,
        path: String,
        httpMethod: HTTPMethod,
        serviceConfig: AWSServiceConfig,
        logger: Logger = AWSClient.loggingDisabled,
        on eventLoop: EventLoop? = nil
    ) async throws {
        return try await execute(
            operation: operationName,
            createRequest: {
                try AWSRequest(
                    operation: operationName,
                    path: path,
                    httpMethod: httpMethod,
                    configuration: serviceConfig
                )
            },
            execute: { request, eventLoop, logger in
                return self.httpClient.execute(request: request, timeout: serviceConfig.timeout, on: eventLoop, logger: logger)
            },
            processResponse: { _ in
                return
            },
            config: serviceConfig,
            logger: logger,
            on: eventLoop
        )
    }

    /// Execute an empty request and return a future with the output object generated from the response
    /// - parameters:
    ///     - operationName: Name of the AWS operation
    ///     - path: path to append to endpoint URL
    ///     - httpMethod: HTTP method to use ("GET", "PUT", "PUSH" etc)
    ///     - config: AWS service configuration used in request creation and signing
    ///     - context: additional context for call
    /// - returns:
    ///     Future containing output object that completes when response is received
    public func execute<Output: AWSDecodableShape>(
        operation operationName: String,
        path: String,
        httpMethod: HTTPMethod,
        serviceConfig: AWSServiceConfig,
        logger: Logger = AWSClient.loggingDisabled,
        on eventLoop: EventLoop? = nil
    ) async throws -> Output {
        return try await execute(
            operation: operationName,
            createRequest: {
                try AWSRequest(
                    operation: operationName,
                    path: path,
                    httpMethod: httpMethod,
                    configuration: serviceConfig
                )
            },
            execute: { request, eventLoop, logger in
                return self.httpClient.execute(request: request, timeout: serviceConfig.timeout, on: eventLoop, logger: logger)
            },
            processResponse: { response in
                return try self.validate(operation: operationName, response: response, serviceConfig: serviceConfig)
            },
            config: serviceConfig,
            logger: logger,
            on: eventLoop
        )
    }

    /// Execute a request with an input object and return a future with the output object generated from the response
    /// - parameters:
    ///     - operationName: Name of the AWS operation
    ///     - path: path to append to endpoint URL
    ///     - httpMethod: HTTP method to use ("GET", "PUT", "PUSH" etc)
    ///     - input: Input object
    ///     - config: AWS service configuration used in request creation and signing
    ///     - context: additional context for call
    /// - returns:
    ///     Future containing output object that completes when response is received
    public func execute<Output: AWSDecodableShape, Input: AWSEncodableShape>(
        operation operationName: String,
        path: String,
        httpMethod: HTTPMethod,
        serviceConfig: AWSServiceConfig,
        input: Input,
        logger: Logger = AWSClient.loggingDisabled,
        on eventLoop: EventLoop? = nil
    ) async throws -> Output {
        return try await execute(
            operation: operationName,
            createRequest: {
                try AWSRequest(
                    operation: operationName,
                    path: path,
                    httpMethod: httpMethod,
                    input: input,
                    configuration: serviceConfig
                )
            },
            execute: { request, eventLoop, logger in
                return self.httpClient.execute(request: request, timeout: serviceConfig.timeout, on: eventLoop, logger: logger)
            },
            processResponse: { response in
                return try self.validate(operation: operationName, response: response, serviceConfig: serviceConfig)
            },
            config: serviceConfig,
            logger: logger,
            on: eventLoop
        )
    }

    /// Execute a request with an input object and return a future with the output object generated from the response
    /// - parameters:
    ///     - operationName: Name of the AWS operation
    ///     - path: path to append to endpoint URL
    ///     - httpMethod: HTTP method to use ("GET", "PUT", "PUSH" etc)
    ///     - input: Input object
    ///     - config: AWS service configuration used in request creation and signing
    ///     - context: additional context for call
    /// - returns:
    ///     Future containing output object that completes when response is received
    public func execute<Output: AWSDecodableShape, Input: AWSEncodableShape>(
        operation operationName: String,
        path: String,
        httpMethod: HTTPMethod,
        serviceConfig: AWSServiceConfig,
        input: Input,
        logger: Logger = AWSClient.loggingDisabled,
        on eventLoop: EventLoop? = nil,
        stream: @escaping AWSHTTPClient.ResponseStream
    ) async throws -> Output {
        return try await execute(
            operation: operationName,
            createRequest: {
                try AWSRequest(
                    operation: operationName,
                    path: path,
                    httpMethod: httpMethod,
                    input: input,
                    configuration: serviceConfig
                )
            },
            execute: { request, eventLoop, logger in
                return self.httpClient.execute(request: request, timeout: serviceConfig.timeout, on: eventLoop, logger: logger, stream: stream)
            },
            processResponse: { response in
                return try self.validate(operation: operationName, response: response, serviceConfig: serviceConfig)
            },
            config: serviceConfig,
            logger: logger,
            on: eventLoop
        )
    }
    /// internal version of execute
    internal func execute<Output>(
        operation operationName: String,
        createRequest: @escaping () throws -> AWSRequest,
        execute: @escaping (AWSHTTPRequest, EventLoop, Logger) -> EventLoopFuture<AWSHTTPResponse>,
        processResponse: @escaping (AWSHTTPResponse) throws -> Output,
        config: AWSServiceConfig,
        logger: Logger = AWSClient.loggingDisabled,
        on eventLoop: EventLoop? = nil
    ) async throws -> Output {
        let eventLoop = eventLoop ?? eventLoopGroup.next()
        let logger = logger.attachingRequestId(Self.globalRequestID.add(1), operation: operationName, service: config.service)
        let dimensions: [(String, String)] = [("aws-service", config.service), ("aws-operation", operationName)]
        let startTime = DispatchTime.now().uptimeNanoseconds

        Counter(label: "aws_requests_total", dimensions: dimensions).increment()
        logger.log(level: self.options.requestLogLevel, "AWS Request")
        do {
            // get credentials
            let credential = try await credentialProvider.getCredential(on: eventLoop, logger: logger).get()
            // construct signer
            let signer = AWSSigner(credentials: credential, name: config.signingName, region: config.region.rawValue)
            // create request and sign with signer
            let awsRequest = try createRequest()
                .applyMiddlewares(config.middlewares + self.middlewares, config: config)
                .createHTTPRequest(signer: signer, byteBufferAllocator: config.byteBufferAllocator)
            // send request to AWS and process result
            let streaming: Bool
            switch awsRequest.body.payload {
            case .stream:
                streaming = true
            default:
                streaming = false
            }
            let response = try await self.invoke(
                with: config,
                eventLoop: eventLoop,
                logger: logger,
                request: { eventLoop in execute(awsRequest, eventLoop, logger) },
                processResponse: processResponse,
                streaming: streaming
            ).get()
            logger.trace("AWS Response")
            Metrics.Timer(
                label: "aws_request_duration",
                dimensions: dimensions,
                preferredDisplayUnit: .seconds
            ).recordNanoseconds(DispatchTime.now().uptimeNanoseconds - startTime)
            return response
        } catch {
            Counter(label: "aws_request_errors", dimensions: dimensions).increment()
            // AWSErrorTypes have already been logged
            if error as? AWSErrorType == nil {
                // log error message
                logger.error("AWSClient error", metadata: [
                    "aws-error-message": "\(error)",
                ])
            }
            throw error
        }
    }

    /// Generate a signed URL
    /// - parameters:
    ///     - url : URL to sign
    ///     - httpMethod: HTTP method to use (.GET, .PUT, .PUSH etc)
    ///     - httpHeaders: Headers that are to be used with this URL. Be sure to include these headers when you used the returned URL
    ///     - expires: How long before the signed URL expires
    ///     - serviceConfig: additional AWS service configuration used to sign the url
    ///     - logger: Logger to output to
    /// - returns:
    ///     A signed URL
    public func signURL(
        url: URL,
        httpMethod: HTTPMethod,
        headers: HTTPHeaders = HTTPHeaders(),
        expires: TimeAmount,
        serviceConfig: AWSServiceConfig,
        logger: Logger = AWSClient.loggingDisabled
    ) async throws -> URL {
        let logger = logger.attachingRequestId(Self.globalRequestID.add(1), operation: "signHeaders", service: serviceConfig.service)
        let signer = try await createSigner(serviceConfig: serviceConfig, logger: logger)
        guard let cleanURL = signer.processURL(url: url) else {
            throw AWSClient.ClientError.invalidURL
        }
        return signer.signURL(url: cleanURL, method: httpMethod, headers: headers, expires: expires)
    }

    /// Generate signed headers
    /// - parameters:
    ///     - url : URL to sign
    ///     - httpMethod: HTTP method to use (.GET, .PUT, .PUSH etc)
    ///     - httpHeaders: Headers that are to be used with this URL.
    ///     - body: Payload to sign as well. While it is unnecessary to provide the body for S3 other services may require it
    ///     - serviceConfig: additional AWS service configuration used to sign the url
    ///     - logger: Logger to output to
    /// - returns:
    ///     A set of signed headers that include the original headers supplied
    public func signHeaders(
        url: URL,
        httpMethod: HTTPMethod,
        headers: HTTPHeaders = HTTPHeaders(),
        body: AWSPayload,
        serviceConfig: AWSServiceConfig,
        logger: Logger = AWSClient.loggingDisabled
    ) async throws -> HTTPHeaders {
        let logger = logger.attachingRequestId(Self.globalRequestID.add(1), operation: "signHeaders", service: serviceConfig.service)
        let signer = try await createSigner(serviceConfig: serviceConfig, logger: logger)
        guard let cleanURL = signer.processURL(url: url) else {
            throw AWSClient.ClientError.invalidURL
        }
        let body: AWSSigner.BodyData? = body.asByteBuffer().map { .byteBuffer($0) }
        return signer.signHeaders(url: cleanURL, method: httpMethod, headers: headers, body: body)
    }

    func createSigner(serviceConfig: AWSServiceConfig, logger: Logger) async throws -> AWSSigner {
        let credential = try await credentialProvider.getCredential(on: eventLoopGroup.next(), logger: logger).get()
        return AWSSigner(credentials: credential, name: serviceConfig.signingName, region: serviceConfig.region.rawValue)
    }
}

#endif // compiler(>=5.4) && $AsyncAwait
