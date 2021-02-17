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

import Logging
import NIO
import NIOConcurrencyHelpers
import SotoSignerV4

/// Protocol providing future holding a credential
public protocol CredentialProvider: CustomStringConvertible {
    /// Return credential
    /// - Parameters:
    ///   - eventLoop: EventLoop to run on
    ///   - logger: Logger to use
    func getCredential(on eventLoop: EventLoop, logger: Logger) -> EventLoopFuture<Credential>

    /// Shutdown credential provider
    /// - Parameter eventLoop: EventLoop to use when shutiting down
    func shutdown(on eventLoop: EventLoop) -> EventLoopFuture<Void>
}

extension CredentialProvider {
    public func shutdown(on eventLoop: EventLoop) -> EventLoopFuture<Void> {
        return eventLoop.makeSucceededFuture(())
    }

    public func getCredential(on eventLoop: EventLoop, logger: Logger) async throws -> Credential {
        return try await getCredential(on: eventLoop, logger: logger).get()
    }

    public var description: String { return "\(type(of: self))" }
}

/// A helper struct to defer the creation of a `CredentialProvider` until after the AWSClient has been created.
public struct CredentialProviderFactory {
    /// The initialization context for a `ContextProvider`
    public struct Context {
        /// The `AWSClient`s internal `HTTPClient`
        public let httpClient: AWSHTTPClient
        /// The `EventLoop` that the `CredentialProvider` should use for credential refreshs
        public let eventLoop: EventLoop
        /// The `Logger` attached to the AWSClient
        public let logger: Logger
        /// AWSClient options
        public let options: AWSClient.Options
    }

    private let cb: (Context) -> CredentialProvider

    private init(cb: @escaping (Context) -> CredentialProvider) {
        self.cb = cb
    }

    internal func createProvider(context: Context) -> CredentialProvider {
        self.cb(context)
    }
}

extension CredentialProviderFactory {
    /// The default CredentialProvider used to access credentials
    public static var `default`: CredentialProviderFactory {
        #if os(Linux)
        return .selector(.environment, .ecs, .ec2, .configFile())
        #else
        return .selector(.environment, .configFile())
        #endif
    }

    /// Use this method to initialize your custom `CredentialProvider`
    public static func custom(_ factory: @escaping (Context) -> CredentialProvider) -> CredentialProviderFactory {
        Self(cb: factory)
    }

    /// Use this method to enforce the use of a `CredentialProvider` that uses the environment variables `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` to create the credentials.
    public static var environment: CredentialProviderFactory {
        Self { _ -> CredentialProvider in
            return StaticCredential.fromEnvironment() ?? NullCredentialProvider()
        }
    }

    /// Use this method to enforce the use of a `CredentialProvider` that uses static credentials.
    public static func `static`(accessKeyId: String, secretAccessKey: String, sessionToken: String? = nil) -> CredentialProviderFactory {
        Self { _ in
            StaticCredential(
                accessKeyId: accessKeyId,
                secretAccessKey: secretAccessKey,
                sessionToken: sessionToken
            )
        }
    }

    /// Use this method to enforce the usage of the Credentials supplied via the ECS Metadata endpoint
    public static var ecs: CredentialProviderFactory {
        Self { context in
            if let provider = ECSMetaDataClient(httpClient: context.httpClient) {
                return RotatingCredentialProvider(context: context, provider: provider)
            }

            // fallback
            return NullCredentialProvider()
        }
    }

    /// Use this method to enforce the usage of the Credentials supplied via the EC2 Instance Metadata endpoint
    public static var ec2: CredentialProviderFactory {
        Self { context in
            let provider = InstanceMetaDataClient(httpClient: context.httpClient)
            return RotatingCredentialProvider(context: context, provider: provider)
        }
    }

    /// Use this method to load credentials from your AWS cli credentials and optional profile configuration files, normally located at `~/.aws/credentials` and `~/.aws/config`.
    public static func configFile(
        credentialsFilePath: String = ConfigFile.defaultCredentialsPath,
        configFilePath: String = ConfigFile.defaultProfileConfigPath,
        profile: String? = nil
    ) -> CredentialProviderFactory {
        return Self { context in
            let provider = ConfigFileCredentialProvider(credentialsFilePath: credentialsFilePath, configFilePath: configFilePath, profile: profile, context: context)
            return RotatingCredentialProvider(context: context, provider: provider)
        }
    }

    /// Enforce the use of no credentials.
    public static var empty: CredentialProviderFactory {
        Self { _ in
            StaticCredential(accessKeyId: "", secretAccessKey: "")
        }
    }

    /// Use the list of credential providers supplied to get credentials. The first one in the list that manages to supply credentials is the one to use
    public static func selector(_ providers: CredentialProviderFactory...) -> CredentialProviderFactory {
        Self { context in
            if providers.count == 1 {
                return providers[0].createProvider(context: context)
            } else {
                return RuntimeSelectorCredentialProvider(providers: providers, context: context)
            }
        }
    }
}
