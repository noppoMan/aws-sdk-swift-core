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

// THIS FILE IS AUTOMATICALLY GENERATED by https://github.com/swift-aws/aws-sdk-swift-core/scripts/generate-errors.swift. DO NOT EDIT.

public struct AWSServerError: AWSErrorType {
    enum Code: String {
        case internalFailure = "InternalFailure"
        case serviceUnavailable = "ServiceUnavailable"
    }
    private var error: Code
    public var message: String?

    public init?(errorCode: String, message: String?) {
        var errorCode = errorCode
        // remove "Exception" suffix
        if errorCode.hasSuffix("Exception") {
            errorCode = String(errorCode.dropLast(9))
        }
        guard let error = Code(rawValue: errorCode) else { return nil }
        self.error = error
        self.message = message
    }
    
    internal init(_ error: Code, message: String? = nil) {
        self.error = error
        self.message = message
    }

    // The request processing has failed because of an unknown error, exception or failure.
    public static var internalFailure:AWSServerError { .init(.internalFailure) }
    // The request has failed due to a temporary failure of the server.
    public static var serviceUnavailable:AWSServerError { .init(.serviceUnavailable) }
}

extension AWSServerError: Equatable {
    public static func == (lhs: AWSServerError, rhs: AWSServerError) -> Bool {
        lhs.error == rhs.error
    }
}

extension AWSServerError : CustomStringConvertible {
    public var description: String {
        return "\(error.rawValue): \(message ?? "")"
    }
}
