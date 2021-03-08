//===----------- PhasedSources.swift - Swift Testing --------------===//
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

public struct SourceFile<Module: PhasedModule> {
  public var fileName: Module.Sources.RawValue
  public var code: [Module.Sources.RawValue: String]

  private init(_ fileName: Module.Sources.RawValue, _ code: [Module.Sources.RawValue: String]) {
    self.fileName = fileName
    self.code = code
  }

  public static func named(_ fileName: Module.Sources) -> SourceFile<Module> {
    return self.init(fileName.rawValue, [:])
  }

  public func `in`(_ phases: Module.Phases..., code: () -> String) -> SourceFile<Module> {
    return self.in(phases: phases, code: code)
  }

  public func `in`(phases: [Module.Phases], code: () -> String) -> SourceFile<Module> {
    var newCode = self.code
    for phase in phases {
      newCode[phase.rawValue] = code()
    }
    return SourceFile(self.fileName, newCode)
  }

  public func code(for phase: Module.Phases) -> String? {
    return self.code[phase.rawValue]
  }

  func isIncluded(in phase: Module.Phases) -> Bool {
    return self.code[phase.rawValue] != nil
  }
}

extension SourceFile: Equatable {
  public static func == (lhs: SourceFile, rhs: SourceFile) -> Bool {
    return lhs.fileName == rhs.fileName && lhs.code == rhs.code
  }
}

extension SourceFile: Hashable {
  public func hash(into hasher: inout Hasher) {
    hasher.combine(self.fileName)
    hasher.combine(self.code)
  }
}
