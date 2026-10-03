import CoreGraphics
import Foundation

/// The Verovio option set for one layout, as the JSON string the toolkit takes.
///
/// Pure, and here rather than inside `VerovioRenderer`, because the bug this
/// type exists to prevent is not visible in a picture of the render: it is what
/// Verovio DOES with two option sets given one after the other.
///
/// ## setOptions MERGES; it does not replace
///
/// Verovio's `setOptions` sets the options the JSON names and leaves every
/// other option at whatever it already was. It does not reset the rest to
/// their defaults.
///
/// The two option sets used to differ by naming `breaks` in the continuous one
/// and not naming it at all in the paged one. So the first continuous engrave
/// set `breaks: "none"` on the shared toolkit and NOTHING ever set it back:
/// every paged engrave for the rest of the process laid the whole score out as
/// one system on one enormous page. Measured on the nine-page arrangement in
/// the workspace, in the engine's own Verovio:
///
///     fresh toolkit  -> paged options        9 pages, breaks = auto
///     fresh toolkit  -> continuous options   1 page,  breaks = none
///     the same one   -> paged options        1 page,  breaks = none   <-- the bug
///     with breaks named in the paged set     9 pages, breaks = auto
///
/// That one line is the root of three reported faults. Pagination gone and the
/// counter reading "p. 1 / 1" is the page count above. Blur is that same strip
/// -- 17000pt wide -- rastered through the paged canvas, which caps a page at
/// 5200px and so drew it at a quarter resolution; the shading flip between one
/// page and two is the same cap landing on a different size. Garbled thumbnails
/// are the whole score squeezed into a page-shaped box.
///
/// So: **every option that differs between the layouts is named in BOTH sets.**
/// Anything else is a value one layout can leave behind for the other to find.
enum EngravingOptions {

    /// A page is a FIXED size: US Letter portrait, which is what the sources
    /// are. Verovio lays out in TENTHS OF A MILLIMETRE -- its own A4 default,
    /// 2100 x 2970, is 210 x 297mm -- so US Letter is 2159 x 2794. Mirrors
    /// render.py's PAGE_WIDTH_TENTHS_MM / PAGE_HEIGHT_TENTHS_MM; keep the two
    /// in step.
    static let pageWidthTenthsMM = 2159
    static let pageHeightTenthsMM = 2794

    /// The engraving scale, as a percentage. Also the conversion from Verovio's
    /// tenths of a millimetre to the points it emits: Verovio writes the page
    /// as `units * scale/100` pixels.
    static let scale = 45

    /// The engraved page in the PDF's own points, which is what the canvas
    /// measures and what `ContinuousTiles` needs in order to say how big a
    /// notehead is on a fitted page. 2159 x 0.45 = 971.55, and Verovio's own
    /// SVG for these options reports 972 x 1258.
    static var pageSize: CGSize {
        CGSize(width: CGFloat(pageWidthTenthsMM) * CGFloat(scale) / 100,
               height: CGFloat(pageHeightTenthsMM) * CGFloat(scale) / 100)
    }

    /// How Verovio breaks systems, per layout.
    ///
    /// `none` puts every system on one line and is what makes the continuous
    /// surface a strip. `auto` is Verovio's own line and page breaking.
    /// `encoded` breaks where the NOTATION says, which is what `ops.paginate`
    /// writes when a reader asks for four bars to a line or for a new line at
    /// bar 17. `render.breaks_for` makes the same choice for the PDF, so a page
    /// on the iPad and a page in an export are broken the same way.
    ///
    /// `auto` ignores encoded breaks outright, so a READER'S pagination needs
    /// `encoded` to be seen -- and ONLY a reader's. Asked for unconditionally
    /// first, it laid out every imported file by its SOURCE EDITION's breaks:
    /// the string-quartet fixture went from 8 pages to its publisher's 4, at
    /// eight and a half bars a line, and the release gate caught it. A file
    /// from MuseScore, Finale, Sibelius or Audiveris carries those breaks for
    /// another engraver's page. So `ops.paginate` marks the score, and only a
    /// marked score is drawn `encoded`; every other one exactly as before.
    /// render.breaks_for is the export side; check_pagination.py holds both.
    ///
    /// The strip stays `none` -- it is one system by definition.
    static func breaks(continuous: Bool, readerPaginated: Bool = false) -> String {
        // `line`, not `encoded`: see render.breaks_for. `encoded` breaks pages
        // only where the notation says, and a reader's pagination says none,
        // so a long paginated score was one page running off its foot.
        continuous ? "none" : (readerPaginated ? "line" : "auto")
    }

    /// The mark a reader's own pagination carries. Mirrors ops.PAGINATION_FIELD.
    static let paginationField = "scoranger-pagination"

    /// Has the READER laid this score out, as opposed to its source edition?
    static func readerPaginated(inMusicXML xml: String) -> Bool {
        xml.range(of: "<miscellaneous-field[^>]*name=\"\(paginationField)\"[^>]*>\\s*reader\\s*</miscellaneous-field>",
                  options: .regularExpression) != nil
    }

    /// A page's top and bottom margins are paper: they keep a printed page
    /// readable. The continuous strip is not paper -- it is trimmed to its one
    /// system by `adjustPageHeight`, and those margins then become 20% of the
    /// strip's height, which is 20% of the music's size on screen for nothing.
    /// The left/right margins stay: they are the run-in before the first clef
    /// and the run-out after the last bar.
    static func verticalMargin(continuous: Bool) -> Int { continuous ? 10 : 100 }

    /// `adjustPageHeight` trims the page to its own content. On the strip that
    /// is what makes it a strip. On paper it is wrong: a page holding less
    /// music would be a SHORTER page, and a two-page spread would show the left
    /// leaf's bottom edge above the right's.
    static func adjustPageHeight(continuous: Bool) -> Bool { continuous }

    /// Whether the systems are spread down the page (Ali, 2026-09-14 item 8).
    ///
    /// Verovio stacks systems from the top of a fixed sheet and breaks when
    /// the next one will not fit, leaving whatever is left as blank paper at
    /// the bottom. On the seeded string quartet, measured with the engine's
    /// own Verovio and this exact option set:
    ///
    ///     page  systems  blank at the foot
    ///       1      3          12.8%
    ///       3      2          38.2%   <-- "two systems and then about a
    ///       4      4          38.8%        third of the sheet is blank"
    ///
    /// With the systems justified the same pages come out at 8.3%, 18.2% and
    /// 18.8%. It is the engraver's answer and it changes nothing else: the
    /// page keeps its size, the breaking is identical, the notation is the
    /// same size, and a spread still shows two leaves of one height.
    ///
    /// The alternative was `adjustPageHeight` on paper, which trims each page
    /// to its own content and would draw the music BIGGER -- and gives every
    /// page a different height, which is what a spread and a thumbnail rail
    /// cannot have. That trade stays refused; see `adjustPageHeight` above.
    ///
    /// Off for the strip, which has one system and is trimmed to it.
    static func justifyVertically(continuous: Bool) -> Bool { !continuous }

    /// The whole option set, with every layout-dependent option named.
    ///
    /// `spacing` is the score's own (`StaffSpacing.values(inMusicXML:)`), and
    /// its two Verovio keys are named EVERY time, defaults included, for the
    /// reason `breaks` is: the toolkit is shared and `setOptions` merges, so a
    /// score that asked for wide staves would otherwise leave them wide for the
    /// next score, which asked for nothing.
    static func json(lyricSize: Double, continuous: Bool,
                     spacing: StaffSpacing.Values = StaffSpacing.defaults,
                     readerPaginated: Bool = false,
                     measureNumbers: MeasureNumbers.Mode = .system) -> String {
        """
        {"scale": \(scale), "footer": "none",
         "breaks": "\(breaks(continuous: continuous, readerPaginated: readerPaginated))",
         "spacingStaff": \(spacing.staff), "spacingSystem": \(spacing.system),
         "mnumInterval": \(MeasureNumbers.interval(measureNumbers)),
         "adjustPageHeight": \(adjustPageHeight(continuous: continuous)),
         "justifyVertically": \(justifyVertically(continuous: continuous)),
         "pageWidth": \(pageWidthTenthsMM), "pageHeight": \(pageHeightTenthsMM),
         "pageMarginTop": \(verticalMargin(continuous: continuous)),
         "pageMarginBottom": \(verticalMargin(continuous: continuous)),
         "pageMarginLeft": 120, "pageMarginRight": 120,
         "lyricSize": \(lyricSize)}
        """
    }

    /// The keys that must appear in EVERY option set, whatever the layout.
    ///
    /// Named here so the test asserting it is asserting a rule rather than a
    /// list someone happened to type twice.
    static let layoutDependentKeys = ["breaks", "adjustPageHeight",
                                      "justifyVertically",
                                      "pageMarginTop", "pageMarginBottom"]

    /// The keys that depend on the SCORE rather than the layout, and must be
    /// named in every option set for the same reason: a merge would otherwise
    /// carry one score's spacing to the next.
    static let scoreDependentKeys = ["spacingStaff", "spacingSystem", "mnumInterval"]
}
