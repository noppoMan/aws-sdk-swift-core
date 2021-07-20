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

#if compiler(>=5.5)

import _Concurrency
import _NIOConcurrency
import Logging
import NIO

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
extension AWSClient {}

#endif // compiler(>=5.5)
