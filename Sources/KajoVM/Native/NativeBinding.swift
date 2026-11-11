import Darwin

// AOT 1 (docs/modules/aot.md, rule 10): binding a compiled module to an
// image by content.
//
// A module is one descriptor the generated C defines (`kajo_native_module`):
//
//     struct KModule {                        offset
//         u64 magic, version;                 0, 8
//         u64 layout0, layout1;               16, 24   the layout hash
//         u64 nilOop, trueOop, falseOop;      32..48   folded into the code
//         u64 groupCount; const KGroup *groups;        56, 64 (sorted by hash)
//         u64 resumeCount; const KResume *resume;      72, 80
//         void (*enter)(KS*, KF*, u64 *fp, u64 *hdr, u64 v, u64 pc);   88
//         u64 methodsGenerated, methodsDeclined;       96, 104
//     };
//     struct KGroup  { u64 h0, h1; KF *activate; KF *cold;
//                      const int32_t *rx; const int16_t *depth; u64 codeLen; };   56 bytes
//     struct KResume { KF *fn; uint32_t pc, depth; };                             16 bytes
//
// At bind every CompiledMethod of the image (block methods included) is
// hashed (`nativeMethodHash`) and looked up; a match fills the method's
// line of the method-to-native table (16 bytes per object-table entry,
// indexed by the method's oop, which is its entry offset: `{activate,
// group}`), and the method is registered as a root so its entry is never
// freed and reused under the binding (`becomeForward` clears a forwarded
// method's line). No match is not an error: the method runs interpreted.

enum ModuleOffset {
    static let magic = 0, version = 8, layout0 = 16, layout1 = 24, nilOop = 32, trueOop = 40, falseOop = 48
    static let groupCount = 56, groups = 64, resumeCount = 72, resume = 80, enter = 88
    static let generated = 96, declined = 104
}

enum GroupOffset {
    static let h0 = 0, h1 = 8, activate = 16, cold = 24, rx = 32, depth = 40, codeLen = 48
    static let stride = 56
}

/// A compiled module: its descriptor, from a `dlopen`ed dylib (tests,
/// `kajo run --native`) or linked into the app (the shells).
@safe public struct NativeModule: @unchecked Sendable {
    let descriptor: UnsafeRawPointer

    /// A descriptor linked into the binary (its symbol's address).
    public init(descriptor: UnsafeRawPointer) { unsafe self.descriptor = descriptor }

    /// `dlopen` the dylib at `path` and take its descriptor. The library
    /// stays loaded for the process's life (its code may be on any stack).
    public static func load(dylib path: String) -> Result<NativeModule, NativeBindError> {
        guard let h = unsafe dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            return .failure(.cannotLoad(unsafe dlerror().map { unsafe String(cString: $0) } ?? path))
        }
        guard let d = unsafe dlsym(h, "kajo_native_module") else { return .failure(.cannotLoad("\(path): no kajo_native_module")) }
        return .success(unsafe NativeModule(descriptor: UnsafeRawPointer(d)))
    }

    func word(_ off: Int) -> UInt64 { unsafe descriptor.load(fromByteOffset: off, as: UInt64.self) }
    func pointer(_ off: Int) -> UnsafeRawPointer? { unsafe descriptor.load(fromByteOffset: off, as: UnsafeRawPointer?.self) }

    /// How many methods the generator wrote and declined (its report).
    public var methodsGenerated: UInt64 { word(ModuleOffset.generated) }
    public var methodsDeclined: UInt64 { word(ModuleOffset.declined) }
}

public enum NativeBindError: Error, Equatable, CustomStringConvertible, Sendable {
    case cannotLoad(String)
    case refused(String)

    public var description: String {
        switch self {
        case .cannotLoad(let s): "cannot load the native module: \(s)"
        case .refused(let s): "native module refused: \(s)"
        }
    }
}

/// What a bind did, for the run line and the tests.
public struct NativeBindReport: Sendable, Equatable {
    public var methods = 0
    public var bound = 0
    /// Methods with no group of their hash (changed since the generation,
    /// made at run time, or never generated), and methods whose hash could
    /// not be computed.
    public var unboundNoMatch = 0
    public var unboundUnreadable = 0
    /// Distinct groups the bound methods use (two methods of equal content
    /// share one).
    public var groupsUsed = 0
    public var bindNs: UInt64 = 0
    /// Set when the module was refused whole (nothing bound).
    public var refused: String? = nil
}

/// The VM's binding, in raw memory beside the VM state.
@unsafe struct NativeBinding {
    let module: NativeModule
    let table: UnsafeMutableRawPointer
    let tableBytes: Int
    let vt: UnsafeMutablePointer<UnsafeRawPointer?>
    var report: NativeBindReport
    /// The bound methods' roots, removed when the binding goes.
    var roots: [RootHandle]
}

typealias NativeEnter = @convention(c) (UnsafeMutableRawPointer, UnsafeRawPointer, UnsafeMutablePointer<UInt64>,
                                        UnsafeMutablePointer<UInt64>, UInt64, UInt64) -> Void

extension NativeModule {
    /// The module's own refusal, before any method is looked at: its magic,
    /// version, layout hash and the nil, true and false it folded.
    func refusal(image: Image) -> String? {
        if word(ModuleOffset.magic) != nativeModuleMagic { return "not a Kajo native module" }
        if word(ModuleOffset.version) != nativeFormatVersion {
            return "interface version \(word(ModuleOffset.version)), this VM's is \(nativeFormatVersion)"
        }
        let l = NativeLayout.hash
        if word(ModuleOffset.layout0) != l.0 || word(ModuleOffset.layout1) != l.1 { return "its layout hash is not this VM's build" }
        if word(ModuleOffset.nilOop) != image.nilObject.raw || word(ModuleOffset.trueOop) != image.trueObject.raw
            || word(ModuleOffset.falseOop) != image.falseObject.raw {
            return "it was generated for an image whose nil, true or false differ"
        }
        if unsafe pointer(ModuleOffset.enter) == nil { return "no entry trampoline" }
        return nil
    }

    var groupCount: Int { Int(word(ModuleOffset.groupCount)) }
    func group(_ i: Int) -> UnsafeRawPointer { unsafe pointer(ModuleOffset.groups).unsafelyUnwrapped + i * GroupOffset.stride }

    /// The group whose hash is `h`, by binary search (the generator sorts
    /// them by `h0`, then `h1`).
    func group(hash h: (UInt64, UInt64)) -> UnsafeRawPointer? {
        var lo = 0, hi = groupCount
        while lo < hi {
            let mid = (lo + hi) / 2
            let g = unsafe group(mid)
            let a = unsafe (g.load(fromByteOffset: GroupOffset.h0, as: UInt64.self), g.load(fromByteOffset: GroupOffset.h1, as: UInt64.self))
            if a == h { return unsafe g }
            if a.0 < h.0 || (a.0 == h.0 && a.1 < h.1) { lo = mid + 1 } else { hi = mid }
        }
        return nil
    }
}

/// Bind `module` to the image's methods: the VM's (before any worker
/// starts, nothing young) or a standalone interpreter's. Answers the
/// binding, or nil with the refusal in the report.
func bindNative(_ image: Image, _ module: NativeModule) -> (NativeBinding?, NativeBindReport) {
    let t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    var report = NativeBindReport()
    if let r = module.refusal(image: image) {
        report.refused = r
        return (nil, report)
    }
    let om = image.om
    let bytes = Int(om.entryCapacity) * 16
    guard let table = unsafe try? VirtualMemory.reserve(bytes) else {
        report.refused = "cannot reserve the method table"
        return (nil, report)
    }
    var methods: [Oop] = []
    var classes = [Bool](repeating: false, count: Int(WellKnown.method) + 1)
    classes[Int(WellKnown.method)] = true
    om.walkInstances(of: classes) { methods.append($0); return true }
    var used = Set<UInt>()
    var roots: [RootHandle] = []
    for m in methods {
        report.methods += 1
        guard let h = nativeMethodHash(om, m) else {
            report.unboundUnreadable += 1
            continue
        }
        guard let g = unsafe module.group(hash: h) else {
            report.unboundNoMatch += 1
            continue
        }
        let line = unsafe table + Int(truncatingIfNeeded: m.raw)
        unsafe line.storeBytes(of: g.load(fromByteOffset: GroupOffset.activate, as: UInt64.self), as: UInt64.self)
        unsafe line.storeBytes(of: UInt64(UInt(bitPattern: g)), toByteOffset: 8, as: UInt64.self)
        roots.append(om.addRoot(m))
        used.insert(UInt(bitPattern: g))
        report.bound += 1
    }
    report.groupsUsed = used.count
    unsafe om.gc.pointee.nativeTable = table
    report.bindNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- t0
    let vt = unsafe makeNativeInterface()
    return (unsafe NativeBinding(module: module, table: table, tableBytes: bytes, vt: vt, report: report, roots: roots), report)
}

/// A worker runs the binding's native code from now on.
func attachNative(_ w: WorkerPointer, _ b: UnsafeMutablePointer<NativeBinding>) {
    unsafe w.pointee.native.table = b.pointee.table
    unsafe w.pointee.native.vt = UnsafeRawPointer(b.pointee.vt)
    unsafe w.pointee.native.module = b.pointee.module.descriptor
}

/// Release a binding: its roots, its table, its interface table. The
/// workers are gone or no longer run (the VM's end, a standalone
/// interpreter's destroy).
func unbindNative(_ image: Image, _ b: NativeBinding) {
    let om = image.om
    for r in unsafe b.roots { om.removeRoot(r) }
    if unsafe om.gc.pointee.nativeTable == b.table { unsafe om.gc.pointee.nativeTable = nil }
    unsafe VirtualMemory.release(b.table, b.tableBytes)
    unsafe b.vt.deallocate()
}

/// The binding's line of the method-to-native table for `method`, or nil.
@inline(__always)
func nativeGroup(_ table: UnsafeMutableRawPointer, _ method: UInt64) -> UnsafeRawPointer? {
    unsafe (table + Int(truncatingIfNeeded: method)).load(fromByteOffset: 8, as: UnsafeRawPointer?.self)
}

extension ObjectMemory {
    /// `becomeForward` frees its sources' entries: a forwarded method's
    /// line in the method-to-native table goes with it (a reshape forwards
    /// a class's methods to their recompiled versions; the running-frame
    /// rule keeps them off every stack). World stopped.
    func unbindNative(_ o: Oop) {
        guard let t = unsafe gc.pointee.nativeTable else { return }
        unsafe (t + Int(truncatingIfNeeded: o.raw)).storeBytes(of: 0, as: UInt64.self)
        unsafe (t + Int(truncatingIfNeeded: o.raw)).storeBytes(of: 0, toByteOffset: 8, as: UInt64.self)
    }
}
