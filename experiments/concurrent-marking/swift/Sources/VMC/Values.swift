// Tagged values and header packing (SPEC-SHARED.md "Values", "Object header").
// Copied from ../ui-thread-scheduling; adds the young bit (SPEC.md
// "Young/old encoding").

import Darwin

public typealias Oop = UInt64

public let classMask: UInt64 = (1 << 22) - 1
public let slotsShift: UInt64 = 22
public let slotsMask: UInt64 = (1 << 32) - 1
public let markBit: UInt64 = 1 << 54
public let bytesBit: UInt64 = 1 << 55
/// Set while the body lives in a nursery (SPEC.md "Young/old encoding").
public let youngBit: UInt64 = 1 << 56

public let intMin: Int64 = -(1 << 62)
public let intMax: Int64 = (1 << 62) - 1

// Well-known class indices. 0 is the forwarder class in A/C (SPEC.md
// "Forwarders") and marks a free or forwarding entry in B.
public let ciForwarder: UInt32 = 0
public let ciSmallInt: UInt32 = 1
public let ciNil: UInt32 = 2
public let ciTrue: UInt32 = 3
public let ciFalse: UInt32 = 4
public let ciClass: UInt32 = 5
public let ciMethod: UInt32 = 6
public let ciArray: UInt32 = 7
public let ciByteArray: UInt32 = 8
public let ciSymbol: UInt32 = 9
public let ciMethodDict: UInt32 = 10
public let ciObject: UInt32 = 11
public let ciProcess: UInt32 = 12
public let ciSemaphore: UInt32 = 13
public let firstUserClass: UInt32 = 14
public let classTableSize = 1024
public let globalCount = 16

public let builtinClassNames = [
    "SmallInteger", "UndefinedObject", "True", "False", "Class", "Method",
    "Array", "ByteArray", "Symbol", "MethodDict", "Object", "Process", "Semaphore",
]

// Class object slots.
public let cSuper = 0, cDict = 1, cName = 2, cInstSize = 3, cIndex = 4, classSlots = 5
// Method object slots.
public let mBytecodes = 0, mLiterals = 1, mArgc = 2, mNTemps = 3, mMaxStack = 4, mSelector = 5, mPrim = 6
public let methodSlots = 7
// Process object slots (SPEC.md "Process object and native stack").
public let pPriority = 0, pState = 1, pWaitingOn = 2, pAffinity = 3, pNext = 4, pRec = 5
public let pSp = 6, pPc = 7, pFp = 8, pHdr = 9, pResult = 10, pExitSem = 11, pId = 12
public let processSlots = 13
public let stReady: Int64 = 0, stRunning: Int64 = 1, stWaiting: Int64 = 2, stTerminated: Int64 = 3
// Semaphore object slots.
public let sExcess = 0, sFirst = 1, sLast = 2, semaphoreSlots = 3

@inline(__always) public func isInt(_ v: Oop) -> Bool { v & 1 != 0 }
@inline(__always) public func intVal(_ v: Oop) -> Int64 { Int64(bitPattern: v) &>> 1 }
@inline(__always) public func mkInt(_ i: Int64) -> Oop { UInt64(bitPattern: (i &<< 1) | 1) }
@inline(__always) public func fitsInt(_ i: Int64) -> Bool { i >= intMin && i <= intMax }

@inline(__always) public func makeHeader(_ cls: UInt32, _ slots: Int, _ bytes: Bool) -> UInt64 {
    UInt64(cls) | (UInt64(truncatingIfNeeded: slots) &<< slotsShift) | (bytes ? bytesBit : 0)
}
@inline(__always) public func hdrClass(_ h: UInt64) -> UInt64 { h & classMask }
@inline(__always) public func hdrSlots(_ h: UInt64) -> Int { Int(truncatingIfNeeded: (h &>> slotsShift) & slotsMask) }
@inline(__always) public func hdrIsBytes(_ h: UInt64) -> Bool { h & bytesBit != 0 }
@inline(__always) public func hdrMarked(_ h: UInt64) -> Bool { h & markBit != 0 }
@inline(__always) public func hdrYoung(_ h: UInt64) -> Bool { h & youngBit != 0 }
/// Object (A/C) or body (B) size in bytes, first word included.
@inline(__always) public func objectBytes(_ h: UInt64) -> Int {
    let n = hdrSlots(h)
    return 8 &+ (hdrIsBytes(h) ? (n &+ 7) & ~7 : n &* 8)
}
@inline(__always) public func sizeFor(_ slots: Int, _ bytes: Bool) -> Int {
    8 &+ (bytes ? (slots &+ 7) & ~7 : slots &* 8)
}

/// Tag a raw address as a SmallInteger (frame header words).
@inline(__always) func tagAddr<T>(_ p: UnsafePointer<T>?) -> Oop { mkInt(Int64(Int(bitPattern: p))) }
@inline(__always) func untagPtr<T>(_ v: Oop, _: T.Type) -> UnsafeMutablePointer<T> {
    UnsafeMutablePointer<T>(bitPattern: Int(intVal(v))).unsafelyUnwrapped
}
@inline(__always) func wordPtr(_ a: UInt) -> UnsafeMutablePointer<UInt64> {
    UnsafeMutablePointer<UInt64>(bitPattern: a).unsafelyUnwrapped
}

@inline(__always) public func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

/// mach_absolute_time ticks; the budget clock (SPEC.md "Budget").
@inline(__always) public func ticks() -> UInt64 { mach_absolute_time() }
public let ticksPerNs: Double = {
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    return Double(tb.denom) / Double(tb.numer)
}()
@inline(__always) public func nsToTicks(_ ns: UInt64) -> UInt64 { UInt64(Double(ns) * ticksPerNs) }
@inline(__always) public func ticksToNs(_ t: UInt64) -> UInt64 { UInt64(Double(t) / ticksPerNs) }

@inline(never)
public func fatal(_ msg: String) -> Never {
    FileHandleStderr.write("kajo: fatal: \(msg)\n")
    exit(2)
}

public enum FileHandleStderr {
    public static func write(_ s: String) {
        var s = s
        s.withUTF8 { buf in _ = Darwin.write(2, buf.baseAddress, buf.count) }
    }
}
