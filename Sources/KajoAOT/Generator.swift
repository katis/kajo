import KajoVM

// AOT 1, the native engine's generator (docs/modules/aot.md): an image's
// methods to one self-contained C file. Linked only by the `kajo` tool and
// the tests; no app carries it.
//
// Per group (one per distinct content hash; methods of equal content share
// it) the file holds:
//
// - `A<k>`: the activation a native send tail-calls (`musttail`): the frame
//   in the VM's own layout (rule 1), the native return marker of the
//   caller's resume point in its context word, then the method's entry.
//   A method with a primitive runs it through the VM's invoke and goes on
//   in its caller, or in the activated fallback frame. Block methods have
//   none (closures are activated by the VM).
// - `R<k>_<pc>`: a hot resume function for the method's entry (pc 0), the
//   instruction after each `send`, and each backward jump's target. Each
//   runs straight-line code (operands in C locals, temps in the frame) from
//   its pc along the fast paths until a send, a return or a slow path.
// - `C<k>`: the cold function: the whole method once, entered at any
//   instruction start (`switch` on the pc), for every continuation a slow
//   path answers and every frame the driver hands native code.
// - `RX<k>`/`DP<k>`: pc -> global resume index (marker targets: entry,
//   the pcs after instructions that can activate a frame, backward jump
//   targets) and pc -> traced operand depth (-1 between instructions).
//
// The module's descriptor `kajo_native_module` (NativeBinding.swift has its
// layout) holds the sorted groups, the global resume table and the entry
// trampoline the driver calls.

package struct AOTOutput: Sendable {
    /// The whole module as one C file (the tests compile it).
    package var source: String
    /// The same as a header, one file per chunk of groups and the tables
    /// (`kajo aot` writes these; each compiles apart).
    package var files: [(name: String, text: String)] = []
    package var methods: Int
    package var groups: Int
    /// Methods the generator declined, with the reason (none in the bar).
    package var declined: [(name: String, reason: String)]
    package var resumePoints: Int
}

/// Generator variants kept for measurement (docs/modules/aot.md, part 1:
/// the return candidates).
package struct AOTOptions: Sendable {
    /// Native returns find the caller's resume function by a lookup (the
    /// caller's method, its group, the group's resume index at the caller
    /// pc; the default, part 1's measurement), or by a marker the native
    /// caller writes in the callee's context word (`--return-marker`).
    package var returnByLookup = true
    /// Groups per C file.
    package var groupsPerFile = 150
    /// Broken variants (tests only, docs/modules/aot.md): a send that does
    /// not bump `counters.sends`; a backward jump's poll with the operands
    /// left in C locals.
    package var brokenNoSendCount = false
    /// Part 3, step 1: `store_ivar` and the temp-vector slots inline.
    package var inlineStores = true
    /// Part 3, step 2: a closure's `value`, `value:`, `value:value:`
    /// activated natively (a block group's activation), and the pc after
    /// each a hot resume function.
    package var inlineClosures = true
    package var brokenNoFlushAtPoll = false
    package init() {}
}

package enum AOTGenerator {
    package static func generate(_ infos: [NativeMethodInfo], nilOop: UInt64, trueOop: UInt64, falseOop: UInt64,
                                 options: AOTOptions = AOTOptions()) -> AOTOutput {
        var groups: [String: (info: NativeMethodInfo, key: (UInt64, UInt64))] = [:]
        var declined: [(String, String)] = []
        for m in infos {
            if let r = declineReason(m) {
                declined.append((m.name, r))
                continue
            }
            let k = hex(m.hash.0) + hex(m.hash.1)
            if groups[k] == nil { groups[k] = (m, m.hash) }
        }
        let sorted = groups.values.sorted { $0.key.0 != $1.key.0 ? $0.key.0 < $1.key.0 : $0.key.1 < $1.key.1 }
        var out = Emitter(nilOop: nilOop, trueOop: trueOop, falseOop: falseOop)
        out.options = options
        out.prelude()
        // Resume indices first: the functions refer to them.
        var plans: [MethodPlan] = []
        var nextResume = 0
        for (k, g) in sorted.enumerated() {
            let p = MethodPlan(index: k, info: g.info, firstResume: nextResume, options: options)
            nextResume += p.resumePCs.count
            plans.append(p)
        }
        out.line("extern KHIDDEN const KResume kajo_resume[];")
        for p in plans { out.declare(p) }
        let header = out.text
        // The methods in files of `perFile` groups each (compiled apart, in
        // parallel), then the tables and the descriptor.
        var chunks: [String] = []
        var k = 0
        while k < plans.count {
            out.text = ""
            for p in plans[k..<min(k + options.groupsPerFile, plans.count)] { out.method(p) }
            chunks.append(out.text)
            k += options.groupsPerFile
        }
        out.text = ""
        out.tables(plans, resumeCount: nextResume, generated: infos.count - declined.count, declined: declined.count)
        let tables = out.text
        var files = [("kajo_native.h", "#ifndef KAJO_NATIVE_H\n#define KAJO_NATIVE_H\n" + header + "#endif\n")]
        for (i, c) in chunks.enumerated() { files.append(("kajo_native_\(i).c", "#include \"kajo_native.h\"\n" + c)) }
        files.append(("kajo_native_tables.c", "#include \"kajo_native.h\"\n" + tables))
        return AOTOutput(source: header + chunks.joined() + tables, files: files, methods: infos.count - declined.count,
                         groups: plans.count, declined: declined, resumePoints: nextResume)
    }

    /// How the generator emits an opcode (plain opcodes; a fused one is
    /// read as its parts): inline with a slow path into the VM, a special
    /// send's slow path, or the VM's own out-of-line code (`exec`). nil
    /// would be a gap; the test `theGeneratorHasNoGap` checks every one.
    package static func emitter(for op: Opcode) -> String? {
        switch op {
        case .pushTemp, .pushLiteral, .pushSelf, .pushIvar, .storeTemp, .pop, .dup, .pushNil, .pushTrue, .pushFalse,
             .pushInt, .send, .returnTop, .returnSelf, .blockReturn, .jump, .jumpIfTrue, .jumpIfFalse, .add, .sub, .mul,
             .lt, .gt, .le, .ge, .eq, .ne, .identical, .notIdentical, .isNil, .notNil, .at:
            return "inline"
        case .div, .intDiv, .mod, .atPut, .size, .value, .value1, .value2: return "special"
        case .storeIvar, .classOf, .sendSuper, .pushClosure, .pushNewArray, .pushTempVectorSlot, .storeTempVectorSlot,
             .pushThisContext, .nonlocalReturn, .ext:
            return "vm"
        default: return nil
        }
    }

    /// The reasons the generator declines a method (open question 3: none
    /// in the kernel and tools images; every opcode has an emitter or runs
    /// through the VM's own out-of-line code).
    static func declineReason(_ m: NativeMethodInfo) -> String? {
        if m.instructions.isEmpty && m.primitive == 0 { return "no bytecodes" }
        if m.maxStack > 4096 { return "stack deeper than 4096" }
        return nil
    }
}

func hex(_ v: UInt64) -> String {
    let s = String(v, radix: 16)
    return String(repeating: "0", count: 16 - s.count) + s
}

/// What the generator decides for one group before emitting it.
struct MethodPlan {
    let index: Int
    let info: NativeMethodInfo
    /// Instruction index by pc.
    let at: [Int: Int]
    /// Hot functions' entry pcs.
    let hot: [Int]
    /// pcs with a global resume index, in order; index = firstResume + i.
    let resumePCs: [Int]
    let firstResume: Int

    init(index: Int, info: NativeMethodInfo, firstResume: Int, options: AOTOptions = AOTOptions()) {
        self.index = index
        self.info = info
        self.firstResume = firstResume
        var at: [Int: Int] = [:]
        for (k, i) in info.instructions.enumerated() { at[i.offset] = k }
        self.at = at
        var hot = Set<Int>()
        var resume = Set<Int>()
        if !info.instructions.isEmpty {
            hot.insert(0)
            resume.insert(0)
        }
        for i in info.instructions where i.depth >= 0 {
            let next = i.offset + i.length
            if i.op == .send && !i.extended, at[next] != nil {
                hot.insert(next)
                resume.insert(next)
            }
            if Self.activates(i), at[next] != nil { resume.insert(next) }
            if options.inlineClosures && (i.op == .value || i.op == .value1 || i.op == .value2), at[next] != nil { hot.insert(next) }
            if i.op.isJump {
                let t = next + i.a
                if i.a < 0 && at[t] != nil {
                    hot.insert(t)
                    resume.insert(t)
                }
            }
        }
        self.hot = hot.sorted()
        self.resumePCs = resume.sorted()
    }

    /// Instructions whose slow path can activate a frame above this one.
    static func activates(_ i: NativeInstruction) -> Bool {
        switch i.op {
        case .send, .sendSuper: return true
        case .identical, .notIdentical, .isNil, .notNil, .classOf: return false
        default: return i.op.specialSelectorIsSent || i.extended
        }
    }

    func resumeIndex(_ pc: Int) -> Int? {
        guard let i = resumePCs.firstIndex(of: pc) else { return nil }
        return firstResume + i
    }

    var hasActivation: Bool { true }
}

extension Opcode {
    /// A special-send opcode whose slow path sends its selector.
    var specialSelectorIsSent: Bool {
        rawValue >= Opcode.add.rawValue && rawValue <= Opcode.notNil.rawValue
    }
}

/// The C text.
struct Emitter {
    let nilOop: UInt64, trueOop: UInt64, falseOop: UInt64
    var options = AOTOptions()
    var text = ""

    init(nilOop: UInt64, trueOop: UInt64, falseOop: UInt64) {
        self.nilOop = nilOop
        self.trueOop = trueOop
        self.falseOop = falseOop
        text.reserveCapacity(1 << 22)
    }

    mutating func line(_ s: String) {
        text += s
        text += "\n"
    }

    mutating func prelude() {
        line("/* Generated by `kajo aot` (AOT 1, docs/modules/aot.md). Do not edit. */")
        line("#include <stdint.h>")
        line("typedef uint64_t u64; typedef int64_t i64; typedef uint32_t u32; typedef int32_t i32; typedef int16_t i16;")
        line("#define KPN __attribute__((preserve_none))")
        line("#define KHIDDEN __attribute__((visibility(\"hidden\")))")
        line("#define KFN KHIDDEN KPN void")
        line("typedef struct KS KS;")
        line("typedef KPN void KF(KS *, u64 *, u64 *, u64, u64, u64, u64);")
        line("#define KCONT ((KF *)1)")
        for (n, v) in NativeLayout.constants { line("#define \(n) \(v)ULL") }
        let h = NativeLayout.hash
        line("#define LAYOUT_HASH0 0x\(hex(h.0))ULL")
        line("#define LAYOUT_HASH1 0x\(hex(h.1))ULL")
        line("#define NILV 0x\(hex(nilOop))ULL")
        line("#define TRUEV 0x\(hex(trueOop))ULL")
        line("#define FALSEV 0x\(hex(falseOop))ULL")
        line("""
        #define LIKELY(x) __builtin_expect(!!(x), 1)
        #define UNLIKELY(x) __builtin_expect(!!(x), 0)
        #define AT(s, off, T) (*(T *)((char *)(s) + (off)))
        #define TAG(n) ((((u64)(n)) << 1) | 1)
        #define UNTAG(w) ((i64)(w) >> 1)
        /* Rule 9: state words, headers and slots are relaxed atomic loads. */
        static inline u64 k_ld(const u64 *p) { return __atomic_load_n(p, __ATOMIC_RELAXED); }
        static inline u64 k_header(KS *s, u64 o) { return k_ld((const u64 *)(AT(s, W_TABLE, char *) + o + 8)); }
        static inline u64 k_state(KS *s, u64 o) { return k_ld((const u64 *)(AT(s, W_TABLE, char *) + o)); }
        /* The body address from the state word just loaded (relocation model, finding 6). */
        static inline u64 k_slot(KS *s, u64 o, u64 i) { return k_ld((const u64 *)(AT(s, W_HEAP, char *) + k_state(s, o) + 8 + i * 8)); }
        static inline u64 k_classof(KS *s, u64 v) {
          if (v & 1) return CLS_SMALLINTEGER;
          if ((v & OOP_TAG_MASK) == 0) return k_header(s, v) & HDR_CLASS_MASK;
          return (v & 2) ? CLS_SMALLFLOAT : CLS_CHARACTER;
        }
        static inline int k_hasslot(KS *s, u64 rcv, u64 n) {
          if (rcv & OOP_TAG_MASK) return 0;
          u64 h = k_header(s, rcv);
          return (h & HDR_BYTES_BIT) == 0 && n < ((h & HDR_COUNT_MASK) >> HDR_COUNT_SHIFT);
        }
        static inline int k_due(KS *s) {
          i64 c = AT(s, W_COUNTDOWN, i64) - 1;
          AT(s, W_COUNTDOWN, i64) = c;
          return c == 0 || __atomic_load_n(AT(s, W_FLAG, u32 *), __ATOMIC_RELAXED) != 0;
        }
        typedef struct KVT {
          KF *(*poll_send)(KS *, u64, u64 *, u64 *, u64 *, u64);
          KF *(*poll_jump)(KS *, u64, u64 *, u64 *, u64 *);
          u64 (*lookup)(KS *, u64, u64);
          KF *(*dnu)(KS *, u64, u64 *, u64 *, u64 *, u64, u64);
          KF *(*invoke)(KS *, u64, u64 *, u64 *, u64 *, u64, u64);
          KF *(*special)(KS *, u64, u64 *, u64 *, u64 *, u64);
          KF *(*exec)(KS *, u64, u64 *, u64 *, u64 *);
          KF *(*ret)(KS *, u64, u64 *, u64 *, u64 *, u64);
          KF *(*fail)(KS *, u64, u64 *, u64 *, u64 *, u64, u64);
          KF *(*overflow)(KS *, u64, u64 *, u64 *, u64 *, u64, u64);
          KF *(*send_slow)(KS *, u64, u64 *, u64 *, u64 *, u64, u64, u64);
          void (*store_barriers)(KS *, u64, u64, u64, u64);
          void (*store_conflict)(KS *, u64, u64, u64, u64);
          void (*remember)(KS *, u64, u64, u64);
        } KVT;
        #define VT(s) AT(s, W_VT, const KVT *)
        static inline int k_canstore(KS *s, u64 o, u64 n) {
          if (o & OOP_TAG_MASK) return 0;
          u64 h = k_header(s, o);
          return (h & HDR_BYTES_BIT) == 0 && (h & HDR_READONLY_BIT) == 0 && n < ((h & HDR_COUNT_MASK) >> HDR_COUNT_SHIFT);
        }
        /* storeWithBarrier restated (rule 9; Nursery/Barrier.swift): with the
           flag line's barrier word set, the VM's store through the barriers.
           Else module 6's post-store check: the state word relaxed, the slot
           stored seq_cst at the body that word names, the word reloaded
           seq_cst; a change or the RELOCATING bit is the VM's conflict path,
           which stores again. Then the young barrier: a reference whose
           header is young in another nursery than the holder's. */
        static inline void k_store(KS *s, u64 o, u64 i, u64 v, u64 site) {
          if (__atomic_load_n(AT(s, W_FLAG, u32 *) + 2, __ATOMIC_RELAXED) != 0) { VT(s)->store_barriers(s, o, i, v, site); return; }
          u64 *sw = (u64 *)(AT(s, W_TABLE, char *) + o);
          u64 e1 = __atomic_load_n(sw, __ATOMIC_RELAXED);
          __atomic_store_n((u64 *)(AT(s, W_HEAP, char *) + e1 + 8 + i * 8), v, __ATOMIC_SEQ_CST);
          u64 e2 = __atomic_load_n(sw, __ATOMIC_SEQ_CST);
          if (UNLIKELY(e2 != e1 || (e1 & ENTRY_RELOCATING_BIT) != 0)) { VT(s)->store_conflict(s, o, i, v, site); return; }
          if ((v & 1) == 0 && (v & OOP_TAG_MASK) == 0) {
            u64 hv = k_header(s, v);
            if ((hv & HDR_YOUNG_BIT) && ((k_header(s, o) ^ hv) & HDR_YOUNG_NURSERY_MASK)) VT(s)->remember(s, o, hv, site);
          }
        }
        typedef struct { KF *fn; u32 pc; u32 depth; } KResume;
        typedef struct { u64 h0, h1; KF *activate; KF *cold; const i32 *rx; const i16 *depth; u64 codeLen; } KGroup;
        typedef struct {
          u64 magic, version, layout0, layout1, nilOop, trueOop, falseOop, groupCount;
          const KGroup *groups;
          u64 resumeCount;
          const KResume *resume;
          void (*enter)(KS *, KF *, u64 *, u64 *, u64, u64);
          u64 generated, declined;
        } KModule;
        /* Rule 6: after a call into the VM, fp, hdr and the value come from what it answered. */
        #define KOUT(f) do { __attribute__((musttail)) return (f)(s, AT(s, W_OUT_FP, u64 *), AT(s, W_OUT_HDR, u64 *), AT(s, W_OUT_V, u64), AT(s, W_OUT_PC, u64), 0, 0); } while (0)
        #define KGO(call) do { KF *f_ = (call); if (f_ == KCONT) break; if (!f_) return; KOUT(f_); } while (0)
        """)
    }

    mutating func declare(_ p: MethodPlan) {
        let k = p.index
        if p.hasActivation { line("KFN kn_A\(k)(KS *, u64 *, u64 *, u64, u64, u64, u64);") }
        for h in p.hot { line("KFN kn_R\(k)_\(h)(KS *, u64 *, u64 *, u64, u64, u64, u64);") }
        line("KFN kn_C\(k)(KS *, u64 *, u64 *, u64, u64, u64, u64);")
    }

    mutating func method(_ p: MethodPlan) {
        line("/* \(p.info.name.replacingOccurrences(of: "*/", with: "* /")) */")
        if p.hasActivation { activation(p) }
        for h in p.hot { function(p, name: "kn_R\(p.index)_\(h)", entries: [h], hot: true) }
        function(p, name: "kn_C\(p.index)", entries: p.info.instructions.filter { $0.depth >= 0 }.map(\.offset), hot: false)
    }

    /// `A<k>`: the frame (rule 1), the marker, the entry. Parameters: fp the
    /// receiver's slot, hdr the caller's header, a the caller's fp, b the
    /// method, c the send's pc after it << 8 | its length, d the caller's
    /// resume index.
    mutating func activation(_ p: MethodPlan) {
        let m = p.info, k = p.index
        if m.isBlock {
            blockActivation(p)
            return
        }
        line("KFN kn_A\(k)(KS *s, u64 *fp, u64 *hdr, u64 a, u64 b, u64 c, u64 d) {")
        if m.primitive != 0 {
            line("  KF *f_ = VT(s)->invoke(s, c >> 8, fp + \(m.argc), (u64 *)a, hdr, b, \(m.argc)ULL | (c & 255) << 8);")
            line("  if (f_ == KCONT) { const KResume *e_ = &kajo_resume[d]; __attribute__((musttail)) return e_->fn(s, (u64 *)a, hdr, fp[0], e_->pc, 0, 0); }")
            line("  if (!f_) return;")
            line("  KOUT(f_);")
            line("}")
            return
        }
        line("  u64 *h = fp + \(1 + m.argc + m.temps);")
        line("  if (UNLIKELY(h + \(Int(5) + m.maxStack) >= AT(s, W_STACKEND, u64 *))) {")
        line("    KF *f_ = VT(s)->overflow(s, c >> 8, fp + \(m.argc), (u64 *)a, hdr, b, c & 255);")
        line("    if (!f_ || f_ == KCONT) return;")
        line("    KOUT(f_);")
        line("  }")
        for i in 0..<m.temps { line("  fp[\(1 + m.argc + i)] = NILV;") }
        line("  u64 *base = AT(s, W_STACKBASE, u64 *);")
        if options.returnByLookup { line("  (void)d;") }
        line("  h[0] = b; h[1] = TAG(c >> 8); h[2] = TAG((u64 *)a - base); h[3] = TAG(hdr - base); h[4] = \(options.returnByLookup ? "EMPTY_CONTEXT" : "TAG(MARKER_BASE + d)");")
        line("  __attribute__((musttail)) return kn_R\(k)_0(s, fp, h, 0, 0, 0, 0);")
        line("}")
    }

    /// `A<k>` of a block group: a closure's `value` site tail-calls it with
    /// fp the closure's slot, hdr the caller's header, a the caller's fp, b
    /// the closure, c the pc after the site << 8 | its argument count, d
    /// the caller's resume index. The frame as `activateClosure` makes it
    /// (the receiver, the arguments, the copied values, nil temps, the
    /// closure word, the header); a count that is not the block's, or no
    /// room, is the VM's own special send.
    mutating func blockActivation(_ p: MethodPlan) {
        let m = p.info, k = p.index
        line("KFN kn_A\(k)(KS *s, u64 *fp, u64 *hdr, u64 a, u64 b, u64 c, u64 d) {")
        line("  if (UNLIKELY((c & 255) != \(m.argc) || fp + \(m.argc + m.temps + 5 + m.maxStack + 1) >= AT(s, W_STACKEND, u64 *))) {")
        line("    KF *f_ = VT(s)->special(s, c >> 8, fp + (c & 255), (u64 *)a, hdr, (u64)(\(Opcode.value.rawValue - Opcode.add.rawValue) + (c & 255)) << 8 | (c & 255));")
        line("    if (f_ == KCONT) { const KResume *e_ = &kajo_resume[d]; __attribute__((musttail)) return e_->fn(s, (u64 *)a, hdr, fp[0], e_->pc, 0, 0); }")
        line("    if (!f_) return;")
        line("    KOUT(f_);")
        line("  }")
        line("  (void)d;")
        line("  fp[0] = k_slot(s, b, CLOSURE_RECEIVER);")
        for i in 0..<m.copied { line("  fp[\(1 + m.argc + i)] = k_slot(s, b, CLOSURE_SIZE + \(i));") }
        if m.temps - 1 > m.copied { for i in m.copied..<(m.temps - 1) { line("  fp[\(1 + m.argc + i)] = NILV;") } }
        line("  fp[\(m.argc + m.temps)] = b;")
        line("  u64 *h = fp + \(1 + m.argc + m.temps);")
        line("  u64 *base = AT(s, W_STACKBASE, u64 *);")
        line("  h[0] = k_slot(s, b, CLOSURE_METHOD); h[1] = TAG(c >> 8); h[2] = TAG((u64 *)a - base); h[3] = TAG(hdr - base); h[4] = EMPTY_CONTEXT;")
        line("  AT(s, W_CLOSURE_ACTIVATIONS, u64)++;")
        line("  __attribute__((musttail)) return kn_R\(k)_0(s, fp, h, 0, 0, 0, 0);")
        line("}")
    }

    /// The pcs a hot function at `entry` runs: its fast-path successors,
    /// never through a send or a return, following forward jumps only.
    func region(_ p: MethodPlan, from entry: Int) -> Set<Int> {
        var seen = Set<Int>()
        var work = [entry]
        while let pc = work.popLast() {
            guard !seen.contains(pc), let k = p.at[pc] else { continue }
            let i = p.info.instructions[k]
            guard i.depth >= 0 else { continue }
            seen.insert(pc)
            let next = pc + i.length
            switch i.op {
            case .send where !i.extended: break
            case .returnTop, .returnSelf, .blockReturn, .nonlocalReturn: break
            case .jump:
                if i.a >= 0 { work.append(next + i.a) }
            case .jumpIfTrue, .jumpIfFalse:
                work.append(next)
                if i.a >= 0 { work.append(next + i.a) }
            default:
                work.append(next)
            }
        }
        return seen
    }

    mutating func function(_ p: MethodPlan, name: String, entries: [Int], hot: Bool) {
        let m = p.info
        let pcs = hot ? region(p, from: entries[0]) : Set(m.instructions.filter { $0.depth >= 0 }.map(\.offset))
        var body = FunctionBody(plan: p, region: pcs)
        body.options = options
        for i in m.instructions where pcs.contains(i.offset) { body.instruction(i) }
        line("KFN \(name)(KS *s, u64 *fp, u64 *hdr, u64 a, u64 b, u64 c, u64 d) {")
        line("  (void)s; (void)fp; (void)hdr; (void)a; (void)b; (void)c; (void)d;")
        if m.maxStack > 0 {
            line("  u64 " + (0..<m.maxStack).map { "x\($0) __attribute__((unused)) = 0" }.joined(separator: ", ") + ";")
        }
        func loads(_ pc: Int, value: Bool) -> String {
            let d = m.instructions[p.at[pc]!].depth
            var s = ""
            for i in 0..<d { s += "x\(i) = hdr[\(5 + i)]; " }
            if value && d > 0 { s += "x\(d - 1) = a; " }
            return s
        }
        if hot {
            let e = entries[0]
            // Every way in (a return, a jump, the driver, a slow path's
            // continuation) passes the top operand in `a`.
            line("  \(loads(e, value: true))goto L\(e);")
            body.targets.insert(e)
        } else {
            line("  switch (b) {")
            for e in entries {
                line("  case \(e): \(loads(e, value: false))goto L\(e);")
                body.targets.insert(e)
            }
            line("  default: __builtin_trap();")
            line("  }")
        }
        for (pc, code) in body.blocks {
            if body.targets.contains(pc) { line("L\(pc):;") }
            text += code
        }
        line("}")
    }

    mutating func tables(_ plans: [MethodPlan], resumeCount: Int, generated: Int, declined: Int) {
        for p in plans {
            let m = p.info
            var rx = [Int](repeating: -1, count: max(m.codeLength, 1))
            for (i, pc) in p.resumePCs.enumerated() { rx[pc] = p.firstResume + i }
            var dp = [Int](repeating: -1, count: max(m.codeLength, 1))
            for i in m.instructions where i.depth >= 0 { dp[i.offset] = i.depth }
            line("static const i32 RX\(p.index)[\(rx.count)] = {\(rx.map(String.init).joined(separator: ","))};")
            line("static const i16 DP\(p.index)[\(dp.count)] = {\(dp.map(String.init).joined(separator: ","))};")
        }
        line("KHIDDEN const KResume kajo_resume[\(max(resumeCount, 1))] = {")
        if resumeCount == 0 { line("  {0, 0, 0}") }
        for p in plans {
            for pc in p.resumePCs {
                let d = p.info.instructions[p.at[pc]!].depth
                let fn = p.hot.contains(pc) ? "kn_R\(p.index)_\(pc)" : "kn_C\(p.index)"
                line("  {\(fn), \(pc), \(d)},")
            }
        }
        line("};")
        line("static const KGroup kajo_groups[\(max(plans.count, 1))] = {")
        if plans.isEmpty { line("  {0, 0, 0, 0, 0, 0, 0}") }
        for p in plans {
            let act = p.hasActivation ? "kn_A\(p.index)" : "0"
            line("  {0x\(hex(p.info.hash.0))ULL, 0x\(hex(p.info.hash.1))ULL, \(act), kn_C\(p.index), RX\(p.index), DP\(p.index), \(p.info.codeLength)},")
        }
        line("};")
        line("static void kajo_enter(KS *s, KF *fn, u64 *fp, u64 *hdr, u64 v, u64 pc) { fn(s, fp, hdr, v, pc, 0, 0); }")
        line("__attribute__((visibility(\"default\"))) const KModule kajo_native_module = {")
        line("  0x\(hex(nativeModuleMagicWord))ULL, FORMAT_VERSION, LAYOUT_HASH0, LAYOUT_HASH1, NILV, TRUEV, FALSEV, \(plans.count),")
        line("  kajo_groups, \(resumeCount), kajo_resume, kajo_enter, \(generated), \(declined)")
        line("};")
    }
}

let nativeModuleMagicWord: UInt64 = 0x5654_414E_4F4A_414B

/// Control leaves the instruction other than by falling through.
func endsBlock(_ op: Opcode) -> Bool {
    op == .returnTop || op == .returnSelf || op == .jump || op == .blockReturn || op == .nonlocalReturn
}

/// One function's code, instruction by instruction, and the labels it
/// jumps to.
struct FunctionBody {
    let plan: MethodPlan
    var options = AOTOptions()
    let region: Set<Int>
    var blocks: [(Int, String)] = []
    var targets = Set<Int>()
    var code = ""
    /// The next pc of the region after each, in emission order.
    let nextInRegion: [Int: Int]

    init(plan: MethodPlan, region: Set<Int>) {
        self.plan = plan
        self.region = region
        let sorted = region.sorted()
        var n: [Int: Int] = [:]
        for (k, pc) in sorted.enumerated() where k + 1 < sorted.count { n[pc] = sorted[k + 1] }
        nextInRegion = n
    }

    var info: NativeMethodInfo { plan.info }

    mutating func emit(_ s: String) {
        code += "  "
        code += s
        code += "\n"
    }

    func lit(_ n: Int) -> String { "0x\(hex(info.literals[n]))ULL" }
    func sp(_ d: Int) -> String { "hdr + \(4 + d)" }
    func flush(_ d: Int) -> String { (0..<d).map { "hdr[\(5 + $0)] = x\($0);" }.joined(separator: " ") }
    func reload(_ d: Int) -> String { (0..<max(d, 0)).map { "x\($0) = hdr[\(5 + $0)];" }.joined(separator: " ") }

    /// Depth before the instruction at `pc`, or nil.
    func depth(at pc: Int) -> Int? {
        guard let k = plan.at[pc] else { return nil }
        let d = info.instructions[k].depth
        return d >= 0 ? d : nil
    }

    /// Continue at `pc` with `d` operands in locals: a jump inside the
    /// function, or a tail call of the hot function there (operands
    /// flushed: it reads them from the frame).
    mutating func goTo(_ pc: Int, _ d: Int) {
        if region.contains(pc) {
            targets.insert(pc)
            emit("goto L\(pc);")
        } else if plan.hot.contains(pc) {
            emit("\(flush(d)) __attribute__((musttail)) return kn_R\(plan.index)_\(pc)(s, fp, hdr, \(d > 0 ? "x\(d - 1)" : "0"), \(pc), 0, 0);")
        } else {
            emit("\(flush(d)) __attribute__((musttail)) return kn_C\(plan.index)(s, fp, hdr, 0, \(pc), 0, 0);")
        }
    }

    /// The VM runs the instruction (`exec`), and native code goes on.
    mutating func viaVM(_ i: NativeInstruction, _ d: Int, after: Int?) {
        emit("\(flush(d)) KGO(VT(s)->exec(s, \(i.offset), \(sp(d)), fp, hdr));")
        if let a = after { emit(reload(a)) }
    }

    /// A special send's slow path (the VM's `specialSend`).
    func special(_ op: Opcode, _ d: Int, next: Int) -> String {
        let index = Int(op.rawValue - Opcode.add.rawValue)
        let argc = op.specialArgc
        return "\(flush(d)) KGO(VT(s)->special(s, \(next), \(sp(d)), fp, hdr, \(index << 8 | argc))); \(reload(d - argc))"
    }

    mutating func poll(target: Int, _ d: Int) {
        let f = options.brokenNoFlushAtPoll ? "" : flush(d)
        emit("if (UNLIKELY(k_due(s))) { \(f) KGO(VT(s)->poll_jump(s, \(target), \(sp(d)), fp, hdr)); \(reload(d)) }")
    }

    mutating func instruction(_ i: NativeInstruction) {
        code = ""
        let d = i.depth, next = i.offset + i.length
        let after = depth(at: next)
        func top(_ k: Int = 1) -> String { "x\(d - k)" }
        switch i.op {
        case .pushTemp: emit("x\(d) = fp[\(1 + i.a)];")
        case .pushLiteral: emit("x\(d) = \(lit(i.a));")
        case .pushSelf: emit("x\(d) = fp[0];")
        case .pushIvar where !i.extended:
            emit("{ u64 r_ = fp[0]; if (UNLIKELY(!k_hasslot(s, r_, \(i.a)))) { \(flush(d)) KGO(VT(s)->fail(s, \(next), \(sp(d)), fp, hdr, \(i.length), r_)); return; } x\(d) = k_slot(s, r_, \(i.a)); }")
        case .storeTemp: emit("fp[\(1 + i.a)] = \(top());")
        case .pop: break
        case .dup: emit("x\(d) = \(top());")
        case .pushNil: emit("x\(d) = NILV;")
        case .pushTrue: emit("x\(d) = TRUEV;")
        case .pushFalse: emit("x\(d) = FALSEV;")
        case .pushInt: emit("x\(d) = 0x\(hex(UInt64(bitPattern: Int64(i.a)) << 1 | 1))ULL;")
        case .send where !i.extended: send(i, d, next: next)
        case .returnTop, .blockReturn: ret(top(), d, next: next)
        case .returnSelf: ret("fp[0]", d, next: next)
        case .jump:
            let t = next + i.a
            if i.a < 0 { poll(target: t, d) }
            goTo(t, d)
        case .jumpIfTrue, .jumpIfFalse:
            let t = next + i.a
            let taken = i.op == .jumpIfTrue ? "TRUEV" : "FALSEV", other = i.op == .jumpIfTrue ? "FALSEV" : "TRUEV"
            emit("{ u64 c_ = \(top());")
            emit("if (c_ == \(taken)) {")
            if i.a < 0 { poll(target: t, d - 1) }
            goTo(t, d - 1)
            emit("}")
            emit("if (UNLIKELY(c_ != \(other))) { \(flush(d)) KGO(VT(s)->fail(s, \(next), \(sp(d)), fp, hdr, \(1 << 8 | i.length), c_)); return; } }")
        case .add, .sub:
            let f = i.op == .add ? "__builtin_add_overflow" : "__builtin_sub_overflow"
            emit("{ u64 a_ = \(top(2)), b_ = \(top()); i64 r_; if (LIKELY(a_ & b_ & 1) && !\(f)((i64)a_, (i64)b_ - 1, &r_)) \(top(2)) = (u64)r_; else { \(special(i.op, d, next: next)) } }")
        case .mul:
            emit("{ u64 a_ = \(top(2)), b_ = \(top()); i64 r_; if (LIKELY(a_ & b_ & 1) && !__builtin_mul_overflow((i64)a_ >> 1, (i64)b_ - 1, &r_)) \(top(2)) = (u64)r_ | 1; else { \(special(i.op, d, next: next)) } }")
        case .lt, .gt, .le, .ge, .eq, .ne:
            let c = ["lt": "<", "gt": ">", "le": "<=", "ge": ">=", "eq": "==", "ne": "!="][i.op.mnemonic]!
            emit("{ u64 a_ = \(top(2)), b_ = \(top()); if (LIKELY(a_ & b_ & 1)) \(top(2)) = ((i64)a_ \(c) (i64)b_) ? TRUEV : FALSEV; else { \(special(i.op, d, next: next)) } }")
        case .identical: emit("\(top(2)) = \(top(2)) == \(top()) ? TRUEV : FALSEV;")
        case .notIdentical: emit("\(top(2)) = \(top(2)) != \(top()) ? TRUEV : FALSEV;")
        case .isNil: emit("\(top()) = \(top()) == NILV ? TRUEV : FALSEV;")
        case .notNil: emit("\(top()) = \(top()) == NILV ? FALSEV : TRUEV;")
        case .at:
            emit("{ u64 a_ = \(top(2)), i_ = \(top()); int done_ = 0;")
            emit("  if ((a_ & OOP_TAG_MASK) == 0 && (i_ & 1)) { u64 h_ = k_header(s, a_); u64 k_ = (u64)((i64)i_ >> 1) - 1;")
            emit("    if ((h_ & HDR_CLASS_MASK) == CLS_ARRAY && k_ < ((h_ & HDR_COUNT_MASK) >> HDR_COUNT_SHIFT)) { \(top(2)) = k_slot(s, a_, k_); done_ = 1; } }")
            emit("  if (!done_) { \(special(i.op, d, next: next)) } }")
        case .value where options.inlineClosures, .value1 where options.inlineClosures, .value2 where options.inlineClosures:
            // Part 3, step 2: the closure's block activation, natively.
            let n = i.op.specialArgc
            let ri = plan.resumeIndex(next) ?? 0
            emit("{ u64 c_ = x\(d - 1 - n);")
            emit("  if ((c_ & OOP_TAG_MASK) == 0 && (k_header(s, c_) & HDR_CLASS_MASK) == CLS_BLOCKCLOSURE) {")
            emit("    KF *b_ = *(KF *const *)(AT(s, W_NTAB, const char *) + k_slot(s, c_, CLOSURE_METHOD));")
            emit("    if (LIKELY(b_ != 0)) { \(flush(d)) __attribute__((musttail)) return b_(s, hdr + \(5 + d - 1 - n), hdr, (u64)fp, c_, \(next << 8 | n), \(ri)); } }")
            emit("  \(special(i.op, d, next: next)) }")
        case .div, .intDiv, .mod, .atPut, .size, .value, .value1, .value2:
            emit(special(i.op, d, next: next))
        case .storeIvar where !i.extended && options.inlineStores:
            // Part 3: the store inline (k_store); a refusal (read-only, no
            // such slot) is the VM's own instruction.
            emit("{ u64 o_ = fp[0]; if (LIKELY(k_canstore(s, o_, \(i.a)))) k_store(s, o_, \(i.a), \(top()), SITE_STORE_IVAR);")
            emit("  else { \(flush(d)) KGO(VT(s)->exec(s, \(i.offset), \(sp(d)), fp, hdr)); \(reload(d - 1)) } }")
        case .storeTempVectorSlot where !i.extended && options.inlineStores:
            emit("{ u64 o_ = fp[\(1 + i.b)]; if (LIKELY(k_canstore(s, o_, \(i.a)))) k_store(s, o_, \(i.a), \(top()), SITE_STORE_TEMP_VECTOR);")
            emit("  else { \(flush(d)) KGO(VT(s)->exec(s, \(i.offset), \(sp(d)), fp, hdr)); \(reload(d - 1)) } }")
        case .pushTempVectorSlot where !i.extended && options.inlineStores:
            emit("{ u64 o_ = fp[\(1 + i.b)]; if (UNLIKELY(!k_hasslot(s, o_, \(i.a)))) { \(flush(d)) KGO(VT(s)->fail(s, \(next), \(sp(d)), fp, hdr, \(i.length), o_)); return; } x\(d) = k_slot(s, o_, \(i.a)); }")
        default:
            viaVM(i, d, after: after)
        }
        // Fall through to the next instruction (it is in the function: the
        // region follows every fall-through); a jump when another block is
        // emitted between.
        if !endsBlock(i.op) && !(i.op == .send && !i.extended) {
            if nextInRegion[i.offset] != next {
                targets.insert(next)
                emit("goto L\(next);")
            }
        }
        blocks.append((i.offset, code))
    }

    mutating func ret(_ value: String, _ d: Int, next: Int) {
        if options.returnByLookup {
            // The lookup candidate: the caller's method, its group, the
            // resume index at the caller's pc.
            emit("{ u64 v_ = \(value);")
            emit("  if (LIKELY(hdr[4] == EMPTY_CONTEXT)) {")
            emit("    u64 *base_ = AT(s, W_STACKBASE, u64 *); u64 *ch_ = base_ + UNTAG(hdr[3]);")
            emit("    const KGroup *g_ = *(const KGroup *const *)(AT(s, W_NTAB, const char *) + ch_[0] + 8);")
            emit("    if (LIKELY(g_ != 0)) { i32 i_ = g_->rx[UNTAG(hdr[1])];")
            emit("      if (LIKELY(i_ >= 0)) { u64 *cf_ = base_ + UNTAG(hdr[2]); fp[0] = v_; AT(s, W_NRETURNS, u64)++;")
            emit("        const KResume *e_ = &kajo_resume[i_]; __attribute__((musttail)) return e_->fn(s, cf_, ch_, v_, e_->pc, 0, 0); } } }")
            emit("  \(flush(d)) KF *f_ = VT(s)->ret(s, \(next), \(sp(d)), fp, hdr, v_); if (!f_ || f_ == KCONT) return; KOUT(f_); }")
            return
        }
        emit("{ u64 v_ = \(value); u64 cw_ = hdr[4];")
        emit("  if (LIKELY((cw_ & 1) && cw_ >= TAG(MARKER_BASE))) {")
        emit("    u64 *base_ = AT(s, W_STACKBASE, u64 *); u64 *cf_ = base_ + UNTAG(hdr[2]); u64 *ch_ = base_ + UNTAG(hdr[3]);")
        emit("    fp[0] = v_; AT(s, W_NRETURNS, u64)++;")
        emit("    const KResume *e_ = &kajo_resume[UNTAG(cw_) - MARKER_BASE];")
        emit("    __attribute__((musttail)) return e_->fn(s, cf_, ch_, v_, e_->pc, 0, 0); }")
        emit("  \(flush(d)) KF *f_ = VT(s)->ret(s, \(next), \(sp(d)), fp, hdr, v_); if (!f_ || f_ == KCONT) return; KOUT(f_); }")
    }

    /// A send (rule 7: poll, count, probe, then the native activation or
    /// the VM's invoke).
    mutating func send(_ i: NativeInstruction, _ d: Int, next: Int) {
        let argc = i.b, sel = lit(i.a)
        let rcvAt = 5 + d - 1 - argc
        let dAfter = d - argc
        let ri = plan.resumeIndex(next)
        emit(flush(d))
        emit("if (UNLIKELY(k_due(s))) { KF *f_ = VT(s)->poll_send(s, \(next), \(sp(d)), fp, hdr, \(i.length)); if (f_ != KCONT) { if (!f_) return; KOUT(f_); } }")
        if !options.brokenNoSendCount { emit("AT(s, W_SENDS, u64)++;") }
        emit("{ u64 *rp_ = hdr + \(rcvAt); u64 cls_ = k_classof(s, *rp_);")
        emit("  const char *e_ = AT(s, W_CACHE, const char *) + ((((\(sel) >> 4) ^ cls_) & (CACHE_ENTRIES - 1)) * CACHE_STRIDE);")
        emit("  u64 m_;")
        emit("  if (LIKELY(*(const u64 *)(e_ + CACHE_CLS) == cls_ && *(const u64 *)(e_ + CACHE_SEL) == \(sel))) m_ = *(const u64 *)(e_ + CACHE_METHOD);")
        emit("  else m_ = VT(s)->lookup(s, cls_, \(sel));")
        // No method (0: the table's line 0 is empty), an unbound method or
        // a primitive: the VM's own send from here (doesNotUnderstand:,
        // invoke).
        emit("  KF *act_ = *(KF *const *)(AT(s, W_NTAB, const char *) + m_);")
        emit("  if (UNLIKELY(!act_)) { KF *f_ = VT(s)->send_slow(s, \(next), \(sp(d)), fp, hdr, \(sel), \(argc | i.length << 8), m_); if (!f_) return; KOUT(f_); }")
        emit("  AT(s, W_NSENDS, u64)++;")
        emit("  __attribute__((musttail)) return act_(s, rp_, hdr, (u64)fp, m_, \(next << 8 | i.length), \(ri ?? 0)); }")
        _ = dAfter
    }
}
