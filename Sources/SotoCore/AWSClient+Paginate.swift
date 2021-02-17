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

import Logging
import NIO

// MARK: Pagination

/// protocol for all AWSShapes that can be paginated.
/// Adds an initialiser that does a copy but inserts a new integer based pagination token
public protocol AWSPaginateToken: AWSShape {
    associatedtype Token
    func usingPaginationToken(_ token: Token) -> Self
}


extension AWSClient {
    /// If an AWS command is returning an arbituary sized array sometimes it adds support for paginating this array
    /// ie it will return the array in blocks of a defined size, each block also includes a token which can be used to access
    /// the next block. This function loads each block and calls a closure with each block as parameter. This function returns
    /// the result of combining all of these blocks using the given closure,
    ///
    /// - Parameters:
    ///   - input: Input for request
    ///   - initialValue: The value to use as the initial accumulating value. `initialValue` is passed to `onPage` the first time it is called.
    ///   - command: Command to be paginated
    ///   - inputKey: The name of token in the request object to continue pagination
    ///   - outputKey: The name of token in the response object to continue pagination
    ///   - eventLoop: EventLoop to run this process on
    ///   - logger: Logger used for logging
    ///   - onPage: closure called with each block of entries. It combines an accumulating result with the contents of response from the call to AWS. This combined result is then returned
    ///         along with a boolean indicating if the paginate operation should continue.
    public func paginate<Input: AWSPaginateToken, Output: AWSShape, Result>(
        input: Input,
        initialValue: Result,
        command: @escaping (Input, Logger, EventLoop?) -> EventLoopFuture<Output>,
        inputKey: KeyPath<Input, Input.Token?>,
        outputKey: KeyPath<Output, Input.Token?>,
        logger: Logger = AWSClient.loggingDisabled,
        on eventLoop: EventLoop? = nil,
        onPage: @escaping (Result, Output, EventLoop) -> EventLoopFuture<(Bool, Result)>
    ) -> EventLoopFuture<Result> where Input.Token: Equatable {
        let eventLoop = eventLoop ?? eventLoopGroup.next()
        let promise = eventLoop.makePromise(of: Result.self)

        func paginatePart(input: Input, currentValue: Result) {
            let responseFuture = command(input, logger, eventLoop)
                .flatMap { response in
                    return onPage(currentValue, response, eventLoop)
                        .map { continuePaginate, result -> Void in
                            guard continuePaginate == true else { return promise.succeed(result) }
                            // get next block token and construct a new input with this token
                            guard let outputToken = response[keyPath: outputKey] else { return promise.succeed(result) }
                            // if output token is still the same as the input token then exit with success
                            guard outputToken != input[keyPath: inputKey] else { return promise.succeed(result) }

                            let input = input.usingPaginationToken(outputToken)
                            paginatePart(input: input, currentValue: result)
                        }
                }
            responseFuture.whenFailure { error in
                promise.fail(error)
            }
        }

        paginatePart(input: input, currentValue: initialValue)

        return promise.futureResult
    }

    /// If an AWS command is returning an arbituary sized array sometimes it adds support for paginating this array
    /// ie it will return the array in blocks of a defined size, each block also includes a token which can be used to access
    /// the next block. This function loads each block and calls a closure with each block as parameter.
    ///
    /// - Parameters:
    ///   - input: Input for request
    ///   - command: Command to be paginated
    ///   - inputKey: The name of token in the request object to continue pagination
    ///   - outputKey: The name of token in the response object to continue pagination
    ///   - eventLoop: EventLoop to run this process on
    ///   - logger: Logger used for logging
    ///   - onPage: closure called with each block of entries. Returns boolean indicating whether we should continue.
    public func paginate<Input: AWSPaginateToken, Output: AWSShape>(
        input: Input,
        command: @escaping (Input, Logger, EventLoop?) -> EventLoopFuture<Output>,
        inputKey: KeyPath<Input, Input.Token?>,
        outputKey: KeyPath<Output, Input.Token?>,
        logger: Logger = AWSClient.loggingDisabled,
        on eventLoop: EventLoop? = nil,
        onPage: @escaping (Output, EventLoop) -> EventLoopFuture<Bool>
    ) -> EventLoopFuture<Void> where Input.Token: Equatable {
        self.paginate(input: input, initialValue: (), command: command, inputKey: inputKey, outputKey: outputKey, logger: logger, on: eventLoop) { _, output, eventLoop in
            return onPage(output, eventLoop).map { rt in (rt, ()) }
        }
    }

    /// If an AWS command is returning an arbituary sized array sometimes it adds support for paginating this array
    /// ie it will return the array in blocks of a defined size, each block also includes a token which can be used to access
    /// the next block. This function loads each block and calls a closure with each block as parameter. This function returns
    /// the result of combining all of these blocks using the given closure,
    ///
    /// - Parameters:
    ///   - input: Input for request
    ///   - initialValue: The value to use as the initial accumulating value. `initialValue` is passed to `onPage` the first time it is called.
    ///   - command: Command to be paginated
    ///   - tokenKey: The name of token in the response object to continue pagination
    ///   - eventLoop: EventLoop to run this process on
    ///   - logger: Logger used for logging
    ///   - onPage: closure called with each block of entries. It combines an accumulating result with the contents of response from the call to AWS. This combined result is then returned
    ///         along with a boolean indicating if the paginate operation should continue.
    public func paginate<Input: AWSPaginateToken, Output: AWSShape, Result>(
        input: Input,
        initialValue: Result,
        command: @escaping (Input, Logger, EventLoop?) -> EventLoopFuture<Output>,
        tokenKey: KeyPath<Output, Input.Token?>,
        logger: Logger = AWSClient.loggingDisabled,
        on eventLoop: EventLoop? = nil,
        onPage: @escaping (Result, Output, EventLoop) -> EventLoopFuture<(Bool, Result)>
    ) -> EventLoopFuture<Result> {
        let eventLoop = eventLoop ?? eventLoopGroup.next()
        let promise = eventLoop.makePromise(of: Result.self)

        func paginatePart(input: Input, currentValue: Result) {
            let responseFuture = command(input, logger, eventLoop)
                .flatMap { response in
                    return onPage(currentValue, response, eventLoop)
                        .map { continuePaginate, result -> Void in
                            guard continuePaginate == true else { return promise.succeed(result) }
                            // get next block token and construct a new input with this token
                            guard let token = response[keyPath: tokenKey] else { return promise.succeed(result) }

                            let input = input.usingPaginationToken(token)
                            paginatePart(input: input, currentValue: result)
                        }
                }
            responseFuture.whenFailure { error in
                promise.fail(error)
            }
        }

        paginatePart(input: input, currentValue: initialValue)

        return promise.futureResult
    }

    /// If an AWS command is returning an arbituary sized array sometimes it adds support for paginating this array
    /// ie it will return the array in blocks of a defined size, each block also includes a token which can be used to access
    /// the next block. This function loads each block and calls a closure with each block as parameter.
    ///
    /// - Parameters:
    ///   - input: Input for request
    ///   - command: Command to be paginated
    ///   - tokenKey: The name of token in the response object to continue pagination
    ///   - eventLoop: EventLoop to run this process on
    ///   - logger: Logger used for logging
    ///   - onPage: closure called with each block of entries. Returns boolean indicating whether we should continue.
    public func paginate<Input: AWSPaginateToken, Output: AWSShape>(
        input: Input,
        command: @escaping (Input, Logger, EventLoop?) -> EventLoopFuture<Output>,
        tokenKey: KeyPath<Output, Input.Token?>,
        logger: Logger = AWSClient.loggingDisabled,
        on eventLoop: EventLoop? = nil,
        onPage: @escaping (Output, EventLoop) -> EventLoopFuture<Bool>
    ) -> EventLoopFuture<Void> {
        self.paginate(input: input, initialValue: (), command: command, tokenKey: tokenKey, logger: logger, on: eventLoop) { _, output, eventLoop in
            return onPage(output, eventLoop).map { rt in (rt, ()) }
        }
    }

    /// If an AWS command is returning an arbituary sized array sometimes it adds support for paginating this array
    /// ie it will return the array in blocks of a defined size, each block also includes a token which can be used to access
    /// the next block. This function loads each block and calls a closure with each block as parameter. This function returns
    /// the result of combining all of these blocks using the given closure,
    ///
    /// - Parameters:
    ///   - input: Input for request
    ///   - initialValue: The value to use as the initial accumulating value. `initialValue` is passed to `onPage` the first time it is called.
    ///   - command: Command to be paginated
    ///   - tokenKey: The name of token in the response object to continue pagination
    ///   - moreResultsKey: The KeyPath for the member of the output that indicates whether we should ask for more data
    ///   - eventLoop: EventLoop to run this process on
    ///   - logger: Logger used for logging
    ///   - onPage: closure called with each block of entries. It combines an accumulating result with the contents of response from the call to AWS. This combined result is then returned
    ///         along with a boolean indicating if the paginate operation should continue.
    public func paginate<Input: AWSPaginateToken, Output: AWSShape, Result>(
        input: Input,
        initialValue: Result,
        command: @escaping (Input, Logger, EventLoop?) -> EventLoopFuture<Output>,
        tokenKey: KeyPath<Output, Input.Token?>,
        moreResultsKey: KeyPath<Output, Bool?>,
        logger: Logger = AWSClient.loggingDisabled,
        on eventLoop: EventLoop? = nil,
        onPage: @escaping (Result, Output, EventLoop) -> EventLoopFuture<(Bool, Result)>
    ) -> EventLoopFuture<Result> {
        let eventLoop = eventLoop ?? eventLoopGroup.next()
        let promise = eventLoop.makePromise(of: Result.self)

        func paginatePart(input: Input, currentValue: Result) {
            let responseFuture = command(input, logger, eventLoop)
                .flatMap { response in
                    return onPage(currentValue, response, eventLoop)
                        .map { continuePaginate, result -> Void in
                            guard continuePaginate == true else { return promise.succeed(result) }
                            // get next block token and construct a new input with this token
                            guard let token = response[keyPath: tokenKey],
                                  response[keyPath: moreResultsKey] == true else { return promise.succeed(result) }

                            let input = input.usingPaginationToken(token)
                            paginatePart(input: input, currentValue: result)
                        }
                }
            responseFuture.whenFailure { error in
                promise.fail(error)
            }
        }

        paginatePart(input: input, currentValue: initialValue)

        return promise.futureResult
    }

    /// If an AWS command is returning an arbituary sized array sometimes it adds support for paginating this array
    /// ie it will return the array in blocks of a defined size, each block also includes a token which can be used to access
    /// the next block. This function loads each block and calls a closure with each block as parameter.
    ///
    /// - Parameters:
    ///   - input: Input for request
    ///   - command: Command to be paginated
    ///   - tokenKey: The name of token in the response object to continue pagination
    ///   - moreResultsKey: The KeyPath for the member of the output that indicates whether we should ask for more data
    ///   - eventLoop: EventLoop to run this process on
    ///   - logger: Logger used for logging
    ///   - onPage: closure called with each block of entries. Returns boolean indicating whether we should continue.
    public func paginate<Input: AWSPaginateToken, Output: AWSShape>(
        input: Input,
        command: @escaping (Input, Logger, EventLoop?) -> EventLoopFuture<Output>,
        tokenKey: KeyPath<Output, Input.Token?>,
        moreResultsKey: KeyPath<Output, Bool?>,
        logger: Logger = AWSClient.loggingDisabled,
        on eventLoop: EventLoop? = nil,
        onPage: @escaping (Output, EventLoop) -> EventLoopFuture<Bool>
    ) -> EventLoopFuture<Void> {
        self.paginate(input: input, initialValue: (), command: command, tokenKey: tokenKey, moreResultsKey: moreResultsKey, logger: logger, on: eventLoop) { _, output, eventLoop in
            return onPage(output, eventLoop).map { rt in (rt, ()) }
        }
    }

    /// If an AWS command is returning an arbituary sized array sometimes it adds support for paginating this array
    /// ie it will return the array in blocks of a defined size, each block also includes a token which can be used to access
    /// the next block. This function loads each block and calls a closure with each block as parameter. This function returns
    /// the result of combining all of these blocks using the given closure,
    ///
    /// - Parameters:
    ///   - input: Input for request
    ///   - initialValue: The value to use as the initial accumulating value. `initialValue` is passed to `onPage` the first time it is called.
    ///   - command: Command to be paginated
    ///   - tokenKey: The name of token in the response object to continue pagination
    ///   - moreResultsKey: The KeyPath for the member of the output that indicates whether we should ask for more data
    ///   - eventLoop: EventLoop to run this process on
    ///   - logger: Logger used for logging
    ///   - onPage: closure called with each block of entries. It combines an accumulating result with the contents of response from the call to AWS. This combined result is then returned
    ///         along with a boolean indicating if the paginate operation should continue.
    @available(*, deprecated, message: "Deprecated this version of paginate in favour of version that includes the inputKey")
    public func paginate<Input: AWSPaginateToken, Output: AWSShape, Result>(
        input: Input,
        initialValue: Result,
        command: @escaping (Input, Logger, EventLoop?) -> EventLoopFuture<Output>,
        tokenKey: KeyPath<Output, Input.Token?>,
        moreResultsKey: KeyPath<Output, Bool>,
        logger: Logger = AWSClient.loggingDisabled,
        on eventLoop: EventLoop? = nil,
        onPage: @escaping (Result, Output, EventLoop) -> EventLoopFuture<(Bool, Result)>
    ) -> EventLoopFuture<Result> {
        let eventLoop = eventLoop ?? eventLoopGroup.next()
        let promise = eventLoop.makePromise(of: Result.self)

        func paginatePart(input: Input, currentValue: Result) {
            let responseFuture = command(input, logger, eventLoop)
                .flatMap { response in
                    return onPage(currentValue, response, eventLoop)
                        .map { continuePaginate, result -> Void in
                            guard continuePaginate == true else { return promise.succeed(result) }
                            // get next block token and construct a new input with this token
                            guard let token = response[keyPath: tokenKey],
                                  response[keyPath: moreResultsKey] else { return promise.succeed(result) }

                            let input = input.usingPaginationToken(token)
                            paginatePart(input: input, currentValue: result)
                        }
                }
            responseFuture.whenFailure { error in
                promise.fail(error)
            }
        }

        paginatePart(input: input, currentValue: initialValue)

        return promise.futureResult
    }

    /// If an AWS command is returning an arbituary sized array sometimes it adds support for paginating this array
    /// ie it will return the array in blocks of a defined size, each block also includes a token which can be used to access
    /// the next block. This function loads each block and calls a closure with each block as parameter.
    ///
    /// - Parameters:
    ///   - input: Input for request
    ///   - command: Command to be paginated
    ///   - tokenKey: The name of token in the response object to continue pagination
    ///   - moreResultsKey: The KeyPath for the member of the output that indicates whether we should ask for more data
    ///   - eventLoop: EventLoop to run this process on
    ///   - logger: Logger used for logging
    ///   - onPage: closure called with each block of entries. Returns boolean indicating whether we should continue.
    @available(*, deprecated, message: "Deprecated this version of paginate in favour of version that includes the inputKey")
    public func paginate<Input: AWSPaginateToken, Output: AWSShape>(
        input: Input,
        command: @escaping (Input, Logger, EventLoop?) -> EventLoopFuture<Output>,
        tokenKey: KeyPath<Output, Input.Token?>,
        moreResultsKey: KeyPath<Output, Bool>,
        logger: Logger = AWSClient.loggingDisabled,
        on eventLoop: EventLoop? = nil,
        onPage: @escaping (Output, EventLoop) -> EventLoopFuture<Bool>
    ) -> EventLoopFuture<Void> {
        self.paginate(input: input, initialValue: (), command: command, tokenKey: tokenKey, moreResultsKey: moreResultsKey, logger: logger, on: eventLoop) { _, output, eventLoop in
            return onPage(output, eventLoop).map { rt in (rt, ()) }
        }
    }
}
