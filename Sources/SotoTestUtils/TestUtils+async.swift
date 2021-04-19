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

#if compiler(>=5.5) && $AsyncAwait

import _Concurrency
import Foundation
import Logging
import SotoCore
import XCTest

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
public func XCTRunAsyncAndBlock(_ closure: @escaping () async throws -> Void) {
    let dg = DispatchGroup()
    dg.enter()
    detach {
        do {
            try await closure()
        } catch {
            XCTFail("\(error)")
        }
        dg.leave()
    }
    dg.wait()
}

#endif // compiler(>=5.5) && $AsyncAwait
