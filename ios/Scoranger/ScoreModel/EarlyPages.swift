import Foundation

/// A score's first page laid out from the bars it needs, ahead of the rest.
///
/// Verovio lays out the whole document before it will draw any page of it,
/// and the reader opening a score looks at page 1. Laying out only the first
/// few pages' worth of bars gives the same page 1 sooner, PROVIDED nothing on
/// that page depends on what was left out. Verovio's breaking is greedy and
/// local (`CastOffSystemsFunctor`, `CastOffPagesFunctor` in 6.2.1): a system
/// is filled bar by bar until the next bar does not fit, a page system by
/// system until the next system does not fit, and each is justified on its
/// own. So the first page of a cut document is the first page of the whole
/// one when
///
///   1. the system that follows the shown pages is a COMPLETE system of the
///      whole score -- it decides where the page breaks, by its height -- so
///      it is not the cut document's last system, which may be short; and
///   2. nothing on the shown pages or in that system points past the cut: a
///      slur, tie or hairpin whose end was cut away is drawn differently, or
///      not at all (an OMR hairpin on the quartet runs `98m+2`, to the end).
///
/// `cut` makes the document, the renderer lays it out, and the two questions
/// are asked of what came back (`systemsOnPage`, `reachPastCut`). Whatever
/// they let through is held to the whole engraving afterwards, drawing
/// against drawing (`VerovioRenderer.engrave`), so a page that got past them
/// wrongly is replaced rather than kept.
///
/// Byte work on the UTF-8 of the MEI, which is a megabyte on a dense score:
/// every needle is ASCII markup, as in `TextSearch`.
enum EarlyPages {

    /// Notes (and rests) a page is taken to hold when choosing where to cut.
    ///
    /// Measured on the six open-speed scores after the MEI rewrites: page 1
    /// held 86 to 228 and a full page 101 to 286. The cut aims at one page
    /// more than is shown, so the system after them is likely complete; too
    /// few and the check refuses the cut and the score opens as before, too
    /// many and the cut saves less.
    static let notesPerPage = 220

    /// A cut keeping more than this share of the bars saves too little of the
    /// layout to pay for laying the first pages out twice.
    static let largestShare = 0.6

    /// The first bars of an MEI document, closed into a document of their own.
    struct Cut {
        /// The cut document: the source up to the end of the last kept bar,
        /// and the closing tags of what was open there.
        let mei: String
        let keptMeasures: Int
        let totalMeasures: Int
        /// The cut document's bytes, and where each kept bar lies in them.
        fileprivate let bytes: [UInt8]
        fileprivate let measures: [Range<Int>]
    }

    /// The first bars of `mei`, enough for `pages` pages and one more, or nil
    /// when the score is too short for a cut to save anything or its
    /// structure is not one this reads.
    static func cut(mei: String, pages: Int) -> Cut? {
        let source = Array(mei.utf8)
        return source.withUnsafeBufferPointer { b -> Cut? in
            let measures = measureRanges(in: b)
            guard !measures.isEmpty else { return nil }
            let target = notesPerPage * (pages + 1)
            var notes = 0
            var kept = 0
            for range in measures {
                notes += countEvents(in: b, range)
                kept += 1
                if notes >= target { break }
            }
            guard notes >= target,
                  Double(kept) <= largestShare * Double(measures.count) else { return nil }
            let end = measures[kept - 1].upperBound
            guard let open = openElements(in: b, upTo: end) else { return nil }
            var bytes = Array(b[0..<end])
            for name in open.reversed() {
                bytes.append(contentsOf: Array("</\(name)>".utf8))
            }
            return Cut(mei: String(decoding: bytes, as: UTF8.self),
                       keptMeasures: kept, totalMeasures: measures.count,
                       bytes: bytes, measures: Array(measures[0..<kept]))
        }
    }

    /// `cut` as `mei`: the same bars of the same score after the renderer's
    /// rewrites, which move verses and marks and never add or remove a bar.
    /// Nil when `mei` does not hold the bars the cut kept.
    static func rewritten(_ cut: Cut, as mei: String) -> Cut? {
        let bytes = Array(mei.utf8)
        let measures = bytes.withUnsafeBufferPointer { measureRanges(in: $0) }
        guard measures.count == cut.keptMeasures else { return nil }
        return Cut(mei: mei, keptMeasures: cut.keptMeasures, totalMeasures: cut.totalMeasures,
                   bytes: bytes, measures: measures)
    }

    /// The cut with every slur, tie, hairpin and the like that starts in it
    /// and ends past it made to end in its last bar instead, and how many were;
    /// the cut itself when none does.
    ///
    /// For the quartet, and OMR scores generally: a misread tie or hairpin
    /// running from an early bar to bar 90, or to the end (`98m+2`), used to
    /// keep the score from any early first page, and it waited 1.4 s on the
    /// simulator for the whole layout. On the shown page such a mark is drawn
    /// as its START segment -- from where it begins to the end of its system
    /// -- wherever in a later system it ends, and so it is in the cut, once
    /// it ends in the cut's last bar: a system after the one that follows the
    /// shown page, which the renderer requires to be complete. Measured with
    /// Verovio 6.2.1 on the six open-speed scores, every first page laid out
    /// from a cut made this way at sixteen cut sizes matched the whole score's
    /// (ids aside).
    ///
    /// ONE shown page only. On a spread the second page's running header was
    /// placed 9 units lower from such a cut (the quartet), so a spread is cut
    /// as it was and a mark reaching past still refuses it.
    ///
    /// A reference to anything but an end (`plist`, ...), and an end whose
    /// start or staff cannot be read, or whose staff has no note in the last
    /// bar, are left as they are, and `reachPastCut` refuses them as before.
    static func endingInside(_ cut: Cut) -> (cut: Cut, moved: Int) {
        guard let lastBar = cut.measures.last else { return (cut, 0) }
        var edits: [(range: Range<Int>, bytes: [UInt8])] = []
        cut.bytes.withUnsafeBufferPointer { b in
            let defined = definedIDs(in: b)
            var lastEvents: [ArraySlice<UInt8>: ArraySlice<UInt8>?] = [:]
            let endMark = Array("endid=\"#".utf8)
            let startMark = Array("startid=\"#".utf8)
            let stampMark = Array("tstamp2=\"".utf8)
            for (bar, range) in cut.measures.enumerated() {
                var scan = range.lowerBound
                while let found = find(endMark, in: b, from: scan), found < range.upperBound {
                    let start = found + endMark.count
                    guard let close = index(of: UInt8(ascii: "\""), in: b, from: start) else { break }
                    scan = close
                    guard defined[ArraySlice(b[start..<close])] == nil,
                          let tagStart = lastIndex(of: UInt8(ascii: "<"), in: b, before: found),
                          let tagEnd = index(of: UInt8(ascii: ">"), in: b, from: found),
                          let from = find(startMark, in: b, from: tagStart), from < tagEnd,
                          let fromClose = index(of: UInt8(ascii: "\""), in: b,
                                                from: from + startMark.count),
                          let startAt = defined[ArraySlice(b[(from + startMark.count)..<fromClose])],
                          let staff = staffNumber(in: b, at: startAt)
                    else { continue }
                    if lastEvents[staff] == nil {
                        lastEvents[staff] = lastEvent(in: b, bar: lastBar, staff: staff)
                    }
                    guard let target = lastEvents[staff] ?? nil else { continue }
                    edits.append((start..<close, Array(target)))
                }
                scan = range.lowerBound
                while let found = find(stampMark, in: b, from: scan), found < range.upperBound {
                    let start = found + stampMark.count
                    var i = start
                    var ahead = 0
                    while i < b.count, b[i] >= UInt8(ascii: "0"), b[i] <= UInt8(ascii: "9") {
                        ahead = ahead * 10 + Int(b[i] - UInt8(ascii: "0"))
                        i += 1
                    }
                    scan = i
                    guard i > start, i < b.count, b[i] == UInt8(ascii: "m"),
                          bar + 1 + ahead > cut.keptMeasures else { continue }
                    edits.append((start..<i, Array(String(cut.keptMeasures - bar - 1).utf8)))
                }
            }
        }
        guard !edits.isEmpty else { return (cut, 0) }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(cut.bytes.count)
        var at = 0
        for edit in edits.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            bytes.append(contentsOf: cut.bytes[at..<edit.range.lowerBound])
            bytes.append(contentsOf: edit.bytes)
            at = edit.range.upperBound
        }
        bytes.append(contentsOf: cut.bytes[at...])
        let measures = bytes.withUnsafeBufferPointer { measureRanges(in: $0) }
        guard measures.count == cut.measures.count else { return (cut, 0) }
        return (Cut(mei: String(decoding: bytes, as: UTF8.self), keptMeasures: cut.keptMeasures,
                    totalMeasures: cut.totalMeasures, bytes: bytes, measures: measures),
                edits.count)
    }

    /// The ids of the bars on one page of Verovio's SVG, system by system.
    ///
    /// Verovio writes a bar as `<g id="ID" class="measure">` inside its
    /// `<g id="..." class="system">`, and loaded from MEI the id is the MEI's
    /// own `xml:id`.
    static func systemsOnPage(svg: String) -> [[String]] {
        let bytes = Array(svg.utf8)
        return bytes.withUnsafeBufferPointer { b -> [[String]] in
            let systemMark = Array("class=\"system\"".utf8)
            let measureMark = Array("\" class=\"measure\"".utf8)
            var systems: [Int] = []
            var at = 0
            while let found = find(systemMark, in: b, from: at) {
                systems.append(found)
                at = found + systemMark.count
            }
            guard !systems.isEmpty else { return [] }
            var out: [[String]] = Array(repeating: [], count: systems.count)
            at = 0
            while let found = find(measureMark, in: b, from: at) {
                at = found + measureMark.count
                // the id is the attribute just before the class
                var start = found
                while start > 0, b[start - 1] != UInt8(ascii: "\"") { start -= 1 }
                guard start >= 4, b[start - 4] == UInt8(ascii: "i"),
                      b[start - 3] == UInt8(ascii: "d"), b[start - 2] == UInt8(ascii: "=")
                else { continue }
                guard let system = systems.lastIndex(where: { $0 < found }) else { continue }
                out[system].append(String(decoding: b[start..<found], as: UTF8.self))
            }
            return out
        }
    }

    /// The first thing in the bars up to and including `lastMeasureID` that
    /// points past the cut, described for a log, or nil when nothing does.
    ///
    /// "Points" is any attribute whose value is `#id` references (`startid`,
    /// `endid`, `plist`, ...) naming an element the cut document does not
    /// hold, and any `tstamp2` reaching more bars ahead than were kept. A bar
    /// that cannot be found counts as pointing past, so a question this cannot
    /// answer is answered no.
    static func reachPastCut(_ cut: Cut, throughMeasure lastMeasureID: String) -> String? {
        let found = cut.bytes.withUnsafeBufferPointer { b -> Int? in
            guard let at = find(Array("xml:id=\"\(lastMeasureID)\"".utf8), in: b, from: 0)
            else { return nil }
            return cut.measures.firstIndex(where: { $0.contains(at) })
        }
        guard let last = found else { return "bar \(lastMeasureID) is not in the cut" }
        return reachPastCut(cut, throughBar: last + 1)
    }

    /// The same question of the cut's first `bars` bars, asked before the cut
    /// is laid out: something reaching past it from its first half almost
    /// always starts on the pages to be shown, and a layout that will be
    /// refused is a layout wasted (on the quartet, 0.8 s on the simulator).
    static func reachPastCut(_ cut: Cut, throughBar bars: Int) -> String? {
        let last = min(bars, cut.measures.count) - 1
        guard last >= 0 else { return nil }
        return cut.bytes.withUnsafeBufferPointer { b -> String? in
            let defined = definedIDs(in: b)
            var scan = 0
            let refMark = Array("=\"#".utf8)
            let stampMark = Array("tstamp2=\"".utf8)
            for (bar, range) in cut.measures[0...last].enumerated() {
                scan = range.lowerBound
                while let found = find(refMark, in: b, from: scan), found < range.upperBound {
                    let start = found + 2
                    guard let close = index(of: UInt8(ascii: "\""), in: b, from: start)
                    else { return "unterminated reference in bar \(bar + 1)" }
                    for token in b[start..<close].split(separator: UInt8(ascii: " "))
                    where token.first == UInt8(ascii: "#") {
                        let id = token.dropFirst()
                        if defined[ArraySlice(id)] == nil {
                            return "#\(String(decoding: id, as: UTF8.self)) from bar \(bar + 1)"
                        }
                    }
                    scan = close
                }
                scan = range.lowerBound
                while let found = find(stampMark, in: b, from: scan), found < range.upperBound {
                    var i = found + stampMark.count
                    var ahead = 0
                    while i < b.count, b[i] >= UInt8(ascii: "0"), b[i] <= UInt8(ascii: "9") {
                        ahead = ahead * 10 + Int(b[i] - UInt8(ascii: "0"))
                        i += 1
                    }
                    if i < b.count, b[i] == UInt8(ascii: "m"), bar + 1 + ahead > cut.keptMeasures {
                        return "tstamp2 \(ahead)m from bar \(bar + 1)"
                    }
                    scan = i
                }
            }
            return nil
        }
    }

    // MARK: - Bytes

    /// Every `xml:id` in the document, and where its value starts.
    private static func definedIDs(in b: UnsafeBufferPointer<UInt8>) -> [ArraySlice<UInt8>: Int] {
        let idMark = Array("xml:id=\"".utf8)
        var defined: [ArraySlice<UInt8>: Int] = [:]
        var scan = 0
        while let found = find(idMark, in: b, from: scan) {
            let start = found + idMark.count
            guard let close = index(of: UInt8(ascii: "\""), in: b, from: start) else { break }
            defined[ArraySlice(b[start..<close])] = start
            scan = close
        }
        return defined
    }

    /// The `n` of the `<staff>` holding the byte at `at`.
    private static func staffNumber(in b: UnsafeBufferPointer<UInt8>, at: Int) -> ArraySlice<UInt8>? {
        let staffMark = Array("<staff ".utf8)
        var i = at
        while i > 0 {
            guard let open = lastIndex(of: UInt8(ascii: "<"), in: b, before: i) else { return nil }
            i = open
            if matches(Array("<measure".utf8), in: b, at: open) { return nil }
            guard matches(staffMark, in: b, at: open) else { continue }
            return attribute(" n=\"", in: b, tagAt: open)
        }
        return nil
    }

    /// The id of the last note or chord on staff `staff` in `bar`.
    private static func lastEvent(in b: UnsafeBufferPointer<UInt8>, bar: Range<Int>,
                                  staff: ArraySlice<UInt8>) -> ArraySlice<UInt8>? {
        let staffMark = Array("<staff ".utf8)
        let staffClose = Array("</staff>".utf8)
        var scan = bar.lowerBound
        while let open = find(staffMark, in: b, from: scan), open < bar.upperBound {
            guard let close = find(staffClose, in: b, from: open), close <= bar.upperBound
            else { return nil }
            scan = close
            guard attribute(" n=\"", in: b, tagAt: open) == staff else { continue }
            var last: ArraySlice<UInt8>?
            var at = open
            while let lt = index(of: UInt8(ascii: "<"), in: b, from: at + 1), lt < close {
                at = lt
                for name in ["<note", "<chord"].map({ Array($0.utf8) })
                where matches(name, in: b, at: lt) && isNameEnd(b[lt + name.count]) {
                    if let id = attribute("xml:id=\"", in: b, tagAt: lt) { last = id }
                }
            }
            return last
        }
        return nil
    }

    /// The value of `mark` (`name="`) in the tag opening at `tagAt`.
    private static func attribute(_ mark: String, in b: UnsafeBufferPointer<UInt8>,
                                  tagAt: Int) -> ArraySlice<UInt8>? {
        guard let tagEnd = index(of: UInt8(ascii: ">"), in: b, from: tagAt),
              let found = find(Array(mark.utf8), in: b, from: tagAt), found < tagEnd
        else { return nil }
        let start = found + mark.utf8.count
        guard let close = index(of: UInt8(ascii: "\""), in: b, from: start), close < tagEnd
        else { return nil }
        return ArraySlice(b[start..<close])
    }

    private static func lastIndex(of byte: UInt8, in b: UnsafeBufferPointer<UInt8>,
                                  before end: Int) -> Int? {
        var i = min(end, b.count) - 1
        while i >= 0 {
            if b[i] == byte { return i }
            i -= 1
        }
        return nil
    }

    /// Every `<measure ...>...</measure>` (or self-closed `<measure .../>`),
    /// in document order. MEI bars do not nest.
    private static func measureRanges(in b: UnsafeBufferPointer<UInt8>) -> [Range<Int>] {
        let open = Array("<measure".utf8)
        let close = Array("</measure>".utf8)
        var out: [Range<Int>] = []
        var at = 0
        while let start = find(open, in: b, from: at) {
            let after = start + open.count
            guard after < b.count, isNameEnd(b[after]) else { at = after; continue }
            guard let tagEnd = index(of: UInt8(ascii: ">"), in: b, from: after) else { break }
            if b[tagEnd - 1] == UInt8(ascii: "/") {
                out.append(start..<(tagEnd + 1))
                at = tagEnd + 1
                continue
            }
            guard let end = find(close, in: b, from: tagEnd) else { break }
            out.append(start..<(end + close.count))
            at = end + close.count
        }
        return out
    }

    /// Notes, rests and spaces in one bar: what fills a page.
    private static func countEvents(in b: UnsafeBufferPointer<UInt8>, _ range: Range<Int>) -> Int {
        var count = 0
        var i = range.lowerBound
        let lt = UInt8(ascii: "<")
        while let found = index(of: lt, in: b, from: i), found < range.upperBound {
            i = found + 1
            for name in eventNames where matches(name, in: b, at: i) {
                let after = i + name.count
                if after < b.count, isNameEnd(b[after]) { count += 1; break }
            }
        }
        return count
    }
    private static let eventNames = ["note", "rest", "mRest", "space", "multiRest"].map { Array($0.utf8) }

    /// The names of the elements open at `end`, outermost first, read from
    /// the tags between bars. The header, the bars and score definitions are
    /// skipped whole; nil when the tags do not balance as expected.
    private static func openElements(in b: UnsafeBufferPointer<UInt8>, upTo end: Int) -> [String]? {
        let skipped = ["meiHead", "measure", "scoreDef"].map { (Array($0.utf8), Array("</\($0)>".utf8)) }
        var stack: [[UInt8]] = []
        var i = 0
        let lt = UInt8(ascii: "<"), gt = UInt8(ascii: ">"), slash = UInt8(ascii: "/")
        tags: while let start = index(of: lt, in: b, from: i), start < end {
            let first = start + 1
            guard first < end else { return nil }
            if b[first] == UInt8(ascii: "?") || b[first] == UInt8(ascii: "!") {
                // a declaration, processing instruction or comment
                let closer = b[first] == UInt8(ascii: "!") && matches(Array("!--".utf8), in: b, at: first)
                    ? Array("-->".utf8) : [gt]
                guard let stop = find(closer, in: b, from: first) else { return nil }
                i = stop + closer.count
                continue
            }
            guard let tagEnd = index(of: gt, in: b, from: first), tagEnd < end else { return nil }
            let closing = b[first] == slash
            var nameEnd = closing ? first + 1 : first
            while nameEnd < tagEnd, !isNameEnd(b[nameEnd]) { nameEnd += 1 }
            let name = Array(b[(closing ? first + 1 : first)..<nameEnd])
            let selfClosed = b[tagEnd - 1] == slash
            if !closing, !selfClosed {
                for (skip, closer) in skipped where skip == name {
                    guard let stop = find(closer, in: b, from: tagEnd), stop + closer.count <= end
                    else { return nil }
                    i = stop + closer.count
                    continue tags
                }
                stack.append(name)
            } else if closing {
                guard stack.last == name else { return nil }
                stack.removeLast()
            }
            i = tagEnd + 1
        }
        return stack.map { String(decoding: $0, as: UTF8.self) }
    }

    private static func isNameEnd(_ c: UInt8) -> Bool {
        c == UInt8(ascii: " ") || c == UInt8(ascii: ">") || c == UInt8(ascii: "/")
            || c == UInt8(ascii: "\n") || c == UInt8(ascii: "\t") || c == UInt8(ascii: "\r")
    }

    private static func matches(_ needle: [UInt8], in b: UnsafeBufferPointer<UInt8>, at i: Int) -> Bool {
        guard i + needle.count <= b.count else { return false }
        for (k, c) in needle.enumerated() where b[i + k] != c { return false }
        return true
    }

    private static func index(of byte: UInt8, in b: UnsafeBufferPointer<UInt8>, from start: Int) -> Int? {
        guard start < b.count, let base = b.baseAddress,
              let hit = memchr(base + start, Int32(byte), b.count - start) else { return nil }
        return UnsafeRawPointer(hit) - UnsafeRawPointer(base)
    }

    private static func find(_ needle: [UInt8], in b: UnsafeBufferPointer<UInt8>, from start: Int) -> Int? {
        needle.withUnsafeBufferPointer { n -> Int? in
            guard start >= 0, b.count - start >= n.count, let base = b.baseAddress,
                  let nb = n.baseAddress,
                  let hit = memmem(base + start, b.count - start, nb, n.count) else { return nil }
            return UnsafeRawPointer(hit) - UnsafeRawPointer(base)
        }
    }
}
