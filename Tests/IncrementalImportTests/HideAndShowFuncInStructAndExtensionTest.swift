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
    try HideAndShowFunc<InStruct>.test(verbose: false)
  }
  func testHideAndShowFuncInExtension() throws {
    try HideAndShowFunc<InExtension>.test(verbose: false)
  }

  enum InStruct {}
  enum InExtension {}

  struct HideAndShowFunc<T>: PhasedTest {
    enum Phases: String, CaseIterable, TestPhase {
      case bothHidden
      case shown
      case bothShown
    }

    static func setup() -> [Expectation<Phases>] {
      [
        .building(ImportedModule<T>.self).rebuildsEverything(),
        .building(MainModule<T>.self).rebuildsEverything(),
      ]
    }

    static var transitioner: [Phases] {
      precondition(T.self == InStruct.self || T.self == InExtension.self)
      return [
        .bothHidden,
        .shown,
        .bothShown,
        .bothHidden,
      ]
    }

    static func testTransition(from: Phases, to: Phases) -> [Expectation<Phases>] {
      switch (from, to) {
      case (.bothHidden, .bothHidden), (.shown, .shown), (.bothShown, .bothShown):
        return [
          .building(ImportedModule.self).rebuildsNothing(),
          .building(MainModule.self).rebuildsNothing(),
        ]
      case (.bothHidden, .shown), (.bothShown, .shown):
        if T.self == InStruct.self {
          return [
            .building(ImportedModule.self).rebuildsEverything(),
            .building(MainModule.self).rebuilds(withIncrementalImports: .main, .callsFuncInExtension, .instantiatesS,
                                                withoutIncrementalImports: .main, .noUseOfS, .callsFuncInExtension, .instantiatesS),
          ]
        } else if T.self == InExtension.self {
          return [
            .building(ImportedModule.self).rebuildsEverything(),
            .building(MainModule.self).rebuilds(withIncrementalImports: .main, .callsFuncInExtension,
                                                withoutIncrementalImports: .main, .noUseOfS, .callsFuncInExtension, .instantiatesS),
          ]
        } else {
          fatalError("Unexpected modality!")
        }
      case (.shown, .bothHidden):
        return [
          .building(ImportedModule.self).rebuildsEverything(),
          .building(MainModule.self).rebuilds(withIncrementalImports: .main, .callsFuncInExtension, .instantiatesS,
                                              withoutIncrementalImports: .main, .noUseOfS, .callsFuncInExtension, .instantiatesS),
        ]
      case (.shown, .bothShown):
        if T.self == InStruct.self {
        return [
            .building(ImportedModule.self).rebuildsEverything(),
            .building(MainModule.self).rebuilds(withIncrementalImports: .main, .callsFuncInExtension,
                                                withoutIncrementalImports: .main, .noUseOfS, .callsFuncInExtension, .instantiatesS),
          ]
        } else if T.self == InExtension.self {
          return [
            .building(ImportedModule.self).rebuildsEverything(),
            .building(MainModule.self).rebuilds(withIncrementalImports: .main, .callsFuncInExtension, .instantiatesS,
                                                withoutIncrementalImports: .main, .noUseOfS, .callsFuncInExtension, .instantiatesS),
          ]
        } else {
          fatalError("Unexpected modality!")
        }
      case (.bothShown, .bothHidden):
        return [
          .building(ImportedModule<T>.self).rebuildsEverything(),
          .building(MainModule<T>.self).rebuilds(withIncrementalImports: .main, .callsFuncInExtension, .instantiatesS,
                                                 withoutIncrementalImports: .main, .noUseOfS, .callsFuncInExtension, .instantiatesS),
        ]
      case (.bothHidden, .bothShown):
        if T.self == InStruct.self {
          return [
            .building(ImportedModule.self).rebuildsEverything(),
            .building(MainModule.self).rebuilds(withIncrementalImports: .main, .callsFuncInExtension, .instantiatesS,
                                                withoutIncrementalImports: .main, .noUseOfS, .callsFuncInExtension, .instantiatesS),
          ]
        } else if T.self == InExtension.self {
          return [
            .building(ImportedModule.self).rebuildsEverything(),
            .building(MainModule.self).rebuilds(withIncrementalImports: .main, .callsFuncInExtension, .instantiatesS,
                                                withoutIncrementalImports: .main, .noUseOfS, .callsFuncInExtension, .instantiatesS),
          ]
        } else {
          fatalError("Unexpected modality!")
        }
      }
    }
  }

  enum MainModule<T>: PhasedModule {
    typealias Phases = HideAndShowFunc<T>.Phases

    static var name: String { "main" }
    static var imports: [String] { [ ImportedModule<T>.name ] }
    static var product: PhasedModuleProduct { .executable }

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
             import \(ImportedModule<T>.name)
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
            import \(ImportedModule<T>.name)
            func baz() { T.bar("asdf") }
            """
          },
        .named(.callsFuncInExtension)
          .in(phases: Phases.allCases) {
            """
            import \(ImportedModule<T>.name)
            func fred() { S.inExtension(3) }
            """
          },
        .named(.instantiatesS)
          .in(phases: Phases.allCases) {
            """
            import \(ImportedModule<T>.name)
            func late() { _ = S() }
            """
          },
      ]
    }
  }

  enum ImportedModule<T>: PhasedModule {
    typealias Phases = HideAndShowFunc<T>.Phases

    static var name: String { "imported" }
    static var imports: [String] { [] }
    static var product: PhasedModuleProduct { .library }

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
          .in(.shown) {
            if T.self == InStruct.self {
              return """
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
            } else if T.self == InExtension.self {
              return """
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
            } else {
              fatalError("Unknown Mutation Type \(T.self)")
            }
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

