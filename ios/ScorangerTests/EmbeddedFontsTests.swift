import SwiftDraw
import XCTest

/// The music font a page embeds, registered once and taken out of the page
/// (`EmbeddedFonts`). What matters is that the page draws the same: SwiftDraw
/// parses a page into its drawing commands, and those are compared whole.
final class EmbeddedFontsTests: XCTestCase {

    /// A real engraving whose tempo mark draws a SMuFL note in Leipzig, which
    /// Verovio embeds. Built by `engine/scripts/make_marks_fixture.py`.
    private func marksPage() throws -> String {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: "marks", withExtension: "svg",
                                           subdirectory: "Fixtures"), "missing fixture marks.svg")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testThePageDrawsTheSameWithoutItsEmbeddedFont() throws {
        let page = try marksPage()
        XCTAssertTrue(page.contains("@font-face"), "the fixture no longer embeds a font")
        let lifted = EmbeddedFonts.lifted(from: page)
        XCTAssertFalse(lifted.contains("@font-face"), "the font was not taken out")
        XCTAssertLessThan(lifted.utf8.count, page.utf8.count - 10_000)
        let before = try XCTUnwrap(SVG(data: Data(page.utf8)))
        let after = try XCTUnwrap(SVG(data: Data(lifted.utf8)))
        XCTAssertEqual(before, after, "the page draws differently without its embedded font")
    }

    /// The control: text in the family has to reach the page at all, or the
    /// comparison above passes with nothing drawn.
    func testTheGlyphIsDrawnInTheFont() throws {
        _ = EmbeddedFonts.lifted(from: try marksPage())
        func drawn(_ family: String) throws -> SVG {
            try XCTUnwrap(SVG(data: Data("""
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200" width="200" height="200">
            <text x="10" y="150" font-family="\(family)" font-size="120px">\u{E1D5}</text>
            </svg>
            """.utf8)))
        }
        // a family nothing answers to is drawn in SwiftDraw's fallback
        XCTAssertNotEqual(try drawn("Leipzig"), try drawn("ScorangerNoSuchFamily"),
                          "the SMuFL note drew in the fallback font: Leipzig did not resolve")
    }

    /// A font embedded under a family it is not named (here Leipzig as
    /// 'Times'), and a font that will not decode, are not registered: both
    /// pages keep the rule.
    func testAFontThatIsNotOursIsLeftInThePage() throws {
        let page = try marksPage()
        let times = page.replacingOccurrences(of: "font-family: 'Leipzig'",
                                              with: "font-family: 'Times'")
        XCTAssertEqual(EmbeddedFonts.lifted(from: times), times)
        let broken = """
        <svg><style type="text/css">@font-face {
            font-family: 'ScorangerNoSuchFont';
            src: url(data:application/font-woff2;charset=utf-8;base64,AAAA) format('woff2');
        }</style></svg>
        """
        XCTAssertEqual(EmbeddedFonts.lifted(from: broken), broken)
    }
}
