//===-------------- ClassExtensionTest.swift - Swift Testing --------------===//
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

import Phaser

/// Shows that adding a class method in an extension in a submodule causes the user importing the class
/// to get recompiled, but not for a struct.
class ClassExtensionTest: XCTestCase {
  func testClassExtension() throws {
    try Test.test(verbose: false)
  }

  struct Test: PhasedTest {
    enum Phases: String, CaseIterable, TestPhase {
      case withFunc
      case withoutFunc
    }

    static var transitioner: [Phases] {
      [
        .withFunc,
        .withoutFunc,
        .withFunc,
        .withoutFunc,
      ]
    }

    static func setup() -> [Expectation<Phases>] {
      [
        .building(ImportedModule.self).rebuildsEverything(),
        .building(MainModule.self).rebuildsEverything(),
      ]
    }

    static func testTransition(from: Phases, to: Phases) -> [Expectation<Phases>] {
      switch (from, to) {
      case (.withFunc, .withFunc), (.withoutFunc, .withoutFunc):
        return [
          .building(ImportedModule.self).rebuildsNothing(),
          .building(MainModule.self).rebuildsNothing(),
        ]
      case (.withFunc, .withoutFunc), (.withoutFunc, .withFunc):
        return [
          .building(ImportedModule.self).rebuilds(withIncrementalImports: .structExtension, .classExtension,
                                                  withoutIncrementalImports: .structExtension, .classExtension),
          .building(MainModule.self).rebuilds(withoutIncrementalImports: .structUser, .classUser),
        ]
      }
    }

    enum MainModule: PhasedModule {
      typealias Phases = Test.Phases

      static var name: String { "main" }

      static var imports: [Import] {
        return [ Import(ImportedModule.self) ]
      }

      static var product: ModuleProduct { .executable }

      enum Sources: String, NameableByRawValue, CaseIterable {
        case structUser, classUser
      }

      static var sources: [SourceFile<Self>] {
        [
          .named(.structUser)
            .in(phases: Phases.allCases) {
              "import \(ImportedModule.name); func su() {_ = S()}"
            },
          .named(.classUser)
            .in(phases: Phases.allCases) {
              "import \(ImportedModule.name); func cu() {_ = C()}"
            },
        ]
      }
    }

    enum ImportedModule: PhasedModule {
      typealias Phases = Test.Phases

      static var name: String { "imported" }
      static var imports: [Import] {
        return []
      }
      static var product: ModuleProduct { .library }

      enum Sources: String, NameableByRawValue, CaseIterable {
        case definer, structExtension, classExtension
      }

      static var sources: [SourceFile<Self>] {
        [
          .named(.definer)
            .in(phases: Phases.allCases) {
              """
              open class C {public init() {}}
              public struct S {public init() {}}
              """
            },
          .named(.structExtension)
            .in(.withFunc) {
              "public extension S { func foo() {} }"
            }
            .in(.withoutFunc) {
              "public extension S {}"
            },
          .named(.classExtension)
            .in(.withFunc) {
              "public extension C { func foo() {} }"
            }
            .in(.withoutFunc) {
              "public extension C {}"
            }
        ]
      }
    }
  }
}

