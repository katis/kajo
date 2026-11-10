// Collectors review, finding 2: a primitive answers failure for a bad
// argument and never traps. `replaceFrom:to:with:startingAt:` computed
// `stop - start + 1` with trapping arithmetic before its bounds check, so
// `replaceFrom: SmallInteger minVal to: SmallInteger maxVal ...` killed
// the VM; `basicNew:` of a word class multiplied before its check. Every
// primitive that takes a SmallInteger argument is called here with
// minVal, maxVal, -1, 0 and the receiver's count + 1 in each integer
// argument (all combinations), and the VM must answer every call (the
// discoverability follow-up added 167 and 168, the pointersTo: follow-up
// 169 and 170). Large
// bytes: `basicNew:` also takes the old and the new size limits and one
// past each, and primitive 38 a byte receiver.

import Testing
@testable import KajoVM

/// One primitive call: the primitive, the receiver (kasm that pushes it),
/// and its arguments, each an integer position or kasm that pushes it.
private struct PrimitiveCase {
    let prim: Int
    let receiver: String
    let args: [String?]  // nil: an integer argument
    let count: Int64      // the receiver's count, for count + 1
}

private let minVal = "\(Oop.smallIntegerMin)", maxVal = "\(Oop.smallIntegerMax)"

private func extremes(_ count: Int64) -> [String] { [minVal, maxVal, "-1", "0", "\(count + 1)"] }

/// Large bytes: `basicNew:` also takes the old limit (the count field's,
/// 16 777 215), one past it (a long byte object for the byte kinds, past
/// the limit for pointers), the byte objects' new limit and one past it.
private let sizeBoundaries = ["\(Header.maxLargeCount)", "\(Header.maxLargeCount + 1)", "\(Header.maxByteLength)",
                              "\(Header.maxByteLength + 1)"]

private let array3 = "  push_lit @Array\n  push_int 3\n  send new: 1\n"
private let bytes4 = "  push_lit @ByteArray\n  push_int 4\n  send new: 1\n"
private let text = "  push_lit 'hello'\n"

private let cases: [PrimitiveCase] = {
    var c: [PrimitiveCase] = []
    for r in [(array3, 3), (bytes4, 4), (text, 5)] as [(String, Int64)] { c.append(PrimitiveCase(prim: 1, receiver: r.0, args: [nil], count: r.1)) }
    c.append(PrimitiveCase(prim: 2, receiver: array3, args: [nil, nil], count: 3))
    c.append(PrimitiveCase(prim: 2, receiver: bytes4, args: [nil, nil], count: 4))
    for k in ["@Array", "@ByteArray", "@String", "@W16", "@W32", "@W64"] {
        c.append(PrimitiveCase(prim: 3, receiver: "  push_lit \(k)\n", args: [nil], count: 0))
    }
    for p in [6, 7] + Array(40...57) { c.append(PrimitiveCase(prim: p, receiver: "", args: [nil], count: 0)) }
    c.append(PrimitiveCase(prim: 14, receiver: "  push_nil\n", args: [nil], count: Int64(Image.globalCount)))
    c.append(PrimitiveCase(prim: 15, receiver: "  push_nil\n", args: [nil, "  push_int 0\n"], count: Int64(Image.globalCount)))
    c.append(PrimitiveCase(prim: 25, receiver: "  push_nil\n", args: [nil, "  push_nil\n"], count: 0))
    c.append(PrimitiveCase(prim: 38, receiver: array3, args: [nil, nil, array3, nil], count: 3))
    // Large bytes: primitive 38 copies bytes too.
    c.append(PrimitiveCase(prim: 38, receiver: bytes4, args: [nil, nil, bytes4, nil], count: 4))
    // The review fixes (items 1, 17, 21): primitive 38 over pointer objects
    // past one polled chunk (32 768 slots), 93 given an integer where it
    // takes a Boolean, and 148 given integers for its path and its text.
    let array40k = "  push_lit @Array\n  push_lit 40000\n  send new: 1\n"
    c.append(PrimitiveCase(prim: 38, receiver: array40k, args: [nil, nil, array40k, nil], count: 40000))
    c.append(PrimitiveCase(prim: 93, receiver: array3, args: [nil], count: 3))
    c.append(PrimitiveCase(prim: 148, receiver: "  push_nil\n", args: [nil, nil], count: 0))
    c.append(PrimitiveCase(prim: 73, receiver: "  push_lit 1.5\n", args: [nil], count: 0))
    c.append(PrimitiveCase(prim: 77, receiver: "  push_nil\n", args: [nil], count: 0))
    c.append(PrimitiveCase(prim: 91, receiver: array3, args: [nil], count: 3))
    c.append(PrimitiveCase(prim: 92, receiver: array3, args: [nil, "  push_int 7\n"], count: 3))
    c.append(PrimitiveCase(prim: 101, receiver: "  push_this_context\n", args: [nil], count: 1))
    c.append(PrimitiveCase(prim: 102, receiver: "  push_this_context\n", args: [nil, "  push_int 7\n"], count: 1))
    c.append(PrimitiveCase(prim: 116, receiver: "  push_int 9\n  push_closure blk 1\n", args: [nil], count: 1))
    c.append(PrimitiveCase(prim: 117, receiver: array3, args: [nil], count: 3))
    c.append(PrimitiveCase(prim: 118, receiver: "  push_nil\n", args: [nil], count: 0))
    for p in [124, 125, 132, 136] { c.append(PrimitiveCase(prim: p, receiver: text, args: [nil], count: 5)) }
    c.append(PrimitiveCase(prim: 127, receiver: text, args: [nil, nil], count: 5))
    c.append(PrimitiveCase(prim: 128, receiver: bytes4, args: ["  push_lit $a\n", nil], count: 4))
    c.append(PrimitiveCase(prim: 134, receiver: text, args: ["  push_lit 'l'\n", nil], count: 5))
    c.append(PrimitiveCase(prim: 152, receiver: "  push_nil\n", args: [nil], count: 0))
    // The discoverability follow-up: the limit of allInstancesOf:limit:
    // (167), and an integer where 167 and 168 take a class or an Array.
    c.append(PrimitiveCase(prim: 167, receiver: "  push_nil\n", args: ["  push_lit @Array\n", nil], count: 0))
    c.append(PrimitiveCase(prim: 167, receiver: "  push_nil\n", args: [nil, nil], count: 0))
    c.append(PrimitiveCase(prim: 168, receiver: "  push_nil\n", args: [nil], count: 0))
    // The pointersTo: follow-up: the limit of pointersTo:limit: (169), and
    // an integer as the target of 169 and 170 (an immediate is a target).
    c.append(PrimitiveCase(prim: 169, receiver: "  push_nil\n", args: ["  push_lit @Array\n", nil], count: 0))
    c.append(PrimitiveCase(prim: 169, receiver: "  push_nil\n", args: [nil, nil], count: 0))
    c.append(PrimitiveCase(prim: 170, receiver: "  push_nil\n", args: [nil], count: 0))
    return c
}()

/// The integer operations take an extreme receiver too.
private func receivers(_ c: PrimitiveCase) -> [String] {
    c.receiver.isEmpty ? extremes(0).map { "  push_lit \($0)\n" } : [c.receiver]
}

private func selector(_ prim: Int, _ argc: Int) -> String {
    argc == 0 ? "p\(prim)" : "p\(prim):" + String(repeating: "a:", count: argc - 1)
}

/// Where the calls go (a class holds at most 512 methods): the class name
/// in kasm and a receiver of it.
private let holders = ["UndefinedObject", "True", "False", "SmallInteger", "Character"]

private func holderReceiver(_ k: Int, _ image: Image) -> Oop {
    [image.nilObject, image.trueObject, image.falseObject, Oop(smallInteger: 0), Oop(character: 65)][k]
}
private let callsPerHolder = 300

/// The kasm: a method per primitive, then one method per call.
private func extremeSource() -> (src: String, calls: [String]) {
    var src = """
    class W16 Object 0 words16
    class W32 Object 0 words32
    class W64 Object 0 words64

    """
    var defined = Set<String>()
    var calls: [String] = []
    for c in cases {
        let sel = selector(c.prim, c.args.count)
        if defined.insert(sel).inserted {
            src += "method Object \(sel) temps=0 prim=\(c.prim)\n  push_nil\n  return_top\nend\n"
        }
        // Every combination of the extreme values in the integer positions.
        var combos: [[String]] = [[]]
        for a in c.args {
            combos = combos.flatMap { prefix in
                (a.map { [$0] } ?? (extremes(c.count) + (c.prim == 3 ? sizeBoundaries : [])).map { "  push_lit \($0)\n" })
                    .map { prefix + [$0] }
            }
        }
        for r in receivers(c) {
            for combo in combos {
                let name = "call\(calls.count)"
                calls.append(name)
                src += "method \(holders[(calls.count - 1) / callsPerHolder]) \(name) temps=1\n" + r + combo.joined()
                    + "  send \(sel) \(c.args.count)\n  pop\n  push_int 0\n  return_top\n"
                if c.prim == 116 { src += "block blk args=0 copied=1 temps=1\n  push_temp 0\n  block_return\n" }
                src += "end\n"
            }
        }
    }
    return (src, calls)
}

@Test func everyPrimitiveAnswersExtremeIntegerArguments() throws {
    let (src, calls) = extremeSource()
    #expect(calls.count > 800)
    let rt = try Runtime(src, background: 1, start: false)
    for (k, name) in calls.enumerated() {
        let p = try #require(rt.vm.spawn(receiver: holderReceiver(k / callsPerHolder, rt.image), selector: name))
        while rt.vm.liveProcessCount > 0 { _ = rt.vm.runOneSlice(worker: 1) }
        #expect(rt.vm.error(of: p) == nil, "\(name): \(String(describing: rt.vm.error(of: p)))")
        #expect(rt.result(p) == 0, "\(name)")
        rt.vm.release(p)
    }
    rt.noFailures()
    rt.stop()
}
