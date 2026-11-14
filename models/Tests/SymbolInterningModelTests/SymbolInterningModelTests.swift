// The model checks of docs/models/symbol-interning.md: every claim holds in
// every interleaving of the three configurations, under the store-buffer
// model and under sequential consistency, and each rule turned off lets
// the explorer find the claim it protects broken (the shortest trace is
// printed).

import Testing
@testable import SymbolInterningModel

func check(_ name: String, _ c: Configuration) -> Report {
    let r = explore(c)
    print("\(name): \(r)")
    return r
}

@Suite struct TheSymbolInterningClaimsHold {
    @Test(arguments: ["sameBytes", "bucketMates", "growth"])
    func inEveryConfiguration(_ name: String) {
        let c: Configuration = name == "sameBytes" ? .sameBytes : name == "bucketMates" ? .bucketMates : .growth
        let r = check(name, c)
        #expect(r.violations.isEmpty && r.finishedRuns > 0, "\(name)")
        var sc = c
        sc.sequentiallyConsistent = true
        let r2 = check(name + " (sequentially consistent)", sc)
        #expect(r2.violations.isEmpty && r2.finishedRuns > 0, "\(name) sc")
    }
}

@Suite struct EachSymbolInterningRuleIsNeeded {
    /// Without the second lookup under the lock, two interners of the same
    /// bytes that both missed insert two Symbols.
    @Test func theSecondLookup() {
        var c = Configuration.sameBytes
        c.secondLookup = false
        c.drops = []
        #expect(check("no second lookup", c).violations[.oneSymbolPerBytes] != nil)
    }

    /// Publishing the Symbol before its bytes are filled lets the lock-free
    /// reader read a Symbol that is not whole.
    @Test func fillBeforePublish() {
        var c = Configuration.sameBytes
        c.fillBeforePublish = false
        #expect(check("publish before fill", c).violations[.wholeReads] != nil)
    }

    /// A relaxed publishing store may drain before the fill's (or the new
    /// bucket's) stores: a reader sees the Symbol or the bucket before it is
    /// whole. Under sequential consistency the same rule off finds nothing,
    /// which shows the violation is the store order.
    @Test func releasePublishingStores() {
        var c = Configuration.sameBytes
        c.releasePublish = false
        #expect(check("relaxed publish", c).violations[.wholeReads] != nil)
        var g = Configuration.bucketMates
        g.releasePublish = false
        #expect(check("relaxed publish, growth", g).violations[.wholeReads] != nil)
        c.sequentiallyConsistent = true
        #expect(check("relaxed publish, sequentially consistent", c).violations.isEmpty)
    }

    /// The suspected hole of the brief: the second lookup hands on a Symbol
    /// another interner made and dropped after a snapshot with no keep-alive
    /// barrier; stored into a scanned holder, it is swept under it.
    @Test func keepAliveOnTheSecondLookup() {
        var c = Configuration.sameBytes
        c.keepAliveSecondLookup = false
        #expect(check("no keep-alive on the second lookup", c).violations[.noLostSymbol] != nil)
    }

    /// The lock-free hit needs it too (the collectors review's rule, kept).
    @Test func keepAliveOnTheFirstLookup() {
        var c = Configuration.sameBytes
        c.keepAliveFirstLookup = false
        #expect(check("no keep-alive on the first lookup", c).violations[.noLostSymbol] != nil)
    }

    /// The growth copies a weakly held Symbol into a bucket born after the
    /// snapshot, whose slots the final mark never nils: without the barrier
    /// the table names a swept Symbol.
    @Test func keepAliveOnTheGrowthCopy() {
        var c = Configuration.growth
        c.keepAliveGrowthCopy = false
        #expect(check("no keep-alive on the growth copy", c).violations[.noLostSymbol] != nil)
    }
}
