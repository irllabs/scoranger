import Foundation

/// Looking for a fixed piece of markup in a whole page or document, fast.
///
/// Foundation's `contains` and `range(of:)` on a Swift `String` compare by
/// grapheme cluster, through a bridged copy of the text. On an engraved page
/// of 400 KB that cost about 20 ms a search, and the engrave asks a page
/// several such questions -- "does it carry any fingering verse, any chord
/// diagram, any `currentColor`?" -- most of which are answered no. Here the
/// question is asked of the UTF-8 bytes with `memmem`.
///
/// Byte for byte is not grapheme for grapheme: a grapheme search would refuse
/// a needle whose last character fused with a combining mark after it in the
/// text. Every needle these passes look for ends in ASCII markup (`"`, `>`, a
/// letter of a tag or attribute name), which in generated SVG, MEI or
/// MusicXML is followed by more markup, never by a combining mark, so the two
/// answers are the same for everything Verovio and the engine write.
enum TextSearch {
    /// Where `needle` first occurs in `text`, as a UTF-8 offset, or nil.
    static func utf8Offset(of needle: String, in text: String, from start: Int = 0) -> Int? {
        func search(_ hay: UnsafeBufferPointer<UInt8>) -> Int? {
            var needle = needle
            return needle.withUTF8 { nd -> Int? in
                guard nd.count > 0, start >= 0, hay.count - start >= nd.count,
                      let hayBase = hay.baseAddress, let ndBase = nd.baseAddress,
                      let found = memmem(hayBase + start, hay.count - start, ndBase, nd.count)
                else { return nil }
                return UnsafeRawPointer(found) - UnsafeRawPointer(hayBase)
            }
        }
        // A native string is searched where it lies; one bridged from an
        // NSString has no UTF-8 to lend and is transcoded once for the search.
        if let found = text.utf8.withContiguousStorageIfAvailable(search) { return found }
        var copy = text
        copy.makeContiguousUTF8()
        return copy.utf8.withContiguousStorageIfAvailable(search) ?? nil
    }

    static func contains(_ text: String, _ needle: String) -> Bool {
        utf8Offset(of: needle, in: text) != nil
    }

    /// Whether `needle` occurs at least twice, the second time after the end
    /// of the first.
    static func occursTwice(_ needle: String, in text: String) -> Bool {
        guard let first = utf8Offset(of: needle, in: text) else { return false }
        return utf8Offset(of: needle, in: text, from: first + needle.utf8.count) != nil
    }

    /// The first occurrence of `needle` in `text`, as a range of `text`.
    static func range(of needle: String, in text: String) -> Range<String.Index>? {
        guard let offset = utf8Offset(of: needle, in: text) else { return nil }
        let start = text.utf8.index(text.utf8.startIndex, offsetBy: offset)
        let end = text.utf8.index(start, offsetBy: needle.utf8.count)
        return start..<end
    }
}

extension TextSearch {
    /// Every `<name ...>...</name>` element named in `names`, in document
    /// order: the ranges `<(a|b)\b[^>]*>.*?</\1>` matches with `.` across
    /// lines, found by literal search instead.
    ///
    /// ICU runs that lazy pattern a character at a time over the whole
    /// document; on "Espresso"'s MEI (780 KB) the note and staff passes of
    /// the fingering lift spent 25 ms in it, natively. Same rules: the name
    /// ends at a word boundary, the start tag runs to its first `>`, and the
    /// element to the first closing tag of its name after that -- matches do
    /// not overlap, and an opening with no closing tag is passed over.
    ///
    /// `text` should be a real NSString (`NSString(string:)`): a Swift string
    /// bridged as one answers each search through a UTF-16 view of its UTF-8.
    static func elementRanges(named names: [String], in text: NSString,
                              within range: NSRange? = nil) -> [NSRange] {
        let whole = range ?? NSRange(location: 0, length: text.length)
        let end = whole.location + whole.length
        func find(_ needle: String, from: Int) -> Int {
            guard from < end else { return NSNotFound }
            return text.range(of: needle, options: .literal,
                              range: NSRange(location: from, length: end - from)).location
        }
        func isWordCharacter(_ c: unichar) -> Bool {
            // a tag name in MEI is ASCII; anything else after one is treated
            // as a letter, which is what ICU's \b makes of a letter
            c >= 0x80 || (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A)
                || (c >= 0x61 && c <= 0x7A) || c == 0x5F
        }
        let opens = names.map { "<" + $0 }
        // the next opening of each name at or after the cursor, kept so a
        // rare name is not searched for again on every element
        var next = [Int](repeating: -1, count: names.count)
        var out: [NSRange] = []
        var cursor = whole.location
        while cursor < end {
            var best = NSNotFound
            var which = -1
            for i in names.indices {
                if next[i] != NSNotFound, next[i] < cursor { next[i] = find(opens[i], from: cursor) }
                if next[i] != NSNotFound, next[i] < best { best = next[i]; which = i }
            }
            guard which >= 0 else { break }
            let afterName = best + opens[which].utf16.count
            if afterName < end, isWordCharacter(text.character(at: afterName)) {
                cursor = best + 1
                continue
            }
            let tagEnd = find(">", from: afterName)
            let close = tagEnd == NSNotFound ? NSNotFound : find("</\(names[which])>", from: tagEnd + 1)
            guard close != NSNotFound else {
                cursor = best + 1
                continue
            }
            let stop = close + names[which].utf16.count + 3
            out.append(NSRange(location: best, length: stop - best))
            cursor = stop
        }
        return out
    }
}
