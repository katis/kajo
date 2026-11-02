import Testing
import KajoVM

/// `kajo run`'s entry point: load, send run: 0 of: 1 to nil, report.
@Test func headlessRunReportsTheChecksumAndCounters() throws {
    var options = Headless.Options()
    options.heapMiB = 16
    options.entries = 1 << 16
    let src = "method UndefinedObject run:of: temps=0\n push_int 20\n send fibx 0\n push_temp 1\n add\n return_top\nend\n"
    let out = Headless.run([("prelude.kasm", kernel("prelude")), ("lib.kasm", kernel("lib")), ("t.kasm", src)], options: options)
    #expect(try out.checksum.get() == 6766)
    #expect(out.counters.first { $0.name == "sends" }?.value == 21891)
}

@Test func headlessRunReportsFailures() {
    var options = Headless.Options()
    options.heapMiB = 16
    options.entries = 1 << 16
    let bad = Headless.run([("t.kasm", "method Nope run:of: temps=0\n return_self\nend\n")], options: options)
    guard case .failure(.load(let msg)) = bad.checksum else { Issue.record("not a load error"); return }
    #expect(msg.contains("t.kasm:1"))
    let dnu = Headless.run([("t.kasm", "method UndefinedObject run:of: temps=0\n push_nil\n send foo 0\n return_top\nend\n")],
                           options: options)
    guard case .failure(.vm(let e)) = dnu.checksum else { Issue.record("not a VM error"); return }
    #expect(e.kind == .doesNotUnderstand && e.selector == "foo")
    options.workers = 2
    let workers = Headless.run([("t.kasm", "")], options: options)
    guard case .failure(.unsupported) = workers.checksum else { Issue.record("two workers accepted"); return }
}
