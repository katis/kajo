// A closed shell refuses its host's calls (docs/modules/closed-shell-calls.md).
// Since shell-close `ShellVM.close` always frees the VM and its image, so a
// host call that enters either after `close` reads freed memory.

import Darwin
import Foundation
import Testing
@testable import KajoCompiler
@testable import KajoVM

/// The hand-run (part 1, and the fix's trap): a closed shell, the freed VM
/// state overwritten, then one host call, named by `KAJO_CLOSED_SHELL_CALL`
/// (`runTurn`, `spawn` or `liveProcessCount`). It ends the test process
/// either way (signal 11 or a sanitizer report on the starting commit, the
/// refusal's message on the fix), so it runs by hand only:
/// `KAJO_CLOSED_SHELL_CALL=spawn swift test --filter aCallAfterCloseByHand`.
@Test(.enabled(if: ProcessInfo.processInfo.environment["KAJO_CLOSED_SHELL_CALL"] != nil))
func aCallAfterCloseByHand() throws {
    let call = ProcessInfo.processInfo.environment["KAJO_CLOSED_SHELL_CALL"] ?? ""
    let shell = TestShell()
    let vm = try openShell(shell)
    #expect(try run(vm, "buildCounter", on: "ShellFixture") != nil)
    let r = vm.close()
    #expect(r.destroyed)
    // Reuse the freed memory as a busy process would: allocations of the
    // VM state's size and alignment filled with a non-pointer pattern.
    let scribble = HandRunScribble(bytes: MemoryLayout<VMState>.stride, alignment: 128, count: 4096)
    defer { scribble.free() }
    print("closed-shell-call \(call): calling after close (\(r))")
    fflush(stdout)
    switch call {
    case "runTurn": print("closed-shell-call runTurn answered \(vm.runTurn(budgetNs: 1_000_000).slices) slices")
    case "spawn": print("closed-shell-call spawn answered \(String(describing: vm.spawn("buildCounter", receiver: "ShellFixture")))")
    case "liveProcessCount": print("closed-shell-call liveProcessCount answered \(vm.liveProcessCount)")
    default: Issue.record("unknown call \(call)")
    }
    print("closed-shell-call \(call): returned")
}

/// Allocations of one size and alignment filled with 0xA5: a late reader
/// of freed memory of that size follows garbage (`DelayEndTests`' Scribble).
private struct HandRunScribble {
    let blocks: [UnsafeMutableRawPointer]
    init(bytes: Int, alignment: Int, count: Int) {
        blocks = (0..<count).map { _ in
            let p = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: alignment)
            p.initializeMemory(as: UInt8.self, repeating: 0xA5, count: bytes)
            return p
        }
    }
    func free() { for p in blocks { p.deallocate() } }
}

/// Every public member of `ShellVM`: checked (its body calls
/// `checkOpen("<name>")`, once per accessor) or exempt, with why.
let shellVMChecked: Set<String> = [
    "start", "openProtocol", "stopsForDebugger", "runTurn", "checkStuck", "spawn", "state", "result", "failure",
    "waitUntilTerminated", "terminate", "release", "liveProcessCount", "resumedProcessCount", "isReleaseImage",
    "nativeBindReport", "nativeGenerated", "snapshot", "counters", "collectorReport", "mainThreadCounters",
    "pauses", "threads", "hopLatencies",
]
let shellVMExempt: [String: String] = [
    "init": "comes before any close",
    "close": "idempotent: a second close finds the flag under closeLock and frees nothing",
    "now": "the clock, no VM",
    "post": "bridge only after the unregistering; other threads post at any time and can always race a close",
    "postRequest": "bridge only after the unregistering; a connection thread can always race a close",
    "queuedEvents": "the bridge's queue under its lock",
    "queuedRequests": "the bridge's queue under its lock",
]
/// Public members of `extension ShellVM` elsewhere in `Sources/`: each
/// reaches the VM only through checked members.
let shellVMDelegating: [String: String] = [
    "isStoppedForDebugger": "KajoApp: spawn, state, result and release, each checked",
]

private let sourcesRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Sources").path

/// The public members declared at the class body's top level, by name,
/// each with its text up to the next declaration.
func shellVMMembers(_ source: String) -> [(name: String, body: String)] {
    let lines = source.components(separatedBy: "\n")
    guard let start = lines.firstIndex(where: { $0.hasPrefix("public final class ShellVM") }),
          let end = lines[(start + 1)...].firstIndex(where: { $0 == "}" }) else { return [] }
    let declaration = /^    (?:@[A-Za-z_]+ +)*(?:public |private |fileprivate |internal |package )?(?:static |convenience |final |override )*(func|var|let|init|deinit)\b/
    var out: [(name: String, public: Bool, body: [String])] = []
    for line in lines[(start + 1)..<end] {
        if line.firstMatch(of: declaration) != nil {
            let isPublic = line.contains("public ")
            let name: String
            if let m = line.firstMatch(of: /(?:func|var|let) +([A-Za-z_][A-Za-z0-9_]*)/) {
                name = String(m.1)
            } else if line.contains("deinit") {
                name = "deinit"
            } else {
                name = "init"
            }
            out.append((name, isPublic, [line]))
        } else if !out.isEmpty {
            out[out.count - 1].body.append(line)
        }
    }
    return out.filter(\.public).map { ($0.name, $0.body.joined(separator: "\n")) }
}

/// Public members of `extension ShellVM` blocks in every Swift file under
/// `Sources/` but the class's own.
func shellVMExtensionMembers() throws -> [(file: String, name: String)] {
    var out: [(file: String, name: String)] = []
    let files = FileManager.default.enumerator(atPath: sourcesRoot)!.compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") }
    for f in files {
        let text = try String(contentsOfFile: sourcesRoot + "/" + f, encoding: .utf8)
        var inside = false
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("extension ShellVM") { inside = true; continue }
            if inside && line == "}" { inside = false; continue }
            if inside, line.hasPrefix("    public "), let m = line.firstMatch(of: /(?:func|var) +([A-Za-z_][A-Za-z0-9_]*)/) {
                out.append((f, String(m.1)))
            }
        }
    }
    return out
}

@Suite struct ClosedShellCallsTests {
    /// The guard answers nothing while the shell is open and the refusal's
    /// message for every checked member once it is closed; the bridge's
    /// calls and a second close still work after it.
    @Test func theGuardRefusesEveryCheckedCallAfterClose() throws {
        let shell = TestShell()
        let vm = try openShell(shell)
        for name in shellVMChecked.sorted() + shellVMExempt.keys.sorted() {
            #expect(vm.refusal(name) == nil, "\(name) refused while open")
        }
        #expect(vm.close().destroyed)
        for name in shellVMChecked.sorted() {
            #expect(vm.refusal(name) == "ShellVM.\(name) after close")
        }
        // The exempt calls after a close: no trap, no VM.
        vm.post(ShellEvent(kind: .synthetic, value: .int(1), timeNs: ShellVM.now()))
        vm.postRequest(connection: 1, json: Array(#"{"op":"ping","id":1}"#.utf8))
        #expect(vm.queuedEvents == 1 && vm.queuedRequests == 1)
        #expect(!vm.close().destroyed)
        #expect(vm.vm.lateSignals == 0)
    }

    /// Every public member of `ShellVM` is checked (its body calls the
    /// check with its own name, once per accessor) or exempt with a reason;
    /// a new member that is neither fails here by name, and so does a
    /// checked member whose check was removed.
    @Test func everyPublicMemberIsCheckedOrExempt() throws {
        let source = try String(contentsOfFile: sourcesRoot + "/KajoVM/Shell/Shell.swift", encoding: .utf8)
        let members = shellVMMembers(source)
        #expect(members.count > 25, "the scan found \(members.count) members")
        var seen = Set<String>()
        for (name, body) in members {
            seen.insert(name)
            let checks = body.components(separatedBy: "checkOpen(\"\(name)\")").count - 1
            let accessors = max(1, body.components(separatedBy: " get {").count - 1 + body.components(separatedBy: " set {").count - 1)
            if shellVMChecked.contains(name) {
                #expect(checks == accessors, "ShellVM.\(name) is listed as checked but calls checkOpen(\"\(name)\") \(checks) times for \(accessors) accessors")
            } else if let why = shellVMExempt[name] {
                #expect(checks == 0, "ShellVM.\(name) is exempt (\(why)) but checks")
            } else {
                Issue.record("ShellVM.\(name) is neither checked nor exempt: check it with checkOpen(\"\(name)\") or say why it is exempt")
            }
        }
        for name in shellVMChecked.union(shellVMExempt.keys) where !seen.contains(name) {
            Issue.record("ShellVM.\(name) is listed but not declared")
        }
        let extensions = try shellVMExtensionMembers()
        #expect(!extensions.isEmpty, "the scan found no extension member")
        for (file, name) in extensions where shellVMDelegating[name] == nil {
            Issue.record("ShellVM.\(name) (\(file)) is an extension member not on the delegating list")
        }
        print("closed-shell-calls members=\(members.count) checked=\(shellVMChecked.count) exempt=\(shellVMExempt.count) extensions=\(extensions.map(\.name))")
    }
}
