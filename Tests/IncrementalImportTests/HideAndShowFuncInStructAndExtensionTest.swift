//===-- HideAndShowFuncInStructAndExtensionTests.swift - Swift Testing ----===//
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

class HideAndShowFuncInStructAndExtensionTests: XCTestCase {
  func testHideAndShowFuncInStruct() throws {
    try HideAndShowFuncInStruct.test(verbose: false)
  }
  func testHideAndShowFuncInExtension() throws {
    try HideAndShowFuncInExtension.test(verbose: false)
  }

  struct HideAndShowFuncInStruct: PhasedTest {
    typealias Phases = HideAndShowFuncInStructAndExtensionTests.Phases
  }

  struct HideAndShowFuncInExtension: PhasedTest {
    typealias Phases = HideAndShowFuncInStructAndExtensionTests.Phases
  }

  enum Phases: String, CaseIterable, PhaseState {
    case bothHidden
    case shownInStruct
    case shownInExtension
    case bothShown

    var expectations: [Expectation<Self>] {
      switch self {
      case .bothHidden:
        return [
          .building(ImportedModule.self).rebuildsEverything(),
          .building(MainModule.self).rebuildsEverything(),
        ]
      case .shownInStruct:
        return [
          .building(ImportedModule.self).rebuildsEverything(),
          .building(MainModule.self).rebuilds(withIncrementalImports: .main, .callsFuncInExtension, .instantiatesS,
                                              withoutIncrementalImports: .main, .noUseOfS, .callsFuncInExtension, .instantiatesS),
        ]
      case .shownInExtension:
        return [
          .building(ImportedModule.self).rebuildsEverything(),
          .building(MainModule.self).rebuilds(withIncrementalImports: .main, .callsFuncInExtension, .instantiatesS,
                                              withoutIncrementalImports: .main, .noUseOfS, .callsFuncInExtension, .instantiatesS),
        ]
      case .bothShown:
        return [
          .building(ImportedModule.self).rebuildsEverything(),
          .building(MainModule.self).rebuilds(withIncrementalImports: .main, .callsFuncInExtension, .instantiatesS,
                                              withoutIncrementalImports: .main, .noUseOfS, .callsFuncInExtension, .instantiatesS),
        ]
      }
    }
  }

  enum MainModule: PhasedModule {
    typealias Phases = HideAndShowFuncInStructAndExtensionTests.Phases

    static var name: String { "main" }
    static var imports: [String] { [ ImportedModule.name ] }
    static var isLibrary: Bool { return false }

    enum Sources: String, CaseIterable, NameableByRawValue {
      case main
      case noUseOfS
      case callsFuncInExtension
      case instantiatesS
    }

    static var sources: [SourceFile<Self>] {
      [
        .named(.main)
          .in(phases: Phases.allCases) {
             """
             import \(ImportedModule.name)
             extension S {
               static func inStruct<I: SignedInteger>(_ si: I) {
                 print("1: not public")
               }
               static func inExtension<I: SignedInteger>(_ si: I) {
                 print("2: not public")
               }
             }
             S.inStruct(3)
             """
          },
        .named(.noUseOfS)
          .in(phases: Phases.allCases) {
            """
            import \(ImportedModule.name)
            func baz() { T.bar("asdf") }
            """
          },
        .named(.callsFuncInExtension)
          .in(phases: Phases.allCases) {
            """
            import \(ImportedModule.name)
            func fred() { S.inExtension(3) }
            """
          },
        .named(.instantiatesS)
          .in(phases: Phases.allCases) {
            """
            import \(ImportedModule.name)
            func late() { _ = S() }
            """
          },
      ]
    }
  }

  enum ImportedModule: PhasedModule {
    typealias Phases = HideAndShowFuncInStructAndExtensionTests.Phases

    static var name: String { "imported" }
    static var imports: [String] { [] }
    static var isLibrary: Bool { return true }

    enum Sources: String, CaseIterable, NameableByRawValue {
      case imported
    }

    static var sources: [SourceFile<Self>] {
      [
        .named(.imported)
          .in(.bothHidden) {
            """
            public protocol PP {}
            public struct S: PP {
             public init() {}
              // public // was commented out; should rebuild users of inStruct
              static func inStruct(_ i: Int) {print("1: private")}
              func fo() {}
            }
            public struct T {
              public init() {}
              public static func bar(_ s: String) {print(s)}
            }
            extension S {
              // public
              static func inExtension(_ i: Int) {print("2: private")}
            }
            """
          }
          .in(.shownInStruct) {
               """
               public protocol PP {}
               public struct S: PP {
                 public init() {}
                 public // was uncommented out; should rebuild users of inStruct
                 static func inStruct(_ i: Int) {print("1: private")}
                 func fo() {}
               }
               public struct T {
                 public init() {}
                 public static func bar(_ s: String) {print(s)}
               }
               extension S {
                 // public
                 static func inExtension(_ i: Int) {print("2: private")}
               }
               """
          }
          .in(.shownInExtension) {
               """
               public protocol PP {}
               public struct S: PP {
                 public init() {}
                 // public // was commented out; should rebuild users of inStruct
                 static func inStruct(_ i: Int) {print("1: private")}
                 func fo() {}
               }
               public struct T {
                 public init() {}
                 public static func bar(_ s: String) {print(s)}
               }
               extension S {
                 public
                 static func inExtension(_ i: Int) {print("2: private")}
               }
               """
          }
          .in(.bothShown) {
               """
               public protocol PP {}
               public struct S: PP {
                 public init() {}
                 public
                 static func inStruct(_ i: Int) {print("1: private")}
                 func fo() {}
               }
               public struct T {
                 public init() {}
                 public static func bar(_ s: String) {print(s)}
               }
               extension S {
                 public  // was uncommented; should rebuild users of inExtension
                 static func inExtension(_ i: Int) {print("2: private")}
               }
               """
          },
      ]
    }
  }
}

