// Module 8b: running a method of an image to completion during the image
// build (the kernel's class initialization), before the image is saved.

extension Image {
    /// `ClassName selector` (class side) in a Process on a one-worker VM
    /// with no nursery and stop-the-world collection, to completion. nil
    /// when it answered; else what went wrong. The VM is gone afterwards, so
    /// the image can be saved (it holds no Process: the terminated one is
    /// released and unreachable).
    package func runToCompletion(className: String, selector: String) -> String? {
        guard let ci = classIndex(named: className) else { return "no class \(className)" }
        var vc = VMConfig()
        vc.backgroundWorkers = 1
        vc.nursery.bytes = 0
        vc.marking.enabled = false
        vc.relocation.enabled = false
        vc.young.mode = .stw
        let vm = VM(image: self, config: vc)
        vm.start()
        guard let p = vm.spawn(receiver: om.classOop(ci), selector: selector) else {
            vm.shutdown()
            vm.destroy()
            return "\(className) class does not understand \(selector)"
        }
        vm.waitUntilAllTerminated()
        let problem = vm.error(of: p).map { "\($0)" }
        vm.release(p)
        vm.shutdown()
        vm.destroy()
        return problem
    }
}
