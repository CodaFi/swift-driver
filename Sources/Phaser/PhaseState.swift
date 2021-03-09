//===--------------- TestPhase.swift - Swift Testing ----------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
import XCTest
import TSCBasic

@_spi(Testing) import SwiftDriver
import SwiftOptions
import TestUtilities

/// A `TestPhase` is a type that defines a number of phases (usually as enum
/// cases) and a set of expectations dependent upon those phases.
///
/// ```
/// enum Example: PhasedTest {
///   enum Phases: String, CaseIterable, TestPhase {
///     case first
///     case second
///     case third
///     // ...
///   }
/// }
/// ```
///
/// - seealso: PhasedModule
public protocol TestPhase: NameableByRawValue, CaseIterable {}
