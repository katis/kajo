// Module 8c: the image loader's rules for saved Processes
// (docs/modules/image-processes.md "The loader's rules"). A saved stack is
// the most powerful input an image carries: a forged frame could run a
// verified method on the wrong receiver, address the wrong temp, or
// return into nothing. Nothing here trusts a word it has not checked: every
// slot read is guarded by its holder's class and size first, every frame
// is checked against its method and the bytecode verifier's traced depth
// at its pc, and every list the scheduler walks is checked acyclic and
// consistent with the states of the Processes in it. All or nothing: the
// first rule broken throws (`verifyImage` destroys the memory).
//
// Safe code: it reads the heap through module 1's checked loads.

/// The scheduler state an image with saved Processes carries (special
/// object 8, `SpecialObjects.scheduler`): an Array of `size` slots.
enum SavedScheduler {
    /// An Array of 12: the six ready queues' heads, then their tails (nil
    /// for an empty queue), in `queueIndex` order.
    static let queues = 0
    /// The Semaphore the VM signals when ephemerons are queued, or nil.
    static let finalization = 1
    /// An Array of chunks, each an Array of pairs: a Process and its stack
    /// (an Array of chunks of its words `[0, sp]`, `chunkWords` each but
    /// the last).
    static let processes = 2
    /// The Process that sent `snapshot:` (resumes after the primitive with
    /// `true` on top of its stack), or nil for a save the VM triggered at a
    /// poll (tests).
    static let saver = 3
    /// The next Process id the saving VM would have given (SmallInteger).
    static let nextId = 4
    static let size = 5

    /// Words per stack chunk and Process pairs per list chunk: one block.
    static let chunkWords = Header.maxSlots
    static let pairsPerChunk = Header.maxSlots / 2
    /// The most words a saved stack may hold (16 Mi, past any stack the
    /// VM grows: `VMConfig.maxStackWords` is 1 Mi by default).
    static let maxStackWords = 1 << 24
    /// The most saved Processes an image may hold.
    static let maxProcesses = 1 << 20
}

/// What `verifyImage`'s walk over every object collected for these rules.
struct HeapProcessObjects {
    var processes: [Oop] = []
    var semaphores: [Oop] = []
    /// Contexts whose `frame` is not nil.
    var liveContexts: [Oop] = []
}

/// One method's traced code, for the frame rules.
private struct TracedMethod {
    let argc: Int
    let temps: Int
    let maxStack: Int
    let flags: Int64
    let methodClass: Oop
    /// Instruction start -> traced depth (reachable instructions only).
    let depthAt: [Int: Int]
    /// Instruction end -> the instruction (reachable instructions only).
    let endingAt: [Int: DecodedInstruction]
}

/// The saved-Process rules. `special` is the verified special-objects Array.
func verifySavedProcesses(_ om: ObjectMemory, special: Oop, nilObj: Oop, trueObj: Oop, methods: Set<Oop>,
                          heap: HeapProcessObjects, limits: LoaderLimits) throws(ImageError) {
    func fail(_ s: String) -> ImageError { .rule("saved Processes: \(s)") }
    func used(_ o: Oop) -> Bool { om.isUsedReference(o) }
    func isA(_ o: Oop, _ c: UInt64) -> Bool { o.isObject && used(o) && om.classIndex(of: o) == c }
    /// An Array of exactly `n` slots (before any slot is read).
    func array(_ o: Oop, _ n: Int? = nil) -> Bool {
        isA(o, WellKnown.array) && !om.isBytes(o) && (n == nil || om.count(of: o) == UInt64(n!))
    }
    func int(_ o: Oop, _ i: Int) -> Int64? {
        let v = om.load(o, i)
        return v.isSmallInteger ? v.smallIntegerValue : nil
    }
    // Process and Semaphore objects are fixed formats of their sizes (the
    // walk checked every object against its class's format); still, guard.
    func isProcess(_ o: Oop) -> Bool { isA(o, WellKnown.process) && !om.isBytes(o) && om.count(of: o) == UInt64(ProcessLayout.size) }
    func isSemaphore(_ o: Oop) -> Bool {
        isA(o, WellKnown.semaphore) && !om.isBytes(o) && om.count(of: o) == UInt64(SemaphoreLayout.size)
    }

    let schedulerState = om.count(of: special) > UInt64(SpecialObjects.scheduler)
        ? om.load(special, SpecialObjects.scheduler) : nilObj

    // MARK: the scheduler state and the list of saved Processes
    var saved: [(process: Oop, stack: Oop)] = []
    var index: [Oop: Int] = [:]
    var queueWords = [Oop](repeating: nilObj, count: 2 * Priority.count * Affinity.count)
    var finalization = nilObj, saver = nilObj
    var nextId: Int64 = 1
    if schedulerState != nilObj {
        guard array(schedulerState, SavedScheduler.size) else { throw fail("the scheduler state is not an Array of \(SavedScheduler.size)") }
        let q = om.load(schedulerState, SavedScheduler.queues)
        guard array(q, queueWords.count) else { throw fail("the ready queues are not an Array of \(queueWords.count)") }
        for i in 0..<queueWords.count { queueWords[i] = om.load(q, i) }
        finalization = om.load(schedulerState, SavedScheduler.finalization)
        guard finalization == nilObj || isSemaphore(finalization) else { throw fail("the finalization Semaphore") }
        saver = om.load(schedulerState, SavedScheduler.saver)
        guard let n = int(schedulerState, SavedScheduler.nextId), n >= 1 else { throw fail("the next Process id") }
        nextId = n
        let list = om.load(schedulerState, SavedScheduler.processes)
        guard array(list) else { throw fail("the Process list is not an Array") }
        for c in 0..<Int(om.count(of: list)) {
            let chunk = om.load(list, c)
            guard array(chunk), om.count(of: chunk) % 2 == 0, om.count(of: chunk) > 0 else {
                throw fail("Process list chunk \(c) is not an Array of pairs")
            }
            for k in 0..<Int(om.count(of: chunk) / 2) {
                let p = om.load(chunk, 2 * k), st = om.load(chunk, 2 * k + 1)
                guard isProcess(p), array(st) else { throw fail("Process list chunk \(c) pair \(k)") }
                guard index[p] == nil else { throw fail("Process \(p) is saved twice") }
                guard saved.count < SavedScheduler.maxProcesses else { throw fail("more than \(SavedScheduler.maxProcesses) Processes") }
                index[p] = saved.count
                saved.append((p, st))
            }
        }
        guard !saved.isEmpty else { throw fail("a scheduler state with no Process") }
    }

    // MARK: every Process in the heap: saved, or terminated
    var ids = Set<Int64>()
    for p in heap.processes {
        guard isProcess(p) else { throw fail("Process \(p)'s shape") }
        let state = int(p, ProcessLayout.state)
        if index[p] == nil {
            // A terminated Process is an ordinary object (record -1, in no
            // list, waiting on nothing); anything else would need a record.
            guard state == ProcessState.terminated.rawValue, int(p, ProcessLayout.record) == -1,
                  om.load(p, ProcessLayout.next) == nilObj, om.load(p, ProcessLayout.waitingOn) == nilObj else {
                throw fail("Process \(p) is live (state \(String(describing: state))) but not saved")
            }
            continue
        }
        guard state == ProcessState.ready.rawValue || state == ProcessState.waiting.rawValue else {
            throw fail("Process \(p) is saved with state \(String(describing: state)) (ready or waiting only)")
        }
        guard let prio = int(p, ProcessLayout.priority), (0..<Int64(Priority.count)).contains(prio),
              let aff = int(p, ProcessLayout.affinity), (0..<Int64(Affinity.count)).contains(aff) else {
            throw fail("Process \(p)'s priority or affinity")
        }
        guard int(p, ProcessLayout.record) == -1 else { throw fail("Process \(p)'s record is not -1") }
        guard let id = int(p, ProcessLayout.id), id >= 1, id < nextId, ids.insert(id).inserted else {
            throw fail("Process \(p)'s id (unique, below the next id \(nextId))")
        }
        guard om.load(p, ProcessLayout.result) == nilObj else { throw fail("Process \(p) has a result but is live") }
        let exit = om.load(p, ProcessLayout.exitSemaphore)
        guard exit == nilObj || isSemaphore(exit) else { throw fail("Process \(p)'s exit Semaphore") }
        let next = om.load(p, ProcessLayout.next)
        guard next == nilObj || index[next] != nil else { throw fail("Process \(p)'s next is not a saved Process") }
        let on = om.load(p, ProcessLayout.waitingOn)
        if state == ProcessState.ready.rawValue {
            guard on == nilObj else { throw fail("ready Process \(p) waits on \(on)") }
        } else {
            guard isSemaphore(on) else { throw fail("waiting Process \(p) waits on no Semaphore") }
        }
    }
    // Every saved Process is one the walk found (it is in the heap).
    guard saved.count == heap.processes.filter({ index[$0] != nil }).count else { throw fail("the Process list") }

    // MARK: the ready queues
    var listed = Set<Oop>()
    var readyCount = 0
    for q in 0..<(Priority.count * Affinity.count) {
        let head = queueWords[q], tail = queueWords[Priority.count * Affinity.count + q]
        guard (head == nilObj) == (tail == nilObj) else { throw fail("ready queue \(q): a head without a tail") }
        var cur = head, last = nilObj
        while cur != nilObj {
            guard let i = index[cur] else { throw fail("ready queue \(q) names \(cur), not a saved Process") }
            let p = saved[i].process
            guard listed.insert(p).inserted else { throw fail("ready queue \(q): Process \(p) is in two lists, or a cycle") }
            guard int(p, ProcessLayout.state) == ProcessState.ready.rawValue,
                  queueIndex(main: int(p, ProcessLayout.affinity) == Int64(Affinity.main),
                             priority: Int(int(p, ProcessLayout.priority)!)) == q else {
                throw fail("ready queue \(q) holds Process \(p) of another state, priority or affinity")
            }
            readyCount += 1
            last = cur
            cur = om.load(cur, ProcessLayout.next)
        }
        guard last == tail else { throw fail("ready queue \(q): the tail is not the last Process") }
    }
    // MARK: the Semaphores' waiter lists (every Semaphore in the heap)
    var waitingCount = 0
    for s in heap.semaphores {
        guard isSemaphore(s), let excess = int(s, SemaphoreLayout.excessSignals), excess >= 0 else {
            throw fail("Semaphore \(s)'s excess signals")
        }
        let first = om.load(s, SemaphoreLayout.firstWaiter), lastW = om.load(s, SemaphoreLayout.lastWaiter)
        guard (first == nilObj) == (lastW == nilObj) else { throw fail("Semaphore \(s): a first waiter without a last") }
        guard first == nilObj || excess == 0 else { throw fail("Semaphore \(s) has waiters and excess signals") }
        var cur = first, last = nilObj
        while cur != nilObj {
            guard let i = index[cur] else { throw fail("Semaphore \(s)'s waiters name \(cur), not a saved Process") }
            let p = saved[i].process
            guard listed.insert(p).inserted else { throw fail("Semaphore \(s): Process \(p) is in two lists, or a cycle") }
            guard int(p, ProcessLayout.state) == ProcessState.waiting.rawValue, om.load(p, ProcessLayout.waitingOn) == s else {
                throw fail("Semaphore \(s)'s waiter \(p) is not waiting on it")
            }
            waitingCount += 1
            last = cur
            cur = om.load(cur, ProcessLayout.next)
        }
        guard last == lastW else { throw fail("Semaphore \(s): the last waiter is not the last Process") }
    }
    guard readyCount + waitingCount == saved.count else {
        throw fail("\(saved.count - readyCount - waitingCount) saved Process(es) in no list")
    }
    if saver != nilObj {
        guard let i = index[saver], int(saved[i].process, ProcessLayout.state) == ProcessState.ready.rawValue else {
            throw fail("the saving Process is not a saved ready Process")
        }
    }

    // MARK: the stacks and their frames
    var traced: [Oop: TracedMethod] = [:]
    func code(_ m: Oop) throws(ImageError) -> TracedMethod {
        if let t = traced[m] { return t }
        // Every method in the table passed verifyHeapMethod for its class
        // already; trace it again for the depths.
        guard methods.contains(m) else { throw fail("a frame's method \(m) is not in the method table") }
        let mc = om.load(m, MethodLayout.methodClass)
        guard mc.isObject, used(mc), om.isBehavior(mc), !om.isBytes(mc), om.count(of: mc) >= UInt64(ClassLayout.size),
              let ci = int(mc, ClassLayout.classIndex), ci > 0, ci < om.classCount else { throw fail("method \(m)'s class") }
        var v: VerifiedCode? = nil
        if let issue = verifyHeapMethod(om, m, classIndex: UInt64(ci), nilObject: nilObj, limits: limits, traced: { v = $0 }) {
            throw fail("method \(m): \(issue)")
        }
        guard let v else { throw fail("method \(m) has no bytecodes to resume in") }
        var depthAt: [Int: Int] = [:], endingAt: [Int: DecodedInstruction] = [:]
        for (k, i) in v.instructions.enumerated() where v.depths[k] >= 0 {
            depthAt[i.offset] = v.depths[k]
            endingAt[i.offset + i.length] = i
        }
        let t = TracedMethod(argc: Int(int(m, MethodLayout.argc)!), temps: Int(int(m, MethodLayout.temps)!),
                             maxStack: Int(int(m, MethodLayout.maxStack)!), flags: int(m, MethodLayout.flags)!,
                             methodClass: mc, depthAt: depthAt, endingAt: endingAt)
        traced[m] = t
        return t
    }
    /// The receiver is an instance of a class that inherits from the
    /// method's class and has its instance variables (the kasm loader's
    /// rule, applied to a live receiver).
    func receiverFits(_ rcv: Oop, _ t: TracedMethod) -> Bool {
        let ci: UInt64
        if rcv.isSmallInteger { ci = WellKnown.smallInteger }
        else if rcv.isSmallFloat { ci = WellKnown.smallFloat }
        else if rcv.isCharacter { ci = WellKnown.character }
        else if rcv.isObject && used(rcv) { ci = om.classIndex(of: rcv) }
        else { return false }
        guard ci > 0, ci < UInt64(om.classCount) else { return false }
        var c = om.classOop(ci)
        var steps = om.classCount
        var found = false
        while c != nilObj && steps > 0 {
            guard c.isObject, used(c), om.isBehavior(c), !om.isBytes(c), om.count(of: c) >= UInt64(ClassLayout.size) else { return false }
            if c == t.methodClass { found = true; break }
            c = om.load(c, ClassLayout.superclass)
            steps -= 1
        }
        guard found, let mci = int(t.methodClass, ClassLayout.classIndex) else { return false }
        let f = om.classFormat(UInt64(mci))
        let needed = f.instancesAreBehaviors ? max(ClassLayout.size, f.namedSlots)
            : (f.isSealed || !f.kind.isPointers ? 0 : f.namedSlots)
        if needed == 0 { return true }
        return rcv.isObject && !om.isBytes(rcv) && om.count(of: rcv) >= UInt64(needed)
    }

    var namedContexts: [Oop: Oop] = [:]  // Context -> the saved Process whose frame names it
    for (p, stack) in saved {
        guard let sp64 = int(p, ProcessLayout.sp), let pc64 = int(p, ProcessLayout.pc), let fp64 = int(p, ProcessLayout.fp),
              let hdr64 = int(p, ProcessLayout.hdr) else { throw fail("Process \(p)'s registers are not SmallIntegers") }
        guard sp64 >= 1, sp64 < Int64(SavedScheduler.maxStackWords) else { throw fail("Process \(p)'s sp \(sp64)") }
        let sp = Int(sp64)
        let n = sp + 1
        let chunks = (n + SavedScheduler.chunkWords - 1) / SavedScheduler.chunkWords
        guard om.count(of: stack) == UInt64(chunks) else { throw fail("Process \(p)'s stack has \(om.count(of: stack)) chunks, sp \(sp) needs \(chunks)") }
        var chunk: [Oop] = []
        for c in 0..<chunks {
            let ch = om.load(stack, c)
            let want = c == chunks - 1 ? n - c * SavedScheduler.chunkWords : SavedScheduler.chunkWords
            guard array(ch, want) else { throw fail("Process \(p)'s stack chunk \(c) is not an Array of \(want)") }
            chunk.append(ch)
        }
        func word(_ i: Int) -> Oop { om.load(chunk[i / SavedScheduler.chunkWords], i % SavedScheduler.chunkWords) }
        func small(_ i: Int) -> Int64? { let v = word(i); return v.isSmallInteger ? v.smallIntegerValue : nil }

        if pc64 == -1 {
            // Never run: word 0 the method, then the receiver and arguments
            // (`fork`'s layout); the first run activates it as the host would.
            guard fp64 == 0, hdr64 == 0 else { throw fail("Process \(p) has never run but has frames") }
            let m = word(0)
            let t = try code(m)
            guard t.flags & MethodFlags.block == 0, t.argc == sp - 1 else {
                throw fail("Process \(p)'s first method takes \(t.argc) argument(s), its stack holds \(sp - 1)")
            }
            guard receiverFits(word(1), t) else { throw fail("Process \(p)'s receiver does not fit its method") }
            continue
        }
        if hdr64 == 0 {
            // A primitive at the bottom of a Process suspended (a host-spawned
            // `wait`): no frame; resuming answers word 1.
            guard pc64 == 0, fp64 == 0, sp == 1, word(0) == nilObj else { throw fail("Process \(p)'s bottom registers") }
            continue
        }
        guard pc64 >= 0, fp64 >= 1, fp64 < hdr64, hdr64 + Int64(Frame.context) <= sp64 else {
            throw fail("Process \(p)'s registers (sp \(sp64), pc \(pc64), fp \(fp64), hdr \(hdr64))")
        }
        var h = Int(hdr64), f = Int(fp64), framePC = Int(pc64)
        var isTop = true
        var calleeF = 0
        var calleeMarker: Int64 = 0
        var frames = 0
        while true {
            frames += 1
            guard frames <= n else { throw fail("Process \(p)'s frames do not end") }
            let what = "Process \(p)'s frame at \(h)"
            guard h >= 1, h + Frame.context < (isTop ? n : calleeF) else { throw fail("\(what): the header is outside its region") }
            let m = word(h + Frame.method)
            let t = try code(m)
            guard f == h - 1 - t.argc - t.temps, f >= 1 else { throw fail("\(what): fp \(f), its method says \(h - 1 - t.argc - t.temps)") }
            let isBlock = t.flags & MethodFlags.block != 0
            var closure = nilObj
            if isBlock {
                closure = word(h - 1)
                guard isA(closure, WellKnown.blockClosure), !om.isBytes(closure), om.count(of: closure) >= UInt64(ClosureLayout.size),
                      om.load(closure, ClosureLayout.method) == m,
                      om.load(closure, ClosureLayout.receiver) == word(f) else {
                    throw fail("\(what): a block activation without its closure")
                }
            }
            guard receiverFits(word(f), t) else { throw fail("\(what): the receiver does not fit the method") }
            // The context word: empty, a return marker, or this frame's Context.
            let cw = word(h + Frame.context)
            var marker: Int64
            if cw.isSmallInteger {
                marker = cw.smallIntegerValue
            } else {
                guard isA(cw, WellKnown.context), !om.isBytes(cw), om.count(of: cw) >= UInt64(ContextLayout.size) else {
                    throw fail("\(what): the context word")
                }
                guard om.load(cw, ContextLayout.frame) == Oop(smallInteger: Int64(h)), om.load(cw, ContextLayout.process) == p,
                      om.load(cw, ContextLayout.method) == m, om.load(cw, ContextLayout.receiver) == word(f),
                      om.load(cw, ContextLayout.closure) == closure, om.load(cw, ContextLayout.pc) == nilObj,
                      let mk = int(cw, ContextLayout.marker) else { throw fail("\(what): its Context does not name it") }
                guard namedContexts.updateValue(p, forKey: cw) == nil else { throw fail("\(what): its Context names another frame") }
                marker = mk
            }
            guard marker == 0 || marker == FrameMarker.discard || marker == FrameMarker.cascade || marker == FrameMarker.step else {
                throw fail("\(what): return marker \(marker)")
            }
            // This frame's pc and operand depth against the traced ones.
            if isTop {
                guard t.depthAt[framePC] == sp - h - Frame.context else {
                    throw fail("\(what): pc \(framePC) with \(sp - h - Frame.context) operand(s), traced \(String(describing: t.depthAt[framePC]))")
                }
            } else if calleeMarker == FrameMarker.cascade {
                // Sent by a non-local return that could not proceed: the
                // value it returned was on top where the callee begins.
                guard let q = t.endingAt[framePC], q.op == .nonlocalReturn, let dq = t.depthAt[q.offset],
                      calleeF == h + Frame.context + dq else { throw fail("\(what): a cascade return not after a non-local return") }
            } else {
                // A send's answer replaces the callee's receiver (dropped
                // again for the discard marker).
                let d = calleeF - h - Frame.context - (calleeMarker == FrameMarker.discard ? 1 : 0)
                guard t.depthAt[framePC] == d else {
                    throw fail("\(what): caller pc \(framePC) with \(d) operand(s), traced \(String(describing: t.depthAt[framePC]))")
                }
            }
            guard let cpc = small(h + Frame.callerPC), let cfp = small(h + Frame.callerFP), let chdr = small(h + Frame.callerHdr) else {
                throw fail("\(what): the caller links are not SmallIntegers")
            }
            if cfp == 0 {
                // The bottom frame, entered by the first run as the host
                // enters a method.
                guard cpc == 0, chdr == 0, f == 1, marker == 0, word(0) == nilObj else { throw fail("\(what): a bottom frame's links") }
                break
            }
            guard chdr >= 1, chdr < Int64(f), cfp >= 1, cfp < chdr, cpc >= 0 else { throw fail("\(what): the caller links") }
            calleeF = f
            calleeMarker = marker
            framePC = Int(cpc)
            h = Int(chdr)
            f = Int(cfp)
            isTop = false
        }
        if p == saver {
            // The saver resumes after the primitive's send with true pushed.
            let top = try code(word(Int(hdr64)))
            guard word(sp) == trueObj, let s = top.endingAt[Int(pc64)],
                  s.op == .send || s.op == .sendSuper || s.op.specialSelector != nil else {
                throw fail("the saving Process does not resume after a send with true")
            }
        }
    }
    if saver != nilObj, let i = index[saver], int(saved[i].process, ProcessLayout.pc) ?? -1 < 0 {
        throw fail("the saving Process has never run")
    }

    // MARK: Contexts: live only in a saved frame that names them (or of a
    // terminated Process, which can never run again)
    for ctx in heap.liveContexts {
        guard isA(ctx, WellKnown.context), om.count(of: ctx) >= UInt64(ContextLayout.size) else { throw fail("Context \(ctx)") }
        if namedContexts[ctx] != nil { continue }
        let p = om.load(ctx, ContextLayout.process)
        guard isProcess(p), index[p] == nil, int(p, ProcessLayout.state) == ProcessState.terminated.rawValue,
              om.load(ctx, ContextLayout.frame).isSmallInteger else {
            throw fail("a live Context \(ctx) no saved frame names")
        }
    }
}
