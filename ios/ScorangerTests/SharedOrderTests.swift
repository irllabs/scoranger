import XCTest

/// The running order two people can edit at once (`SharedOrder`).
///
/// design/FIREBASE.md §6.5. The property that matters is one line: the key
/// returned is strictly between its neighbours, by string comparison, always.
/// Everything else here is that property under the conditions that break naive
/// implementations -- repeated insertion in the same gap, insertion at either
/// end, and the case where two keys are adjacent characters with no room
/// between them.
final class SharedOrderTests: XCTestCase {

    /// The invariant, asserted directly.
    private func assertBetween(_ key: String, _ before: String?, _ after: String?,
                               _ message: String = "", line: UInt = #line) {
        if let before { XCTAssertGreaterThan(key, before, "\(message) not after \(before)", line: line) }
        if let after { XCTAssertLessThan(key, after, "\(message) not before \(after)", line: line) }
    }

    func testAnEmptyListGetsAKeyInTheMiddleOfTheAlphabet() {
        let only = SharedOrder.between(nil, nil)
        XCTAssertFalse(only.isEmpty)
        // Not the first character: a key at the bottom leaves no room to insert
        // before it without lengthening, and the first thing anyone does to a
        // setlist is put something at the top.
        XCTAssertGreaterThan(only, String(SharedOrder.alphabet.first!))
        XCTAssertLessThan(only, String(SharedOrder.alphabet.last!))
    }

    func testAppendingKeepsGoingUp() {
        var keys: [String] = []
        var previous: String? = nil
        for i in 0..<200 {
            let key = SharedOrder.between(previous, nil)
            assertBetween(key, previous, nil, "append \(i)")
            keys.append(key)
            previous = key
        }
        XCTAssertEqual(keys, keys.sorted(), "appending did not produce an ascending list")
        XCTAssertEqual(Set(keys).count, keys.count, "appending produced a duplicate")
    }

    func testPrependingKeepsGoingDown() {
        var keys: [String] = []
        var next: String? = nil
        for i in 0..<200 {
            let key = SharedOrder.between(nil, next)
            assertBetween(key, nil, next, "prepend \(i)")
            keys.append(key)
            next = key
        }
        XCTAssertEqual(keys, keys.sorted().reversed(), "prepending did not descend")
        XCTAssertEqual(Set(keys).count, keys.count, "prepending produced a duplicate")
    }

    /// The one that kills a double-based implementation: insert repeatedly into
    /// the SAME gap. A double runs out of mantissa after about fifty of these
    /// and the order stops being editable; a string just gets longer.
    func testInsertingRepeatedlyIntoTheSameGapNeverRunsOut() {
        let low = SharedOrder.between(nil, nil)
        let high = SharedOrder.between(low, nil)
        var upper = high
        for i in 0..<500 {
            let key = SharedOrder.between(low, upper)
            assertBetween(key, low, upper, "squeeze \(i)")
            upper = key
        }
        XCTAssertLessThan(upper.count, 400,
                          "the key grew a character per insertion; the encoding "
                          + "is not halving the gap")
    }

    /// Adjacent characters with nothing between them -- "a" and "b" -- still
    /// admit a key, by going deeper rather than by giving up.
    func testAdjacentKeysStillAdmitOneBetweenThem() {
        assertBetween(SharedOrder.between("a", "b"), "a", "b")
        assertBetween(SharedOrder.between("0", "1"), "0", "1")
        assertBetween(SharedOrder.between("y", "z"), "y", "z")
        // and where one is a prefix of the other
        assertBetween(SharedOrder.between("a", "aa"), "a", "aa")
        assertBetween(SharedOrder.between("a", "ab"), "a", "ab")
    }

    /// A setlist that arrives whole gets keys with room between them, so the
    /// first reorder does not immediately have to lengthen one.
    func testAWholeSetlistIsSpreadInOrder() {
        let keys = SharedOrder.spread(count: 12)
        XCTAssertEqual(keys.count, 12)
        XCTAssertEqual(keys, keys.sorted(), "spread was not ascending")
        XCTAssertEqual(Set(keys).count, 12, "spread produced a duplicate")
        for (a, b) in zip(keys, keys.dropFirst()) {
            assertBetween(SharedOrder.between(a, b), a, b, "gap between \(a) and \(b)")
        }
        XCTAssertEqual(SharedOrder.spread(count: 0), [])
    }

    /// TWO PEOPLE, DIFFERENT ENTRIES: both moves survive. This is the whole
    /// reason for the design -- with an array on the parent document, one of
    /// these two writes would silently discard the other.
    func testTwoEditorsMovingDifferentEntriesBothSurvive() {
        // A B C D E, and each entry owns its key
        var order = Dictionary(uniqueKeysWithValues:
            zip(["A", "B", "C", "D", "E"], SharedOrder.spread(count: 5)))
        func sorted() -> [String] { order.sorted { $0.value < $1.value }.map(\.key) }
        XCTAssertEqual(sorted(), ["A", "B", "C", "D", "E"])

        // Aisha moves E to the front; Ben moves A to the end. Neither reads the
        // other's write, which is what concurrent means.
        let eKey = SharedOrder.between(nil, order["A"]!)
        let aKey = SharedOrder.between(order["E"]!, nil)
        order["E"] = eKey       // both land, in either arrival order
        order["A"] = aKey

        XCTAssertEqual(sorted(), ["E", "B", "C", "D", "A"],
                       "one editor's move was lost")
    }

    /// TWO PEOPLE, THE SAME ENTRY: last writer wins, and there is no third
    /// state. Correct and unsurprising (§6.5).
    func testTwoEditorsMovingTheSameEntryEndWithOneOfTheTwoPlacements() {
        var order = Dictionary(uniqueKeysWithValues:
            zip(["A", "B", "C"], SharedOrder.spread(count: 3)))
        let toFront = SharedOrder.between(nil, order["A"]!)
        let toBack = SharedOrder.between(order["C"]!, nil)

        order["B"] = toFront
        order["B"] = toBack     // the later write
        let sorted = order.sorted { $0.value < $1.value }.map(\.key)
        XCTAssertEqual(sorted, ["A", "C", "B"])
        XCTAssertTrue(order["B"] == toBack, "the later placement did not win")
    }

    /// Every key is comparable as a plain string on any device: digits and
    /// lower case only, so no collation or locale can reorder them.
    func testKeysUseOnlyAsciiOrderedCharacters() {
        let produced = SharedOrder.spread(count: 40)
            + (0..<40).map { _ in SharedOrder.between("a", "b") }
        for key in produced {
            XCTAssertTrue(key.allSatisfy { SharedOrder.alphabet.contains($0) },
                          "\(key) has a character outside the alphabet")
        }
    }

    // MARK: - moving a row one place

    /// The bug this rule exists for, written as a test.
    ///
    /// Reading "the entry below" from the list as it stands is wrong for a
    /// downward move: the row being moved still occupies the slot it is
    /// leaving, so the entry below it is the one being displaced, and a key
    /// between that entry and the one after it is a key the row already sorts
    /// before. The move becomes a write that changes nothing, and the row
    /// visibly springs back.
    func testMovingARowDownActuallyMovesIt() {
        var keys = SharedOrder.spread(count: 4)          // A B C D
        let moved = 1                                     // B
        let landing = SharedOrder.neighbours(moving: keys[moved], by: 1, in: keys)!
        keys[moved] = SharedOrder.between(landing.before, landing.after)
        // B now sorts third: A C B D.
        XCTAssertEqual(order(of: keys), [0, 2, 1, 3])
    }

    func testMovingARowUpActuallyMovesIt() {
        var keys = SharedOrder.spread(count: 4)
        let moved = 2                                     // C
        let landing = SharedOrder.neighbours(moving: keys[moved], by: -1, in: keys)!
        keys[moved] = SharedOrder.between(landing.before, landing.after)
        XCTAssertEqual(order(of: keys), [0, 2, 1, 3])
    }

    func testMovingTheFirstRowDownAndTheLastRowUpBothLand() {
        var keys = SharedOrder.spread(count: 3)
        let down = SharedOrder.neighbours(moving: keys[0], by: 1, in: keys)!
        keys[0] = SharedOrder.between(down.before, down.after)
        XCTAssertEqual(order(of: keys), [1, 0, 2])

        keys = SharedOrder.spread(count: 3)
        let up = SharedOrder.neighbours(moving: keys[2], by: -1, in: keys)!
        keys[2] = SharedOrder.between(up.before, up.after)
        XCTAssertEqual(order(of: keys), [0, 2, 1])
    }

    // MARK: - moving a row by dragging it

    /// A drag moves a row any number of places with the same one-key write.
    /// `RowReorder` says where it landed; the offset is landing minus start.
    func testDraggingTheFirstRowToTheEndLandsItLast() {
        var keys = SharedOrder.spread(count: 4)          // A B C D
        let landing = SharedOrder.neighbours(moving: keys[0], by: 3, in: keys)!
        keys[0] = SharedOrder.between(landing.before, landing.after)
        XCTAssertEqual(order(of: keys), [1, 2, 3, 0])     // B C D A
    }

    func testDraggingTheLastRowToTheTopLandsItFirst() {
        var keys = SharedOrder.spread(count: 4)
        let landing = SharedOrder.neighbours(moving: keys[3], by: -3, in: keys)!
        keys[3] = SharedOrder.between(landing.before, landing.after)
        XCTAssertEqual(order(of: keys), [3, 0, 1, 2])     // D A B C
    }

    func testDraggingAMiddleRowTwoPlacesDown() {
        var keys = SharedOrder.spread(count: 5)          // A B C D E
        let landing = SharedOrder.neighbours(moving: keys[1], by: 2, in: keys)!
        keys[1] = SharedOrder.between(landing.before, landing.after)
        XCTAssertEqual(order(of: keys), [0, 2, 3, 1, 4])  // A C D B E
    }

    /// Every drag of every row to every other slot puts it in that slot, and
    /// the list it leaves behind is the list `RowReorder` drew.
    func testEveryDragLandsWhereTheListDrewIt() {
        let keys = SharedOrder.spread(count: 6)
        for from in keys.indices {
            for to in keys.indices where to != from {
                var moved = keys
                let landing = SharedOrder.neighbours(moving: keys[from], by: to - from, in: keys)!
                moved[from] = SharedOrder.between(landing.before, landing.after)
                XCTAssertEqual(order(of: moved),
                               RowReorder.moving(Array(keys.indices), from: from, to: to),
                               "dragging \(from) to \(to)")
            }
        }
    }

    /// Off the end is nil, not a clamp: the caller writes nothing at all,
    /// rather than sending a write that reorders nothing.
    func testAMoveOffEitherEndIsRefusedRatherThanClamped() {
        let keys = SharedOrder.spread(count: 3)
        XCTAssertNil(SharedOrder.neighbours(moving: keys[0], by: -1, in: keys))
        XCTAssertNil(SharedOrder.neighbours(moving: keys[2], by: 1, in: keys))
        XCTAssertNil(SharedOrder.neighbours(moving: "not-in-the-list", by: 1, in: keys))
        XCTAssertNil(SharedOrder.neighbours(moving: "a", by: 1, in: ["a"]))
    }

    /// The trap the signature was changed to remove.
    ///
    /// This took an INDEX into a list it assumed was sorted. Hand it a list
    /// that is not, and it read the wrong neighbours and returned a lower bound
    /// GREATER than its upper bound -- `between("x", "w")` answered `"xi"`,
    /// which is above both. The fuzz test below found it in six moves; nothing
    /// in the type said the list had to be sorted, and nothing complained.
    ///
    /// It sorts the list itself now, so an out-of-order list is not a
    /// different answer, it is the same answer.
    func testAnUnsortedListIsSortedRatherThanBelieved() {
        let ordered = SharedOrder.spread(count: 4)
        let jumbled = [ordered[2], ordered[0], ordered[3], ordered[1]]
        for key in ordered {
            for by in [-1, 1] {
                XCTAssertEqual(SharedOrder.neighbours(moving: key, by: by, in: jumbled).map { "\($0.before ?? "-")/\($0.after ?? "-")" },
                               SharedOrder.neighbours(moving: key, by: by, in: ordered).map { "\($0.before ?? "-")/\($0.after ?? "-")" },
                               "the order the keys arrive in must not change the answer")
            }
        }
    }

    /// Two hundred one-place moves, and the keys stay strictly ordered and
    /// distinct throughout.
    ///
    /// SEEDED, not random. The first version of this used
    /// `SystemRandomNumberGenerator` and failed on the gate with a sequence
    /// nobody could reproduce -- a fuzz test whose failures cannot be replayed
    /// reports a bug and withholds the evidence. Five fixed seeds cover the
    /// same ground and a failure is a value that can be typed back in.
    func testTwoHundredMovesKeepTheKeysOrderedAndDistinct() {
        for seed in UInt64(1)...5 {
            var generator = Seeded(seed)
            var keys = SharedOrder.spread(count: 8)
            for step in 0..<200 {
                let moving = keys[Int.random(in: 0..<keys.count, using: &generator)]
                let by = Bool.random(using: &generator) ? 1 : -1
                guard let landing = SharedOrder.neighbours(moving: moving, by: by,
                                                           in: keys) else { continue }
                let key = SharedOrder.between(landing.before, landing.after)
                let where_ = "seed \(seed) step \(step): between(\(landing.before ?? "nil"), \(landing.after ?? "nil")) = \(key)"
                if let before = landing.before { XCTAssertTrue(key > before, where_) }
                if let after = landing.after { XCTAssertTrue(key < after, where_) }
                keys[keys.firstIndex(of: moving)!] = key
                XCTAssertEqual(Set(keys).count, keys.count,
                               "two entries share a key -- \(where_)")
            }
        }
    }

    /// Sorted positions of the keys, so a test can say "B is third now"
    /// without caring what the keys are.
    private func order(of keys: [String]) -> [Int] {
        keys.enumerated().sorted { $0.element < $1.element }.map(\.offset)
    }
}

/// A generator whose sequence can be typed back in.
///
/// xorshift64, seeded. It exists because a fuzz test that cannot replay its
/// own failure is a bug report with the evidence withheld.
private struct Seeded: RandomNumberGenerator {
    private var state: UInt64
    init(_ seed: UInt64) {
        state = seed &* 6364136223846793005 &+ 1442695040888963407
    }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
