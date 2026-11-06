import Darwin
import Synchronization

/// Test instrumentation for the object memory's reservations
/// (`ObjectMemoryConfig.reservations`): which are live, and the `failAt`-th
/// one (1-based; 0 never) refused, so a test sees an initializer release
/// what it reserved before a later reservation failed.
final class ReservationProbe: Sendable {
    let failAt: Int
    private let state = Mutex<(made: Int, live: [UInt: Int])>((0, [:]))

    init(failAt: Int = 0) { self.failAt = failAt }

    /// Reservations made and not released: address and bytes.
    var live: [UInt: Int] { state.withLock { $0.live } }
    var made: Int { state.withLock { $0.made } }

    /// The next reservation is refused.
    func refuses() -> Bool { state.withLock { s in s.made + 1 == failAt } }

    func reserved(_ p: UnsafeMutableRawPointer, _ bytes: Int) {
        state.withLock { s in
            s.made += 1
            s.live[UInt(bitPattern: p)] = bytes
        }
    }

    func released(_ p: UnsafeMutableRawPointer) { state.withLock { s in _ = s.live.removeValue(forKey: UInt(bitPattern: p)) } }
}

/// Address-space reservations for the object memory. Pages are zero-filled
/// on first touch. Only the `vm_map.h` family is used: `mach_vm.h` is
/// unsupported in the iOS SDK (AGENTS.md).
enum VirtualMemory {
    /// The task port. The macOS SDK and, since iOS 27 under Xcode's build of
    /// the package, the iOS SDK import `mach_task_self_` as a mutable global
    /// (unsafe to read); one accessor keeps every build warning-free.
    private static var task: mach_port_t { unsafe mach_task_self_ }

    /// Distance between the heap and its alias (ADR 0007): an entry state word
    /// holding `offset + aliasDistance` (RELOCATING, module 6) still leads
    /// to the intact body.
    static let aliasDistance: UInt64 = 1 << 32

    /// `mmap` and `munmap`, not `vm_allocate`: ThreadSanitizer intercepts
    /// them and resets its shadow of the range, so a later reservation at
    /// the same address (another VM in the same process) does not inherit
    /// the earlier one's accesses. With the Mach calls it reported a race
    /// between two tests' side tables that merely shared an address.
    static func reserve(_ bytes: Int, probe: ReservationProbe? = nil) throws(ObjectMemoryError) -> UnsafeMutableRawPointer {
        if probe?.refuses() == true { throw .reservationFailed("mmap \(bytes) bytes: refused by the test probe") }
        let p = unsafe mmap(nil, bytes, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0)
        guard let p = unsafe p, unsafe p != MAP_FAILED else {
            throw .reservationFailed("mmap \(bytes) bytes: \(errno)")
        }
        unsafe probe?.reserved(p, bytes)
        return unsafe p
    }

    static func release(_ p: UnsafeMutableRawPointer, _ bytes: Int, probe: ReservationProbe? = nil) {
        _ = unsafe munmap(p, bytes)
        unsafe probe?.released(p)
    }

    /// Reserve `aliasDistance + bytes` and map one memory object of `bytes`
    /// at the start and again at `+ aliasDistance`.
    ///
    /// ThreadSanitizer cannot see that the two mappings alias: an access
    /// through the alias and one through the base are different addresses
    /// to it. Any protocol that uses the alias (module 6's RELOCATING state)
    /// is covered by tests and its ordering argument only (AGENTS.md).
    static func reserveTwice(_ bytes: Int, probe: ReservationProbe? = nil) throws(ObjectMemoryError) -> (UnsafeMutableRawPointer, mach_port_t) {
        precondition(bytes > 0 && UInt64(bytes) <= aliasDistance)
        if probe?.refuses() == true { throw .reservationFailed("mmap alias range: refused by the test probe") }
        let span = vm_size_t(bytes)
        // The range is reserved with `mmap` and released with `munmap` (see
        // `reserve`); the two mappings of the memory object replace parts
        // of it.
        let range = unsafe mmap(nil, Int(aliasDistance) + bytes, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0)
        guard let range = unsafe range, unsafe range != MAP_FAILED else { throw .reservationFailed("mmap alias range: \(errno)") }
        let addr = vm_address_t(UInt(bitPattern: range))
        var kr: kern_return_t
        var size = memory_object_size_t(span)
        var entry: mach_port_t = 0
        kr = unsafe mach_make_memory_entry_64(task, &size, 0, MAP_MEM_NAMED_CREATE | VM_PROT_READ | VM_PROT_WRITE,
                                              &entry, mach_port_t(MACH_PORT_NULL))
        guard kr == KERN_SUCCESS, size >= span else {
            _ = unsafe munmap(range, Int(aliasDistance) + bytes)
            throw .reservationFailed("mach_make_memory_entry_64: \(kr)")
        }
        for at in [addr, addr + vm_address_t(aliasDistance)] {
            var a = at
            kr = unsafe vm_map(task, &a, span, 0, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE, entry, 0, 0,
                               VM_PROT_READ | VM_PROT_WRITE, VM_PROT_READ | VM_PROT_WRITE, VM_INHERIT_NONE)
            guard kr == KERN_SUCCESS, a == at else {
                _ = unsafe munmap(range, Int(aliasDistance) + bytes)
                _ = mach_port_deallocate(task, entry)
                throw .reservationFailed("vm_map: \(kr)")
            }
        }
        guard let p = unsafe UnsafeMutableRawPointer(bitPattern: UInt(addr)) else {
            // Not reachable (`mmap` answered the range), but a failure
            // releases what it holds (collectors review, finding 6).
            _ = unsafe munmap(range, Int(aliasDistance) + bytes)
            _ = mach_port_deallocate(task, entry)
            throw .reservationFailed("vm_allocate returned 0")
        }
        unsafe probe?.reserved(p, bytes)
        return (unsafe p, entry)
    }

    static func releaseTwice(_ p: UnsafeMutableRawPointer, _ bytes: Int, _ entry: mach_port_t, probe: ReservationProbe? = nil) {
        _ = unsafe munmap(p, Int(aliasDistance) + bytes)
        _ = mach_port_deallocate(task, entry)
        unsafe probe?.released(p)
    }
}
