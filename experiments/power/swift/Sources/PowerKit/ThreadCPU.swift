// Per-thread CPU time for every thread of the task (SPEC.md "Telemetry"):
// task_threads and thread_info(THREAD_EXTENDED_INFO) give user and system
// time in ns, the pthread name and the current priority;
// THREAD_IDENTIFIER_INFO gives the 64-bit thread id, which the kernel
// hands out in increasing order. VM threads are classified by the ids that
// appear while a Runtime starts them (`newThreads`), so no VM source had to
// change to name them.

import Darwin

public struct ThreadSample: Sendable, Equatable {
    public var tid: UInt64
    public var cpuNs: UInt64
    public var name: String
    public var curPri: Int32
}

public enum ThreadCPU {
    /// Every thread of this task, by thread id.
    public static func snapshot() -> [UInt64: ThreadSample] {
        var list: thread_act_array_t? = nil
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return [:] }
        var out: [UInt64: ThreadSample] = [:]
        for i in 0..<Int(count) {
            let th = list[i]
            var idInfo = thread_identifier_info_data_t()
            var n = mach_msg_type_number_t(MemoryLayout<thread_identifier_info_data_t>.size / MemoryLayout<natural_t>.size)
            let kr1 = withUnsafeMutablePointer(to: &idInfo) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) {
                    thread_info(th, thread_flavor_t(THREAD_IDENTIFIER_INFO), $0, &n)
                }
            }
            var ext = thread_extended_info_data_t()
            var m = mach_msg_type_number_t(MemoryLayout<thread_extended_info_data_t>.size / MemoryLayout<natural_t>.size)
            let kr2 = withUnsafeMutablePointer(to: &ext) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(m)) {
                    thread_info(th, thread_flavor_t(THREAD_EXTENDED_INFO), $0, &m)
                }
            }
            if kr1 == KERN_SUCCESS && kr2 == KERN_SUCCESS {
                let name = withUnsafeBytes(of: ext.pth_name) { raw -> String in
                    let bytes = raw.prefix { $0 != 0 }
                    return String(decoding: bytes, as: UTF8.self)
                }
                out[idInfo.thread_id] = ThreadSample(tid: idInfo.thread_id, cpuNs: ext.pth_user_time &+ ext.pth_system_time,
                                                     name: name, curPri: ext.pth_curpri)
            }
            mach_port_deallocate(mach_task_self_, th)
        }
        let size = vm_size_t(Int(count) * MemoryLayout<thread_t>.stride)
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)), size)
        return out
    }

    /// Thread ids present in `after` but not in `before`, ascending (creation order).
    public static func newThreads(_ before: [UInt64: ThreadSample], _ after: [UInt64: ThreadSample]) -> [UInt64] {
        after.keys.filter { before[$0] == nil }.sorted()
    }

    /// The calling thread's id.
    public static func selfId() -> UInt64 {
        var t: UInt64 = 0
        pthread_threadid_np(nil, &t)
        return t
    }

    /// CPU ns of `tids` between two snapshots (a thread missing from `b`
    /// exited; its last known time in `a` counts as zero growth).
    public static func cpuDelta(_ a: [UInt64: ThreadSample], _ b: [UInt64: ThreadSample], _ tids: [UInt64]) -> UInt64 {
        var s: UInt64 = 0
        for t in tids {
            guard let y = b[t] else { continue }
            s &+= y.cpuNs &- (a[t]?.cpuNs ?? 0)
        }
        return s
    }
}
