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
///
/// - seealso: PhasedTest
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

// MARK: Build Directories

extension TestContext {
  func createBuildDirectories(for module: String) {
    try! localFileSystem.createDirectory(self.buildRoot(for: module))
    try! localFileSystem.createDirectory(self.sourceRoot(for: module))
  }
}

extension TestContext {
  /// Computes the directory containing the given module's build products.
  ///
  /// - Parameter module: The name of the module.
  /// - Returns: An absolute path to the build root - relative to the root
  ///            directory of this test context.
  func buildRoot(for module: String) -> AbsolutePath {
    self.rootDir.appending(component: "\(module)-buildroot")
  }

  /// Computes the directory containing the given module's source files.
  ///
  /// - Parameter module: The name of the module.
  /// - Returns: An absolute path to the build root - relative to the root
  ///            directory of this test context.
  func sourceRoot(for module: String) -> AbsolutePath {
    self.rootDir.appending(component: "\(module)-srcroot")
  }

  /// Computes the path to the output file map for the given module.
  ///
  /// - Parameter module: The name of the module.
  /// - Returns: An absolute path to the output file map - relative to the root
  ///            directory of this test context.
  func outputFileMapPath(for module: String) -> AbsolutePath {
    self.buildRoot(for: module).appending(component: "OFM")
  }

  /// Computes the path to the `.swiftmodule` file for the given module.
  ///
  /// - Parameter module: The name of the module.
  /// - Returns: An absolute path to the swiftmodule file - relative to the root
  ///            directory of this test context.
  func swiftmodulePath(for module: String) -> AbsolutePath {
    self.buildRoot(for: module).appending(component: "\(module).swiftmodule")
  }

  /// Computes the path to the `.swift` file for the given module.
  ///
  /// - Parameter name: The name of the swift file.
  /// - Parameter module: The name of the module.
  /// - Returns: An absolute path to the swift file - relative to the root
  ///            directory of this test context.
  func swiftFilePath(for name: String, in module: String) -> AbsolutePath {
    self.sourceRoot(for: module).appending(component: "\(name).swift")
  }
}
