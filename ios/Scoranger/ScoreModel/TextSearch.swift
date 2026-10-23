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
