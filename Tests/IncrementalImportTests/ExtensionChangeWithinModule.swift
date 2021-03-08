//===------ ExtensionChangeWithinModuleTests.swift - Swift Testing --------===//
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
import Phaser

@_spi(Testing) import SwiftDriver
import SwiftOptions

class ExtensionChangeWithinModuleTests: XCTestCase {
  func testExtensionChangeWithinModule() throws {
    try ExtensionChange.test(verbose: false)
  }


  struct ExtensionChange: PhasedTest {
    enum Phases: String, CaseIterable, PhaseState {
      case noFunc, withFunc

      var expectations: [Expectation<Phases>] {
        switch self {
        case .noFunc:
          return [
            .building(Module.self).rebuildsEverything(),
          ]
        case .withFunc:
          return [
            .building(Module.self).rebuilds(withIncrementalImports: .main, .noFunc,
                                            withoutIncrementalImports: .main, .noFunc),
          ]
        }
      }
    }

    enum Module: PhasedModule {
      typealias Phases = ExtensionChange.Phases

      static var name: String { "mainM" }
      static var imports: [String] { return [] }
      static var isLibrary: Bool { false }

      enum Sources: String, NameableByRawValue, CaseIterable {
        case main, noFunc, userOfT, instantiator
      }

      static var sources: [SourceFile<Module>] {
        [
          .named(.main)
            .in(phases: Phases.allCases) {
              """
              struct S {static func foo<I: SignedInteger>(_ si: I) {}}
              S.foo(3)
              """
            },
          .named(.noFunc)
            .in(.noFunc) {
              """
              extension S {}
              struct T {static func foo() {}}
              """
            }
            .in(.withFunc) {
              """
              extension S {static func foo(_ i: Int) {}}
              struct T {static func foo() {}}
              """
            },
          .named(.userOfT)
            .in(phases: Phases.allCases) {
              "func baz() {T.foo()}"
            },
          .named(.instantiator)
            .in(phases: Phases.allCases) {
              "func bar() {_ = S()}"
            },
        ]
      }
    }
  }
}
