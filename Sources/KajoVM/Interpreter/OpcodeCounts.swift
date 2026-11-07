// Interpreter speed: the opcode-pair and triple counts that decide which
// instructions are fused (docs/modules/interpreter-speed.md, "The counts").
// A counting build only: compiled with `-Xswiftc -DKAJO_COUNT_OPCODES`; the
// product has none of it, and `interpret` is unchanged without the flag.
//
// Dynamic: every dispatch is counted, and a pair or triple is counted only
// when each instruction began where the one before it ended (fall-through:
// no jump taken, no send or return between), the sequences a fusion can
// replace. Static: every method and block method made through
// `makeMethodObjects` (the image build, the kasm loader, the make primitive)
// counts its pairs and triples with the second and third instruction not a
// jump target. Both go to the file `KAJO_OPCODE_COUNTS` names, appended at
// exit, one `kind a b c count` line each (`-` for an unused position).
// One table for the process, unsynchronized: run counting builds with one
// worker for exact numbers (more workers lose a few increments).

#if KAJO_COUNT_OPCODES
import Darwin

@unsafe struct OpcodeCountTables {
    var singles = [UInt64](repeating: 0, count: 256)
    var pairs = [UInt64](repeating: 0, count: 256 * 256)
    var triples: UnsafeMutablePointer<UInt64>
    var staticSingles = [UInt64](repeating: 0, count: 256)
    var staticPairs = [UInt64](repeating: 0, count: 256 * 256)
    var staticTriples = [Int: UInt64]()
    var prev1 = -1, prev2 = -1
    var expected: UnsafePointer<UInt8>? = nil
    var prevExpected: Bool = false

    init() {
        let bytes = 256 * 256 * 256 * 8
        let p = unsafe mmap(nil, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)!
        unsafe triples = p.bindMemory(to: UInt64.self, capacity: 256 * 256 * 256)
    }
}

nonisolated(unsafe) var opcodeCountTables: UnsafeMutablePointer<OpcodeCountTables> = {
    let p = UnsafeMutablePointer<OpcodeCountTables>.allocate(capacity: 1)
    unsafe p.initialize(to: OpcodeCountTables())
    atexit { dumpOpcodeCounts() }
    return unsafe p
}()

/// One dispatch: `byte` at `at`.
@inline(never)
func countOpcode(_ byte: UInt8, _ at: UnsafePointer<UInt8>) {
    let t = unsafe opcodeCountTables
    let op = Int(byte)
    unsafe t.pointee.singles[op] &+= 1
    let sequential = unsafe t.pointee.expected == at
    if sequential, unsafe t.pointee.prev1 >= 0 {
        unsafe t.pointee.pairs[t.pointee.prev1 &* 256 &+ op] &+= 1
        if unsafe t.pointee.prevExpected, unsafe t.pointee.prev2 >= 0 {
            unsafe t.pointee.triples[(t.pointee.prev2 &* 256 &+ t.pointee.prev1) &* 256 &+ op] &+= 1
        }
    }
    unsafe t.pointee.prevExpected = sequential
    unsafe t.pointee.prev2 = t.pointee.prev1
    unsafe t.pointee.prev1 = op
    let len = Opcode.decode(byte).map { $0 == .ext ? 0 : $0.length } ?? 0
    unsafe t.pointee.expected = len == 0 ? nil : at + len
}

/// One method's bytecodes as made.
func countStaticOpcodes(_ bytes: [UInt8]) {
    var ins: [DecodedInstruction] = []
    var off = 0
    while off < bytes.count, let d = decodeInstruction(bytes, at: off) {
        ins.append(d)
        off += d.length
    }
    var targets = Set<Int>()
    for d in ins where d.op.isJump { targets.insert(d.offset + d.length + d.a) }
    let t = unsafe opcodeCountTables
    func code(_ d: DecodedInstruction) -> Int { d.length > d.op.length ? Int(Opcode.ext.rawValue) : Int(d.op.rawValue) }
    for (k, d) in ins.enumerated() {
        unsafe t.pointee.staticSingles[code(d)] += 1
        guard k + 1 < ins.count, !targets.contains(ins[k + 1].offset), !d.op.endsBlock else { continue }
        unsafe t.pointee.staticPairs[code(d) * 256 + code(ins[k + 1])] += 1
        guard k + 2 < ins.count, !targets.contains(ins[k + 2].offset), !ins[k + 1].op.endsBlock else { continue }
        unsafe t.pointee.staticTriples[(code(d) * 256 + code(ins[k + 1])) * 256 + code(ins[k + 2]), default: 0] += 1
    }
}

func dumpOpcodeCounts() {
    guard let path = unsafe getenv("KAJO_OPCODE_COUNTS").map({ unsafe String(cString: $0) }) else { return }
    let t = unsafe opcodeCountTables
    func name(_ i: Int) -> String { Opcode.decode(UInt8(i))?.mnemonic ?? "byte\(i)" }
    var out = ""
    for i in 0..<256 where unsafe t.pointee.singles[i] > 0 { out += "dyn1 \(name(i)) - - \(unsafe t.pointee.singles[i])\n" }
    for i in 0..<(256 * 256) where unsafe t.pointee.pairs[i] > 0 {
        out += "dyn2 \(name(i >> 8)) \(name(i & 255)) - \(unsafe t.pointee.pairs[i])\n"
    }
    // Only the opcodes in use: 0 ..< count, and ext.
    let n = Int(Opcode.count)
    for a in 0..<n { for b in 0..<n { for c in 0..<n {
        let v = unsafe t.pointee.triples[(a * 256 + b) * 256 + c]
        if v > 0 { out += "dyn3 \(name(a)) \(name(b)) \(name(c)) \(v)\n" }
    } } }
    for i in 0..<256 where unsafe t.pointee.staticSingles[i] > 0 { out += "st1 \(name(i)) - - \(unsafe t.pointee.staticSingles[i])\n" }
    for i in 0..<(256 * 256) where unsafe t.pointee.staticPairs[i] > 0 {
        out += "st2 \(name(i >> 8)) \(name(i & 255)) - \(unsafe t.pointee.staticPairs[i])\n"
    }
    for (k, v) in unsafe t.pointee.staticTriples { out += "st3 \(name(k >> 16)) \(name((k >> 8) & 255)) \(name(k & 255)) \(v)\n" }
    guard let f = unsafe fopen(path, "a") else { return }
    unsafe fputs(out, f)
    unsafe fclose(f)
}
#endif
