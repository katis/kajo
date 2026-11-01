/// Kajo virtual machine core.
///
/// Nothing is decided yet beyond the implementation language (see
/// docs/adr/0001-swift-for-the-vm-core.md). The object representation, GC
/// strategy and scheduler are open decisions; each should land as its own
/// module that hides the decision, with an ADR.
public enum KajoVM {
    public static let version = "0.0.0"
}
