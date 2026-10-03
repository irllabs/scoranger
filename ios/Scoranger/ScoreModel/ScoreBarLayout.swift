import CoreGraphics

/// What the score's top bar shows at a given width, and in what order things
/// yield when there is not enough of it.
///
/// #60: on a phone the bar had no ✕ at all. The version count added beside the
/// title pushed it out, and with no ✕ there is no way to leave the score --
/// a dead end, on the one screen size where there is no other route back. It
/// was present in build 149 and gone in 152.
///
/// The fix is not to shorten one control. It is to say ONCE what the bar gives
/// up first, so the next thing added to it cannot squeeze out the way out:
///
///   1. ✕ close          FIXED. Never yields. Without it the score is a trap.
///   2. Select ⌖, Ask, … the actions the score view exists for. ⌖ joins them
///                       in 0.6.14 and does NOT yield, because a phone has no
///                       Pencil: with ⌖ off the bar there is no way to draw a
///                       lasso at all, and that is a feature rather than a
///                       shortcut. It takes Edit's place at the narrow end.
///   2b. Edit            yields on a phone. Markup is still reachable -- the
///                       Options screen's own Annotations row opens it and
///                       says whether it is on -- so this costs two taps, not
///                       a feature. §3 E-A asked for exactly this and named
///                       the cost.
///   3. OMR progress     only exists while a transcription runs, and while it
///                       does it is the only sign in the score view that
///                       anything is happening -- so it outranks both
///                       switches. It yields only where seating it would take
///                       the bar below its floor, which is what #60 was.
///   4. the two switches Performance mode and Show transport, TOGETHER: they
///                       are the same kind of control and they share one
///                       fallback, and a bar showing one and not the other
///                       reads as arbitrary. Optional -- Options carries both
///                       at exactly the widths the bar does not (0.6.8).
///   5. layout control   three cells, then two
///   6. the title        flexible: it truncates, it does not disappear
///   7. version count    optional -- the title block opens the same band, so
///                       nothing becomes unreachable when it goes
///   8. add to set list   optional, and the FIRST to go (0.6.11). Every op in
///                       this app makes a version, so the count above is a
///                       shortcut to something a reader reaches constantly;
///                       putting an arrangement in a set list is organising,
///                       done occasionally, and the library's own set list
///                       picker still does it from the other direction. So
///                       this drops a shortcut, never a feature.
///
/// Item 8 was a "Pencil: select" chip until 0.6.10, which yielded before
/// everything above it. Ali asked for it off the bar, freeing 90pt at every
/// width -- which is what left room to seat the + here without taking
/// anything else off a narrow bar. The mode itself is not lost -- the Edit
/// button's own active state shows it, and Selection & chat states it in
/// words.
///
/// Nothing above the line an item sits on is ever sacrificed for it.
enum ScoreBarLayout {
    struct Fit: Equatable {
        /// The "N versions" dropdown trigger.
        var showsVersions: Bool
        /// The + that puts this arrangement in a set list (0.6.11 #1).
        ///
        /// Last in the yield order and so the first to go. Defaulted, unlike
        /// `showsVersions`, because every existing `Fit(...)` in the tests and
        /// in `ScoreScreens` names the fields it cares about and a new
        /// REQUIRED field would have meant editing all of them to say
        /// "and not this either".
        var showsAddToSetlist: Bool = false
        /// Cells in the layout control: 3 (page/spread/continuous) or 2
        /// (page/continuous -- a spread across a phone is two thumbnails).
        var layoutCells: Int
        /// The "Show transport" toggle, beside the layout cells (0.6.3 #6).
        ///
        /// Optional, and the Options screen keeps the same switch AT EXACTLY
        /// THESE WIDTHS: a bar too narrow to seat it must not be a bar with no
        /// way to turn playback's chrome back on. Dropping a SHORTCUT is
        /// allowed here; dropping a feature is not.
        var showsTransportToggle: Bool = true
        /// The "Performance mode" toggle, beside the transport (0.6.8).
        ///
        /// It moves with `showsTransportToggle` and is never separately false:
        /// see the yield order above. Kept as its own flag rather than read off
        /// the transport's, because a reader of `ScoreOptionsScreen` asking
        /// "is Performance mode on the bar?" should not have to know that.
        var showsPerformanceToggle: Bool = true
        /// ‹ carries the origin's name [C6] when there is room; a bare ‹ when
        /// there is not. The name is a courtesy, the way out is a necessity.
        var showsOriginName: Bool = true
        /// The transcription chip at the trailing end of the bar, drawn only
        /// while OMR is actually running (`AppState.omrBusy`).
        var showsOMRProgress: Bool = false
        /// The pencil that turns markup on.
        ///
        /// Yields on a phone, where ⌖ needs the room more: markup has a second
        /// door (Options -> Annotations, which states its own on/off) and the
        /// lasso has none.
        var showsEdit: Bool = true
        /// The ⌖ that arms Select (§9.3).
        ///
        /// Never false. It is in `essentials` rather than in the yield order,
        /// because on a phone it is the ONLY way to draw a lasso -- the iPad
        /// reaches one with the Pencil and a phone has no Pencil. Kept as a
        /// field anyway so `fits` reads as a list of what is on the bar.
        var showsSelectArm: Bool = true
        /// The "#N" badge: which arrangement of the piece this is.
        var showsNumeral: Bool = true
        /// The PHONE's second row (Ph4): the layout control, Perform and +
        /// sit in a 34pt row of their own above the tray, and the bar keeps
        /// back, title, Pencil, Select, Ask and More.
        ///
        /// It is not a yield step. The three controls do not compete with the
        /// bar for width at all once they have a row; what the phone gets out
        /// of it is the PENCIL back on the bar, which every step of the yield
        /// order above had to take off it.
        var secondRow: Bool = false
        /// The second line under the title: piece name and version.
        ///
        /// Costs no WIDTH -- it is a second line in the same column -- so it is
        /// not in `fits`. It goes on a narrow bar anyway: two truncated lines
        /// read worse than one whole one, and its piece name largely repeats
        /// the title while its version is what the dropdown behind the title
        /// says.
        var showsSubtitle: Bool = true

        /// Whether the title should EXPAND into the bar's slack rather than
        /// sit centred between two spacers.
        ///
        /// A SwiftUI Text yields before a Spacer does, so on a narrow bar the
        /// title collapsed to an ellipsis while the spacers kept their space.
        /// Expanding is the fix that cannot overflow -- unlike a hard minimum,
        /// which pushed the ✕ off the bar (#60, reproduced while fixing #62).
        var titleExpands: Bool { !showsNumeral }

        /// Whether the OPTIONS screen carries each switch: exactly where the
        /// bar does not (0.6.8).
        ///
        /// Stated here rather than as a `!` at each call site, because it is
        /// the invariant and not a convenience: a switch belongs in exactly one
        /// of the two places at every width. In both, and they drift; in
        /// neither, and the feature is gone. `ScoreOptionsScreen` reads these,
        /// `ScoreTopBar` reads the pair above them, and both are handed the
        /// same `Fit` from the one measurement `ContentView` owns.
        var optionsCarriesPerformanceToggle: Bool { !showsPerformanceToggle && !secondRow }
        var optionsCarriesTransportToggle: Bool { !showsTransportToggle }
        /// The Options screen's Annotations row is markup's second door, and
        /// it is the only one at the widths the bar has yielded the pencil.
        /// It is on that screen at EVERY width -- unlike the two switches
        /// above, which are in exactly one place -- because it also says
        /// whether markup is currently on, which the bar's button shows only
        /// while the bar has it.
        var optionsCarriesEdit: Bool { !showsEdit }

        /// Print (0.17.0, Ali: "a print button ... in the top bar along with
        /// the other buttons"). FALSE by default, so every narrower rung of
        /// the ladder below drops it without naming it; the wide rungs seat it.
        /// Where it is not on the bar, More carries it.
        var showsPrint: Bool = false
        var optionsCarriesPrint: Bool { !showsPrint }
    }

    /// Measured widths of the bar's parts, so the arithmetic below is legible
    /// rather than a table of magic numbers.
    /// The way out: ‹ alone, a 34pt capsule. FIXED, as ever.
    static let closeWidth: CGFloat = 34
    /// What the origin's NAME adds to it [C6]: a 6pt gap, a word capped at
    /// 140 in the view, and the capsule's 24 of padding less the 34 the bare
    /// glyph already had. An optional seat, and the FIRST to yield: a
    /// courtesy about where the reader was, ahead of every shortcut.
    static let originNameWidth: CGFloat = 6 + 140 + 24 - 34 + 15
    static let actionWidth: CGFloat = 34          // Edit, Select, Ask, …
    static let gap: CGFloat = 8
    static let padding: CGFloat = 24              // s12 either side
    static let threeCells: CGFloat = 40 * 3 + 2   // cells plus their dividers
    static let twoCells: CGFloat = 40 * 2 + 1
    static let versionsWidth: CGFloat = 110
    /// The + and the gap before it. The same button as Edit and Ask.
    static let addToSetlistWidth: CGFloat = actionWidth + gap
    static let printWidth: CGFloat = actionWidth + gap
    /// The transport toggle and the gap before it.
    /// Retired in 0.8: the tray is always there. Kept at zero so the Fit's
    /// field and the switch arithmetic need not move.
    static let transportWidth: CGFloat = 0
    /// "Perform", glyph AND word [C5], and the gap before it: 15 + 6 + ~52 of
    /// Inter 600 13.5 + 24 of padding, rounded up.
    static let performanceWidth: CGFloat = 100 + 8
    /// Both switches, which yield as one step.
    static var switchesWidth: CGFloat { transportWidth + performanceWidth }
    /// The transcription chip and the gap before it: a determinate ring and one
    /// line of words.
    ///
    /// Wide enough for the longest thing it says -- "waiting (1 ahead)…", and
    /// "page 12 of 12" once Audiveris starts. It was 122 and compressed both to
    /// an ellipsis, which is a readout that has stopped being one; the words
    /// were shortened as well (MakeEditable.converting).
    static let omrWidth: CGFloat = 142 + 8
    static let numeralWidth: CGFloat = 40
    /// Less than this and the title is not a title any more.
    ///
    /// 90, not 100: the narrowest common iPhone is 375pt, and the essentials
    /// plus two layout cells plus 100 came to 381 -- six points over. A hard
    /// minimum that does not fit is how something gets pushed off the bar, and
    /// that is #60.
    static let titleMinimum: CGFloat = 90

    /// The pencil and the gap before it. The same button as Ask.
    static let editWidth: CGFloat = actionWidth + gap

    /// The bar's fixed furniture: the way out, ⌖, Ask, …, and their gaps.
    ///
    /// THREE actions, and Edit is not one of them any more -- it is counted
    /// separately by `editWidth` because it is the one that yields. The sum is
    /// unchanged for a bar that still seats the pencil, so every threshold
    /// below means what it did before 0.6.14.
    static var essentials: CGFloat {
        padding + closeWidth + actionWidth * 3 + gap * 5
    }

    /// The narrowest the bar can be and still hold ✕, ⌖, Ask, …, two layout
    /// cells and a readable title. Nothing may be seated that takes it below
    /// this: that is #60.
    ///
    /// It is the same 371 it was before ⌖ existed, because ⌖ took the pencil's
    /// place rather than being added beside it. A phone at 393 has 22pt of
    /// slack and the narrowest common iPhone, 375, has four.
    static var floor: CGFloat { essentials + twoCells + titleMinimum }

    /// What the bar shows, given its width and whether a transcription is
    /// running.
    ///
    /// The chip is seated FIRST and out of the same width, so everything below
    /// it in the order yields to it rather than the other way round. It yields
    /// itself only where seating it would take the bar under its floor -- on a
    /// phone, which has about four points of slack at reading width. There the
    /// score view still says a transcription is running: `ContentView` draws
    /// the same chip over the canvas instead. One chip, one signal, two places
    /// it can sit.
    static func fit(barWidth: CGFloat, omrBusy: Bool = false,
                    compact: Bool = false) -> Fit {
        if compact {
            var fit = phoneLayout(barWidth: barWidth)
            // The chip is seated only where it genuinely fits beside what the
            // bar already holds; everywhere else `ContentView` draws it over
            // the canvas, which is the arrangement 0.6.8 settled.
            if omrBusy, barWidth > 0 {
                var withChip = fit
                withChip.showsOMRProgress = true
                if fits(withChip, in: barWidth) { fit = withChip }
            }
            return fit
        }
        let seatsOMR = omrBusy && barWidth > 0 && barWidth - omrWidth >= floor
        var fit = layout(barWidth: seatsOMR ? barWidth - omrWidth : barWidth)
        fit.showsOMRProgress = seatsOMR
        return fit
    }

    /// The phone's bar, with the second row carrying three of its controls
    /// (Ph4).
    ///
    /// Everything the yield order took off a narrow bar -- the pencil first,
    /// then the title's own companions -- was taken to make room for the
    /// layout cells, Perform and the +. Given those a row of their own, the
    /// bar has 150pt it did not have, which is enough for the pencil AND the
    /// numeral AND the subtitle at 375. The origin's NAME still yields first
    /// [C6]: 151pt for a courtesy is what no phone has.
    static func phoneLayout(barWidth: CGFloat) -> Fit {
        let everything = Fit(showsVersions: false, showsAddToSetlist: false,
                             layoutCells: 0, showsTransportToggle: false,
                             showsPerformanceToggle: false, showsOriginName: true,
                             secondRow: true)
        guard barWidth > 0 else { return everything }
        var ladder = [everything]
        var step = everything
        step.showsOriginName = false;  ladder.append(step)
        step.showsSubtitle = false;    ladder.append(step)
        step.showsNumeral = false;     ladder.append(step)
        // And, last, the pencil -- which is where the old ladder started.
        // Nothing reaches this rung on a phone the app supports (it needs
        // less than 332pt), but the bar must not overflow at a width nobody
        // has rather than yield one more control, because that is #60.
        step.showsEdit = false;        ladder.append(step)
        return ladder.first { fits($0, in: barWidth) } ?? step
    }

    /// What the second row seats, and in what order IT yields: the + first,
    /// as on the bar (0.6.11), then Perform's word, and never the layout
    /// cells -- which is what the row exists to carry.
    static let secondRowCells: CGFloat = twoCells
    static func secondRowFitsPlus(width: CGFloat) -> Bool {
        width >= padding + secondRowCells + gap + performanceWidth + addToSetlistWidth
    }

    private static func layout(barWidth: CGFloat) -> Fit {
        var everything = Fit(showsVersions: true, showsAddToSetlist: true,
                             layoutCells: 3)
        everything.showsPrint = true
        // Unmeasured: show everything rather than flashing a stripped bar on
        // the first frame and filling it in afterwards.
        guard barWidth > 0 else { return everything }

        // The numeral is in every threshold below, because it is on the bar in
        // every one of those fits. It was left out of the arithmetic here while
        // `fits` counted it, so the two disagreed by 40pt and the steps between
        // 696 and 736 claimed to fit a bar they overflowed. No real device sits
        // in that band, which is why five discrete widths never found it; the
        // sweep that seats the transcription chip did, because the chip moves
        // every threshold by its own width.
        let base = essentials + editWidth + titleMinimum + numeralWidth
        let forAll = base + threeCells + versionsWidth + switchesWidth
            + addToSetlistWidth + printWidth + originNameWidth
        if barWidth >= forAll { return everything }

        // The origin's NAME beside the ‹ goes first [C6]: a bare ‹ still
        // leaves, and the name is a courtesy about where the reader was. On
        // an iPad in portrait (834) it is what yields; in landscape it fits.
        let withoutOriginName = forAll - originNameWidth
        if barWidth >= withoutOriginName {
            var fit = Fit(showsVersions: true, showsAddToSetlist: true, layoutCells: 3,
                          showsOriginName: false)
            fit.showsPrint = true
            return fit
        }
        // Then the +: the library's set list picker still offers the same
        // operation, so this costs a shortcut rather than a feature.
        let withoutAdd = withoutOriginName - addToSetlistWidth
        if barWidth >= withoutAdd {
            var fit = Fit(showsVersions: true, layoutCells: 3, showsOriginName: false)
            fit.showsPrint = true
            return fit
        }
        // Then Print, which More carries at every width the bar does not.
        let withoutPrint = withoutAdd - printWidth
        if barWidth >= withoutPrint {
            return Fit(showsVersions: true, layoutCells: 3, showsOriginName: false)
        }
        // Then the version count. The title block opens VERSIONS when this
        // has gone, so versions stay REACHABLE -- this drops a shortcut, never
        // a feature. That invariant was briefly untrue: 0.6.3 #8 split the band
        // so the title opened arrangements only, and a phone at reading width
        // had no route to versions at all. Whoever changes what the title opens
        // must keep this true (ScoreTopBar.titleBlock).
        let withoutVersions = withoutPrint - versionsWidth
        if barWidth >= withoutVersions {
            return Fit(showsVersions: false, layoutCells: 3, showsOriginName: false)
        }
        // Then BOTH switches, together. Options carries both at exactly the
        // widths the bar does not (ScoreOptionsScreen reads this same Fit), and
        // the transport reveals itself on the first playable arrangement anyway
        // (TransportReveal) -- so a phone loses two shortcuts and nothing else.
        let withoutSwitches = withoutVersions - switchesWidth
        if barWidth >= withoutSwitches {
            return Fit(showsVersions: false, layoutCells: 3,
                       showsTransportToggle: false, showsPerformanceToggle: false,
                       showsOriginName: false)
        }
        // Then the spread cell, which is the one a narrow screen cannot use.
        let twoCellFit = Fit(showsVersions: false, layoutCells: 2,
                             showsTransportToggle: false, showsPerformanceToggle: false,
                             showsOriginName: false)
        if fits(twoCellFit, in: barWidth) { return twoCellFit }

        // Then the PENCIL, and this is the step 0.6.14 added. A phone reaches
        // markup through Options -> Annotations, which also states whether it
        // is on; it reaches a lasso through ⌖ and nowhere else, because it has
        // no Pencil. So the pencil yields and ⌖ stays. §3 E-A asked for this
        // and named the cost: Edit becomes two taps on the screen where markup
        // is most wanted.
        let withoutEdit = Fit(showsVersions: false, layoutCells: 2,
                              showsTransportToggle: false,
                              showsPerformanceToggle: false,
                              showsOriginName: false, showsEdit: false)
        if fits(withoutEdit, in: barWidth) { return withoutEdit }

        // Then the title's COMPANIONS, so the title itself can stay readable.
        // #62: with the version count already yielded, the title block is the
        // only route to the version dropdown -- and it had collapsed to
        // "#1 S… ⌄", which nobody reads as a control. The subtitle goes first
        // (its piece name largely repeats the title, and its version is what
        // the dropdown behind the title says), then the numeral.
        //
        // They yield rather than the title being given a hard minimum: forcing
        // a width here pushed the ✕ off the bar entirely, which is #60.
        let withoutSubtitle = Fit(showsVersions: false, layoutCells: 2,
                                  showsTransportToggle: false,
                                  showsPerformanceToggle: false,
                                  showsOriginName: false, showsEdit: false,
                                  showsSubtitle: false)
        if fits(withoutSubtitle, in: barWidth) { return withoutSubtitle }
        return Fit(showsVersions: false, layoutCells: 2,
                   showsTransportToggle: false, showsPerformanceToggle: false,
                   showsOriginName: false, showsEdit: false, showsNumeral: false,
                   showsSubtitle: false)
    }

    /// Whether a bar this wide can seat everything it is being asked to.
    /// Used by the test that guards the phone.
    static func fits(_ fit: Fit, in width: CGFloat) -> Bool {
        var needed = essentials + titleMinimum
        if fit.layoutCells >= 3 { needed += threeCells }
        else if fit.layoutCells == 2 { needed += twoCells }
        // 0 cells: the phone's second row has them (Ph4).
        if fit.showsEdit { needed += editWidth }
        if fit.showsVersions { needed += versionsWidth }
        if fit.showsAddToSetlist { needed += addToSetlistWidth }
        if fit.showsPrint { needed += printWidth }
        if fit.showsTransportToggle { needed += transportWidth }
        if fit.showsPerformanceToggle { needed += performanceWidth }
        if fit.showsOriginName { needed += originNameWidth }
        if fit.showsOMRProgress { needed += omrWidth }
        if fit.showsNumeral { needed += numeralWidth }
        return needed <= width
    }
}
