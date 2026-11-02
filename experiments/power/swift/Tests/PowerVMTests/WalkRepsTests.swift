// walkNxR on the object table (VMB): R traversals sum R/2 times what walkN's
// two do, so the kernel only lengthens the traversal.

import Darwin
import Kasm
import Testing
import VMB

private func checksum(_ line: String) -> Int64? {
    for f in line.split(separator: " ") where f.hasPrefix("checksum=") { return Int64(f.dropFirst(9)) }
    return nil
}

// Part of FrameTests' serialized suite: kernelFlavor is a global.
extension FrameTests {
    @Test func repsScaleTheChecksum() throws {
        kernelFlavor = .objectRepresentation
        defer { kernelFlavor = .concurrentYoung }
        let dir = NSTemporaryDirectoryShim()
        let two = try checksum(VMB.benchLine(kernel: "walk12", workers: 1, snapshotDir: dir))
        let six = try checksum(VMB.benchLine(kernel: "walk12x6", workers: 1, snapshotDir: dir))
        #expect(two != nil && six != nil)
        #expect(six! == 3 * two!)
    }
}

private func NSTemporaryDirectoryShim() -> String {
    String(cString: getenv("TMPDIR") ?? strdup("/tmp"))
}
