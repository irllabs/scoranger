import XCTest

/// `TextSearch` answers the engrave's "is this markup anywhere in the page?"
/// questions from the UTF-8 bytes. These hold it to Foundation's own answer
/// for the kind of text it is asked about.
final class TextSearchTests: XCTestCase {

    private let page = #"<svg><g class="verse"><title class="labelAttr">wf</title>"#
        + #"<text x="1"><tspan font-size="405px">X</tspan></text></g></svg>"#

    func testFindsWhatFoundationFinds() {
        for needle in [#"class="verse""#, "labelAttr", "<svg ", "</svg>", "wf", "nothing",
                       #"<title class="labelAttr">gt"#, "\u{E260}"] {
            XCTAssertEqual(TextSearch.contains(page, needle), page.contains(needle), needle)
        }
    }

    func testRangeIsTheFirstOccurrence() throws {
        let text = "ab</svg>cd</svg>"
        let r = try XCTUnwrap(TextSearch.range(of: "</svg>", in: text))
        XCTAssertEqual(r, text.range(of: "</svg>"))
        XCTAssertEqual(String(text[r]), "</svg>")
        XCTAssertNil(TextSearch.range(of: "</g>", in: text))
    }

    /// Offsets are counted in UTF-8, so a range after a multibyte character
    /// still lands on the right text.
    func testRangeAfterMultibyteText() throws {
        let text = "é\u{E260}♩ <svg width=\"1\">"
        let r = try XCTUnwrap(TextSearch.range(of: "<svg ", in: text))
        XCTAssertEqual(String(text[r]), "<svg ")
        XCTAssertTrue(TextSearch.contains(text, "\u{E260}"))
        XCTAssertTrue(TextSearch.contains(text, "♩"))
    }

    /// A string bridged from an NSString (what the regex passes hand back)
    /// has no UTF-8 of its own to lend; it is searched all the same.
    func testBridgedString() {
        let bridged = NSMutableString(string: page) as String
        XCTAssertTrue(TextSearch.contains(bridged, "labelAttr"))
        XCTAssertFalse(TextSearch.contains(bridged, "harm"))
        XCTAssertEqual(TextSearch.range(of: "<text", in: bridged), bridged.range(of: "<text"))
    }

    func testOccursTwice() {
        XCTAssertFalse(TextSearch.occursTwice("<rehearsal", in: "<rehearsal>A</rehearsal>"))
        XCTAssertTrue(TextSearch.occursTwice(
            "<rehearsal", in: "<rehearsal>A</rehearsal><rehearsal>B</rehearsal>"))
        XCTAssertFalse(TextSearch.occursTwice("<rehearsal", in: ""))
        // overlapping occurrences are one occurrence, as two searches made it
        XCTAssertFalse(TextSearch.occursTwice("aa", in: "aaa"))
        XCTAssertTrue(TextSearch.occursTwice("aa", in: "aaaa"))
    }

    func testEmptyNeedleIsNotFound() {
        XCTAssertFalse(TextSearch.contains(page, ""))
        XCTAssertFalse(TextSearch.contains("", "a"))
    }

    // MARK: - Elements, found as the lazy pattern finds them

    private func regexRanges(_ pattern: String, _ text: String) -> [NSRange] {
        let re = try! NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        return re.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
            .map(\.range)
    }

    /// The fingering lift's passes found their blocks with
    /// `<(chord|note)\b[^>]*>.*?</\1>` and `<staff\b[^>]*>.*?</staff>`; the
    /// literal scan that replaced them must find exactly the same ranges,
    /// including where the pattern's own rules are surprising.
    func testElementRangesAreThePatternsMatches() {
        let texts = [
            // a chord holding notes, then a lone note, across lines
            "<chord xml:id=\"c\">\n<note a=\"1\"><verse n=\"1\"/></note>\n<note/></chord><note b=\"2\">x</note>",
            // a self-closed note runs on to the next </note>, as the pattern does
            "<note id=\"a\"/><rest/><note>y</note><note>z</note>",
            // a name that only starts like one is not it
            "<notes>q</notes><noteX>r</noteX><note>s</note><chordal/>",
            // an opening with no closing tag is passed over
            "<note><verse/>never closed <chord>k</chord>",
            // text in other scripts before, inside and between
            "é♩<note>Ban–bridge ♩</note>ü<chord>ö<note>ñ</note></chord>\u{E260}",
            "", "<note", "<note>", "<chord></note></chord>",
        ]
        for text in texts {
            let ns = NSString(string: text)
            XCTAssertEqual(TextSearch.elementRanges(named: ["chord", "note"], in: ns),
                           regexRanges("<(chord|note)\\b[^>]*>.*?</\\1>", text), text)
            XCTAssertEqual(TextSearch.elementRanges(named: ["note"], in: ns),
                           regexRanges("<note\\b[^>]*>.*?</note>", text), text)
        }
        let staves = "<staffDef n=\"1\"/><staff n=\"1\"><layer/></staff><staff n=\"2\">\n</staff>"
        XCTAssertEqual(TextSearch.elementRanges(named: ["staff"], in: NSString(string: staves)),
                       regexRanges("<staff\\b[^>]*>.*?</staff>", staves))
    }
}
