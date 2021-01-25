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

public enum IncrementalBuild {
  static func plan(
    driver: Driver,
    jobsInPhases: JobsInPhases,
    options: IncrementalBuild.Options) throws -> IncrementalBuild.Plan? {


    let reporter: Reporter?
    if driver.parsedOptions.hasArgument(.driverShowIncremental) || driver.showJobLifecycle {
      reporter = Reporter(diagnosticEngine: driver.diagnosticEngine,
                          outputFileMap: driver.outputFileMap)
    } else {
      reporter = nil
    }

    guard let (outputFileMap, buildRecordInfo, outOfDateBuildRecord)
            = try driver.getBuildInfo(reporter)
    else {
      return nil
    }

    guard let (moduleDependencyGraph,
               inputsHavingMalformedSwiftDeps: inputsHavingMalformedSwiftDeps) =
            Self.computeModuleDependencyGraph(
              buildRecordInfo,
              outOfDateBuildRecord,
              outputFileMap,
              driver,
              reporter,
              options)
    else {
      return nil
    }

    let (skippedCompileGroups, mandatoryJobsInOrder) = try Self.computeInputsAndGroups(
      jobsInPhases,
      driver,
      buildRecordInfo,
      outOfDateBuildRecord,
      inputsHavingMalformedSwiftDeps: inputsHavingMalformedSwiftDeps,
      moduleDependencyGraph,
      reporter,
      options)

    return IncrementalBuild.Plan(jobsInPhases: jobsInPhases,
                                 moduleDependencyGraph: moduleDependencyGraph,
                                 mandatoryJobsInOrder: mandatoryJobsInOrder,
                                 skippedCompileGroups: skippedCompileGroups,
                                 reporter: reporter,
                                 options: options)
  }
}

extension IncrementalBuild {
  struct Options: OptionSet {
    var rawValue: UInt8

    static let showJobLifecycle = Self(rawValue: 1 << 0)
    static let showIncremental = Self(rawValue: 1 << 1)
    static let emitDependencyDotFileAfterEveryImport = Self(rawValue: 1 << 2)
    static let verifyDependencyGraphAfterEveryImport = Self(rawValue: 1 << 3)
  }
}

extension IncrementalBuild {
  struct Plan {
    private let jobsInPhases: JobsInPhases

    /// The oracle for deciding what depends on what. Applies to this whole module.
    private let moduleDependencyGraph: ModuleDependencyGraph

    /// All of the pre-compile or compilation job (groups) known to be required (i.e. in 1st wave).
    /// Already batched, and in order of input files.
    public let mandatoryJobsInOrder: [Job]

    /// Keyed by primary input. As required compilations are discovered after the first wave, these shrink.
    private var skippedCompileGroups: [TypedVirtualPath: CompileJobGroup]

    /// If non-null outputs information for `-driver-show-incremental` for input path
    private let reporter: Reporter?

    private var options: IncrementalBuild.Options

    fileprivate init(
      jobsInPhases: JobsInPhases,
      moduleDependencyGraph: ModuleDependencyGraph,
      mandatoryJobsInOrder: [Job],
      skippedCompileGroups: [TypedVirtualPath: CompileJobGroup],
      reporter: IncrementalBuild.Reporter?,
      options: IncrementalBuild.Options
    ) {
      self.jobsInPhases = jobsInPhases
      self.moduleDependencyGraph = moduleDependencyGraph
      self.mandatoryJobsInOrder = mandatoryJobsInOrder
      self.skippedCompileGroups = skippedCompileGroups
      self.reporter = reporter
      self.options = options
    }

    func execute() -> IncrementalCompilationState {
      let state = IncrementalCompilationState(self)
      // For compatibility with swiftpm, the driver produces batched jobs
      // for every job, even when run in incremental mode, so that all jobs
      // can be returned from `planBuild`.
      // But in that case, don't emit lifecycle messages.
      formBatchedJobs(self.jobsInPhases.allJobs,
                      showJobLifecycle: self.reporter != nil)
      return
    }
  }
}

extension IncrementalBuild {
  private static func computeModuleDependencyGraph(
    _ buildRecordInfo: BuildRecordInfo,
    _ outOfDateBuildRecord: BuildRecord,
    _ outputFileMap: OutputFileMap,
    _ driver: Driver,
    _ reporter: IncrementalBuild.Reporter?,
    _ options: IncrementalBuild.Options
  )
  -> (ModuleDependencyGraph, inputsHavingMalformedSwiftDeps: [TypedVirtualPath])?
  {
    let diagnosticEngine = driver.diagnosticEngine
    guard let (moduleDependencyGraph, inputsWithMalformedSwiftDeps: inputsWithMalformedSwiftDeps) =
            ModuleDependencyGraph.buildInitialGraph(
              diagnosticEngine: diagnosticEngine,
              inputs: buildRecordInfo.compilationInputModificationDates.keys,
              previousInputs: outOfDateBuildRecord.allInputs,
              outputFileMap: outputFileMap,
              parsedOptions: options,
              remarkDisabled: Diagnostic.Message.remark_incremental_compilation_has_been_disabled,
              reporter: reporter)
    else {
      return nil
    }
    // Preserve legacy behavior,
    // but someday, just ensure inputsWithUnreadableSwiftDeps are compiled
    if let badSwiftDeps = inputsWithMalformedSwiftDeps.first?.1 {
      diagnosticEngine.emit(
        .remark_incremental_compilation_has_been_disabled(
          because: "malformed swift dependencies file '\(badSwiftDeps)'")
      )
      return nil
    }
    let inputsHavingMalformedSwiftDeps = inputsWithMalformedSwiftDeps.map {$0.0}
    return (moduleDependencyGraph,
            inputsHavingMalformedSwiftDeps: inputsHavingMalformedSwiftDeps)
  }

  private static func computeInputsAndGroups(
    _ jobsInPhases: JobsInPhases,
    _ driver: Driver,
    _ buildRecordInfo: BuildRecordInfo,
    _ outOfDateBuildRecord: BuildRecord,
    inputsHavingMalformedSwiftDeps: [TypedVirtualPath],
    _ moduleDependencyGraph: ModuleDependencyGraph,
    _ reporter: IncrementalBuild.Reporter?,
    _ options: IncrementalBuild.Options
  ) throws -> (skippedCompileGroups: [TypedVirtualPath: CompileJobGroup],
               mandatoryJobsInOrder: [Job])
  {
    let compileGroups =
      Dictionary(uniqueKeysWithValues:
                    jobsInPhases.compileGroups.map {($0.primaryInput, $0)} )

     let skippedInputs = Self.computeSkippedCompilationInputs(
      allGroups: jobsInPhases.compileGroups,
      fileSystem: driver.fileSystem,
      buildRecordInfo: buildRecordInfo,
      inputsHavingMalformedSwiftDeps: inputsHavingMalformedSwiftDeps,
      moduleDependencyGraph: moduleDependencyGraph,
      outOfDateBuildRecord: outOfDateBuildRecord,
      alwaysRebuildDependents: driver.parsedOptions.contains(.driverAlwaysRebuildDependents),
      reporter: reporter)

    let skippedCompileGroups = compileGroups.filter {skippedInputs.contains($0.key)}

    let mandatoryCompileGroupsInOrder = driver.inputFiles.compactMap {
      input -> CompileJobGroup? in
      skippedInputs.contains(input)
        ? nil
        : compileGroups[input]
    }

    let mandatoryJobsInOrder = try
      jobsInPhases.beforeCompiles +
      driver.formBatchedJobs(
        mandatoryCompileGroupsInOrder.flatMap {$0.allJobs()},
        showJobLifecycle: driver.showJobLifecycle)

    return (skippedCompileGroups: skippedCompileGroups,
            mandatoryJobsInOrder: mandatoryJobsInOrder)
  }
}

fileprivate extension Driver {
  /// Decide if an incremental compilation is possible, and return needed values if so.
  func getBuildInfo(
    _ reporter: IncrementalBuild.Reporter?
  ) throws -> (OutputFileMap, BuildRecordInfo, BuildRecord)? {
    guard let outputFileMap = outputFileMap
    else {
      diagnosticEngine.emit(.warning_incremental_requires_output_file_map)
      return nil
    }
    guard let buildRecordInfo = buildRecordInfo else {
      reporter?.reportDisablingIncrementalBuild("no build record path")
      return nil
    }
    // FIXME: This should work without an output file map. We should have
    // another way to specify a build record and where to put intermediates.
    guard let outOfDateBuildRecord = buildRecordInfo.populateOutOfDateBuildRecord(
            inputFiles: inputFiles, reporter: reporter)
    else {
      return nil
    }
    if let reporter = reporter {
      let missingInputs = Set(outOfDateBuildRecord.inputInfos.keys).subtracting(inputFiles.map {$0.file})
      guard missingInputs.isEmpty else {
        reporter.report(
          "Incremental compilation has been disabled, " +
          " because  the following inputs were used in the previous compilation but not in this one: "
            + missingInputs.map {$0.basename} .joined(separator: ", "))
        return nil
      }
    }
    return (outputFileMap, buildRecordInfo, outOfDateBuildRecord)
  }
}

fileprivate extension CompilerMode {
  var supportsIncrementalCompilation: Bool {
    switch self {
    case .standardCompile, .immediate, .repl, .batchCompile: return true
    case .singleCompile, .compilePCM: return false
    }
  }
}

extension Diagnostic.Message {
  fileprivate static var warning_incremental_requires_output_file_map: Diagnostic.Message {
    .warning("ignoring -incremental (currently requires an output file map)")
  }
  fileprivate static func remark_disabling_incremental_build(because why: String) -> Diagnostic.Message {
    return .remark("Disabling incremental build: \(why)")
  }
  fileprivate static func remark_incremental_compilation_has_been_disabled(because why: String) -> Diagnostic.Message {
    return .remark("Incremental compilation has been disabled: \(why)")
  }

  fileprivate static func remark_incremental_compilation(because why: String) -> Diagnostic.Message {
    .remark("Incremental compilation: \(why)")
  }
}


// MARK: - Scheduling the first wave, i.e. the mandatory pre- and compile jobs

extension IncrementalBuild {

  /// Figure out which compilation inputs are *not* mandatory
  private static func computeSkippedCompilationInputs(
    allGroups: [CompileJobGroup],
    fileSystem: FileSystem,
    buildRecordInfo: BuildRecordInfo,
    inputsHavingMalformedSwiftDeps: [TypedVirtualPath],
    moduleDependencyGraph: ModuleDependencyGraph,
    outOfDateBuildRecord: BuildRecord,
    alwaysRebuildDependents: Bool,
    reporter: IncrementalBuild.Reporter?
  ) -> Set<TypedVirtualPath> {
    let changedInputs = Self.computeChangedInputs(
        groups: allGroups,
        buildRecordInfo: buildRecordInfo,
        moduleDependencyGraph: moduleDependencyGraph,
        outOfDateBuildRecord: outOfDateBuildRecord,
        reporter: reporter)

    let externalDependents = computeExternallyDependentInputs(
      buildTime: outOfDateBuildRecord.buildTime,
      fileSystem: fileSystem,
      moduleDependencyGraph: moduleDependencyGraph,
      reporter: moduleDependencyGraph.reporter)

    let inputsMissingOutputs = allGroups.compactMap {
      $0.outputs.contains {(try? !fileSystem.exists($0.file)) ?? true}
        ? $0.primaryInput
        : nil
    }

    // Combine to obtain the inputs that definitely must be recompiled.
    let definitelyRequiredInputs =
      Set(changedInputs.map({ $0.filePath }) + externalDependents +
            inputsHavingMalformedSwiftDeps
            + inputsMissingOutputs)
    if let reporter = reporter {
      for scheduledInput in definitelyRequiredInputs.sorted(by: {$0.file.name < $1.file.name}) {
        reporter.report("Queuing (initial):", path: scheduledInput)
      }
    }

    // Sometimes, inputs run in the first wave that depend on the changed inputs for the
    // first wave, even though they may not require compilation.
    // Any such inputs missed, will be found by the rereading of swiftDeps
    // as each first wave job finished.
    let speculativeInputs = computeSpeculativeInputs(
      changedInputs: changedInputs,
      externalDependents: externalDependents,
      inputsMissingOutputs: Set(inputsMissingOutputs),
      moduleDependencyGraph: moduleDependencyGraph,
      alwaysRebuildDependents: alwaysRebuildDependents,
      reporter: reporter)
      .subtracting(definitelyRequiredInputs)

    if let reporter = reporter {
      for dependent in speculativeInputs.sorted(by: {$0.file.name < $1.file.name}) {
        reporter.report("Queuing because of the initial set:", path: dependent)
      }
    }
    let immediatelyCompiledInputs = definitelyRequiredInputs.union(speculativeInputs)

    let skippedInputs = Set(buildRecordInfo.compilationInputModificationDates.keys)
      .subtracting(immediatelyCompiledInputs)
    if let reporter = reporter {
      for skippedInput in skippedInputs.sorted(by: {$0.file.name < $1.file.name})  {
        reporter.report("Skipping input:", path: skippedInput)
      }
    }
    return skippedInputs
  }
}

extension IncrementalBuild {
  /// Encapsulates information about an input the driver has determined has
  /// changed in a way that requires an incremental rebuild.
  struct ChangedInput {
    /// The path to the input file.
    var filePath: TypedVirtualPath
    /// The status of the input file.
    var status: InputInfo.Status
    /// If `true`, the modification time of this input matches the modification
    /// time recorded from the prior build in the build record.
    var datesMatch: Bool
  }

  /// Find the inputs that have changed since last compilation, or were marked as needed a build
  private static func computeChangedInputs(
    groups: [CompileJobGroup],
    buildRecordInfo: BuildRecordInfo,
    moduleDependencyGraph: ModuleDependencyGraph,
    outOfDateBuildRecord: BuildRecord,
    reporter: IncrementalBuild.Reporter?
  ) -> [ChangedInput] {
    groups.compactMap { group in
      let input = group.primaryInput
      let modDate = buildRecordInfo.compilationInputModificationDates[input]
        ?? Date.distantFuture
      let inputInfo = outOfDateBuildRecord.inputInfos[input.file]
      let previousCompilationStatus = inputInfo?.status ?? .newlyAdded
      let previousModTime = inputInfo?.previousModTime

      // Because legacy driver reads/writes dates wrt 1970,
      // and because converting time intervals to/from Dates from 1970
      // exceeds Double precision, must not compare dates directly
      var datesMatch: Bool {
        modDate.timeIntervalSince1970 == previousModTime?.timeIntervalSince1970
      }

      switch previousCompilationStatus {
      case .upToDate where datesMatch:
        reporter?.report("May skip current input:", path: input)
        return nil

      case .upToDate:
        reporter?.report("Scheduing changed input", path: input)
      case .newlyAdded:
        reporter?.report("Scheduling new", path: input)
      case .needsCascadingBuild:
        reporter?.report("Scheduling cascading build", path: input)
      case .needsNonCascadingBuild:
        reporter?.report("Scheduling noncascading build", path: input)
      }
      return ChangedInput(filePath: input,
                          status: previousCompilationStatus,
                          datesMatch: datesMatch)
    }
  }

  /// Any files dependent on modified files from other modules must be compiled, too.
  private static func computeExternallyDependentInputs(
    buildTime: Date,
    fileSystem: FileSystem,
    moduleDependencyGraph: ModuleDependencyGraph,
    reporter: IncrementalBuild.Reporter?
 ) -> [TypedVirtualPath] {
    var externallyDependentSwiftDeps = Set<ModuleDependencyGraph.SwiftDeps>()
    for extDep in moduleDependencyGraph.externalDependencies {
      let extModTime = extDep.file.flatMap {
        try? fileSystem.getFileInfo($0).modTime}
        ?? Date.distantFuture
      if extModTime >= buildTime {
        for dependent in moduleDependencyGraph.untracedDependents(of: extDep) {
          guard let swiftDeps = dependent.swiftDeps else {
            fatalError("Dependent \(dependent) does not have swiftdeps file!")
          }
          reporter?.report(
            "Queuing because of external dependency on newer \(extDep.file?.basename ?? "extDep?")",
            path: TypedVirtualPath(file: swiftDeps.file, type: .swiftDeps))
          externallyDependentSwiftDeps.insert(swiftDeps)
        }
      }
    }
    return externallyDependentSwiftDeps.compactMap {
      moduleDependencyGraph.sourceSwiftDepsMap[$0]
    }
  }

  /// Returns the cascaded files to compile in the first wave, even though it may not be need.
  /// The needs[Non}CascadingBuild stuff was cargo-culted from the legacy driver.
  /// TODO: something better, e.g. return nothing here, but process changed swiftDeps
  /// before the whole frontend job finished.
  private static func computeSpeculativeInputs(
    changedInputs: [ChangedInput],
    externalDependents: [TypedVirtualPath],
    inputsMissingOutputs: Set<TypedVirtualPath>,
    moduleDependencyGraph: ModuleDependencyGraph,
    alwaysRebuildDependents: Bool,
    reporter: IncrementalBuild.Reporter?
  ) -> Set<TypedVirtualPath> {
    let cascadingChangedInputs = Self.computeCascadingChangedInputs(from: changedInputs,
                                                                    inputsMissingOutputs: inputsMissingOutputs,
                                                                    alwaysRebuildDependents: alwaysRebuildDependents,
                                                                    reporter: reporter)
    let cascadingExternalDependents = alwaysRebuildDependents ? externalDependents : []
    // Collect the dependent files to speculatively schedule
    var dependentFiles = Set<TypedVirtualPath>()
    let cascadingFileSet = Set(cascadingChangedInputs).union(cascadingExternalDependents)
    for cascadingFile in cascadingFileSet {
       let dependentsOfOneFile = moduleDependencyGraph
        .findDependentSourceFiles(of: cascadingFile)
      for dep in dependentsOfOneFile where !cascadingFileSet.contains(dep) {
        if dependentFiles.insert(dep).0 {
          reporter?.report(
            "Immediately scheduling dependent on \(cascadingFile.file.basename)", path: dep)
        }
      }
    }
    return dependentFiles
  }

  // Collect the files that will be compiled whose dependents should be schedule
  private static func computeCascadingChangedInputs(
    from changedInputs: [ChangedInput],
    inputsMissingOutputs: Set<TypedVirtualPath>,
    alwaysRebuildDependents: Bool,
    reporter: IncrementalBuild.Reporter?
  ) -> [TypedVirtualPath] {
    changedInputs.compactMap { changedInput in
      let inputIsUpToDate =
        changedInput.datesMatch && !inputsMissingOutputs.contains(changedInput.filePath)
      let basename = changedInput.filePath.file.basename

      // If we're asked to always rebuild dependents, all we need to do is
      // return inputs whose modification times have changed.
      guard !alwaysRebuildDependents else {
        if inputIsUpToDate {
          reporter?.report(
            "not scheduling dependents of \(basename) despite -driver-always-rebuild-dependents because is up to date")
          return nil
        } else {
          reporter?.report(
            "scheduling dependents of \(basename); -driver-always-rebuild-dependents")
          return changedInput.filePath
        }
      }

      switch changedInput.status {
      case .needsCascadingBuild:
        reporter?.report(
          "scheduling dependents of \(basename); needed cascading build")
        return changedInput.filePath
      case .upToDate:
        reporter?.report(
          "not scheduling dependents of \(basename); unknown changes")
        return nil
       case .newlyAdded:
        reporter?.report(
          "not scheduling dependents of \(basename): no entry in build record or dependency graph")
        return nil
      case .needsNonCascadingBuild:
        reporter?.report(
          "not scheduling dependents of \(basename): does not need cascading build")
        return nil
      }
    }
  }
}
