//===--------------- PhaseState.swift - Swift Testing ------------------===//
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

/// A `PhaseState` is a type that defines a number of phases (usually as enum
/// cases) and a set of expectations dependent upon those phases.
///
/// ```
/// enum Example: PhasedTest {
///   enum Phases: String, CaseIterable, PhaseState {
///     case first
///     case second
///     case third
///     // ...
///   }
///
///   var expectations: [Expectation<Self>] {
///     switch self {
///     case .first:
///       return [
///         .building(Module.self).rebuilds(withIncrementalImports: ...,
///                                         withoutIncrementalImports: ...),
///       ]
///      case .second:
///        return // ...
///      case .third:
///        return // ...
///     }
///   }
/// }
/// ```
///
/// - seealso: PhasedModule
public protocol PhaseState: NameableByRawValue, CaseIterable {
  var expectations: [Expectation<Self>] { get }
}

extension PhaseState {
  /// Validate the expectations of this test in the given context, executing
  /// the build as needed.
  func check(in context: TestContext) {
    if context.verbose {
      print("Entering", self.rawValue, "state")
    }

    let jobs = self.updateChangedSources(context)
    assert(jobs.count == expectations.count)
    for (job, expectation) in zip(jobs, self.expectations) {
      let compiledSources = job.run(context)
      expectation.check(against: compiledSources, context, nextStateName: self.rawValue)
    }
  }
}

// MARK: Implementation Details

extension PhaseState {

  /// Bring source files into agreement with desired versions
  private func updateChangedSources(_ context: TestContext) -> [BuildJob] {
    var jobs = [BuildJob]()
    for expectation in self.expectations {
      do {
        try expectation.module.prepareFiles(in: self) { action in
          switch action {
          case let .delete(file):
            try localFileSystem.removeFileTree(context.swiftFilePath(for: file))
          case let .update(file, code: code):
            XCTAssertNoThrow(
              try localFileSystem.writeIfChanged(path: context.swiftFilePath(for: file),
                                                 bytes: ByteString(encodingAsUTF8: code)),
              file: expectation.file, line: expectation.line)
          }
        }
      } catch let e {
        XCTFail("Unexpected exception while preparing files in phase \(self): \(e)",
                file: expectation.file, line: expectation.line)
      }

      jobs.append(BuildJob(module: expectation.module, in: self))
    }
    return jobs
  }
}
