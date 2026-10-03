import SwiftUI
import UIKit

/// The design system's tokens: "Notebook" (0.8) — a rehearsal notebook on a
/// warm table: pages of `panel` on a `band` ground, capsule controls, dashed
/// rules instead of borders, the arrangement numeral stamped in a clay ring.
/// Spec: design/DESIGN_SYSTEM.md; the sixteen binding rules are its §0.
/// Light only, by decision, so nothing here consults the colour scheme.
///
/// 0.8.0 is TOKENS ONLY (§12 stage 1): values here change, shapes do not.
/// Every existing view restyles through these.
enum Theme {

    // Transitional aliases from build 116's placeholder Theme. Every call site
    // moves onto the tokens below as its view is restyled; these go with the
    // last one.
    static let structure = Accent.clay
    static let arrangementNumber = Accent.clay

    // MARK: - Colour (§1)

    /// Surfaces (§1). Values unchanged from 0.7; ROLES changed:
    /// `band` is the table -- the app's base colour behind every page --
    /// `panel` is a page, `well` a control at rest, `paper` the score page and
    /// the inside of a text field and nothing else.
    enum Surface {
        static let paper  = Color(hex: 0xFFFFFF)
        /// Retired in 0.8 (§1): kept one release for the transition, no new
        /// use. Every 0.7 ground repointed to `band` in 0.8.0.
        static let ground = Color(hex: 0xF4F0E8)
        static let panel  = Color(hex: 0xFAF7F1)
        static let well   = Color(hex: 0xEFEAE0)
        static let band   = Color(hex: 0xF1ECE2)
    }

    /// Ink. `ink3` is supplementary only: never the sole carrier of meaning.
    enum Ink {
        static let ink  = Color(hex: 0x1A1917)
        static let ink2 = Color(hex: 0x6B655C)
        static let ink3 = Color(hex: 0x8A8378)
    }

    /// The single accent. `clay` is restricted to ≥15pt semibold text, numerals,
    /// icons and borders; small accent text uses `clayStrong`.
    enum Accent {
        static let clay       = Color(hex: 0xCC5C2E)
        static let clayStrong = Color(hex: 0xA8481F)
        static let clayPress  = Color(hex: 0xB14D22)
        static let clayTint   = Color(hex: 0xF7E7DD)
        /// Border for the user's chat bubble, per §7.7.
        static let clayBorder = Color(hex: 0xE7C4B1)
    }

    /// System status, deliberately outside the three-colour budget and never
    /// used decoratively.
    enum Status {
        static let ok     = Color(hex: 0x3BA05C)
        static let warn   = Color(hex: 0xC8791B)
        static let danger = Color(hex: 0xC0392B)
        static let highlight = Color(hex: 0xFFE25A).opacity(0.4)
        static let errorFill   = Color(hex: 0xFBEEEC)
        static let errorBorder = Color(hex: 0xE3B4AE)
    }

    /// Pencil inks. Fixed: the user's marks are content, not palette.
    enum Pen {
        static let red   = Color(hex: 0xD64B3F)
        static let blue  = Color(hex: 0x2A6BD6)
        static let green = Color(hex: 0x2E9159)
        static let amber = Color(hex: 0xE08A25)
        static let black = Ink.ink
    }

    enum Line {
        static let line  = Color(hex: 0xE2DBCE)
        static let line2 = Color(hex: 0xCFC6B6)
        static let dim   = Color(hex: 0x1A1917).opacity(0.34)
    }

    // MARK: - Type (§2)

    /// One entry per row of the type table. Carries the tracking and casing the
    /// spec attaches to the role, so callers cannot get them out of step.
    enum Role {
        case numeralXL, numeralL, numeralM
        case title, titleS, panelTitle
        case row, body, control, label, meta
        case data, dataS
        case knobLabel, knobData   // under a tray knob (§7.8): Inter 600 9.5, mono 9.5

        var font: Font { Theme.font(self) }

        /// Tracking in points, converted from the spec's em values (§2).
        var tracking: CGFloat {
            switch self {
            case .numeralXL: return -0.03 * 22
            case .numeralL:  return -0.03 * 15
            case .numeralM:  return -0.03 * 12
            case .title:     return -0.02 * 26
            case .titleS:    return -0.01 * 16
            case .panelTitle: return -0.015 * 20
            // The tracked-out caps label of 0.7 is retired (§2 rule 2): a
            // section label is Inter 600 12, sentence case, no tracking.
            case .label:     return 0
            case .data:      return 0
            default:         return 0
            }
        }

        /// Nothing is uppercased by role any more (§2 rule 2).
        var isUppercase: Bool { false }

        /// Line spacing where the spec pins it.
        var lineSpacing: CGFloat? {
            switch self {
            case .body: return 14 * 0.45
            default:    return nil
            }
        }
    }

    /// Registered face names. Variable fonts report their default instance, so
    /// Space Grotesk arrives as "SpaceGrotesk-Light" and every weight above it
    /// has to come from the wght axis rather than from `.weight()`.
    private enum Face {
        static let grotesk = "SpaceGrotesk-Light"
        static let inter   = "Inter-Regular"
        static let monoRegular = "IBMPlexMono-Regular"
        static let monoMedium  = "IBMPlexMono-Medium"
    }

    /// The 0.8 ladder (§2), one step larger than 0.7 throughout. The roles
    /// keep their 0.7 names so no call site moves in the tokens-only stage;
    /// the mapping to §2's names is in the comments.
    static func font(_ role: Role) -> Font {
        switch role {
        case .numeralXL: return variable(Face.grotesk, 22, 700, .title2)    // stamp in a 56 ring
        case .numeralL:  return variable(Face.grotesk, 15, 700, .title2)    // stamp in a 40 ring
        case .numeralM:  return variable(Face.grotesk, 12, 700, .title2)    // stamp in a 30 ring
        case .title:     return variable(Face.grotesk, 26, 700, .title1)    // headTitle
        case .titleS:    return variable(Face.grotesk, 16, 600, .headline)  // rowName / barTitle
        case .panelTitle: return variable(Face.grotesk, 20, 700, .title3)  // the panel's header (§7.2)
        case .row:       return variable(Face.inter, 14.5, 500, .body)      // panelItem
        case .body:      return variable(Face.inter, 14, 400, .body)        // body
        case .control:   return variable(Face.inter, 13.5, 600, .body)      // control
        case .label:     return variable(Face.inter, 12, 600, .caption1)    // section label, sentence case
        case .meta:      return variable(Face.inter, 12.5, 400, .caption1)  // meta
        case .data:      return staticFace(Face.monoMedium, 12, .caption1)  // data
        case .dataS:     return staticFace(Face.monoRegular, 11, .caption1)
        case .knobLabel: return variable(Face.inter, 9.5, 600, .caption2)
        case .knobData:  return staticFace(Face.monoMedium, 9.5, .caption2)
        }
    }

    /// A weight taken from the font's `wght` variation axis, then scaled for
    /// Dynamic Type against the given text style (§2.5).
    private static func variable(_ name: String, _ size: CGFloat,
                                 _ weight: CGFloat,
                                 _ style: UIFont.TextStyle) -> Font {
        let wght = UIFontDescriptor.AttributeName(
            rawValue: kCTFontVariationAttribute as String)
        let descriptor = UIFontDescriptor(fontAttributes: [
            .name: name,
            // 'wght' as a four-character code
            wght: [0x77676874: weight],
        ])
        let base = UIFont(descriptor: descriptor, size: size)
        return Font(UIFontMetrics(forTextStyle: style).scaledFont(for: base))
    }

    /// The control role as a UIFont at a given text size, for MEASURING a
    /// label before it is drawn (LibraryActionBarMetrics). The same face,
    /// weight and scaling as `.control`, so what is measured is what is drawn.
    static func controlUIFont(for size: DynamicTypeSize) -> UIFont {
        let wght = UIFontDescriptor.AttributeName(
            rawValue: kCTFontVariationAttribute as String)
        let descriptor = UIFontDescriptor(fontAttributes: [
            .name: Face.inter, wght: [0x77676874: 600.0],
        ])
        let base = UIFont(descriptor: descriptor, size: 13.5)
        return UIFontMetrics(forTextStyle: .body).scaledFont(
            for: base, compatibleWith: UITraitCollection(
                preferredContentSizeCategory: TextScale.category(for: size)))
    }

    /// The data role the same way (the bar's "N selected" readout).
    static func dataUIFont(for size: DynamicTypeSize) -> UIFont {
        let base = UIFont(name: Face.monoMedium, size: 12)
            ?? UIFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        return UIFontMetrics(forTextStyle: .caption1).scaledFont(
            for: base, compatibleWith: UITraitCollection(
                preferredContentSizeCategory: TextScale.category(for: size)))
    }

    private static func staticFace(_ name: String, _ size: CGFloat,
                                   _ style: UIFont.TextStyle) -> Font {
        guard let base = UIFont(name: name, size: size) else {
            return Font.system(size: size, design: .monospaced)
        }
        return Font(UIFontMetrics(forTextStyle: style).scaledFont(for: base))
    }

    /// Fails loudly in debug if a face did not register, because the fallback
    /// is silent and the whole look depends on these three families.
    static func verifyFontsRegistered() {
        #if DEBUG
        for name in [Face.grotesk, Face.inter, Face.monoRegular, Face.monoMedium] {
            if UIFont(name: name, size: 12) == nil {
                assertionFailure("font \(name) is not registered — check UIAppFonts")
            }
        }
        #endif
    }

    // MARK: - Metrics (§3, §4)

    enum Metric {
        /// The only spacing values in the app.
        static let s2: CGFloat = 2, s4: CGFloat = 4, s6: CGFloat = 6
        static let s8: CGFloat = 8, s12: CGFloat = 12, s16: CGFloat = 16
        static let s20: CGFloat = 20, s24: CGFloat = 24, s32: CGFloat = 32

        static let panelPadding: CGFloat = 14
        static let rowVertical: CGFloat = 7
        static let rowMinHeight: CGFloat = 36
        static let versionRowVertical: CGFloat = 4
        static let versionIndent: CGFloat = 42
        static let stepIndent: CGFloat = 64
        static let sheetRowVertical: CGFloat = 9
        static let sheetRowMinHeight: CGFloat = 40

        static let libraryWidth: CGFloat = 320
        static let chatWidth: CGFloat = 380
        /// Settings, docked at the trailing edge rather than covering the
        /// screen (#51). Wider than the chat: it holds fields and their notes,
        /// where the chat holds a conversation.
        static let settingsWidth: CGFloat = 460
        // Retired. The spec's fixed page widths (520, and 436 with both panels
        // open) were derived from a 1180pt mockup; enforcing them on a 1032pt
        // iPad left dead bands beside the score and, because the pane is also
        // the scroll view, capped how far zoom could pan. The canvas now takes
        // the full gap between the panels. Kept documented rather than deleted
        // so the numbers are not reintroduced from the spec by mistake.
        /// What the score keeps clear at the bottom of its canvas, so the
        /// docked ink bar never sits on the last system.
        ///
        /// This was `pillHeight`, and the pill lost its score-view role in the
        /// redesign -- the number outlived the thing it measured, which is how
        /// a layout ends up reserving space for something that is not there.
        /// The ink bar is what is down there now: its own 44pt plus the 8pt it
        /// docks off the edge.
        static let scoreBottomChrome: CGFloat = 52
        static let pillButton: CGFloat = 38
        static let hitTarget: CGFloat = 44

        /// Room a library row must keep clear on its trailing edge.
        ///
        /// The row's ☰ is drawn as an OVERLAY -- it has to be, since the row
        /// itself is a button and a button inside a button's label cannot be
        /// tapped -- so the layout knows nothing about it and ran the row's own
        /// content underneath: "v001 · 3 Aug" and the chevron came out sitting
        /// under the ☰. The overlay is one hit target wide with `s8` of its own
        /// trailing padding; this leaves that much plus a gap.
        static let rowMenuInset: CGFloat = hitTarget + s8 + s8
        /// Room for TWO trailing controls -- a share button leading of the
        /// `☰` (design/FIREBASE.md §6A.2). Derived from `hitTarget`, not
        /// written as 104: the whole point of these being metrics is that a
        /// change to the hit target moves everything that depends on it.
        static let rowTwoControlInset: CGFloat = hitTarget + hitTarget + s8 + s8
        /// Room for THREE: a shared set list's Sync button leading of its
        /// share button (0.18.0). Only a shared row pays for it.
        static let rowThreeControlInset: CGFloat = hitTarget * 3 + s8 + s8

        /// The gutter Edit mode's checkbox lives in.
        ///
        /// Exactly one hit target, and nothing either side of it: with 8pt of
        /// its own leading padding the whole list stepped 52pt sideways on
        /// entering Edit mode, which reads as the screen changing rather than
        /// as a column appearing (L23).
        static let checkboxGutter: CGFloat = hitTarget

        /// The widest a pushed screen's content column gets.
        ///
        /// A row is a label and its answer, and on a 1376pt iPad the two ended
        /// up a metre apart with nothing between them -- the label at the left
        /// edge and its chevron at the right, which reads as two unrelated
        /// things rather than as a row (L34). Books stop their measure for the
        /// same reason.
        static let readingColumn: CGFloat = 720

        // The Notebook's table (§3): pages 16 from the table's edges, the
        // panel 380 wide and 10 from the page, 22 of padding inside it.
        static let tableMargin: CGFloat = 16
        static let pagePanelGap: CGFloat = 10
        static let panelWidth: CGFloat = 380
        static let panelSide: CGFloat = 22
        static let pageSide: CGFloat = 24

        /// The navigation redesign's chrome (NAVIGATION_SYSTEM.md §5).
        static let scoreTopBar: CGFloat = 52
        /// The same bar on a phone (§9.6). Eight points, taken from the one
        /// piece of chrome that is on screen in every mode.
        static let scoreTopBarCompact: CGFloat = 44
        /// Scrubber and transport as ONE row, on a phone on its side (§3 E-B).
        static let scoreDeckCompact: CGFloat = 48

        /// The score's top bar at this size class.
        static func scoreTopBar(compact: Bool) -> CGFloat {
            compact ? scoreTopBarCompact : scoreTopBar
        }
        static let scoreTopBarPerformance: CGFloat = 38
        static let thumbStripHeight: CGFloat = 96
        static let transportHeight: CGFloat = 56

        /// §4. Every button, field, chip, segment, panel item: a capsule.
        static let rCtl: CGFloat = 999
        /// §4: the rounded surfaces inside a page -- the segmented control,
        /// panel blocks. Kept under its 0.7 name so no call site moves.
        ///
        /// It is NOT the page's own top corners any more, nor the tray's:
        /// both are square against the screen's edge since 0.8.2 (items 9 and
        /// 10). `rPage` is the alias those two used and now has no caller.
        static let rPanel: CGFloat = 22
        static let rPage: CGFloat = rPanel
        /// The scroll-mode strip and message bubbles.
        static let rInner: CGFloat = 14
        /// A score page; 3 for a thumbnail, 2 for a filmstrip thumbnail.
        static let rScore: CGFloat = 6
        /// The stamp's ring: 2.5pt at 40, 3 at 56, 2 at 30 (§4 `ring`).
        static let stampRing: CGFloat = 2.5
        static let sheetWidth: CGFloat = 620
        static let alertWidth: CGFloat = 420
    }

    // MARK: - The rule (§4)

    /// The only line in the app: 1pt dashed `line2`, under rows, under
    /// key/value rows, between panel blocks. Never doubled [C13]. Replaces
    /// every 1pt solid divider and every border a control used to wear.
    ///
    /// A `Shape`, deliberately: it draws across whatever bounds it is given
    /// and has no size of its own. The first version was a `Path` from 0 to
    /// 4000 clipped to a 1pt frame, and a Path's IDEAL size is its bounding
    /// box -- so every row it sat under grew to 3999pt wide, its centre went
    /// off-screen, and no tap landed on the Details row (found by the UI
    /// tests, the first run after the restyle).
    struct Rule: View {
        var vertical = false
        var body: some View {
            RuleLine(vertical: vertical)
                .stroke(Line.line2, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
        }
    }

    /// The rule, closed around a group: the same 1pt dashed `line2`, drawn as
    /// a boundary rather than a line, so a set of controls reads as one thing.
    ///
    /// The app had only the straight rule, and a group of controls could be
    /// separated from its neighbours but never enclosed by them -- the three
    /// layout cells sat on the bar with nothing saying they were three answers
    /// to one question.
    struct DashedBoundary: ViewModifier {
        var cornerRadius: CGFloat = Metric.rCtl
        func body(content: Content) -> some View {
            content.overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Line.line2,
                                  style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
    }

    struct RuleLine: Shape {
        var vertical: Bool
        func path(in rect: CGRect) -> Path {
            var p = Path()
            if vertical {
                p.move(to: CGPoint(x: rect.midX, y: rect.minY))
                p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            } else {
                p.move(to: CGPoint(x: rect.minX, y: rect.midY))
                p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            }
            return p
        }
    }

    /// Shadows exist only on the two things that float over the score: the
    /// ink tools and the selection chip (§4). No shadows on pages. `panel` and
    /// `sheet` are kept as names so no call site moves in 0.8.0, and both are
    /// now the identity: a page on the table casts nothing.
    enum Elevation {
        static func panel<V: View>(_ view: V) -> some View { view }
        static func pill<V: View>(_ view: V) -> some View {
            view.shadow(color: Color(hex: 0x1A1917).opacity(0.12), radius: 10 / 2, y: 2)
        }
        static func sheet<V: View>(_ view: V) -> some View { view }
    }

    // MARK: - Motion (§5)

    enum Motion {
        static let overlay = Animation.spring(response: 0.32, dampingFraction: 0.86)
        static let pillState = Animation.snappy(duration: 0.12)
        static let disclosure = Animation.easeOut(duration: 0.18)
        static let inkBar = Animation.easeOut(duration: 0.16)
        static let versionFlash = Animation.easeOut(duration: 0.24)

        /// Reduce Motion swaps the slide for a short cross-fade (§5, §9).
        static func overlay(reduced: Bool) -> Animation {
            reduced ? .easeInOut(duration: 0.12) : overlay
        }
    }
}

// MARK: - Applying a type role

extension View {
    /// Applies a role's font, tracking and line spacing together, so the three
    /// cannot drift apart.
    func typeRole(_ role: Theme.Role) -> some View {
        modifier(TypeRoleModifier(role: role))
    }

    /// Encloses a group of controls in the app's dashed rule.
    func dashedBoundary(cornerRadius: CGFloat = Theme.Metric.rCtl) -> some View {
        modifier(Theme.DashedBoundary(cornerRadius: cornerRadius))
    }
}

private struct TypeRoleModifier: ViewModifier {
    let role: Theme.Role

    func body(content: Content) -> some View {
        let styled = content
            .font(role.font)
            .tracking(role.tracking)
        if let spacing = role.lineSpacing {
            return AnyView(styled.lineSpacing(spacing))
        }
        return AnyView(styled)
    }
}

extension Text {
    /// Caps labels carry their casing as part of the role (§2 rule 3).
    func roleText(_ role: Theme.Role) -> Text {
        role.isUppercase ? self : self
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}
