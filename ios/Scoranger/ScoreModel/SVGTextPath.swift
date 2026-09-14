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
        /// Characters the chosen face had no glyph for, in document order.
        let missing: [Character]
    }

    /// `origin` is SVG's anchor point on the BASELINE, in user units, y down.
    static func outline(_ text: String, family: String, size: CGFloat,
                        bold: Bool, italic: Bool,
                        origin: CGPoint, anchor: Anchor) -> Result? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, size > 0 else { return nil }
        let font = face(family: family, size: size, bold: bold, italic: italic)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: trimmed, attributes: [.font: font]))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))

        var startX = origin.x
        switch anchor {
        case .start:  break
        case .middle: startX -= width / 2
        case .end:    startX -= width
        }

        let out = CGMutablePath()
        var missing: [Character] = []
        let characters = Array(trimmed)
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return nil }
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            CTRunGetStringIndices(run, CFRange(location: 0, length: count), &indices)
            let runFont = unsafeBitCast(
                CFDictionaryGetValue(
                    CTRunGetAttributes(run),
                    Unmanaged.passUnretained(kCTFontAttributeName).toOpaque()),
                to: CTFont.self)
            for i in 0..<count {
                // The glyph outline is in text space: origin on the baseline,
                // y UP. SVG's y runs DOWN, so every glyph is mirrored as it is
                // placed rather than the whole page being drawn upside down.
                var placement = CGAffineTransform(a: 1, b: 0, c: 0, d: -1,
                                                  tx: startX + positions[i].x,
                                                  ty: origin.y - positions[i].y)
                guard glyphs[i] != 0,
                      let glyph = CTFontCreatePathForGlyph(runFont, glyphs[i], &placement)
                else {
                    let index = indices[i]
                    if index >= 0, index < characters.count { missing.append(characters[index]) }
                    continue
                }
                out.addPath(glyph)
            }
        }
        guard !out.isEmpty || !missing.isEmpty else { return nil }
        return Result(path: out.copy() ?? out, missing: missing)
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
