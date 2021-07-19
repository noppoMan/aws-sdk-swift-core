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

import AsyncHTTPClient
import Dispatch
import struct Foundation.URL
import struct Foundation.URLQueryItem
import Logging
import Metrics
import NIO
import NIOConcurrencyHelpers
import NIOHTTP1
import NIOTransportServices
import SotoSignerV4
import SotoXML

/// This is the workhorse of SotoCore. You provide it with a `AWSShape` Input object, it converts it to `AWSRequest` which is then converted
/// to a raw `HTTPClient` Request. This is then sent to AWS. When the response from AWS is received if it is successful it is converted to a `AWSResponse`
/// which is then decoded to generate a `AWSShape` Output object. If it is not successful then `AWSClient` will throw an `AWSErrorType`.
public final class AWSClient {
    // MARK: Member variables

    /// Default logger that logs nothing
    public static let loggingDisabled = Logger(label: "AWS-do-not-log", factory: { _ in SwiftLogNoOpLogHandler() })

    static let globalRequestID = NIOAtomic<Int>.makeAtomic(value: 0)

    /// AWS credentials provider
    public let credentialProvider: CredentialProvider
    /// Middleware code to be applied to requests and responses
    public let middlewares: [AWSServiceMiddleware]
    /// HTTP client used by AWSClient
    public let httpClient: AWSHTTPClient
    /// Keeps a record of how we obtained the HTTP client
    let httpClientProvider: HTTPClientProvider
    /// EventLoopGroup used by AWSClient
    public var eventLoopGroup: EventLoopGroup { return httpClient.eventLoopGroup }
    /// Retry policy specifying what to do when a request fails
    public let retryPolicy: RetryPolicy
    /// Logger used for non-request based output
    let clientLogger: Logger
    /// client options
    let options: Options

    private let isShutdown = NIOAtomic<Bool>.makeAtomic(value: false)

    // MARK: Initialization

    /// Initialize an AWSClient struct
    /// - parameters:
    ///     - credentialProvider: An object that returns valid signing credentials for request signing.
    ///     - retryPolicy: Object returning whether retries should be attempted. Possible options are NoRetry(), ExponentialRetry() or JitterRetry()
    ///     - middlewares: Array of middlewares to apply to requests and responses
    ///     - httpClientProvider: HTTPClient to use. Use `.createNew` if you want the client to manage its own HTTPClient.
    ///     - logger: Logger used to log background AWSClient events
    public init(
        credentialProvider credentialProviderFactory: CredentialProviderFactory = .default,
        retryPolicy retryPolicyFactory: RetryPolicyFactory = .default,
        middlewares: [AWSServiceMiddleware] = [],
        options: Options,
        httpClientProvider: HTTPClientProvider,
        logger clientLogger: Logger = AWSClient.loggingDisabled
    ) {
        // setup httpClient
        self.httpClientProvider = httpClientProvider
        switch httpClientProvider {
        case .shared(let providedHTTPClient):
            self.httpClient = providedHTTPClient
        case .createNewWithEventLoopGroup(let elg):
            self.httpClient = AsyncHTTPClient.HTTPClient(eventLoopGroupProvider: .shared(elg), configuration: .init(timeout: .init(connect: .seconds(10))))
        case .createNew:
            self.httpClient = AsyncHTTPClient.HTTPClient(eventLoopGroupProvider: .createNew, configuration: .init(timeout: .init(connect: .seconds(10))))
        }

        self.credentialProvider = credentialProviderFactory.createProvider(context: .init(
            httpClient: httpClient,
            eventLoop: httpClient.eventLoopGroup.next(),
            logger: clientLogger,
            options: options
        ))

        self.middlewares = middlewares
        self.retryPolicy = retryPolicyFactory.retryPolicy
        self.clientLogger = clientLogger
        self.options = options
    }

    /// Initialize an AWSClient struct
    /// - parameters:
    ///     - credentialProvider: An object that returns valid signing credentials for request signing.
    ///     - retryPolicy: Object returning whether retries should be attempted. Possible options are NoRetry(), ExponentialRetry() or JitterRetry()
    ///     - middlewares: Array of middlewares to apply to requests and responses
    ///     - httpClientProvider: HTTPClient to use. Use `.createNew` if you want the client to manage its own HTTPClient.
    ///     - logger: Logger used to log background AWSClient events
    public convenience init(
        credentialProvider credentialProviderFactory: CredentialProviderFactory = .default,
        retryPolicy retryPolicyFactory: RetryPolicyFactory = .default,
        middlewares: [AWSServiceMiddleware] = [],
        httpClientProvider: HTTPClientProvider,
        logger clientLogger: Logger = AWSClient.loggingDisabled
    ) {
        self.init(
            credentialProvider: credentialProviderFactory,
            retryPolicy: retryPolicyFactory,
            middlewares: middlewares,
            options: Options(),
            httpClientProvider: httpClientProvider,
            logger: clientLogger
        )
    }

    deinit {
        assert(self.isShutdown.load(), "AWSClient not shut down before the deinit. Please call client.syncShutdown() when no longer needed.")
    }

    // MARK: API Calls

    /// Shutdown client synchronously. Before an `AWSClient` is deleted you need to call this function or the async version `shutdown`
    /// to do a clean shutdown of the client. It cleans up `CredentialProvider` tasks and shuts down the HTTP client if it was created by
    /// the `AWSClient`.
    ///
    /// - Throws: AWSClient.ClientError.alreadyShutdown: You have already shutdown the client
    public func syncShutdown() throws {
        let errorStorageLock = Lock()
        var errorStorage: Error?
        let continuation = DispatchWorkItem {}
        self.shutdown(queue: DispatchQueue(label: "aws-client.shutdown")) { error in
            if let error = error {
                errorStorageLock.withLock {
                    errorStorage = error
                }
            }
            continuation.perform()
        }
        continuation.wait()
        try errorStorageLock.withLock {
            if let error = errorStorage {
                throw error
            }
        }
    }

    /// Shutdown AWSClient asynchronously. Before an `AWSClient` is deleted you need to call this function or the synchronous
    /// version `syncShutdown` to do a clean shutdown of the client. It cleans up `CredentialProvider` tasks and shuts down
    /// the HTTP client if it was created by the `AWSClient`. Given we could be destroying the `EventLoopGroup` the client
    /// uses, we have to use a `DispatchQueue` to run some of this work on.
    ///
    /// - Parameters:
    ///   - queue: Dispatch Queue to run shutdown on
    ///   - callback: Callback called when shutdown is complete. If there was an error it will return with Error in callback
    public func shutdown(queue: DispatchQueue = .global(), _ callback: @escaping (Error?) -> Void) {
        guard self.isShutdown.compareAndExchange(expected: false, desired: true) else {
            callback(ClientError.alreadyShutdown)
            return
        }
        let eventLoop = eventLoopGroup.next()
        // ignore errors from credential provider. Don't need shutdown erroring because no providers were available
        credentialProvider.shutdown(on: eventLoop).whenComplete { _ in
            // if httpClient was created by AWSClient then it is required to shutdown the httpClient.
            switch self.httpClientProvider {
            case .createNew, .createNewWithEventLoopGroup:
                self.httpClient.shutdown(queue: queue) { error in
                    if let error = error {
                        self.clientLogger.log(level: self.options.errorLogLevel, "Error shutting down HTTP client", metadata: [
                            "aws-error": "\(error)",
                        ])
                    }
                    callback(error)
                }

            case .shared:
                callback(nil)
            }
        }
    }

    // MARK: Member structs/enums

    /// Errors returned by `AWSClient` code
    public struct ClientError: Swift.Error, Equatable {
        enum Error {
            case alreadyShutdown
            case invalidURL
            case tooMuchData
            case notEnoughData
            case waiterFailed
            case waiterTimeout
        }

        let error: Error

        /// client has already been shutdown
        public static var alreadyShutdown: ClientError { .init(error: .alreadyShutdown) }
        /// URL provided to client is invalid
        public static var invalidURL: ClientError { .init(error: .invalidURL) }
        /// Too much data has been supplied for the Request
        public static var tooMuchData: ClientError { .init(error: .tooMuchData) }
        /// Not enough data has been supplied for the Request
        public static var notEnoughData: ClientError { .init(error: .notEnoughData) }
        /// Waiter failed, but without an error. ie a successful api call was an error
        public static var waiterFailed: ClientError { .init(error: .waiterFailed) }
        /// Waiter failed to complete in time alloted
        public static var waiterTimeout: ClientError { .init(error: .waiterTimeout) }
    }

    /// Specifies how `HTTPClient` will be created and establishes lifecycle ownership.
    public enum HTTPClientProvider {
        /// HTTP Client will be provided by the user. Owner of this group is responsible for its lifecycle. Any HTTPClient that conforms to
        /// `AWSHTTPClient` can be specified here including AsyncHTTPClient
        case shared(AWSHTTPClient)
        /// HTTP Client will be created by the client using provided EventLoopGroup. When `shutdown` is called, created `HTTPClient`
        /// will be shut down as well.
        case createNewWithEventLoopGroup(EventLoopGroup)
        /// HTTP Client will be created by the client. When `shutdown` is called, created `HTTPClient` will be shut down as well.
        case createNew
    }

    /// Additional options
    public struct Options {
        /// log level used for request logging
        let requestLogLevel: Logger.Level
        /// log level used for error logging
        let errorLogLevel: Logger.Level

        /// Initialize AWSClient.Options
        /// - Parameter requestLogLevel:Log level used for request logging
        public init(
            requestLogLevel: Logger.Level = .debug,
            errorLogLevel: Logger.Level = .debug
        ) {
            self.requestLogLevel = requestLogLevel
            self.errorLogLevel = errorLogLevel
        }
    }
}

// MARK: API Calls

// public facing apis
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
        hostPrefix: String? = nil,
        logger: Logger = AWSClient.loggingDisabled,
        on eventLoop: EventLoop? = nil
    ) -> EventLoopFuture<Void> {
        return execute(
            operation: operationName,
            createRequest: {
                try AWSRequest(
                    operation: operationName,
                    path: path,
                    httpMethod: httpMethod,
                    input: input,
                    hostPrefix: hostPrefix,
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
    ) -> EventLoopFuture<Void> {
        return execute(
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
    ) -> EventLoopFuture<Output> {
        return execute(
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
        hostPrefix: String? = nil,
        logger: Logger = AWSClient.loggingDisabled,
        on eventLoop: EventLoop? = nil
    ) -> EventLoopFuture<Output> {
        return execute(
            operation: operationName,
            createRequest: {
                try AWSRequest(
                    operation: operationName,
                    path: path,
                    httpMethod: httpMethod,
                    input: input,
                    hostPrefix: hostPrefix,
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
        hostPrefix: String? = nil,
        logger: Logger = AWSClient.loggingDisabled,
        on eventLoop: EventLoop? = nil,
        stream: @escaping AWSHTTPClient.ResponseStream
    ) -> EventLoopFuture<Output> {
        return execute(
            operation: operationName,
            createRequest: {
                try AWSRequest(
                    operation: operationName,
                    path: path,
                    httpMethod: httpMethod,
                    input: input,
                    hostPrefix: hostPrefix,
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
    ) -> EventLoopFuture<Output> {
        let eventLoop = eventLoop ?? eventLoopGroup.next()
        let logger = logger.attachingRequestId(Self.globalRequestID.add(1), operation: operationName, service: config.service)
        // get credentials
        let future: EventLoopFuture<Output> = credentialProvider.getCredential(on: eventLoop, logger: logger)
            .flatMapThrowing { credential -> AWSHTTPRequest in
                // construct signer
                let signer = AWSSigner(credentials: credential, name: config.signingName, region: config.region.rawValue)
                // create request and sign with signer
                let awsRequest = try createRequest()
                return try awsRequest
                    .applyMiddlewares(config.middlewares + self.middlewares, config: config)
                    .createHTTPRequest(signer: signer, byteBufferAllocator: config.byteBufferAllocator)
            }.flatMap { request -> EventLoopFuture<Output> in
                // send request to AWS and process result
                let streaming: Bool
                switch request.body.payload {
                case .stream:
                    streaming = true
                default:
                    streaming = false
                }
                return self.invoke(
                    with: config,
                    eventLoop: eventLoop,
                    logger: logger,
                    request: { eventLoop in execute(request, eventLoop, logger) },
                    processResponse: processResponse,
                    streaming: streaming
                )
            }
        return recordRequest(future, service: config.service, operation: operationName, logger: logger)
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
    ) -> EventLoopFuture<URL> {
        let logger = logger.attachingRequestId(Self.globalRequestID.add(1), operation: "signURL", service: serviceConfig.service)
        return createSigner(serviceConfig: serviceConfig, logger: logger).flatMapThrowing { signer in
            guard let cleanURL = signer.processURL(url: url) else {
                throw AWSClient.ClientError.invalidURL
            }
            return signer.signURL(url: cleanURL, method: httpMethod, headers: headers, expires: expires)
        }
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
    ) -> EventLoopFuture<HTTPHeaders> {
        let logger = logger.attachingRequestId(Self.globalRequestID.add(1), operation: "signHeaders", service: serviceConfig.service)
        return createSigner(serviceConfig: serviceConfig, logger: logger).flatMapThrowing { signer in
            guard let cleanURL = signer.processURL(url: url) else {
                throw AWSClient.ClientError.invalidURL
            }
            let body: AWSSigner.BodyData? = body.asByteBuffer().map { .byteBuffer($0) }
            return signer.signHeaders(url: cleanURL, method: httpMethod, headers: headers, body: body)
        }
    }

    func createSigner(serviceConfig: AWSServiceConfig, logger: Logger) -> EventLoopFuture<AWSSigner> {
        return credentialProvider.getCredential(on: eventLoopGroup.next(), logger: logger).map { credential in
            return AWSSigner(credentials: credential, name: serviceConfig.signingName, region: serviceConfig.region.rawValue)
        }
    }
}

// response validator
extension AWSClient {
    /// Generate an AWS Response from  the operation HTTP response and return the output shape from it. This is only every called if the response includes a successful http status code
    internal func validate<Output: AWSDecodableShape>(operation operationName: String, response: AWSHTTPResponse, serviceConfig: AWSServiceConfig) throws -> Output {
        assert((200..<300).contains(response.status.code), "Shouldn't get here if error was returned")

        let raw = (Output.self as? AWSShapeWithPayload.Type)?._payloadOptions.contains(.raw) == true
        let awsResponse = try AWSResponse(from: response, serviceProtocol: serviceConfig.serviceProtocol, raw: raw)
            .applyMiddlewares(serviceConfig.middlewares + middlewares, config: serviceConfig)

        return try awsResponse.generateOutputShape(operation: operationName)
    }

    /// Create error from HTTPResponse. This is only called if we received an unsuccessful http status code.
    internal func createError(for response: AWSHTTPResponse, serviceConfig: AWSServiceConfig, logger: Logger) -> Error {
        // if we can create an AWSResponse and create an error from it return that
        if let awsResponse = try? AWSResponse(from: response, serviceProtocol: serviceConfig.serviceProtocol)
            .applyMiddlewares(serviceConfig.middlewares + middlewares, config: serviceConfig),
            let error = awsResponse.generateError(serviceConfig: serviceConfig, logLevel: options.errorLogLevel, logger: logger)
        {
            return error
        } else {
            // else return "Unhandled error message" with rawBody attached
            var rawBodyString: String?
            if var body = response.body {
                rawBodyString = body.readString(length: body.readableBytes)
            }
            let context = AWSErrorContext(
                message: "Unhandled Error",
                responseCode: response.status,
                headers: response.headers
            )
            return AWSRawError(rawBody: rawBodyString, context: context)
        }
    }
}

// invoker
extension AWSClient {
    private func invoke<Output>(
        with serviceConfig: AWSServiceConfig,
        eventLoop: EventLoop,
        logger: Logger,
        request: @escaping (EventLoop) -> EventLoopFuture<AWSHTTPResponse>,
        processResponse: @escaping (AWSHTTPResponse) throws -> Output,
        streaming: Bool
    ) -> EventLoopFuture<Output> {
        let promise = eventLoop.makePromise(of: Output.self)

        func execute(attempt: Int) {
            // execute HTTP request
            _ = request(eventLoop)
                .flatMapThrowing { (response) throws -> Void in
                    // if it returns an HTTP status code outside 2xx then throw an error
                    guard (200..<300).contains(response.status.code) else {
                        throw self.createError(for: response, serviceConfig: serviceConfig, logger: logger)
                    }
                    let output = try processResponse(response)
                    promise.succeed(output)
                }
                .flatMapErrorThrowing { (error) -> Void in
                    // if streaming and the error returned is an AWS error fail immediately. Do not attempt
                    // to retry as the streaming function will not know you are retrying
                    if streaming,
                       error is AWSErrorType || error is AWSRawError
                    {
                        promise.fail(error)
                        return
                    }
                    // If I get a retry wait time for this error then attempt to retry request
                    if case .retry(let retryTime) = self.retryPolicy.getRetryWaitTime(error: error, attempt: attempt) {
                        logger.trace("Retrying request", metadata: [
                            "aws-retry-time": "\(Double(retryTime.nanoseconds) / 1_000_000_000)",
                        ])
                        // schedule task for retrying AWS request
                        eventLoop.scheduleTask(in: retryTime) {
                            execute(attempt: attempt + 1)
                        }
                    } else {
                        promise.fail(error)
                    }
                }
        }

        execute(attempt: 0)

        return promise.futureResult
    }
}

extension AWSClient.ClientError: CustomStringConvertible {
    /// return human readable description of error
    public var description: String {
        switch error {
        case .alreadyShutdown:
            return "The AWSClient is already shutdown"
        case .invalidURL:
            return """
            The request url is invalid format.
            This error is internal. So please make a issue on https://github.com/soto-project/soto/issues to solve it.
            """
        case .tooMuchData:
            return "You have supplied too much data for the Request."
        case .notEnoughData:
            return "You have not supplied enough data for the Request."
        case .waiterFailed:
            return "Waiter failed"
        case .waiterTimeout:
            return "Waiter failed to complete in time allocated"
        }
    }
}

extension AWSClient {
    /// Record request in swift-metrics, and swift-log
    func recordRequest<Output>(_ future: EventLoopFuture<Output>, service: String, operation: String, logger: Logger) -> EventLoopFuture<Output> {
        let dimensions: [(String, String)] = [("aws-service", service), ("aws-operation", operation)]
        let startTime = DispatchTime.now().uptimeNanoseconds

        Counter(label: "aws_requests_total", dimensions: dimensions).increment()
        logger.log(level: self.options.requestLogLevel, "AWS Request")

        return future.map { response in
            logger.trace("AWS Response")
            Metrics.Timer(
                label: "aws_request_duration",
                dimensions: dimensions,
                preferredDisplayUnit: .seconds
            ).recordNanoseconds(DispatchTime.now().uptimeNanoseconds - startTime)
            return response
        }.flatMapErrorThrowing { error in
            Counter(label: "aws_request_errors", dimensions: dimensions).increment()
            // AWSErrorTypes have already been logged
            if error as? AWSErrorType == nil {
                // log error message
                logger.log(level: self.options.errorLogLevel, "AWSClient error", metadata: [
                    "aws-error-message": "\(error)",
                ])
            }
            throw error
        }
    }
}

extension Logger {
    func attachingRequestId(_ id: Int, operation: String, service: String) -> Logger {
        var logger = self
        logger[metadataKey: "aws-service"] = .string(service)
        logger[metadataKey: "aws-operation"] = .string(operation)
        logger[metadataKey: "aws-request-id"] = "\(id)"
        return logger
    }
}
