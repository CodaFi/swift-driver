//===--------------- PhasedModule.swift - Swift Testing -----------------===//
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

/// A `PhasedModule` is a type that describes the layout of a Swift module with
/// component Swift files that change over a given set of phases.
///
/// To define a phased module, first define the set of phases that the module
/// will change with respect to in an implementation of `PhaseState`. Then,
/// define the set of sources that occur in the module:
///
///
/// ```
/// enum Phases: String, CaseIterable, PhaseState {
///   case first
///   case second
/// }
///
/// enum Module: PhasedModule {
///   typealias Phases = Example.Phases
///
///   static var name: String { "Example" }
///   static var imports: [String] { return [] }
///   static var isLibrary: Bool { true }
///
///   enum Sources: String, NameableByRawValue, CaseIterable {
///     case main
///     case other
///   }
///
///   static var sources: [SourceFile<Module>] {
///     [
///       // Define main.swift
///       .named(.main)
///         // main.swift exists unchanged in all phases.
///         .in(phases: Phases.allCases) {
///           """
///           struct Foo {}
///           """
///         },
///       // Define other.swift
///       .named(.other)
///         // In the first phase we write an empty file
///         .in(.first) {
///           """
///           """
///         }
///         // In the second, we write a file that uses `Foo`
///         .in(.second) {
///           """
///           let _ = Foo()
///           """
///         },
///         // By omitting the third phase, Phaser will delete this
///         // file from the build.
///     ]
///   }
/// }
/// ```
///
/// The total set of `Sources` that are a part of this module must also be
/// defined, but not necessarily used in `sources` array. This enables
/// `Expectation` values to make reference to the source files defined in a
/// given incremental build test.
public protocol PhasedModule: CaseIterable {
  /// The phases associated with this module.
  associatedtype Phases: PhaseState
  /// The type of source file references
  associatedtype Sources: NameableByRawValue, CaseIterable

  /// The name of this module.
  static var name: String { get }

  /// The modules imported by this module, if any.
  static var imports: [String] { get }

  /// Returns true iff the module is a library, vs an app
  static var isLibrary: Bool { get }

  /// The phase-dependent set of source files in this module.
  static var sources: [SourceFile<Self>] { get }
}

extension PhasedModule {
  public static func sources(in phase: Self.Phases) -> [SourceFile<Self>] {
    return Self.sources.filter { $0.isIncluded(in: phase) }
  }
}
