import Darwin
import Synchronization

/// The interpreter as the host sees it: runs a send on a stack and answers
/// the result or a VMError. Owns its state (one per worker from module 3
/// on); the image and the stacks belong to the caller. Cold code: the hot
/// path is `interpret` and the send path, which see only the raw state.
@safe final class Interpreter {
    let image: Image
    let state: StatePointer
    private var loadsSeen: Int

    init(image: Image) {
        self.image = image
        let flag = unsafe makeFlagLine()
        // A worker of no VM: its polls only honour the test switch below.
        let w = unsafe Worker.make(image: image, vm: nil, index: 0, isMain: true, flag: flag, pollEvery: 1024, seed: 1)
        unsafe state = w.pointer(to: \Worker.interp)!
        loadsSeen = image.loads
    }

    func destroy() {
        let flag = unsafe state.pointee.safepointFlag
        unsafe Worker.destroy(workerOf(state))
        unsafe freeFlagLine(flag)
    }

    var machine: Machine { unsafe Machine(state: state) }
    var counters: InterpreterCounters { unsafe state.pointee.counters }

    /// The test switch standing in for module 3's safepoint request: while
    /// set, every poll (sends and backward jumps) collects.
    var safepointRequested: Bool {
        get { unsafe state.pointee.safepointFlag.pointee.load(ordering: .relaxed) != 0 }
        set { unsafe state.pointee.safepointFlag.pointee.store(newValue ? 1 : 0, ordering: .relaxed) }
    }

    // MARK: - running

    /// `receiver selector arguments` on `stack`, from the bottom of the
    /// stack: the result, or the error with the stack left as it was.
    func run(on stack: Stack, receiver: Oop, selector: String, arguments: [Oop]) -> Result<Oop, VMError> {
        runToReturn(on: stack, receiver: receiver, selector: selector, arguments: arguments).map { _ in takeResult() }
    }

    /// As `run`, but the result stays in the result register (a root) until
    /// `takeResult`.
    func runToReturn(on stack: Stack, receiver: Oop, selector: String, arguments: [Oop]) -> Result<Oop, VMError> {
        if image.loads != loadsSeen {  // a load may have shadowed a cached method
            machine.flushCache()
            loadsSeen = image.loads
        }
        attach(stack)
        let sel = (try? image.intern(selector)) ?? .none
        let argc = arguments.count
        unsafe state.pointee.exit = .running
        unsafe state.pointee.regs = SavedRegisters()
        if sel == .none {
            return .failure(VMError(kind: .outOfMemory, selector: selector, receiverClass: nil, method: nil, pc: 0, primitive: 0))
        }
        if argc > 255 || argc + 3 >= stack.words {
            return .failure(VMError(kind: .stackOverflow, selector: selector, receiverClass: nil, method: nil, pc: 0, primitive: 0))
        }
        unsafe stack.base[0] = image.nilObject.raw
        unsafe stack.base[1] = receiver.raw
        for (i, a) in arguments.enumerated() { unsafe stack.base[2 + i] = a.raw }
        let leave = unsafe UnsafePointer(state.pointee.leaveCode)
        let host = unsafe Regs(pc: leave, sp: stack.base + 1 + argc, fp: stack.base, hdr: stack.base, code: leave,
                               lits: UnsafePointer(stack.base))
        let first = unsafe send(state, image.om, host, sel.raw, argc, 0, poll: false, count: false)
        unsafe drive(state, first)
        switch unsafe state.pointee.exit {
        case .returned:
            return .success(unsafe state.pointee.regs.result)
        case .error:
            return .failure(currentError())
        case .suspended:
            preconditionFailure("a standalone interpreter has no Process to suspend")
        case .running:
            // The host's send ran a primitive: the result is in the receiver's slot.
            let v = unsafe Oop(raw: stack.base[1])
            unsafe state.pointee.regs = SavedRegisters(sp: 0, result: v)
            unsafe state.pointee.exit = .returned
            return .success(v)
        }
    }

    /// Take the result register's value and clear it, so it stops being a
    /// root.
    func takeResult() -> Oop {
        let v = unsafe state.pointee.regs.result
        unsafe state.pointee.regs.result = .none
        return v
    }

    private func attach(_ stack: Stack) {
        unsafe state.pointee.stackBase = stack.base
        unsafe state.pointee.stackEnd = stack.base + stack.words
    }

    // MARK: - inspection

    /// A collection with this interpreter's roots: the stack up to the
    /// saved sp and the oop registers.
    func collect(_ stack: Stack) {
        attach(stack)
        machine.collect()
    }

    /// The frames left on the stack by the last run, innermost first, as
    /// `Class>>selector`.
    func backtrace(_ stack: Stack) -> [String] {
        var out: [String] = []
        var hdr = unsafe state.pointee.regs.hdr
        while hdr > 0 && hdr + Frame.callerHdr < stack.words {
            out.append(image.methodName(stack[hdr + Frame.method]) ?? "?")
            if unsafe stack.base[hdr + Frame.callerFP] == Frame.hostFP { break }
            hdr = untagged(unsafe stack.base[hdr + Frame.callerHdr])
        }
        return out
    }

    private func currentError() -> VMError {
        let e = unsafe state.pointee.error
        let r = unsafe state.pointee.regs
        return VMError(kind: e.kind, selector: e.selector == .none ? nil : image.symbolName(e.selector),
                       receiverClass: e.receiverClass == 0 ? nil : image.className(e.receiverClass),
                       method: r.method == .none ? nil : image.methodName(r.method), pc: r.pc, primitive: e.primitive)
    }
}
