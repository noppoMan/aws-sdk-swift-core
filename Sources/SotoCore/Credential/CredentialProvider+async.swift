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

#if compiler(>=5.5)

import _NIOConcurrency
import Logging
import NIO
import SotoSignerV4

/// Async Protocol for providing credentials
@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
public protocol AsyncCredentialProvider: CredentialProvider {
    /// Return credential
    /// - Parameters:
    ///   - eventLoop: EventLoop to run on
    ///   - logger: Logger to use
    func getCredential(on eventLoop: EventLoop, logger: Logger) async throws -> Credential
}

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
extension AsyncCredentialProvider {
    public func getCredential(on eventLoop: EventLoop, logger: Logger) -> EventLoopFuture<Credential> {
        let promise = eventLoop.makePromise(of: Credential.self)
        promise.completeWithAsync { try await getCredential(on: eventLoop, logger: logger) }
        return promise.futureResult
    }
}

#endif // compiler(>=5.5)
