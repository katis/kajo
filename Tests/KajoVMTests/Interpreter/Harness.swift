@testable import KajoVM

/// An image with kasm loaded, an interpreter and one stack. Destroyed by
/// the caller.
struct Harness {
    let image: Image
    let interpreter: Interpreter
    let stack: Stack

    /// `before` runs between boot and load (garbage below the methods).
    init(_ src: String, base: [String] = ["prelude", "lib"], heapBlocks: Int = 512, entries: Int = 1 << 18,
         stress: StressFlags = [], verify: Bool = true, stackWords: Int = 1 << 16,
         before: (Image) -> Void = { _ in }) throws {
        image = try makeImage(heapBlocks: heapBlocks, entries: entries, stress: stress, verify: verify)
        before(image)
        try image.load(base.map { (file: "\($0).kasm", text: kernel($0)) } + [(file: "test.kasm", text: src)])
        interpreter = Interpreter(image: image)
        stack = Stack(words: stackWords)
    }

    /// Send `selector` to nil with SmallInteger arguments.
    func run(_ selector: String = "run:of:", _ args: [Int64] = [0, 1]) -> Result<Oop, VMError> {
        interpreter.run(on: stack, receiver: image.nilObject, selector: selector, arguments: args.map { Oop(smallInteger: $0) })
    }

    /// The SmallInteger a successful run answers.
    func value(_ selector: String = "run:of:", _ args: [Int64] = [0, 1]) throws -> Int64 {
        let v = try run(selector, args).get()
        guard v.isSmallInteger else { throw HarnessError.notAnInteger(v) }
        return v.smallIntegerValue
    }

    func error(_ selector: String = "run:of:", _ args: [Int64] = [0, 1]) -> VMError? {
        if case .failure(let e) = run(selector, args) { return e }
        return nil
    }

    var om: ObjectMemory { image.om }

    func destroy() {
        stack.destroy()
        interpreter.destroy()
        image.destroy()
    }
}

enum HarnessError: Error { case notAnInteger(Oop) }

/// `method UndefinedObject run:of: temps=<temps>` with `body`.
func runOf(_ body: String, temps: Int = 0) -> String {
    "\nmethod UndefinedObject run:of: temps=\(temps)\n\(body)\nend\n"
}
