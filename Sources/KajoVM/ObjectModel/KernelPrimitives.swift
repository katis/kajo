import Darwin

// Module 8b's primitives, the ones the kernel needed that 8a did not have:
//
//   75   Float printString: the shortest digits that read back as the same
//        double (Swift's), in Smalltalk's spelling (`1.0e20`, `-0.5`,
//        `nan`, `inf`)
//   78   String asFloat: the double a decimal String names (Swift's
//        `Double(_:)`, the bootstrap compiler's reader), fails otherwise
//   117  slotAt: read named or indexed pointer slot i (1-based) of any
//        object, sealed ones included: reading cannot break what sealing
//        protects (bytecodes, literal Arrays and Symbols are read-only;
//        the method dictionary and the class objects stay unwritable)
//   118  classAt: the class with index i (1-based), nil for none
//   119  classCount: the class table's size
//   140  emitEvent: kind fields: anArray. One NDJSON event to the host's
//        sink (`VMHooks.event`), timestamped now, with the Process id; the
//        fields alternate keys and values (Strings, Symbols, SmallIntegers,
//        Floats, Characters, nil, true, false, Arrays of these)
//   141  microsecondClock: monotonic microseconds (uptime)
//
// Each checks its receiver and arguments and fails cleanly.

enum KernelPrimitives {
    static let table: [(number: Int, selector: String, argc: Int)] = [
        (75, "Float printString", 0), (78, "String asFloat", 0), (117, "slotAt:", 1), (118, "classAt:", 1),
        (119, "classCount", 0), (140, "emitEvent:fields:", 2), (141, "microsecondClock", 0),
    ]
}

@inline(never)
func kernelPrimitive(_ n: Int, _ m: Machine, _ c: PrimitiveCall) -> Oop {
    let om = m.om
    switch n {
    case 75:
        guard c.argc == 0, let d = m.double(c.receiver) else { return .none }
        return m.newString(Array(smalltalkFloatString(d).utf8))
    case 78:
        guard c.argc == 0, c.receiver.isObject, om.isBytes(c.receiver) else { return .none }
        let ci = m.classIndex(of: c.receiver)
        guard ci == WellKnown.string || ci == WellKnown.symbol,
              let text = String(validating: om.bytes(of: c.receiver), as: UTF8.self),
              text.utf8.count < 400, text.allSatisfy({ $0.isASCII && ($0.isNumber || "+-.eE".contains($0)) }),
              let d = Double(text) else { return .none }
        return m.float(d)
    case 117:
        guard c.argc == 1, c.receiver.isObject, !om.isBytes(c.receiver), c.arg0.isSmallInteger else { return .none }
        let i = c.arg0.smallIntegerValue
        guard i >= 1, i <= Int64(om.count(of: c.receiver)) else { return .none }
        let v = om.load(c.receiver, Int(i - 1))
        // A weak slot's referent is kept alive while marking (as `at:`).
        unsafe keepAliveRead(m.state, c.receiver, Int(i - 1), v)
        return v
    case 118:
        guard c.argc == 1, c.arg0.isSmallInteger else { return .none }
        let i = c.arg0.smallIntegerValue
        guard i >= 1, i < Int64(om.classCount) else { return m.nilObject }
        let k = om.classOop(UInt64(i))
        return k.isObject ? k : m.nilObject
    case 119:
        return c.argc == 0 ? Oop(smallInteger: Int64(om.classCount - 1)) : .none
    case 140:
        guard c.argc == 2, let kind = m.text(c.arg0), c.arg1.isObject, m.classIndex(of: c.arg1) == WellKnown.array,
              om.count(of: c.arg1) % 2 == 0 else { return .none }
        let w = unsafe workerOf(m.state)
        var json = Array("{\"v\":1,\"kind\":".utf8)
        appendJSONString(&json, Array(kind.utf8))
        json += Array(",\"ts\":\(clock_gettime_nsec_np(CLOCK_REALTIME) / 1000)".utf8)
        let current = unsafe w.pointee.current
        if current != .none, current.isObject, !om.isBytes(current), om.count(of: current) > UInt64(ProcessLayout.id) {
            let id = om.load(current, ProcessLayout.id)
            if id.isSmallInteger { json += Array(",\"process\":\(id.smallIntegerValue)".utf8) }
        }
        let fields = c.arg1
        var k = 0
        while k < Int(om.count(of: fields)) {
            guard let key = m.text(om.load(fields, k)) else { return .none }
            json.append(44)
            appendJSONString(&json, Array(key.utf8))
            json.append(58)
            guard m.appendJSON(&json, om.load(fields, k + 1), depth: 0) else { return .none }
            k += 2
        }
        json.append(125)
        guard let vm = unsafe w.pointee.vm else { return c.receiver }
        unsafe vm.count(.events)
        if let h = unsafe vm.pointee.hooks.event {
            json.withUnsafeBufferPointer { b in unsafe h(vm.pointee.hooks.context, b.baseAddress!, b.count) }
        }
        return c.receiver
    case 141:
        return c.argc == 0 ? Oop(smallInteger: Int64(nanoseconds() / 1000)) : .none
    default:
        return .none
    }
}

/// Smalltalk's spelling of a double, from Swift's shortest round-trip
/// digits: `1.0`, `0.1`, `1.0e20`, `1.0e-7`, `nan`, `inf`, `-inf`.
func smalltalkFloatString(_ d: Double) -> String {
    if d.isNaN { return "nan" }
    if d.isInfinite { return d < 0 ? "-inf" : "inf" }
    var s = d.description  // "1.0", "1e+20", "1.5e-07"
    if let e = s.firstIndex(of: "e") {
        var mantissa = String(s[..<e])
        var exponent = String(s[s.index(after: e)...])
        if !mantissa.contains(".") { mantissa += ".0" }
        if exponent.hasPrefix("+") { exponent.removeFirst() }
        let negative = exponent.hasPrefix("-")
        if negative { exponent.removeFirst() }
        while exponent.count > 1 && exponent.hasPrefix("0") { exponent.removeFirst() }
        s = mantissa + "e" + (negative ? "-" : "") + exponent
    }
    return s
}

private func appendJSONString(_ out: inout [UInt8], _ bytes: [UInt8]) {
    out.append(34)
    for b in bytes {
        switch b {
        case 34: out += [92, 34]
        case 92: out += [92, 92]
        case 10: out += [92, 110]
        case 13: out += [92, 114]
        case 9: out += [92, 116]
        case 0..<32:
            let hex = Array("0123456789abcdef".utf8)
            out += [92, 117, 48, 48, hex[Int(b >> 4)], hex[Int(b & 15)]]
        default: out.append(b)
        }
    }
    out.append(34)
}

extension Machine {
    /// A String or Symbol's text.
    func text(_ o: Oop) -> String? {
        guard o.isObject, om.isBytes(o) else { return nil }
        let ci = classIndex(of: o)
        guard ci == WellKnown.string || ci == WellKnown.symbol else { return nil }
        return String(decoding: om.bytes(of: o), as: UTF8.self)
    }

    /// A new String holding `bytes` (valid UTF-8), `.none` when the heap is full.
    func newString(_ bytes: [UInt8]) -> Oop {
        guard bytes.count <= Header.maxLargeCount else { return .none }
        let s = allocateAny(WellKnown.string, count: bytes.count, bytes: true)
        if s == .none { return .none }
        for (i, b) in bytes.enumerated() { om.storeByte(s, i, b) }
        return s
    }

    /// One field value as JSON; false for a kind of object events do not carry.
    func appendJSON(_ out: inout [UInt8], _ v: Oop, depth: Int) -> Bool {
        if v == nilObject { out += Array("null".utf8); return true }
        if v == trueObject { out += Array("true".utf8); return true }
        if v == falseObject { out += Array("false".utf8); return true }
        if v.isSmallInteger { out += Array("\(v.smallIntegerValue)".utf8); return true }
        if v.isCharacter, let u = Unicode.Scalar(UInt32(truncatingIfNeeded: v.characterValue)) {
            appendJSONString(&out, Array(String(Character(u)).utf8))
            return true
        }
        if let s = text(v) {
            appendJSONString(&out, Array(s.utf8))
            return true
        }
        if let d = double(v) {
            out += Array((d.isFinite ? "\(d)" : "null").utf8)
            return true
        }
        guard depth < 8, v.isObject, classIndex(of: v) == WellKnown.array else { return false }
        out.append(91)
        for i in 0..<Int(om.count(of: v)) {
            if i > 0 { out.append(44) }
            guard appendJSON(&out, om.load(v, i), depth: depth + 1) else { return false }
        }
        out.append(93)
        return true
    }
}
