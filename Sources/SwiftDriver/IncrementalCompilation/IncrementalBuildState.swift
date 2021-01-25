//===--------------- IncrementalCompilation.swift - Incremental -----------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2019 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
import TSCBasic
import Foundation
import SwiftOptions

public class IncrementalCompilationState {
  /// The oracle for deciding what depends on what. Applies to this whole module.
  private let moduleDependencyGraph: ModuleDependencyGraph

  /// If non-null outputs information for `-driver-show-incremental` for input path
  private let reporter: IncrementalBuild.Reporter?

  /// All of the pre-compile or compilation job (groups) known to be required (i.e. in 1st wave).
  /// Already batched, and in order of input files.
  public let mandatoryJobsInOrder: [Job]

  /// Sadly, has to be `var` for formBatchedJobs
  private var driver: Driver

  /// Track required jobs that haven't finished so the build record can record the corresponding
  /// input statuses.
  private var unfinishedJobs: Set<Job>

  /// Keyed by primary input. As required compilations are discovered after the first wave, these shrink.
  private var skippedCompileGroups = [TypedVirtualPath: CompileJobGroup]()

  /// Jobs to run *after* the last compile, for instance, link-editing.
  public let jobsAfterCompiles: [Job]

  private let confinementQueue = DispatchQueue(label: "com.apple.swift-driver.IncrementalCompilationState")

// MARK: - Creating IncrementalCompilationState if possible
  /// Return nil if not compiling incrementally
  init(_ plan: IncrementalBuild.Plan) throws {
    self.unfinishedJobs = Set(plan.mandatoryJobsInOrder)
    self.jobsAfterCompiles = plan.jobsInPhases.afterCompiles
    self.moduleDependencyGraph = moduleDependencyGraph
    self.driver = driver
  }
}

// MARK: - Scheduling
extension IncrementalCompilationState {
  /// Remember a job (group) that is before a compile or a compile itself.
  /// `job` just finished. Update state, and return the skipped compile job (groups) that are now known to be needed.
  /// If no more compiles are needed, return nil.
  /// Careful: job may not be primary.

  public func getJobsDiscoveredToBeNeededAfterFinishing(
    job finishedJob: Job, result: ProcessResult
   ) throws -> [Job]? {
    return try confinementQueue.sync {
      unfinishedJobs.remove(finishedJob)

      guard case .terminated = result.exitStatus else {
        return []
      }

      // Find and deal with inputs that how need to be compiled
      let discoveredInputs = collectInputsDiscovered(from: finishedJob)
      assert(Set(discoveredInputs).isDisjoint(with: finishedJob.primaryInputs),
             "Primaries should not overlap secondaries.")

      if let reporter = self.reporter {
        for input in discoveredInputs {
          reporter.report("Queuing because of dependencies discovered later:", path: input)
        }
      }
      let newJobs = try getJobsFor(discoveredCompilationInputs: discoveredInputs)
      unfinishedJobs.formUnion(newJobs)
      if unfinishedJobs.isEmpty {
        // no more compilations are possible
        return nil
      }
      return newJobs
    }
 }

  /// After `job` finished find out which inputs must compiled that were not known to need compilation before
  private func collectInputsDiscovered(from job: Job)  -> [TypedVirtualPath] {
    guard job.kind == .compile else {
      return []
    }
    return Array(
      Set(
        job.primaryInputs.flatMap {
          input -> [TypedVirtualPath] in
          if let found = moduleDependencyGraph.findSourcesToCompileAfterCompiling(input) {
            return found
          }
          self.reporter?.report("Failed to read some swiftdeps; compiling everything", path: input)
          return Array(skippedCompileGroups.keys)
        }
      )
      .subtracting(job.primaryInputs) // have already compiled these
    )
    .sorted {$0.file.name < $1.file.name}
  }

  /// Find the jobs that now must be run that were not originally known to be needed.
  private func getJobsFor(
    discoveredCompilationInputs inputs: [TypedVirtualPath]
  ) throws -> [Job] {
    let unbatched = inputs.flatMap { input -> [Job] in
      if let group = skippedCompileGroups.removeValue(forKey: input) {
        let primaryInputs = group.compileJob.primaryInputs
        assert(primaryInputs.count == 1)
        assert(primaryInputs[0] == input)
        self.reporter?.report("Scheduling discovered", path: input)
        return group.allJobs()
      }
      else {
        self.reporter?.report("Tried to schedule discovered input again", path: input)
        return []
      }
    }
    return try driver.formBatchedJobs(unbatched, showJobLifecycle: driver.showJobLifecycle)
  }
}

// MARK: - After the build
extension IncrementalCompilationState {
  var skippedCompilationInputs: Set<TypedVirtualPath> {
    Set(skippedCompileGroups.keys)
  }
  public var skippedJobs: [Job] {
    skippedCompileGroups.values
      .sorted {$0.primaryInput.file.name < $1.primaryInput.file.name}
      .flatMap {$0.allJobs()}
  }
}

// MARK: - Remarks

extension IncrementalBuild {
  /// A type that manages the reporting of remarks about the state of the
  /// incremental build.
  public struct Reporter {
    let diagnosticEngine: DiagnosticsEngine
    let outputFileMap: OutputFileMap?

    /// Report a remark with the given message.
    ///
    /// The `path` parameter is used specifically for reporting the state of
    /// compile jobs that are transiting through the incremental build pipeline.
    /// If provided, and valid entries in the output file map are provided,
    /// the reporter will format a message of the form
    ///
    /// ```
    /// <message> {compile: <output> <= <input>}
    /// ```
    ///
    /// Which mirrors the behavior of the legacy driver.
    ///
    /// - Parameters:
    ///   - message: The message to emit in the remark.
    ///   - path: If non-nil, the path of an output for an incremental job.
    func report(_ message: String, path: TypedVirtualPath? = nil) {
      guard let outputFileMap = outputFileMap,
            let path = path,
            let input = path.type == .swift ? path.file : outputFileMap.getInput(outputFile: path.file)
      else {
        diagnosticEngine.emit(.remark_incremental_compilation(because: message))
        return
      }
      let output = outputFileMap.getOutput(inputFile: path.file, outputType: .object)
      let compiling = " {compile: \(output.basename) <= \(input.basename)}"
      diagnosticEngine.emit(.remark_incremental_compilation(because: "\(message) \(compiling)"))
    }

    // Emits a remark indicating incremental compilation has been disabled.
    func reportDisablingIncrementalBuild(_ why: String) {
      report("Disabling incremental build: \(why)")
    }

    // Emits a remark indicating incremental compilation has been disabled.
    //
    // FIXME: This entrypoint exists for compatiblity with the legacy driver.
    // This message is not necessary, and we should migrate the tests.
    func reportIncrementalCompilationHasBeenDisabled(_ why: String) {
      report("Incremental compilation has been disabled, \(why)")
    }
  }
}
