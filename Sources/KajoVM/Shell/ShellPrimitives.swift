import Darwin

// Module 9a's primitives, the shell's (docs/modules/shells.md, ADR 0010):
//
//   150  View class primCall: op handle: h with: args. A hop primitive: on
//        the main worker it decodes op (a Symbol or String), h (a
//        SmallInteger or nil) and args (an Array of nil, true, false,
//        SmallIntegers, Floats, Strings and Symbols) into a `ViewCall`,
//        calls the shell's view host in a blocking region (it touches no
//        heap object) and answers the host's `ShellValue`; off main it
//        suspends the Process, makes it main-affine and retries the send on
//        the main worker, as primitive 29 does. Fails with no shell (so
//        headless code never hops to a main thread nobody turns), at the
//        bottom of a Process, on an argument it cannot decode, and when the
//        host answers nil (an unknown op or handle). Module 9c: a call on
//        main that ends past the turn's deadline makes the next poll check
//        the budget (a view call can take milliseconds, a send nanoseconds).
//   151  View class hasShell: whether a view host is installed.
//   152  View class releaseHandle: h. Tells the shell the wrapper of h died
//        (any worker; the shell releases the native view on its main
//        thread). With no shell it answers the receiver and does nothing.
//   153  UIEventLoop class eventSemaphore: sem. The Semaphore the shell's
//        event queue signals once per event (a pending root, replacing an
//        earlier one); events queued before are signalled now. Fails with
//        no shell.
//   154  UIEventLoop class nextEvent: the oldest queued event as an Array
//        {kind. target. value. microseconds}, or nil. `kind` and `target`
//        are SmallIntegers (target 0: none), `value` nil, a SmallInteger, a
//        Float or a String, `microseconds` the time the event happened on
//        the clock of `Smalltalk microsecondClock` (primitive 141). Fails
//        with no shell.
//
// Module 9c (docs/modules/developer-ui.md):
//
//   164  ClientTransport class primCall: op handle: h with: args. The
//        protocol client's transport: op, the connection handle (nil or a
//        SmallInteger) and args (as primitive 150's) to the host's `client`
//        callback, on any worker, in a blocking region (it touches no heap
//        object), and the host's answer. Not a hop: the host owns the
//        sockets and posts what they receive as `line` and `lost` events.
//        Fails with no client host, on an argument it cannot decode and
//        when the host answers nil.
//
// Each checks its receiver and arguments and fails cleanly. None of them is
// on a hot path: they are out of line from `primitive`.

enum ShellPrimitives {
    static let table: [(number: Int, selector: String, argc: Int)] = [
        (150, "primCall:handle:with:", 3), (151, "hasShell", 0), (152, "releaseHandle:", 1),
        (153, "eventSemaphore:", 1), (154, "nextEvent", 0),
        (159, "DevProtocol class primRegister:", 1), (160, "DevProtocol class primNextRequest", 0),
        (161, "DevProtocol class primEmit:", 1), (164, "ClientTransport class primCall:handle:with:", 3),
    ]
}

@inline(never)
func shellPrimitive(_ n: Int, _ m: Machine, _ c: PrimitiveCall) -> Oop {
    let w = unsafe workerOf(m.state)
    guard let vm = unsafe w.pointee.vm else { return n == 151 ? (c.argc == 0 ? m.falseObject : .none) : .none }
    let bridge = unsafe shellBridge(vm)
    switch n {
    case 150:
        guard c.argc == 3, let bridge, let host = bridge.callbacks.views else { return .none }
        if unsafe w.pointee.isMain {
            guard let call = decodeViewCall(m, c) else { return .none }
            unsafe blockingBegin(vm, w)
            let answer = host(call)
            unsafe blockingEnd(vm, w)
            unsafe vm.count(.viewCalls)
            // Module 9c: a view call can take milliseconds of the toolkit's
            // time (a window made, a table reloaded) where a send takes
            // nanoseconds, so a turn that makes many overran its budget by
            // the time of the 1024 polls before its next budget check: past
            // the deadline, the next poll checks it.
            if unsafe ticks() >= w.pointee.deadline { unsafe w.pointee.interp.countdown = 1 }
            guard let answer else { return .none }
            return encode(m, answer)
        }
        // Off main: retry the send on the main worker (no side effect yet).
        guard unsafe w.pointee.interp.regs.hdr != 0, unsafe w.pointee.current != .none else { return .none }
        let r = unsafe w.pointee.interp.regs
        unsafe requeueCurrent(vm, w, sp: r.sp, pc: r.pc &- w.pointee.interp.sendLength, affinity: Affinity.main,
                              reason: .suspended, hop: true)
        unsafe vm.count(.hops)
        unsafe vm.count(.viewHops)
        return c.receiver
    case 151:
        guard c.argc == 0 else { return .none }
        return bridge?.callbacks.views != nil ? m.trueObject : m.falseObject
    case 152:
        guard c.argc == 1, c.arg0.isSmallInteger else { return .none }
        if let bridge, let release = bridge.callbacks.release {
            release(Int(c.arg0.smallIntegerValue))
            unsafe vm.count(.viewReleases)
        }
        return c.receiver
    case 153:
        guard c.argc == 1, let bridge, c.arg0.isObject, m.om.classIndex(of: c.arg0) == WellKnown.semaphore else { return .none }
        let h = unsafe registerPending(vm, c.arg0)
        if h < 0 { return .none }
        let (old, owed) = bridge.register(c.arg0, handle: h)
        if old >= 0 { unsafe unregisterPending(vm, old) }
        for _ in 0..<owed { unsafe signalSemaphore(vm, w, c.arg0) }
        return c.receiver
    case 154:
        guard c.argc == 0, let bridge else { return .none }
        guard let e = bridge.take() else { return m.nilObject }
        unsafe vm.count(.shellEvents)
        return eventArray(m, e)
    // Module 9b: the development protocol (docs/modules/development-protocol.md).
    case 159:
        guard c.argc == 1, let bridge, !m.om.isReleaseImage, c.arg0.isObject,
              m.om.classIndex(of: c.arg0) == WellKnown.semaphore, bridge.isProtocolOpen else { return .none }
        let h = unsafe registerPending(vm, c.arg0)
        if h < 0 { return .none }
        guard let (old, owed) = bridge.registerProtocol(c.arg0, handle: h) else {
            unsafe unregisterPending(vm, h)
            return .none
        }
        if old >= 0 { unsafe unregisterPending(vm, old) }
        for _ in 0..<owed { unsafe signalSemaphore(vm, w, c.arg0) }
        return c.receiver
    case 160:
        guard c.argc == 0, let bridge, !m.om.isReleaseImage else { return .none }
        guard let (conn, json) = bridge.takeRequest() else { return m.nilObject }
        let text = m.newString(json)
        if text == .none { return .none }
        let a = m.allocate(WellKnown.array, slots: 2, keeping: text)
        if a == .none { return .none }
        m.store(a, 0, Oop(smallInteger: Int64(conn)), .atPut)
        m.store(a, 1, text, .atPut)
        unsafe vm.count(.protocolRequests)
        return a
    case 161:
        // A line the protocol wrote (a reply or an event) to the host's
        // event sink as it is: a String of valid UTF-8, one JSON object, no
        // line break. The host's transport routes replies by their "conn".
        // Module 9c: or an Array of Strings and ByteArrays, joined (a line
        // longer than one object can be: `Json writePieces:`).
        guard c.argc == 1, let bridge, !m.om.isReleaseImage, bridge.isProtocolOpen, let bytes = lineBytes(m, c.arg0) else { return .none }
        guard bytes.first == 123, bytes.last == 125, !bytes.contains(10), !bytes.contains(13),
              String(validating: bytes, as: UTF8.self) != nil else { return .none }
        unsafe vm.count(.protocolReplies)
        if let f = bridge.callbacks.events { f(bytes) }
        return c.receiver
    case 164:
        guard c.argc == 3, let bridge, let host = bridge.callbacks.client, let call = decodeViewCall(m, c) else { return .none }
        unsafe blockingBegin(vm, w)
        let answer = host(call)
        unsafe blockingEnd(vm, w)
        unsafe vm.count(.clientCalls)
        guard let answer else { return .none }
        return encode(m, answer)
    default:
        return .none
    }
}

/// Primitive 161's line: a String's bytes, or the bytes of an Array's
/// Strings and ByteArrays joined (at most 64 MiB); nil otherwise.
private func lineBytes(_ m: Machine, _ v: Oop) -> [UInt8]? {
    // Large bytes: a long String (past 16 MiB) is not a line (`text` is
    // nil for it); the transport's own limit is 16 MiB (RequestLimits).
    if m.text(v) != nil { return m.om.bytes(of: v) }
    guard v.isObject, m.classIndex(of: v) == WellKnown.array else { return nil }
    var out: [UInt8] = []
    for i in 0..<Int(m.om.count(of: v)) {
        let p = m.om.load(v, i)
        guard p.isObject else { return nil }
        let ci = m.classIndex(of: p)
        guard m.text(p) != nil || ci == WellKnown.byteArray, let b = m.om.bytesIfShort(of: p) else { return nil }
        out += b
        if out.count > 64 << 20 { return nil }
    }
    return out
}

/// op, handle and arguments as Swift values; nil when one cannot be read.
private func decodeViewCall(_ m: Machine, _ c: PrimitiveCall) -> ViewCall? {
    let op = c.arg0, handle = c.arg1, args = m.argument(2, of: c)
    guard let name = m.text(op) else { return nil }
    let h: Int
    if handle == m.nilObject { h = 0 } else if handle.isSmallInteger { h = Int(handle.smallIntegerValue) } else { return nil }
    guard args.isObject, m.classIndex(of: args) == WellKnown.array else { return nil }
    var values: [ShellValue] = []
    for i in 0..<Int(m.om.count(of: args)) {
        guard let v = decode(m, m.om.load(args, i)) else { return nil }
        values.append(v)
    }
    return ViewCall(op: name, handle: h, arguments: values)
}

private func decode(_ m: Machine, _ v: Oop) -> ShellValue? {
    if v == m.nilObject { return .nil }
    if v == m.trueObject { return .bool(true) }
    if v == m.falseObject { return .bool(false) }
    if v.isSmallInteger { return .int(v.smallIntegerValue) }
    if let s = m.text(v) { return .string(s) }
    if let d = m.double(v) { return .double(d) }
    return nil
}

/// A host value as an oop (`.none` when the heap is full).
private func encode(_ m: Machine, _ v: ShellValue) -> Oop {
    switch v {
    case .nil: return m.nilObject
    case .bool(let b): return b ? m.trueObject : m.falseObject
    case .int(let i): return Oop.fitsSmallInteger(i) ? Oop(smallInteger: i) : m.float(Double(i))
    case .double(let d): return m.float(d)
    case .string(let s): return m.newString(Array(s.utf8))
    }
}

/// {kind. target. value. microseconds}: the value first, then the Array
/// with the value kept as a root across its allocation.
private func eventArray(_ m: Machine, _ e: ShellEvent) -> Oop {
    let value = encode(m, e.value)
    if value == .none { return .none }
    let a = m.allocate(WellKnown.array, slots: 4, keeping: value)
    if a == .none { return .none }
    m.store(a, 0, Oop(smallInteger: Int64(e.kind.rawValue)), .atPut)
    m.store(a, 1, Oop(smallInteger: Int64(e.target)), .atPut)
    m.store(a, 2, value, .atPut)
    m.store(a, 3, Oop(smallInteger: Int64(e.timeNs / 1000)), .atPut)
    return a
}
