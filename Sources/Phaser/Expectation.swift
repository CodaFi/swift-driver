//===------------------- Expectation.swift - Swift Testing ----------------===//
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

/// What is supposed to be recompiled when taking a step.
///
/// - seealso: PhasedTest
public struct Expectation<Phases: TestPhase> {
  let module: ProtoModule

  /// Expected when incremental imports are enabled
  private let withIncrementalImports: [String]

  // Expected when incremental imports are disabled
  private let withoutIncrementalImports: [String]

  let file: StaticString
  let line: UInt

  fileprivate init(
    module: String,
    sourceGenerator: @escaping (Phases) -> [(String, String?)],
    imports: [String],
    product: PhasedModuleProduct,
    with: [String], without: [String],
    file: StaticString,
    line: UInt
  ) {
    self.module = ProtoModule(name: module,
                            sourceGenerator: sourceGenerator,
                            imports: imports,
                            product: product)
    self.withIncrementalImports = with
    self.withoutIncrementalImports = without
    self.file = file
    self.line = line
  }

  public static func building<Module: PhasedModule>(_ module: Module.Type) -> ModuleExpectation<Module>
    where Module.Phases == Phases
  {
    return ModuleExpectation(name: module.name, sourceGenerator: { phase in
      module.sources(in: phase).map { ($0.fileName, $0.code(for: phase)) }
    })
  }

  /// Return the appropriate expectation
  private func when(in context: TestContext) -> [String] {
    switch context.incrementalImports {
    case .enabled:
      return self.withIncrementalImports
    case .disabled:
      return self.withoutIncrementalImports
    }
  }

  /// Check actuals against expectations
  func check(against actuals: [String], _ context: TestContext, nextStateName: String) {
    let expected = when(in: context)
    let expectedSet = Set(expected)
    let actualsSet = Set(actuals)

    let extraCompilations = actualsSet.subtracting(expectedSet)
    let missingCompilations = expectedSet.subtracting(actualsSet)

    XCTAssert(extraCompilations.isEmpty,
      "Extra compilations: \(extraCompilations), \(context), in state: \(nextStateName)",
      file: self.file, line: self.line)

    XCTAssert(missingCompilations.isEmpty,
      "Missing compilations: \(missingCompilations), \(context), in state: \(nextStateName)",
      file: self.file, line: self.line)
  }
}

extension Expectation {
  struct ProtoModule {
    let name: String
    let sourceGenerator: (Phases) -> [(String, String?)]
    let imports: [String]
    let product: PhasedModuleProduct
  }
}

extension Expectation.ProtoModule {
  enum FileAction {
    case delete(String)
    case update(String, code: String)
  }

  func prepareFiles(in phase: Phases, _ apply: (FileAction) throws -> Void) rethrows {
    for (file, maybeCode) in self.sourceGenerator(phase) {
      if let code = maybeCode {
        try apply(.update(file, code: code))
      } else {
        try apply(.delete(file))
      }
    }
  }

  func sourceFileNames(in state: Phases) -> [String] {
    self.sourceGenerator(state).map { $0.0 }
  }
}

public struct ModuleExpectation<Module: PhasedModule> {
  public let name: String
  public let sourceGenerator: (Module.Phases) -> [(String, String?)]

  /// Returns an expectation that succeeds when every file in the module
  /// rebuilds, and fails when any file in the module is skipped.
  ///
  /// This expectation is often useful for the initial phase and for any
  /// transitions that invalidate entire modules, such as when the incremental
  /// imports are disabled.
  public func rebuildsEverything(
    file: StaticString = #file,
    line: UInt = #line
  ) -> Expectation<Module.Phases> {
    return .init(module: self.name,
                 sourceGenerator: self.sourceGenerator,
                 imports: Module.imports,
                 product: Module.product,
                 with: Module.sources.map { $0.fileName },
                 without: Module.sources.map { $0.fileName },
                 file: file,
                 line: line)
  }

  /// Returns an expectation that succeeds when every file in the module is
  /// skipped, and fails when any file in the module builds.
  ///
  /// This expectation is often useful for same-state transitions.
  public func rebuildsNothing(
    file: StaticString = #file,
    line: UInt = #line
  ) -> Expectation<Module.Phases> {
    return .init(module: self.name,
                 sourceGenerator: self.sourceGenerator,
                 imports: Module.imports,
                 product: Module.product,
                 with: [],
                 without: [],
                 file: file,
                 line: line)
  }

  /// Returns an expectation that succeeds when the given files rebuild, and
  /// fails if the actual module build contains files that are outside of the
  /// given set of sources.
  ///
  /// The order and uniqueness of sources is not important.
  public func rebuilds(
    withIncrementalImports: Module.Sources...,
    withoutIncrementalImports: Module.Sources...,
    file: StaticString = #file,
    line: UInt = #line
  ) -> Expectation<Module.Phases> {
    return self.rebuilds(withIncrementalImports: withIncrementalImports,
                         withoutIncrementalImports: withoutIncrementalImports,
                         file: file, line: line)
  }

  /// Returns an expectation that succeeds when the given files rebuild, and
  /// fails if the actual module build contains files that are outside of the
  /// given set of sources.
  ///
  /// The order and uniqueness of sources is not important.
  public func rebuilds(
    withIncrementalImports: [Module.Sources],
    withoutIncrementalImports: [Module.Sources],
    file: StaticString = #file,
    line: UInt = #line
  ) -> Expectation<Module.Phases> {
    return .init(module: self.name,
                 sourceGenerator: self.sourceGenerator,
                 imports: Module.imports,
                 product: Module.product,
                 with: withIncrementalImports.map { $0.rawValue },
                 without: withoutIncrementalImports.map { $0.rawValue },
                 file: file,
                 line: line)
  }
}
