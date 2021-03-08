//===------------- PhasedTest.swift - Swift Testing ---------------------===//
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

/// A `PhasedTest` is a type that defines a container for a test of the
/// incremental build.
///
/// An `PhasedTest` is composed of a number of build phases. To define these
/// phases, supply a nested enum named "Phases` with the desired structure.
/// For example,
///
/// ```
/// enum Example: PhasedTest {
///   enum Phases: PhaseState {
///     case first
///     case second
///     case third
///     // ...
///   }
/// }
/// ```
///
/// - seealso: PhaseState
public protocol PhasedTest {
  associatedtype Phases: PhaseState
}

extension PhasedTest {
  /// The top-level function, runs the whole test.
  public static func test(verbose: Bool) throws {
    for withIncrementalImports in TestContext.IncrementalImports.allCases {
      try withTemporaryDirectory { rootDir in
        try Self.execute(in: TestContext(in: rootDir,
                                         incrementalImports: withIncrementalImports,
                                         verbose: verbose))
      }
    }
  }

  /// Run the test with or without incremental imports.
  private static func execute(in context: TestContext) throws {
    XCTAssertNoThrow(
      try localFileSystem.changeCurrentWorkingDirectory(to: context.rootDir))

    let allModuleNames = Set(Phases.allCases.flatMap { $0.expectations.map { $0.module.name } })
    for module in allModuleNames {
      context.createBuildDirectory(for: module)
    }

    for phase in Phases.allCases {
      phase.check(in: context)
    }
  }
}
