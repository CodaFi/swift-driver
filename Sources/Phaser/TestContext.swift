//===-------------- TestContext.swift - Swift Testing ----------- ---------===//
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
import TSCBasic

/// Bundles up (incidental) values to be passed down to the various functions.
/// (See `PhasedTest`.)
struct TestContext: CustomStringConvertible {
  enum IncrementalImports: CaseIterable, Equatable {
    case enabled
    case disabled
  }

  /// The root directory of the test; temporary
  var rootDir: AbsolutePath

  /// Are incremental imports enabled? Tests both ways.
  var incrementalImports: IncrementalImports

  /// Print out much more info to help debug the test
  var verbose: Bool

  init(
    in rootDir: AbsolutePath,
    incrementalImports: IncrementalImports,
    verbose: Bool
  ) {
    self.rootDir = rootDir
    self.incrementalImports = incrementalImports
    self.verbose = verbose
  }

  var description: String {
    "\(incrementalImports == .enabled ? "with" : "without") incremental imports"
  }
}

extension TestContext {
  func createBuildDirectory(for module: String) {
    try! localFileSystem.createDirectory(self.buildRoot(for: module))
  }
}

extension TestContext {
  func buildRoot(for module: String) -> AbsolutePath {
    self.rootDir.appending(component: "\(module)DD")
  }

  func outputFileMapPath(for module: String) -> AbsolutePath {
    self.buildRoot(for: module).appending(component: "OFM")
  }

  func swiftmodulePath(for module: String) -> AbsolutePath {
    self.buildRoot(for: module).appending(component: "\(module).swiftmodule")
  }

  func swiftFilePath(for name: String) -> AbsolutePath {
    self.rootDir.appending(component: "\(name).swift")
  }
}
