# experiments

Throwaway spikes that answer a design question before it is locked in. One
directory per experiment with its own design brief and results. They stay in
the tree so ADRs can point at the evidence, and may be deleted once nothing
references them.

| Directory | Question | Outcome |
|---|---|---|
| `vm-language-bench/` | Rust or Swift for the VM core? | Swift. See `docs/adr/0001-swift-for-the-vm-core.md` |
| `object-representation/` | Direct pointers with forwarders, an object table, or heap offsets? | Object table, proposed. See `docs/adr/0003-object-representation.md` |
