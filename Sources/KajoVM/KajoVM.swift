/// Kajo virtual machine core.
///
/// Built module by module (docs/PLAN.md). Present: the object memory
/// (`ObjectMemory/`, docs/modules/object-memory.md): oops as entry-table
/// offsets (ADR 0003), the block heap, allocation contexts, the
/// stop-the-world collector and compactor, become, reshape, snapshots and
/// the verifiers. Everything is internal; the VM's public surface arrives
/// with the interpreter and the shells.
public enum KajoVM {
    public static let version = "0.1.0"
}
