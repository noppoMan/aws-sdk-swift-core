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

import AsyncHTTPClient
import AWSSignerV4
import AWSXML
import Baggage
import BaggageLogging
import Dispatch
import struct Foundation.Data
import class Foundation.JSONDecoder
import class Foundation.JSONSerialization
import struct Foundation.URL
import struct Foundation.URLQueryItem
import Instrumentation
import Logging
import Metrics
import NIO
import NIOConcurrencyHelpers
import NIOHTTP1
import NIOTransportServices
import TracingInstrumentation

/// This is the workhorse of aws-sdk-swift-core. You provide it with a `AWSShape` Input object, it converts it to `AWSRequest` which is then converted
/// to a raw `HTTPClient` Request. This is then sent to AWS. When the response from AWS is received if it is successful it is converted to a `AWSResponse`
/// which is then decoded to generate a `AWSShape` Output object. If it is not successful then `AWSClient` will throw an `AWSErrorType`.
public final class AWSClient {
    /// AWS client context, carries trace context and logger.
    public typealias Context = BaggageLogging.LoggingBaggageContextCarrier

    /// Errors returned by AWSClient code
    public struct ClientError: Swift.Error, Equatable {
        enum Error {
            case alreadyShutdown
            case invalidURL
            case tooMuchData
        }

        let error: Error

        /// client has already been shutdown
        public static var alreadyShutdown: ClientError { .init(error: .alreadyShutdown) }
        /// URL provided to client is invalid
        public static var invalidURL: ClientError { .init(error: .invalidURL) }
        /// Too much data has been supplied for the Request
        public static var tooMuchData: ClientError { .init(error: .tooMuchData) }
    }

    public struct HTTPResponseError: Swift.Error {
        public let response: AWSHTTPResponse
    }

    /// Specifies how `HTTPClient` will be created and establishes lifecycle ownership.
    public enum HTTPClientProvider {
        /// HTTP Client will be provided by the user. Owner of this group is responsible for its lifecycle. Any HTTPClient that conforms to
        /// `AWSHTTPClient` can be specified here including AsyncHTTPClient
        case shared(AWSHTTPClient)
        /// HTTP Client will be created by the client. When `shutdown` is called, created `HTTPClient` will be shut down as well.
        case createNew
    }

    /// AWS credentials provider
    public let credentialProvider: CredentialProvider
    /// middleware code to be applied to requests and responses
    public let middlewares: [AWSServiceMiddleware]
    /// HTTP client used by AWSClient
    public let httpClient: AWSHTTPClient
    /// keeps a record of how we obtained the HTTP client
    let httpClientProvider: HTTPClientProvider
    /// EventLoopGroup used by AWSClient
    public var eventLoopGroup: EventLoopGroup { return httpClient.eventLoopGroup }
    /// Retry policy specifying what to do when a request fails
    public let retryPolicy: RetryPolicy

    private let context: AWSClient.Context

    private let isShutdown = NIOAtomic<Bool>.makeAtomic(value: false)

    /// Initialize an AWSClient struct
    /// - parameters:
    ///     - credentialProvider: An object that returns valid signing credentials for request signing.
    ///     - retryPolicy: Object returning whether retries should be attempted. Possible options are NoRetry(), ExponentialRetry() or JitterRetry()
    ///     - middlewares: Array of middlewares to apply to requests and responses
    ///     - httpClientProvider: HTTPClient to use. Use `.createNew` if you want the client to manage its own HTTPClient.
    public init(
        credentialProvider credentialProviderFactory: CredentialProviderFactory = .default,
        retryPolicy retryPolicyFactory: RetryPolicyFactory = .default,
        middlewares: [AWSServiceMiddleware] = [],
        httpClientProvider: HTTPClientProvider,
        context: AWSClient.Context = AWSClient.emptyContext()
    ) {
        // TODO: not sure if it makes sense as most resources are created lazily
        var span = InstrumentationSystem.tracingInstrument.startSpan(named: "AWSClient.init", context: context)
        defer {
            span.end()
        }

        // setup httpClient
        self.httpClientProvider = httpClientProvider
        switch httpClientProvider {
        case .shared(let providedHTTPClient):
            self.httpClient = providedHTTPClient
        case .createNew:
            self.httpClient = InstrumentationSystem.tracingInstrument.span(named: "createHTTPClient", context: context.with(baggage: span.context)) { _ in
                AWSClient.createHTTPClient()
            }
        }

        self.credentialProvider = credentialProviderFactory.createProvider(context: .init(
            httpClient: httpClient,
            eventLoop: httpClient.eventLoopGroup.next(),
            context: context
        ))

        self.middlewares = middlewares
        self.retryPolicy = retryPolicyFactory.retryPolicy
        self.context = context
    }

    deinit {
        assert(self.isShutdown.load(), "AWSClient not shut down before the deinit. Please call client.syncShutdown() when no longer needed.")
    }

    /// Shutdown client synchronously. Before an AWSClient is deleted you need to call this function or the async version `shutdown`
    /// to do a clean shutdown of the client. It cleans up CredentialProvider tasks and shuts down the HTTP client if it was created by this
    /// AWSClient.
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

    /// Shutdown AWSClient asynchronously. Before an AWSClient is deleted you need to call this function or the synchronous
    /// version `syncShutdown` to do a clean shutdown of the client. It cleans up CredentialProvider tasks and shuts down
    /// the HTTP client if it was created by this AWSClient. Given we could be destroying the EventLoopGroup the client
    /// uses, we have to use a DispatchQueue to run some of this work on.
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
            case .createNew:
                self.httpClient.shutdown(queue: queue) { error in
                    if let error = error {
                        self.context.logger.error("Error shutting down HTTP client", metadata: [
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
}

// invoker
extension AWSClient {
    fileprivate func invoke(
        with serviceConfig: AWSServiceConfig,
        context: Context,
        _ request: @escaping (Context) -> EventLoopFuture<AWSHTTPResponse>
    ) -> EventLoopFuture<AWSHTTPResponse> {
        let eventloop = self.eventLoopGroup.next()
        let promise = eventloop.makePromise(of: AWSHTTPResponse.self)

        let span = InstrumentationSystem.tracingInstrument.startSpan(named: "invoke", context: context)
        func execute(attempt: Int) {
            // execute HTTP request
            _ = request(context.with(baggage: span.context))
                .flatMapThrowing { (response) throws -> Void in
                    // if it returns an HTTP status code outside 2xx then throw an error
                    guard (200..<300).contains(response.status.code) else { throw HTTPResponseError(response: response) }
                    promise.succeed(response)
                }
                .flatMapErrorThrowing { (error) -> Void in
                    // If I get a retry wait time for this error then attempt to retry request
                    if case .retry(let retryTime) = self.retryPolicy.getRetryWaitTime(error: error, attempt: attempt) {
                        context.logger.info("Retrying request", metadata: [
                            "aws-retry-time": "\(Double(retryTime.nanoseconds) / 1_000_000_000)",
                        ])
                        // schedule task for retrying AWS request
                        eventloop.scheduleTask(in: retryTime) {
                            execute(attempt: attempt + 1)
                        }
                    } else if let responseError = error as? HTTPResponseError {
                        // if there was no retry and error was a response status code then attempt to convert to AWS error
                        promise.fail(self.createError(for: responseError.response, serviceConfig: serviceConfig, logger: context.logger))
                    } else {
                        promise.fail(error)
                    }
                }
        }

        execute(attempt: 0)

        return promise.futureResult.endSpan(span)
    }

    /// create HTTPClient
    fileprivate static func createHTTPClient() -> AWSHTTPClient {
        return AsyncHTTPClient.HTTPClient(eventLoopGroupProvider: .createNew)
    }
}

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
        context: AWSClient.Context,
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
                    configuration: serviceConfig
                )
            },
            execute: { request, eventLoop, context in
                return self.httpClient.execute(request: request, timeout: serviceConfig.timeout, on: eventLoop, context: context)
            },
            processResponse: { _ in
                return
            },
            config: serviceConfig,
            context: context,
            on: eventLoop
        )
    }

    /// execute an empty request and return a future with an empty response
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
        context: AWSClient.Context,
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
            execute: { request, eventLoop, context in
                return self.httpClient.execute(request: request, timeout: serviceConfig.timeout, on: eventLoop, context: context)
            },
            processResponse: { _ in
                return
            },
            config: serviceConfig,
            context: context,
            on: eventLoop
        )
    }

    /// execute an empty request and return a future with the output object generated from the response
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
        context: AWSClient.Context,
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
            execute: { request, eventLoop, context in
                return self.httpClient.execute(request: request, timeout: serviceConfig.timeout, on: eventLoop, context: context)
            },
            processResponse: { response in
                return try self.validate(operation: operationName, response: response, serviceConfig: serviceConfig)
            },
            config: serviceConfig,
            context: context,
            on: eventLoop
        )
    }

    /// execute a request with an input object and return a future with the output object generated from the response
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
        context: AWSClient.Context,
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
                    configuration: serviceConfig
                )
            },
            execute: { request, eventLoop, context in
                return self.httpClient.execute(request: request, timeout: serviceConfig.timeout, on: eventLoop, context: context)
            },
            processResponse: { response in
                return try self.validate(operation: operationName, response: response, serviceConfig: serviceConfig)
            },
            config: serviceConfig,
            context: context,
            on: eventLoop
        )
    }

    /// execute a request with an input object and return a future with the output object generated from the response
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
        context: AWSClient.Context,
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
                    configuration: serviceConfig
                )
            },
            execute: { request, eventLoop, context in
                return self.httpClient.execute(request: request, timeout: serviceConfig.timeout, on: eventLoop, context: context, stream: stream)
            },
            processResponse: { response in
                return try self.validate(operation: operationName, response: response, serviceConfig: serviceConfig)
            },
            config: serviceConfig,
            context: context,
            on: eventLoop
        )
    }

    /// internal version of execute
    internal func execute<Output>(
        operation operationName: String,
        createRequest: @escaping () throws -> AWSRequest,
        execute: @escaping (AWSHTTPRequest, EventLoop, AWSClient.Context) -> EventLoopFuture<AWSHTTPResponse>,
        processResponse: @escaping (AWSHTTPResponse) throws -> Output,
        config: AWSServiceConfig,
        context: AWSClient.Context,
        on eventLoop: EventLoop? = nil
    ) -> EventLoopFuture<Output> {
        let eventLoop = eventLoop ?? eventLoopGroup.next()
        // TODO: discuss hot to update the context (and its baggage)
        var context = context
        context.setRequest(.init(operation: operationName, serviceConfig: config))
        let span = InstrumentationSystem.tracingInstrument.startSpan(
            named: "\(config.service):\(operationName)", // TODO: or just "execute"?
            context: context
        )
        context = context.with(baggage: span.context)
        let future: EventLoopFuture<Output> = InstrumentationSystem.tracingInstrument.span(named: "getCredential", context: context) { span in
            credentialProvider.getCredential(on: eventLoop, context: context.with(baggage: span.context))
        }
        .flatMapThrowing { credential in
            let signer = AWSSigner(credentials: credential, name: config.signingName, region: config.region.rawValue)
            let awsRequest = try createRequest()
            return try awsRequest
                .applyMiddlewares(config.middlewares + self.middlewares)
                .createHTTPRequest(signer: signer)
        }.flatMap { request in
            return self.invoke(with: config, context: context) { context in
                execute(request, eventLoop, context)
            }
        }.flatMapThrowing { response in
            try InstrumentationSystem.tracingInstrument.span(named: "processResponse", context: context) { _ in
                try processResponse(response)
            }
        }
        .endSpan(span)
        return recordRequest(future, service: config.service, operation: operationName, context: context)
    }

    /// generate a signed URL
    /// - parameters:
    ///     - url : URL to sign
    ///     - httpMethod: HTTP method to use ("GET", "PUT", "PUSH" etc)
    ///     - expires: How long before the signed URL expires
    ///     - serviceConfig: additional AWS service configuration used to sign the url
    /// - returns:
    ///     A signed URL
    public func signURL(
        url: URL,
        httpMethod: String,
        expires: Int = 86400,
        serviceConfig: AWSServiceConfig,
        context: CredentialProvider.Context
    ) -> EventLoopFuture<URL> {
        var context = context
        context.setRequest(.init(operation: "signURL", serviceConfig: serviceConfig))
        return InstrumentationSystem.tracingInstrument.span(named: "signURL", context: context) { span in
            createSigner(serviceConfig: serviceConfig, context: context.with(baggage: span.context)).map { signer in
                signer.signURL(url: url, method: HTTPMethod(rawValue: httpMethod), expires: expires)
            }
        }
    }

    func createSigner(serviceConfig: AWSServiceConfig, context: CredentialProvider.Context) -> EventLoopFuture<AWSSigner> {
        return credentialProvider.getCredential(on: eventLoopGroup.next(), context: context).map { credential in
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
            .applyMiddlewares(serviceConfig.middlewares + middlewares)

        return try awsResponse.generateOutputShape(operation: operationName)
    }

    /// Create error from HTTPResponse. This is only called if we received an unsuccessful http status code.
    internal func createError(for response: AWSHTTPResponse, serviceConfig: AWSServiceConfig, logger: Logger) -> Error {
        // if we can create an AWSResponse and create an error from it return that
        if let awsResponse = try? AWSResponse(from: response, serviceProtocol: serviceConfig.serviceProtocol)
            .applyMiddlewares(serviceConfig.middlewares + middlewares),
            let error = awsResponse.generateError(serviceConfig: serviceConfig, logger: logger)
        {
            return error
        } else {
            // else return "Unhandled error message" with rawBody attached
            var rawBodyString: String?
            if var body = response.body {
                rawBodyString = body.readString(length: body.readableBytes)
            }
            return AWSError(statusCode: response.status, message: "Unhandled Error", rawBody: rawBodyString)
        }
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
            This error is internal. So please make a issue on https://github.com/swift-aws/aws-sdk-swift/issues to solve it.
            """
        case .tooMuchData:
            return "You have supplied too much data for the Request."
        }
    }
}

extension AWSClient {
    /// Record request in swift-metrics, and swift-log
    func recordRequest<Output>(_ future: EventLoopFuture<Output>, service: String, operation: String, context: AWSClient.Context) -> EventLoopFuture<Output> {
        let logger = context.logger

        let dimensions: [(String, String)] = [("aws-service", service), ("aws-operation", operation)]
        let startTime = DispatchTime.now().uptimeNanoseconds

        Counter(label: "aws_requests_total", dimensions: dimensions).increment()
        logger.info("AWS Request")

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
                logger.error("AWSClient error", metadata: [
                    "aws-error-message": "\(error)",
                ])
            }
            throw error
        }
    }
}

// MARK: DefaultContext

// TODO: revisit, see https://github.com/slashmo/gsoc-swift-baggage-context/issues/23

extension AWSClient {
    private struct DefaultContext: AWSClient.Context {
        private let _logger: Logger
        var logger: Logger {
            get {
                self._logger.with(context: self.baggage)
            }
            set {
                // TODO: will not be required in next release, see https://github.com/slashmo/gsoc-swift-baggage-context/pull/31
            }
        }

        var baggage: BaggageContext = .init()

        internal init(logger: Logger, baggage: BaggageContext = .init()) {
            self._logger = logger
            self.baggage = baggage
        }
    }

    private static let loggingDisabled = Logger(label: "AWS-do-not-log", factory: { _ in SwiftLogNoOpLogHandler() })

    public static func emptyContext(logger: Logging.Logger? = nil, baggage: BaggageContext = .init()) -> AWSClient.Context {
        AWSClient.DefaultContext(logger: logger ?? Self.loggingDisabled, baggage: baggage)
    }
}

extension AWSClient.Context {
    // TODO: discuss how to update context baggage
    public func with(baggage: BaggageContext) -> AWSClient.Context {
        var copy = self
        copy.baggage = baggage
        return copy
    }
}

// MARK: RequestMetadata

private extension AWSClient {
    struct RequestMetadata: CustomStringConvertible {
        static let globalRequestID = NIOAtomic<Int>.makeAtomic(value: 0)

        var requestId: Int
        var service: String
        var operation: String

        var description: String {
            "aws-request-id=\(requestId),aws-service=\(service),aws-operation=\(operation)"
        }

        init(operation: String, serviceConfig: AWSServiceConfig, requestId: Int = Self.globalRequestID.add(1)) {
            self.requestId = requestId
            self.service = serviceConfig.service
            self.operation = operation
        }
    }

    enum RequestKey: BaggageContextKey {
        typealias Value = RequestMetadata
        // TODO: the name is not logged as the logger metadata key, check/report/fix
        var name: String { "aws-sdk" }
    }
}

private extension AWSClient.Context {
    mutating func setRequest(_ value: AWSClient.RequestMetadata) {
        baggage[AWSClient.RequestKey.self] = value
    }
}
