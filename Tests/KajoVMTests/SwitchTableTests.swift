// The third review's small fixes, part 2, item 5 (verification.R4): every
// field of the six test-switch structs has a row here, naming the test that
// sets it, or how its broken variant is run by hand, or the option it is.
// A new switch without a row fails, and a row whose switch is gone fails
// ("A rule every member of a type must keep is kept by a test that reads
// the source", as ClosedShellCallsTests does for ShellVM).

import Foundation
import Testing

enum SwitchRow {
    /// The test file (a basename under Tests/) and the function in it that
    /// sets the switch.
    case test(String, String)
    /// A broken variant run by hand: the doc (under docs/) that says how,
    /// and what it must give.
    case byHand(String, String)
    /// Not a broken variant but a knob: the command-line option that sets
    /// it, and the doc that records its by-hand run.
    case option(String, String)
}

/// The six structs: file under Sources/KajoVM and name.
let switchStructs: [(file: String, name: String)] = [
    ("ObjectMemory/Config.swift", "TestSwitches"), ("Workers/VMConfig.swift", "VMTestSwitches"),
    ("Nursery/NurseryConfig.swift", "NurseryTestSwitches"), ("Marking/MarkingConfig.swift", "MarkingTestSwitches"),
    ("Relocation/RelocationConfig.swift", "RelocationTestSwitches"), ("YoungCollection/YoungConfig.swift", "YoungTestSwitches"),
]

let switchTable: [String: SwitchRow] = [
    "TestSwitches.ignorePins": .test("CompactionTests.swift", "withoutThePinRuleThePinnedObjectMoves"),
    "TestSwitches.trustCountField": .test("LongBytesPrimitiveTests.swift", "aLongByteArrayIsIndexedPastTheCountField"),
    "TestSwitches.trustLongLength": .test("LongBytesTests.swift", "aLoaderThatTrustsTheLengthLetsItPassTheRun"),
    "TestSwitches.skipUnwindMarks": .test("ClosureTests.swift", "aNonLocalReturnRunsTheEnsureBlocksItCrosses"),
    "TestSwitches.superFromReceiverClass": .test("SendTests.swift", "superLooksUpFromTheMethodsClass"),
    "TestSwitches.noNormalization": .test("NumberTests.swift", "largeIntegerResultsAreNormalized"),
    "TestSwitches.noBoundaryCheck": .test("StringTests.swift", "aPositionInsideAScalarFails"),
    "TestSwitches.pinWalkSkipsContext": .test("ObjectModelVMTests.swift", "contextMaterializationKeepsTheFramePin"),
    "TestSwitches.runBlind": .test("LargeObjectVMTests.swift", "largeRuntime"),
    "TestSwitches.noSmallFloatPath": .test("SmallFloatPathTests.swift", "theSmallFloatPathAnswersAsTheOldPath"),
    "TestSwitches.noFusion": .test("FusionTests.swift", "fusedInstructionsAnswerAsThePlainOnes"),
    "VMTestSwitches.keepResultRegister": .test("ProcessRootsTests.swift", "theResultRegisterIsClearedAtTermination"),
    "VMTestSwitches.countReleasedAsParked": .test("SafepointTests.swift", "backToBackStopsDoNotLetReleasedWorkersRun"),
    "VMTestSwitches.flushAfterStop": .test("ProcessRootsTests.swift", "registersAreFlushedBeforeEveryStop"),
    "VMTestSwitches.publishBeforeClearing": .test("ProcessRootsTests.swift", "aSuspendedProcessIsPublishedAfterClearingCurrent"),
    "VMTestSwitches.noBytePolls": .test("LongBytesMeasurement.swift", "longByteObjectsMeasured"),
    "VMTestSwitches.buildingPauseUs": .test("ZeroingTests.swift", "huntWhileZeroing"),
    "VMTestSwitches.walksSeeBuilding": .test("ZeroingTests.swift", "huntWhileZeroing"),
    "VMTestSwitches.slowPeek": .test("ZeroingTests.swift", "withoutTheMarkAStringIsSeenHalfFilled"),
    "VMTestSwitches.internNoKeepAlive": .test("SymbolInterningTests.swift", "secondLookupDuringMarking"),
    "VMTestSwitches.internNoSecondLookup": .test("SymbolInterningTests.swift", "internSymbolsRuntime"),
    "VMTestSwitches.internPublishBeforeFill": .test("SymbolInterningTests.swift", "lookupsDuringAnInsert"),
    "VMTestSwitches.internPauseUs": .test("SymbolInterningTests.swift", "lookupsDuringAnInsert"),
    "VMTestSwitches.internSlowAllocation": .test("SymbolInterningTests.swift", "internSymbolsRuntime"),
    "VMTestSwitches.symbolBucketMax": .test("SymbolTableFullTests.swift", "fullTableRuntime"),
    "VMTestSwitches.symbolFullFailsAtOnce": .test("SymbolTableFullTests.swift", "fullTableRuntime"),
    "VMTestSwitches.lateSignalsIgnoreEnd": .test("DelayEndTests.swift", "brokenVariantALateTimerTouchesTheFreedVM"),
    "NurseryTestSwitches.skipBarrierAt": .test("BarrierSiteTests.swift", "siteScenario"),
    "NurseryTestSwitches.dropCarriedHolders": .test("AgeTests.swift", "anOldHolderOfASurvivorStaysRemembered"),
    "NurseryTestSwitches.forgetPromotedHolders": .test("AgeTests.swift", "aPromotedHolderOfASurvivorIsRemembered"),
    "NurseryTestSwitches.sameClaimTag": .test("AgeTests.swift", "aSurvivorIsCopiedByTheNextScavenge"),
    "NurseryTestSwitches.keepDeadWeakSlots": .test("WeakTests.swift", "withoutNilingTheVerifierReportsADanglingWeakSlot"),
    "NurseryTestSwitches.promotionReserveBlocks": .test("VMEndTests.swift", "runKeep"),
    "NurseryTestSwitches.keptAcrossNurseries": .test("VerifierFaultsTests.swift", "keptAcrossRun"),
    "NurseryTestSwitches.keptAcrossWithoutRescan": .test("VerifierFaultsTests.swift", "keptAcrossRun"),
    "MarkingTestSwitches.satbOff": .test("ConcurrentMarkingTests.swift", "satbScenario"),
    "MarkingTestSwitches.literal": .test("ConcurrentMarkingTests.swift", "literalPromotion"),
    "MarkingTestSwitches.literalGrey": .test("ConcurrentMarkingTests.swift", "literalPromotion"),
    "MarkingTestSwitches.noSurvivorRoots": .test("ConcurrentMarkingTests.swift", "survivorAtSnapshot"),
    "MarkingTestSwitches.noRememberedFilter": .test("ConcurrentMarkingTests.swift", "deadRememberedHolder"),
    "MarkingTestSwitches.noWeakKeepAlive": .test("WeakMarkingTests.swift", "weakReadDuringMarking"),
    "MarkingTestSwitches.qosOnBlocksOnly": .test("FallbackPolicyTests.swift", "policyWantsRaise"),
    "MarkingTestSwitches.noSweepForEntries": .test("FallbackPolicyTests.swift", "tableRunsOutWhileSweeping"),
    "MarkingTestSwitches.unboundedFinalMark": .test("FinalMarkTests.swift", "finalMarkAgainstTheBound"),
    "MarkingTestSwitches.noOwedScanBarrier": .test("FinalMarkTests.swift", "storeIntoAnOwedNursery"),
    "MarkingTestSwitches.collectBeforeRootScan": .test("FinalMarkTests.swift", "collectionOfAnOwedNursery"),
    "MarkingTestSwitches.markerSkipsRootScans": .test("FinalMarkTests.swift", "storeIntoAnOwedNursery"),
    "MarkingTestSwitches.sweepStopUnbounded": .test("SweepStopTests.swift", "withTheSwitchTheSweepStopFinishesTheWholeSweep"),
    "MarkingTestSwitches.applyAheadOfSweep": .test("SweepStopTests.swift", "handingOverAnEntryTheSweepHasNotReachedFailsTheVerifier"),
    "MarkingTestSwitches.noEntryRateRule": .test("SweepStopTests.swift", "theEntryRateRuleStartsACycleBeforeTheTableFills"),
    "MarkingTestSwitches.noStalls": .test("FallbackPolicyTests.swift", "raisedDuringTheCycle"),
    "MarkingTestSwitches.stallsWithoutMarker": .test("FallbackPolicyTests.swift", "waitForTheCycle"),
    "MarkingTestSwitches.stallJustifiedByRunningCycle": .test("AllocationStallTests.swift", "fullHeapUnjustified"),
    "MarkingTestSwitches.stallIgnoresEntries": .test("AllocationStallTests.swift", "entriesGate"),
    "MarkingTestSwitches.markerSlowdown": .test("AllocationStallTests.swift", "headless"),
    "RelocationTestSwitches.pinRule": .test("RelocationTests.swift", "framePin"),
    "RelocationTestSwitches.hazardRule": .test("RelocationTests.swift", "hazard"),
    "RelocationTestSwitches.epochRule": .test("RelocationTests.swift", "epochs"),
    "RelocationTestSwitches.enterZero": .test("RelocationTests.swift", "enterWindow"),
    "RelocationTestSwitches.manualRelocation": .test("LargeObjectVMTests.swift", "relocationScenario"),
    "YoungTestSwitches.youngDeletionBarrier": .test("YoungCollectionTests.swift", "withoutTheYoungDeletionBarrierTheValueIsLost"),
    "YoungTestSwitches.secondHandshake": .test("YoungCollectionTests.swift", "withoutTheSecondHandshakeTheDeletionRecordIsNeverSeen"),
    "YoungTestSwitches.crossNurseryBarrier": .test("YoungCollectionTests.swift", "crossNursery"),
    "YoungTestSwitches.handshakeStackScan": .test("YoungCollectionTests.swift", "stackOnly"),
    "YoungTestSwitches.epochRule": .test("RelocationTests.swift", "epochs"),
    "YoungTestSwitches.carryHolders": .test("YoungCollectionTests.swift", "carried"),
    "YoungTestSwitches.newHalfScan": .test("YoungCollectionTests.swift", "newHalf"),
    "YoungTestSwitches.deferredOwnership": .test("YoungCollectionTests.swift", "deferredAcrossACycle"),
    "YoungTestSwitches.quiescentWakeZero": .test("YoungCollectionTests.swift", "wakeWindow"),
    "YoungTestSwitches.arrayCopyOrdering": .test("YoungCollectionTests.swift", "copyAcrossTheScan"),
    "YoungTestSwitches.youngRoots": .test("YoungCollectionTests.swift", "youngRootAtSnapshot"),
    "YoungTestSwitches.mainCollectsItsOwnNursery": .test("MainOffloadTests.swift", "mainCollects"),
    "YoungTestSwitches.hook": .test("YoungSupport.swift", "install"),
    "YoungTestSwitches.hookContext": .test("YoungSupport.swift", "install"),
    "VMTestSwitches.noPendingRoots": .test("ProcessTests.swift", "withoutPendingRootsTheSemaphoresAreLostToACollection"),
    "MarkingTestSwitches.youngRootsInStop": .test("FinalMarkTests.swift", "withYoungRootsInStopTheInitialMarkScansInItsStop"),
    "MarkingTestSwitches.stallRelocation": .option("--stall-reloc", "docs/modules/review-3-small-fixes-part-2.md"),
    "YoungTestSwitches.mainWaitsForWantedStops": .byHand("docs/modules/final-mark.md",
        "the second collection never opens inside the hook (theMainWorkerOpensOneCollectionWhileAStopIsWanted)"),
]

private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().path

/// The fields (top-level `var`s) of struct `name` in `source`.
func switchFields(_ source: String, _ name: String) -> [String] {
    guard let start = source.range(of: "struct \(name)"), let open = source[start.upperBound...].firstIndex(of: "{") else { return [] }
    var depth = 0, line = "", out: [String] = []
    var i = open
    repeat {
        let ch = source[i]
        if ch == "{" { depth += 1 } else if ch == "}" { depth -= 1 }
        if ch == "\n" {
            if depth == 1, let m = line.firstMatch(of: /^\s*(?:public |package )?var (\w+)/) { out.append(String(m.1)) }
            line = ""
        } else {
            line.append(ch)
        }
        i = source.index(after: i)
    } while depth > 0 && i < source.endIndex
    return out
}

/// Every field of the six structs, as "Struct.field".
func allSwitchFields() throws -> [String] {
    try switchStructs.flatMap { s in
        let text = try String(contentsOfFile: repoRoot + "/Sources/KajoVM/" + s.file, encoding: .utf8)
        return switchFields(text, s.name).map { "\(s.name).\($0)" }
    }
}

/// The rows the fields lack, the rows whose field is gone, and the rows
/// whose test, doc or option does not name the switch.
func switchTableProblems(fields: [String], table: [String: SwitchRow]) throws -> [String] {
    var problems: [String] = []
    for f in fields where table[f] == nil { problems.append("\(f): no row") }
    for k in table.keys where !fields.contains(k) { problems.append("\(k): a row with no such field") }
    let tests = FileManager.default.enumerator(atPath: repoRoot + "/Tests")?.compactMap { $0 as? String } ?? []
    for (k, row) in table {
        let field = String(k.split(separator: ".")[1])
        switch row {
        case .test(let file, let fn):
            guard let rel = tests.first(where: { $0.hasSuffix("/" + file) }) else { problems.append("\(k): no test file \(file)"); continue }
            let text = try String(contentsOfFile: repoRoot + "/Tests/" + rel, encoding: .utf8)
            if !text.contains("func \(fn)") { problems.append("\(k): \(file) has no func \(fn)") }
            if text.firstMatch(of: try Regex("\\.\(field)\\b")) == nil { problems.append("\(k): \(file) does not name .\(field)") }
        case .byHand(let doc, _), .option(_, let doc):
            let text = (try? String(contentsOfFile: repoRoot + "/" + doc, encoding: .utf8)) ?? ""
            if !text.contains(field) { problems.append("\(k): \(doc) does not name \(field)") }
            if case .option(let flag, _) = row {
                let cli = try String(contentsOfFile: repoRoot + "/Sources/kajo/main.swift", encoding: .utf8)
                if !cli.contains("\"\(flag)\"") { problems.append("\(k): kajo has no option \(flag)") }
            }
        }
    }
    return problems.sorted()
}

@Suite struct SwitchTableTests {
    @Test func everySwitchHasARow() throws {
        let fields = try allSwitchFields()
        print("switch table: \(fields.count) fields in \(switchStructs.count) structs, \(switchTable.count) rows")
        #expect(fields.count >= 75)
        let problems = try switchTableProblems(fields: fields, table: switchTable)
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    /// The check itself: a field with no row and a row with no field are
    /// both named (the hand-run variant adds a field to a struct in a
    /// scratch tree; this is the same check over a changed list).
    @Test func aFieldWithoutARowIsNamed() throws {
        var fields = try allSwitchFields()
        fields.append("VMTestSwitches.aSwitchWithNoRow")
        let problems = try switchTableProblems(fields: fields, table: switchTable)
        #expect(problems == ["VMTestSwitches.aSwitchWithNoRow: no row"])
        var table = switchTable
        table["VMTestSwitches.gone"] = .test("ProcessTests.swift", "x")
        let more = try switchTableProblems(fields: try allSwitchFields(), table: table)
        #expect(more.contains("VMTestSwitches.gone: a row with no such field"))
    }
}
