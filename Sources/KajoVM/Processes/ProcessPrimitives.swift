// Module 3's primitives (numbering of experiments/ui-thread-scheduling
// SPEC.md where it exists). Each checks its receiver and arguments and
// fails cleanly; outside a VM (module 2's standalone interpreter) every one
// fails. A primitive that suspends its Process does all its bookkeeping
// itself, publishes the Process last, sets the interpreter's exit to
// `.suspended` and never touches the stack again; `primitiveSend` then
// leaves the loop. A primitive that can hop has no side effect before its
// affinity check.

enum ProcessPrimitives {
    static let table: [(number: Int, selector: String, argc: Int)] = [
        (20, "fork:with:priority:main:exit:", 5), (21, "yield", 0), (22, "Semaphore wait", 0),
        (23, "Semaphore signal", 0), (24, "Process terminate", 0), (25, "delay:signal:", 2),
        (26, "newSemaphore", 0), (29, "shell call (setLabel:), main only", 1), (32, "detachFromMain", 0),
        (33, "activeProcess", 0), (34, "workerId", 0),
    ]
}

@inline(never)
func processPrimitive(_ n: Int, _ m: Machine, _ c: PrimitiveCall) -> Oop {
    let w = unsafe workerOf(m.state)
    guard let vm = unsafe w.pointee.vm, unsafe w.pointee.current != .none || n == 26 else { return .none }
    let om = m.om
    switch n {
    case 20: return unsafe primFork(vm, w, m, c)
    case 21:
        guard c.argc == 0 else { return .none }
        unsafe requeueCurrent(vm, w, sp: 0, pc: 0, result: (0, c.receiver), reason: .suspended)
        unsafe vm.count(.yields)
        return c.receiver
    case 22:
        guard c.argc == 0, isA(m, c.receiver, WellKnown.semaphore) else { return .none }
        _ = unsafe waitSemaphore(vm, w, c.receiver, argc: 0)
        return c.receiver
    case 23:
        guard c.argc == 0, isA(m, c.receiver, WellKnown.semaphore) else { return .none }
        unsafe signalSemaphore(vm, w, c.receiver)
        return c.receiver
    case 24:
        guard c.argc == 0, isA(m, c.receiver, WellKnown.process) else { return .none }
        if unsafe c.receiver == w.pointee.current {
            unsafe w.pointee.leave = .terminated
            unsafe w.pointee.interp.exit = .suspended
        } else {
            unsafe terminateProcess(vm, w, c.receiver)
        }
        return c.receiver
    case 25:
        guard c.argc == 2, c.arg0.isSmallInteger, c.arg0.smallIntegerValue >= 0,
              c.arg0.smallIntegerValue <= Int64(Int32.max), isA(m, c.arg1, WellKnown.semaphore) else { return .none }
        return unsafe startDelay(vm, ms: Int(c.arg0.smallIntegerValue), sem: c.arg1) ? c.receiver : .none
    case 26:
        guard c.argc == 0 else { return .none }
        let s = m.allocate(WellKnown.semaphore, slots: SemaphoreLayout.size)
        if s != .none { om.store(s, SemaphoreLayout.excessSignals, Oop(smallInteger: 0)) }
        return s
    case 29:
        guard c.argc == 1 else { return .none }
        if unsafe w.pointee.isMain {
            let v = c.arg0.isSmallInteger ? c.arg0.smallIntegerValue : 0
            guard let h = unsafe vm.pointee.hooks.shell else { return c.arg0.isSmallInteger ? c.arg0 : Oop(smallInteger: 0) }
            // Module 7: the shell call may block for long without touching
            // the heap: a blocking region (acknowledged by proxy).
            unsafe blockingBegin(vm, w)
            let r = unsafe h(vm.pointee.hooks.context, 0, v)
            unsafe blockingEnd(vm, w)
            return Oop.fitsSmallInteger(r) ? Oop(smallInteger: r) : .none
        }
        // Off main: retry the send on the main worker. At the bottom of a
        // Process there is no send to retry (v0 refuses).
        guard unsafe w.pointee.interp.regs.hdr != 0 else { return .none }
        let r = unsafe w.pointee.interp.regs
        unsafe requeueCurrent(vm, w, sp: r.sp, pc: r.pc &- w.pointee.interp.sendLength, affinity: Affinity.main,
                              reason: .suspended, hop: true)
        unsafe vm.count(.hops)
        return c.receiver
    case 32:
        guard c.argc == 0 else { return .none }
        unsafe requeueCurrent(vm, w, sp: 0, pc: 0, affinity: Affinity.any, result: (0, c.receiver), reason: .suspended)
        unsafe vm.count(.detaches)
        return c.receiver
    case 33: return unsafe c.argc == 0 ? w.pointee.current : .none
    case 34: return c.argc == 0 ? Oop(smallInteger: Int64(unsafe w.pointee.index)) : .none
    default: return .none
    }
}

@inline(__always)
private func isA(_ m: Machine, _ o: Oop, _ cls: UInt64) -> Bool { o.isObject && m.om.classIndex(of: o) == cls }

/// `rcv fork: #selector with: arg priority: p main: bool exit: sem`. The
/// method must exist and take at most one argument (with: is ignored for a
/// unary one) and have no primitive; priority nil (the forker's) or 0...2.
private func primFork(_ vm: VMPointer, _ w: WorkerPointer, _ m: Machine, _ c: PrimitiveCall) -> Oop {
    guard c.argc == 5 else { return .none }
    let om = m.om
    let selector = c.arg0, arg = c.arg1
    let priority = m.argument(2, of: c), main = m.argument(3, of: c), exit = m.argument(4, of: c)
    guard selector.isObject, om.classIndex(of: selector) == WellKnown.symbol else { return .none }
    let prio: Int
    if priority == m.nilObject {
        prio = intSlot(om, unsafe w.pointee.current, ProcessLayout.priority)
    } else {
        guard priority.isSmallInteger, (0..<Int64(Priority.count)).contains(priority.smallIntegerValue) else { return .none }
        prio = Int(priority.smallIntegerValue)
    }
    guard main == m.trueObject || main == m.falseObject else { return .none }
    guard exit == m.nilObject || isA(m, exit, WellKnown.semaphore) else { return .none }
    let method = lookupMethod(om, nilObject: m.nilObject, classIndex: m.classIndex(of: c.receiver), selector: selector)
    guard method != .none, om.load(method, MethodLayout.primitive) == Oop(smallInteger: 0) else { return .none }
    let argc = om.load(method, MethodLayout.argc).smallIntegerValue
    guard argc <= 1 else { return .none }
    // receiver, selector, arg and the rest stay on the stack (roots) while
    // the Process is allocated.
    let p = unsafe createProcess(vm, w, receiver: c.receiver, method: method, args: argc == 1 ? [arg] : [],
                                 priority: prio, main: main == m.trueObject, exit: exit)
    return p
}
