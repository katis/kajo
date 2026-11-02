extension ObjectMemory {
    func compact(extraRoots: [Oop] = []) { collect(extraRoots: extraRoots) }
}
