import Darwin

/// Address-space reservations for the object memory. Pages are zero-filled
/// on first touch. Only the `vm_map.h` family is used: `mach_vm.h` is
/// unsupported in the iOS SDK (AGENTS.md).
enum VirtualMemory {
    /// Distance between the heap and its alias (ADR 0007): an entry state word
    /// holding `offset + aliasDistance` (RELOCATING, module 6) still leads
    /// to the intact body.
    static let aliasDistance: UInt64 = 1 << 32

    static func reserve(_ bytes: Int) throws(ObjectMemoryError) -> UnsafeMutableRawPointer {
        var addr: vm_address_t = 0
        let kr = unsafe vm_allocate(mach_task_self_, &addr, vm_size_t(bytes), VM_FLAGS_ANYWHERE)
        guard kr == KERN_SUCCESS, let p = unsafe UnsafeMutableRawPointer(bitPattern: UInt(addr)) else {
            throw .reservationFailed("vm_allocate \(bytes) bytes: \(kr)")
        }
        return unsafe p
    }

    static func release(_ p: UnsafeMutableRawPointer, _ bytes: Int) {
        _ = unsafe vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: p)), vm_size_t(bytes))
    }

    /// Reserve `aliasDistance + bytes` and map one memory object of `bytes`
    /// at the start and again at `+ aliasDistance`.
    ///
    /// ThreadSanitizer cannot see that the two mappings alias: an access
    /// through the alias and one through the base are different addresses
    /// to it. Any protocol that uses the alias (module 6's RELOCATING state)
    /// is covered by tests and its ordering argument only (AGENTS.md).
    static func reserveTwice(_ bytes: Int) throws(ObjectMemoryError) -> (UnsafeMutableRawPointer, mach_port_t) {
        precondition(bytes > 0 && UInt64(bytes) <= aliasDistance)
        let task = unsafe mach_task_self_
        let span = vm_size_t(bytes)
        var addr: vm_address_t = 0
        var kr = unsafe vm_allocate(task, &addr, vm_size_t(aliasDistance) + span, VM_FLAGS_ANYWHERE)
        guard kr == KERN_SUCCESS else { throw .reservationFailed("vm_allocate alias range: \(kr)") }
        var size = memory_object_size_t(span)
        var entry: mach_port_t = 0
        kr = unsafe mach_make_memory_entry_64(task, &size, 0, MAP_MEM_NAMED_CREATE | VM_PROT_READ | VM_PROT_WRITE,
                                              &entry, mach_port_t(MACH_PORT_NULL))
        guard kr == KERN_SUCCESS, size >= span else {
            _ = vm_deallocate(task, addr, vm_size_t(aliasDistance) + span)
            throw .reservationFailed("mach_make_memory_entry_64: \(kr)")
        }
        for at in [addr, addr + vm_address_t(aliasDistance)] {
            var a = at
            kr = unsafe vm_map(task, &a, span, 0, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE, entry, 0, 0,
                               VM_PROT_READ | VM_PROT_WRITE, VM_PROT_READ | VM_PROT_WRITE, VM_INHERIT_NONE)
            guard kr == KERN_SUCCESS, a == at else {
                _ = vm_deallocate(task, addr, vm_size_t(aliasDistance) + span)
                _ = mach_port_deallocate(task, entry)
                throw .reservationFailed("vm_map: \(kr)")
            }
        }
        guard let p = unsafe UnsafeMutableRawPointer(bitPattern: UInt(addr)) else {
            throw .reservationFailed("vm_allocate returned 0")
        }
        return (unsafe p, entry)
    }

    static func releaseTwice(_ p: UnsafeMutableRawPointer, _ bytes: Int, _ entry: mach_port_t) {
        _ = unsafe vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: p)),
                                 vm_size_t(aliasDistance) + vm_size_t(bytes))
        _ = unsafe mach_port_deallocate(mach_task_self_, entry)
    }
}
