//===---------------- BuildJob.swift - Swift Testing -------------------===//
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

@_spi(Testing) import SwiftDriver
import SwiftOptions
import TestUtilities

/// Everything needed to invoke the driver and build a module.
///
/// - seealso: PhasedTest
struct BuildJob {
  var moduleName: String
  var sources: [String]
  var imports: [Import]
  var product: ModuleProduct

  init<State: TestPhase>(module: Expectation<State>.ProtoModule, in phase: State) {
    self.moduleName = module.name
    self.sources = module.sourceFileNames(in: phase)
    self.imports = module.imports
    self.product = module.product
  }

  /// Returns the basenames without extension of the compiled source files.
  func run(_ context: TestContext) -> [String] {
    writeOFM(context)
    let allArgs = arguments(context)

    var collector = CompiledSourceCollector()
    let handlers = [
        {collector.handle(diagnostic: $0)},
        context.verbose ? Driver.stderrDiagnosticsHandler : nil
    ].compactMap { $0 }
    let diagnosticsEngine = DiagnosticsEngine(handlers: handlers)

    var driver = try! Driver(args: allArgs, diagnosticsEngine: diagnosticsEngine)
    let jobs = try! driver.planBuild()
    try! driver.run(jobs: jobs)

    return collector.compiledSources(context)
  }

  private func writeOFM(_ context: TestContext) {
    OutputFileMapCreator.write(
      module: self.moduleName,
      inputPaths: self.sources.map { context.swiftFilePath(for: $0, in: self.moduleName) },
      derivedData: context.buildRoot(for: self.moduleName),
      to: context.outputFileMapPath(for: self.moduleName))
  }

  func arguments(_ context: TestContext) -> [String] {
    var libraryArgs: [String] {
      [
        "-parse-as-library",
        "-emit-module-path", context.swiftmodulePath(for: self.moduleName).pathString,
      ]
    }

    var appArgs: [String] {
      let swiftModules = self.imports.map {
        context.swiftmodulePath(for: $0.importName).parentDirectory.pathString
      }
      return swiftModules.flatMap { ["-I", $0, "-F", $0] }
    }

    var incrementalImportsArgs: [String] {
      switch context.incrementalImports {
      case .enabled:
        return ["-enable-incremental-imports"]
      case .disabled:
        return ["-disable-incremental-imports"]
      }
    }

    return Array(
    [
      [
        "swiftc",
        "-no-color-diagnostics",
        "-incremental",
        "-driver-show-incremental",
        "-driver-show-job-lifecycle",
        "-c",
        "-module-name", self.moduleName,
        "-output-file-map", context.outputFileMapPath(for: self.moduleName).pathString,
      ],
      incrementalImportsArgs,
      self.product == .library ? libraryArgs : appArgs,
      sources.map { context.swiftFilePath(for: $0, in: self.moduleName).pathString }
    ].joined())
  }
}
