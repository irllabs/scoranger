import CoreGraphics
import CoreText
import Foundation

/// One run of SVG `<text>` turned into outlines.
///
/// Text is the one part of Verovio's output that is NOT geometry: staff
/// labels, chord symbols, tempo marks, tuplet numbers and page numbers are
/// characters in a named family, and the page only reads correctly if the
/// glyphs for them exist on the device. Outlining them here rather than
/// drawing strings at render time keeps the display list one kind of thing --
/// paths -- so zoom costs nothing extra and the renderer stays a single loop.
///
/// What it does NOT solve, and reports instead: SMuFL characters that Verovio
/// writes as TEXT in its own music font (a metronome mark's note head is
/// `U+ECA5` in "Leipzig"). Those are not in any system face, so the font
/// substitution behind `CTLine` yields `.notdef`. See `VECTOR_RENDER.md`.
enum SVGTextPath {

    enum Anchor: String {
        case start, middle, end
    }

    struct Result {
        let path: CGPath
        /// Characters the chosen face had no glyph for. They are NOT drawn:
        /// Core Text answers a missing character with a last-resort box, and a
        /// box in the middle of a tempo mark is a worse lie than a gap the
        /// report names.
        let missing: [Character]
        /// Where the run actually started, after `anchor` was applied.
        let leftEdge: CGFloat
        /// How far the pen moved, so the next unpositioned run can continue
        /// from here.
        let advance: CGFloat
    }

    /// `origin` is SVG's anchor point on the BASELINE, in user units, y down.
    static func outline(_ text: String, family: String, size: CGFloat,
                        bold: Bool, italic: Bool,
                        origin: CGPoint, anchor: Anchor) -> Result? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, size > 0 else { return nil }
        let font = face(family: family, size: size, bold: bold, italic: italic)

        // Asked of the face we CHOSE, before layout. Core Text's own answer is
        // not usable for this: it cascades to a last-resort font and hands
        // back a perfectly valid glyph id for a box, so a page full of
        // U+ECA5 boxes reports itself as fully drawn.
        var missing: [Character] = []
        var drawable = ""
        for character in trimmed {
            if has(character, in: font) {
                drawable.append(character)
            } else {
                missing.append(character)
            }
        }
        guard !drawable.isEmpty else {
            return Result(path: CGMutablePath(), missing: missing,
                          leftEdge: origin.x, advance: 0)
        }

        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: drawable, attributes: [Self.fontKey: font]))
        let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))

        var startX = origin.x
        switch anchor {
        case .start:  break
        case .middle: startX -= advance / 2
        case .end:    startX -= advance
        }

        let out = CGMutablePath()
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return nil }
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            let runFont = unsafeBitCast(
                CFDictionaryGetValue(
                    CTRunGetAttributes(run),
                    Unmanaged.passUnretained(kCTFontAttributeName).toOpaque()),
                to: CTFont.self)
            for i in 0..<count where glyphs[i] != 0 {
                // The glyph outline is in text space: origin on the baseline,
                // y UP. SVG's y runs DOWN, so every glyph is mirrored as it is
                // placed rather than the whole page being drawn upside down.
                var placement = CGAffineTransform(a: 1, b: 0, c: 0, d: -1,
                                                  tx: startX + positions[i].x,
                                                  ty: origin.y - positions[i].y)
                guard let glyph = CTFontCreatePathForGlyph(runFont, glyphs[i], &placement)
                else { continue }
                out.addPath(glyph)
            }
        }
        return Result(path: out.copy() ?? out, missing: missing,
                      leftEdge: startX, advance: advance)
    }

    /// How wide this run is, without placing it.
    ///
    /// A `<text>` block with `text-anchor="middle"` and several runs -- the
    /// page number, "– 2 –", is three -- has to be measured WHOLE before the
    /// first glyph can be positioned, so the measurement is separable from the
    /// drawing.
    static func advance(of text: String, family: String, size: CGFloat,
                        bold: Bool, italic: Bool) -> CGFloat {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, size > 0 else { return 0 }
        let font = face(family: family, size: size, bold: bold, italic: italic)
        let drawable = String(trimmed.filter { has($0, in: font) })
        guard !drawable.isEmpty else { return 0 }
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: drawable, attributes: [Self.fontKey: font]))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// `.font` is UIKit's and AppKit's sugar for this key, and neither is
    /// imported here -- the display list has to build in a test bundle with no
    /// host app as readily as in the app.
    private static let fontKey = kCTFontAttributeName as NSAttributedString.Key

    /// Does this face have a glyph for `character` itself, without cascading?
    private static func has(_ character: Character, in font: CTFont) -> Bool {
        var utf16 = Array(String(character).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        return CTFontGetGlyphsForCharacters(font, &utf16, &glyphs, utf16.count)
    }

    /// The face for an SVG `font-family` list.
    ///
    /// Verovio emits `Times, serif` for everything it does not set explicitly.
    /// A generic name is not a face, so it is resolved here; an unknown family
    /// falls back the same way, because a page drawn in the wrong serif is
    /// legible and a page drawn in nothing is not.
    static func face(family: String, size: CGFloat, bold: Bool, italic: Bool) -> CTFont {
        let names = family.split(separator: ",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " '\"")) }
            .filter { !$0.isEmpty }
        var font: CTFont?
        for name in names {
            switch name.lowercased() {
            case "serif", "times", "times new roman":
                font = CTFontCreateWithName("Times New Roman" as CFString, size, nil)
            case "sans-serif", "helvetica", "arial":
                font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
            default:
                let candidate = CTFontCreateWithName(name as CFString, size, nil)
                // CTFontCreateWithName NEVER fails: an unknown name comes back
                // as the system face under its own name, so the only way to
                // know whether the family was found is to ask what came back.
                let resolved = CTFontCopyFamilyName(candidate) as String
                if resolved.compare(name, options: .caseInsensitive) == .orderedSame {
                    font = candidate
                }
            }
            if font != nil { break }
        }
        let base = font ?? CTFontCreateWithName("Times New Roman" as CFString, size, nil)
        var traits: CTFontSymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        guard !traits.isEmpty else { return base }
        return CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, traits) ?? base
    }
}
