// Module 8e: the rules a class definition keeps, written once for the image
// build (`Image.defineKernelClasses`, and `Plan` in KajoCompiler for the
// names) and for the define-class and redefine primitives (145, 146,
// `ObjectModel/LiveClasses.swift`): the primitive re-checks what the build
// checks, with the same code and the same messages.

package enum ClassRules {
    /// The sizes against the superclass's: at least its named slots on the
    /// instance side and its class-side instance variables on the class side.
    static func sizeProblem(name: String, superName: String, superNamedSlots: Int, superMetaSlots: Int, namedSlots: Int,
                            metaSlots: Int) -> String? {
        if superNamedSlots > namedSlots { return "\(name) has fewer instance variables than \(superName)" }
        if superMetaSlots > ClassLayout.size + metaSlots { return "\(name) has fewer class-side instance variables than \(superName)" }
        return nil
    }

    /// No subclass of a sealed class (the well-known ones are re-parented by
    /// the build, never made), no pointers under bytes.
    static func subclassProblem(name: String, superName: String, superFormat sf: ClassFormat, format: ClassFormat) -> String? {
        if sf.isSealed { return "\(name) cannot subclass the sealed \(superName)" }
        if !sf.kind.isPointers && format.kind.isPointers { return "\(name) cannot be pointers under \(superName)" }
        return nil
    }

    /// A class name: an identifier beginning with a capital (ASCII), not the
    /// prefix of a removed class.
    package static func classNameProblem(_ name: String) -> String? {
        guard isIdentifier(name), let f = name.unicodeScalars.first, f.properties.isUppercase else {
            return "'\(name)' is not a class name (an identifier beginning with a capital)"
        }
        if name.hasPrefix(obsoletePrefix) { return "'\(name)' is the name of a removed class" }
        return nil
    }

    /// A removed class keeps its class object, renamed (module 8e).
    package static let obsoletePrefix = "AnObsolete"

    /// The names of a class: every instance variable and class-side instance
    /// variable name (inherited first) an identifier and unique, its class
    /// variables capitalized, declared once along the chain (`inherited`:
    /// each class variable its superclasses declare, by name, with the
    /// declaring class) and shadowing no instance variable of either side;
    /// and none of its own instance variables shadowing a class variable it
    /// sees. The image build's messages (`Plan`), which
    /// `theBuildRefusesBadClassVariables` checks.
    package static func namesProblem(className c: String, instanceVariables all: [String], classInstanceVariables allMeta: [String],
                                     ownInstanceVariables: [String], ownClassInstanceVariables: [String], classVariables: [String],
                                     inherited: [String: String]) -> String? {
        for n in all + allMeta + classVariables where !isIdentifier(n) { return "\(c): bad name '\(n)'" }
        if Set(all).count != all.count { return "\(c): an instance variable name twice" }
        if Set(allMeta).count != allMeta.count { return "\(c): a class-side instance variable name twice" }
        var visible = inherited
        for v in classVariables {
            func refuse(_ why: String) -> String { "\(c): class variable \(v) \(why)" }
            guard let first = v.unicodeScalars.first, first.properties.isUppercase else { return refuse("must begin with a capital") }
            if let owner = visible[v] { return refuse(owner == c ? "declared twice" : "shadows \(owner)'s class variable") }
            if all.contains(v) { return refuse("shadows an instance variable") }
            if allMeta.contains(v) { return refuse("shadows a class-side instance variable") }
            visible[v] = c
        }
        for v in ownInstanceVariables + ownClassInstanceVariables where visible[v] != nil {
            return "\(c): instance variable \(v) shadows \(visible[v]!)'s class variable"
        }
        return nil
    }
}
