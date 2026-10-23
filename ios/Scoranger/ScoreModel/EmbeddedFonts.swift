import CoreGraphics
import CoreText
import Foundation

/// The music font Verovio embeds in a page whose text draws with it,
/// registered with CoreText once instead of decoded by SwiftDraw for every
/// piece of text on every page.
///
/// A page whose text uses a SMuFL glyph -- the note in a tempo mark, say --
/// carries the whole font (Leipzig, 58 KB of base64 WOFF2) in a `@font-face`
/// rule. SwiftDraw scans that stylesheet three times with `NSScanner`, then
/// base64-decodes and WOFF2-decodes the font again for EVERY text element in
/// the family. On "Under Paris Skies" that was half of drawing page 1: 69 ms
/// natively, 35 of them the font.
///
/// With the font registered in the process under the family the page names,
/// and the rule taken out of the page, SwiftDraw finds no source for the
/// family and asks CoreText for it by name (`CTFontCreateWithName`), which
/// answers with the same font. The glyphs are drawn as paths from the same
/// outlines either way, and the fidelity check of the open-speed work holds
/// every page drawn this way to the pixels it had before.
///
/// Taken out only when this exact font, byte for byte, is the one registered
/// under that family: a page embedding a different font of the same name, or
/// a family some other font already answers to, keeps its rule and is drawn
/// as it always was.
enum EmbeddedFonts {

    private static let lock = NSLock()
    /// Family -> the base64 of the font registered under it.
    private static var registered: [String: String] = [:]
    /// Families that could not be registered, or were not ours to register.
    private static var refused: Set<String> = []

    private static let ruleStart = "<style type=\"text/css\">@font-face {"
    private static let ruleEnd = "</style>"

    /// `svg` without its embedded font, when that font is registered here (by
    /// this call or an earlier one); `svg` unchanged otherwise.
    static func lifted(from page: String) -> String {
        var svg = page
        svg.makeContiguousUTF8()
        guard let start = TextSearch.utf8Offset(of: ruleStart, in: svg),
              let close = TextSearch.utf8Offset(of: ruleEnd, in: svg, from: start)
        else { return page }
        let u = svg.utf8
        let from = u.index(u.startIndex, offsetBy: start)
        let to = u.index(u.startIndex, offsetBy: close + ruleEnd.utf8.count)
        let rule = String(svg[from..<to])
        // one font, in the form Verovio writes it, or nothing is touched
        guard !TextSearch.occursTwice("@font-face", in: rule),
              TextSearch.contains(rule, "format('woff2')"),
              let family = between("font-family: '", and: "'", in: rule),
              let data = between("base64,", and: ")", in: rule),
              isRegistered(family: family, base64: data)
        else { return page }
        return String(svg[..<from]) + String(svg[to...])
    }

    /// The text between the first `open` and the `close` after it.
    private static func between(_ open: String, and close: String, in text: String) -> String? {
        guard let a = TextSearch.utf8Offset(of: open, in: text) else { return nil }
        let start = a + open.utf8.count
        guard let b = TextSearch.utf8Offset(of: close, in: text, from: start), start < b
        else { return nil }
        let u = text.utf8
        return String(text[u.index(u.startIndex, offsetBy: start)..<u.index(u.startIndex, offsetBy: b)])
    }

    private static func isRegistered(family: String, base64: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let mine = registered[family] { return mine == base64 }
        if refused.contains(family) { return false }
        // A font that already answers to the name would be the one CoreText
        // hands SwiftDraw, whatever this page embeds.
        // And the font must BE the family the page names, or registering it
        // would put a font in the process under some other name.
        guard !answers(to: family),
              let bytes = Data(base64Encoded: base64),
              let provider = CGDataProvider(data: bytes as CFData),
              let font = CGFont(provider),
              font.postScriptName as String? == family,
              CTFontManagerRegisterGraphicsFont(font, nil) else {
            refused.insert(family)
            return false
        }
        guard answers(to: family) else {
            CTFontManagerUnregisterGraphicsFont(font, nil)
            refused.insert(family)
            return false
        }
        registered[family] = base64
        return true
    }

    /// Whether CoreText resolves `family` by name, as SwiftDraw asks it to
    /// (`CGProvider.createCTFont`): by PostScript or family name.
    private static func answers(to family: String) -> Bool {
        let font = CTFontCreateWithName(family as CFString, 12, nil)
        return (CTFontCopyPostScriptName(font) as String).caseInsensitiveCompare(family) == .orderedSame
            || CTFontCopyFamilyName(font) as String == family
    }
}
