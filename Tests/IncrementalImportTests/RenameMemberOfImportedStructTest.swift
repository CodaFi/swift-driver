//===--------------- IncrementalImportTests.swift - Swift Testing ---------===//
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


// MARK: - Test cases
class RenameMemberOfImportedStructTest: XCTestCase {
  func testRenamingMember() throws {
    try RenameMemberOfImportedStruct.test(verbose: false)
  }

  // MARK: - RenameMemberOfImportedStruct

  /// Change the name of a member of an imported struct.
  /// Ensure that only the users get rebuilt
  struct RenameMemberOfImportedStruct: PhasedTest {
    enum Phases: String, CaseIterable, PhaseState {
      case initial
      case renamed

      var expectations: [Expectation<Self>] {
        switch self {
        case .initial:
          return [
            .building(ImportedModule.self).rebuildsEverything(),
            .building(MainModule.self).rebuildsEverything(),
          ]
        case .renamed:
          return [
            .building(ImportedModule.self).rebuildsEverything(),
            .building(MainModule.self).rebuilds(withIncrementalImports: .main,
                                                withoutIncrementalImports: .main, .otherFile),
          ]
        }
      }
    }
  }

  enum MainModule: PhasedModule {
    typealias Phases = RenameMemberOfImportedStruct.Phases

    static var name: String { "main" }
    static var imports: [String] { [ ImportedModule.name ] }
    static var isLibrary: Bool { false }

    enum Sources: String, NameableByRawValue, CaseIterable {
      case main, otherFile
    }

    static var sources: [SourceFile<Self>] {
      [
        .named(.main)
          .in(phases: Phases.allCases) {
            """
            import \(ImportedModule.name)
            ImportedStruct().importedMember()
            """
          },
        .named(.otherFile)
          .in(phases: Phases.allCases) {
            ""
          },
      ]
    }
  }

  enum ImportedModule: PhasedModule {
    typealias Phases = RenameMemberOfImportedStruct.Phases

    static var name: String { "imported" }
    static var imports: [String] { [] }
    static var isLibrary: Bool { true }


    enum Sources: String, NameableByRawValue, CaseIterable {
      case memberDefiner
    }

    static var sources: [SourceFile<Self>] {
      [
        .named(.memberDefiner)
          .in(.initial) {
            """
            public struct ImportedStruct {
              public init() {}
              public func importedMember() {}
              // change the name below, only mainFile should rebuild:
              public func nameToBeChanged() {}
            }
            """
          }
          .in(.renamed) {
            """
            public struct ImportedStruct {
              public init() {}
              public func importedMember() {}
              // change the name below, only mainFile should rebuild:
              public func nameWasChanged() {}
            }
            """
          }
      ]
    }
  }
}
