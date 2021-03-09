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
/// A `PhasedTest` is composed of a number of build phases. To define these
/// phases, supply a nested enum named `Phases` with the desired structure. Then,
/// define the desired transition system by providing the initial state and
/// a function that yields an expectation for each combination of transitions.
///
/// For example,
///
/// ```
/// enum Example: PhasedTest {
///   enum Phases: TestPhase {
///     case first
///     case second
///     case third
///     // ...
///   }
///
///   static var initial: FirstPhase<Phases> {
///     FirstPhase(phase: .first, expectations: [
///       .building(Module.self).rebuildsNothing()
///     ])
///   }
///
///   static func testTransition(from: Phases, to: Phases) -> [Expectation<Phases>] {
///     switch (from, to) {
///     case (.first, .first), (.second, .second), (.third, .third):
///        // Use an empty array to skip a particular phase transition
///        return []
///      case (.first, .second), (.second, .first):
///        return [ .building(Module.self).rebuildsNothing() ]
///      // ...
///     }
///   }
/// }
/// ```
///
/// `PhasedTest.test(verbose:)` can then be used to connect the phased test to
/// the ambient test harness. `Phaser` will attempt to test every pair of
/// transitions in the system, and will automatically divine and execute a
/// build plan from the expectations in the system.
///
/// - seealso: TestPhase
public protocol PhasedTest {
  associatedtype Phases: TestPhase
  associatedtype Transitioner: Sequence where Transitioner.Element == Phases

  /// Retrieves the initial expectations for the test.
  static func setup() -> [Expectation<Phases>]

  /// A function that computes the expected outcome after a transition from
  /// the given `from` phase to the given `to ` phase.
  ///
  /// If a transition has no meaningful content, return the empty array to skip
  /// the execution of the build.
  static func testTransition(from: Phases, to: Phases) -> [Expectation<Phases>]

  /// A type that yields a sequence of transitions that the test runner uses
  /// to generate test cases.
  ///
  /// The framework provides a `DefaultTransitioner` that explores the entire
  /// phase space pair-wise. This may be undesirable in case a test needs to
  /// repeat some sequence of phase transitions.
  static var transitioner: Transitioner { get }
}

public struct DefaultTransitioner<Phases: TestPhase>: Sequence {
  private let contents: [Phases]

  init() {
    var contents = [Phases]()
    for from in Phases.allCases {
      for to in Phases.allCases {
        contents.append(contentsOf: [from, to])
      }
    }
    self.contents = contents
  }

  public func makeIterator() -> Array<Phases>.Iterator {
    return contents.makeIterator()
  }
}

extension PhasedTest {
  public static var transitioner: DefaultTransitioner<Phases> {
    return DefaultTransitioner<Phases>()
  }
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

    var iterator = Self.transitioner.makeIterator()
    guard var from = iterator.next() else {
      fatalError("Transitioner did not yield a first phase")
    }

    let initial = Self.setup()
    if context.verbose {
      print("Setting up in state", from)
    }

    for module in initial.map({ $0.module.name }) {
      context.createBuildDirectories(for: module)
    }

    Self.check(initial, in: context,
               from: from, to: from,
               initial: true)

    while let to = iterator.next() {
      defer { from = to }

      if context.verbose {
        print("Transitioning from", from, "to", to)
      }
      let expectations = self.testTransition(from: from, to: to)
      guard !expectations.isEmpty else {
        continue
      }
      Self.check(expectations, in: context,
                 from: from, to: to,
                 initial: false)
    }
  }
}

// MARK: Implementation Details

extension PhasedTest {
  /// Validate the expectations of this test in the given context, executing
  /// the build as needed.
  private static func check(
    _ expectations: [Expectation<Self.Phases>],
    in context: TestContext,
    from: Phases,
    to: Phases,
    initial: Bool
  ) {
    let jobs = self.updateChangedSources(expectations, in: context,
                                         from: from, to: to, initial: initial)
    assert(jobs.count == expectations.count)
    for (job, expectation) in zip(jobs, expectations) {
      let compiledSources = job.run(context)
      expectation.check(against: compiledSources, context, nextStateName: to.rawValue)
    }
  }
}

extension PhasedTest {
  /// Bring source files into agreement with desired versions
  private static func updateChangedSources(
    _ expectations: [Expectation<Phases>],
    in context: TestContext,
    from: Phases,
    to: Phases,
    initial: Bool
  ) -> [BuildJob] {
    var jobs = [BuildJob]()
    for expectation in expectations {
      jobs.append(BuildJob(module: expectation.module, in: to))

      // Always execute the initial build. But if we're transitioning between
      // the same states, it is useful not to touch anything so we can allow
      // clients to assert that nothing has changed.
      guard initial || from != to else {
        continue
      }
      
      do {
        try expectation.module.prepareFiles(in: to) { action in
          switch action {
          case let .delete(file):
            try localFileSystem.removeFileTree(context.swiftFilePath(for: file, in: expectation.module.name))
          case let .update(file, code: code):
            XCTAssertNoThrow(
              try localFileSystem.writeIfChanged(path: context.swiftFilePath(for: file, in: expectation.module.name),
                                                 bytes: ByteString(encodingAsUTF8: code)),
              file: expectation.file, line: expectation.line)
          }
        }
      } catch let e {
        XCTFail("Unexpected exception while preparing files in phase \(self): \(e)",
                file: expectation.file, line: expectation.line)
      }
    }
    return jobs
  }
}
