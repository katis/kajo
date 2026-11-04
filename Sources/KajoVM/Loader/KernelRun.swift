// Module 8b: running a method of an image to completion during the image
// build (the kernel's class initialization), before the image is saved.

extension Image {
    /// `ClassName selector` (class side; with `strings`, `ClassName selector:
    /// anArrayOfStrings`) in a Process on a one-worker VM
    /// with no nursery and stop-the-world collection, to completion. nil
    /// when it answered; else what went wrong: a VM error, or (module 8d)
    /// no answer, which is how the kernel's unhandled errors end a Process
    /// (UnhandledError writes the error and its frames on the Transcript and
    /// terminates it): before 8d a build whose `recordSources:` failed
    /// half way went on as if it had worked. The VM is gone afterwards, so
    /// the image can be saved (it holds no Process: the terminated one is
    /// released and unreachable).
    package func runToCompletion(className: String, selector: String, strings: [String]? = nil) -> String? {
        guard let ci = classIndex(named: className) else { return "no class \(className)" }
        var vc = VMConfig()
        vc.backgroundWorkers = 1
        vc.nursery.bytes = 0
        vc.marking.enabled = false
        vc.relocation.enabled = false
        vc.young.mode = .stw
        let vm = VM(image: self, config: vc)
        vm.start()
        let args = strings.map { [vm.newStringArray($0)] } ?? []
        guard let p = vm.spawn(receiver: om.classOop(ci), selector: selector, arguments: args) else {
            vm.shutdown()
            vm.destroy()
            return "\(className) class does not understand \(selector)"
        }
        vm.waitUntilAllTerminated()
        var problem = vm.error(of: p).map { "\($0)" }
        if problem == nil && vm.result(of: p) == nilObject {
            problem = "ended without an answer (an unhandled error: the Transcript shows it)"
        }
        vm.release(p)
        vm.shutdown()
        vm.destroy()
        return problem
    }
}
