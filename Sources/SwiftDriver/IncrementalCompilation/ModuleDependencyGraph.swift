//===------- ModuleDependencyGraph.swift ----------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
import Foundation
import TSCBasic
import SwiftOptions


// MARK: - ModuleDependencyGraph

/*@_spi(Testing)*/ public final class ModuleDependencyGraph {
  
  var nodeFinder = NodeFinder()
  
  /// When integrating a change, want to find untraced nodes so we can kick off jobs that have not been
  /// kicked off yet
  private var tracedNodes = Set<Node>()
  
  private(set) var sourceSwiftDepsMap = BidirectionalMap<TypedVirtualPath, SwiftDeps>()

  // Supports requests from the driver to getExternalDependencies.
  public internal(set) var externalDependencies = Set<ExternalDependency>()
  
  let verifyDependencyGraphAfterEveryImport: Bool
  let emitDependencyDotFileAfterEveryImport: Bool
  let reporter: IncrementalBuild.Reporter?
  
  private let diagnosticEngine: DiagnosticsEngine
  
  public init(
    diagnosticEngine: DiagnosticsEngine,
    reporter: IncrementalBuild.Reporter?,
    emitDependencyDotFileAfterEveryImport: Bool,
    verifyDependencyGraphAfterEveryImport: Bool)
  {
    self.verifyDependencyGraphAfterEveryImport = verifyDependencyGraphAfterEveryImport
    self.emitDependencyDotFileAfterEveryImport = emitDependencyDotFileAfterEveryImport
    self.reporter = reporter
    self.diagnosticEngine = diagnosticEngine
  }
}
// MARK: - initial build only
extension ModuleDependencyGraph {
  /// Builds a graph
  /// Returns nil if some input has no place to put a swiftdeps file
  /// Returns a list of inputs whose swiftdeps files could not be read
  static func buildInitialGraph<Inputs: Sequence>(
    diagnosticEngine: DiagnosticsEngine,
    inputs: Inputs,
    previousInputs: Set<VirtualPath>,
    outputFileMap: OutputFileMap?,
    parsedOptions: IncrementalBuild.Options,
    remarkDisabled: (String) -> Diagnostic.Message,
    reporter: IncrementalBuild.Reporter?
  ) -> (ModuleDependencyGraph, inputsWithMalformedSwiftDeps: [(TypedVirtualPath, VirtualPath)])?
  where Inputs.Element == TypedVirtualPath
  {
    let graph = Self(
      diagnosticEngine: diagnosticEngine,
      reporter: reporter,
      emitDependencyDotFileAfterEveryImport: parsedOptions.contains(.emitDependencyDotFileAfterEveryImport),
      verifyDependencyGraphAfterEveryImport: parsedOptions.contains(.verifyDependencyGraphAfterEveryImport))

    let inputsAndSwiftdeps = inputs.map {input in
      (input, outputFileMap?.existingOutput( inputFile: input.file,
                                             outputType: .swiftDeps)
      )
    }
    for isd in inputsAndSwiftdeps where isd.1 == nil {
      // The legacy driver fails silently here.
      diagnosticEngine.emit(
        remarkDisabled("\(isd.0.file.basename) has no swiftDeps file")
      )
      return nil
    }
    let inputsWithMalformedSwiftDeps = inputsAndSwiftdeps.compactMap {
      input, swiftDepsFile -> (TypedVirtualPath, VirtualPath)? in
      guard let swiftDepsFile = swiftDepsFile
      else {
        return nil
      }
      let swiftDeps = SwiftDeps(swiftDepsFile)
      graph.sourceSwiftDepsMap[input] = swiftDeps
      guard previousInputs.contains(input.file)
      else {
        // do not try to read swiftdeps of a new input
        return nil
      }
      let changes = Integrator.integrate(swiftDeps: swiftDeps,
                                         into: graph,
                                         input: input,
                                         reporter: reporter,
                                         diagnosticEngine: diagnosticEngine)
      return changes == nil ? (input, swiftDepsFile) : nil
    }
    return (graph, inputsWithMalformedSwiftDeps)
  }
}
// MARK: - Scheduling the first wave
extension ModuleDependencyGraph {
  /// Find all the sources that depend on `sourceFile`. For some source files, these will be
  /// speculatively scheduled in the first wave.
  func findDependentSourceFiles(
    of sourceFile: TypedVirtualPath
  ) -> [TypedVirtualPath] {
    var allSwiftDepsToRecompile = Set<SwiftDeps>()

    let swiftDeps = sourceSwiftDepsMap[sourceFile]

    for swiftDepsToRecompile in
      findSwiftDepsToRecompileWhenWholeSwiftDepsChanges( swiftDeps ) {
      if swiftDepsToRecompile != swiftDeps {
        allSwiftDepsToRecompile.insert(swiftDepsToRecompile)
      }
    }
    return allSwiftDepsToRecompile.map {
      let dependentSource = sourceSwiftDepsMap[$0]
      self.reporter?.report(
        "Found dependent of \(sourceFile.file.basename):", path: dependentSource)
      return dependentSource
    }
  }

  /// Find all the swiftDeps files that depend on `swiftDeps`.
  /// Really private, except for testing.
  /*@_spi(Testing)*/ public func findSwiftDepsToRecompileWhenWholeSwiftDepsChanges(
    _ swiftDeps: SwiftDeps
  ) -> Set<SwiftDeps> {
    let nodes = nodeFinder.findNodes(for: swiftDeps) ?? [:]
    /// Tests expect this to be reflexive
    return findSwiftDepsToRecompileWhenNodesChange(nodes.values)
  }
}
// MARK: - Scheduling the 2nd wave
extension ModuleDependencyGraph {
  /// After `source` has been compiled, figure out what other source files need compiling.
  /// Used to schedule the 2nd wave.
  /// Return nil in case of an error.
  func findSourcesToCompileAfterCompiling(
    _ source: TypedVirtualPath
  ) -> [TypedVirtualPath]? {
    findSourcesToCompileAfterIntegrating(
      input: source,
      swiftDeps: sourceSwiftDepsMap[source])
  }

  /// After a compile job has finished, read its swiftDeps file and return the source files needing
  /// recompilation.
  /// Return nil in case of an error.
  /// May return a source that has already been compiled.
  private func findSourcesToCompileAfterIntegrating(
    input: TypedVirtualPath,
    swiftDeps: SwiftDeps
  ) -> [TypedVirtualPath]? {
    Integrator.integrate(swiftDeps: swiftDeps,
                         into: self,
                         input: input,
                         reporter: self.reporter,
                         diagnosticEngine: diagnosticEngine)
      .map {
        findSwiftDepsToRecompileWhenNodesChange($0)
          .map {sourceSwiftDepsMap[$0]}
      }
  }
}

// MARK: - Scheduling either wave
extension ModuleDependencyGraph {
  /// Find all the swiftDeps affected when the nodes change.
  /*@_spi(Testing)*/ public func findSwiftDepsToRecompileWhenNodesChange<Nodes: Sequence>(
    _ nodes: Nodes
  ) -> Set<SwiftDeps>
  where Nodes.Element == Node
  {
    let affectedNodes = Tracer.findPreviouslyUntracedUsesOf(
      defs: nodes,
      in: self,
      diagnosticEngine: diagnosticEngine)
      .tracedUses
    return Set(affectedNodes.compactMap {$0.swiftDeps})
  }

  /*@_spi(Testing)*/ public func untracedDependents(
    of externalSwiftDeps: ExternalDependency
  ) -> [ModuleDependencyGraph.Node] {
    // These nodes will depend on the *interface* of the external Decl.
    let key = DependencyKey(interfaceFor: externalSwiftDeps)
    let node = Node(key: key, fingerprint: nil, swiftDeps: nil)
    return nodeFinder
      .orderedUses(of: node)
      .filter({ use in isUntraced(use) })
  }
}
fileprivate extension DependencyKey {
  init(interfaceFor dep: ExternalDependency ) {
    self.init(aspect: .interface, designator: .externalDepend(dep))
  }
}
// MARK: - tracking traced nodes
extension ModuleDependencyGraph {

  func isUntraced(_ n: Node) -> Bool {
    !isTraced(n)
  }
  func isTraced(_ n: Node) -> Bool {
    tracedNodes.contains(n)
  }
  func amTracing(_ n: Node) {
    tracedNodes.insert(n)
  }
  func ensureGraphWillRetraceDependents<Nodes: Sequence>(of nodes: Nodes)
  where Nodes.Element == Node
  {
    nodes.forEach { tracedNodes.remove($0) }
  }
}

// MARK: - utilities for unit testing
extension ModuleDependencyGraph {
  /// Testing only
  /*@_spi(Testing)*/ public func haveAnyNodesBeenTraversed(inMock i: Int) -> Bool {
    let swiftDeps = SwiftDeps(mock: i)
    // optimization
    if let fileNode = nodeFinder.findFileInterfaceNode(forMock: swiftDeps),
       isTraced(fileNode) {
      return true
    }
    if let nodes = nodeFinder.findNodes(for: swiftDeps)?.values,
       nodes.contains(where: isTraced) {
      return true
    }
    return false
  }
}
// MARK: - verification
extension ModuleDependencyGraph {
  @discardableResult
  func verifyGraph() -> Bool {
    nodeFinder.verify()
  }
}
// MARK: - debugging
extension ModuleDependencyGraph {
  func emitDotFile(_ g: SourceFileDependencyGraph, _ swiftDeps: SwiftDeps) {
    // TODO: Incremental emitDotFIle
    fatalError("unimplmemented, writing dot file of dependency graph")
  }
}
