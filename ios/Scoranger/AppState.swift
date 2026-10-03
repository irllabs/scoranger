import Foundation
import UniformTypeIdentifiers
import PDFKit
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var manifest: Manifest?
    /// Whether the library has been looked for yet.
    ///
    /// Distinct from "the library is empty": at launch the manifest is nil and
    /// the engine has not answered, which looked exactly like a user with no
    /// scores -- so the empty state flashed up for a moment before the library
    /// arrived, and on the remote-engine path it was the alarming one ("Engine
    /// unreachable"). Nil means unknown; this says whether we have looked.
    @Published private(set) var libraryLoaded = false
    @Published var selectedSlug: String?
    /// Sidebar preview: the score whose versions the sidebar shows. Set by a
    /// plain row tap; does NOT navigate (that's `select(slug:)`).
    @Published var previewedSlug: String?
    /// nil = follow the score's latest version
    @Published var pinnedVersion: String?
    @Published var pdfDocument: PDFDocument?
    @Published var loadingPDF = false
    @Published var engineOK = false
    /// Why the RENDER failed, and nothing else.
    ///
    /// Its one reader is the "Render failed" placeholder in `ContentView`,
    /// which is on screen only when a score is open and no page could be
    /// drawn -- so it shows a Verovio failure with the build stamp, in mono,
    /// where the failure happened. Forty other failures used to be written
    /// here too and were therefore silent: an Import Book that died on a
    /// missing Python module set this from the LIBRARY, where nothing renders
    /// it, and looked exactly like a button that did nothing.
    ///
    /// Everything that is not a render failure goes to `notice` through
    /// `report(_:_:)`. `check_error_reporting.py` fails the build if a new
    /// write appears here.
    @Published var lastError: String?

    /// The engine failure already spoken. `refresh` polls every two seconds;
    /// without this the notice would come back a second after dismissal.
    private var reportedEngineFailure: String?

    /// Say so.
    ///
    /// `action` is the verb phrase as the reader would say it -- "rename that
    /// part", not the op's name. This is the ONLY route a non-render failure
    /// takes to the screen: `notice`, which `NoticeBar` renders over both the
    /// library and an open score.
    func report(_ action: String, _ error: Error) {
        notice = OperationReport.failure(action, error: error)
    }
    /// One-shot user-facing message shown as an alert (share-sheet receipts etc.)
    @Published var notice: String?
    /// The transcription queue, projected out of `pendingImports` so the
    /// arithmetic can be tested with no app (`OMRQueue`).
    var omrEntries: [OMRQueue.Entry] {
        pendingImports.filter(\.isTranscription).map {
            OMRQueue.Entry(id: $0.id, arrangement: $0.arrangement, name: $0.name,
                           running: !$0.waiting, stage: $0.stage, fraction: $0.fraction)
        }
    }

    /// What ONE arrangement's transcription is doing, or nil. THE answer: the
    /// top bar's chip, the Make editable switch, the Convert panel, More's row
    /// and the transport all read this and nothing else, so they cannot
    /// disagree.
    ///
    /// They used to read an app-wide `omrBusy` Bool, which is how Ali opened
    /// one arrangement and saw another's progress -- and, worse, saw a
    /// progress bar over a score whose own Make editable read off.
    func omrStatus(for slug: String?) -> OMRStatus? {
        OMRQueue.status(ofArrangement: slug, in: omrEntries)
    }

    /// The score ON SCREEN, which is what every surface in the score view
    /// means by "is this transcribing?".
    var omrHere: OMRStatus? { omrStatus(for: selectedSlug) }

    /// Kept as a spelling for the surfaces that ask "is the score I am drawing
    /// being transcribed?". It is SCOPED now; there is no app-wide busy flag
    /// left to read.
    var omrBusy: Bool { omrHere != nil }

    var omrStage: String? { omrHere.map(MakeEditable.detailText) }
    var omrFraction: Double? { omrHere?.fraction }

    /// The whole queue in a line, for the surface that shows all of it.
    var omrQueueSummary: String? { OMRQueue.summary(omrEntries) }
    /// What the lasso caught, held by durable address so it survives the
    /// re-render every engine op triggers. This replaces the yellow-band
    /// highlight, which inferred bar numbers from where a stroke landed across
    /// the page — an estimate that was wrong as often as it was right.
    @Published var selection: ScoreSelection?
    /// Which "<slug>/<version>" the current selection was made on, and which
    /// one the loaded geometry describes.
    ///
    /// Ali saw a selection made in one arrangement appear in its duplicate.
    /// The engine's copy is genuinely independent -- `duplicate` writes a new
    /// slug, a new row and its own v001 -- and every key here is already
    /// slug-scoped, so the mechanism is still unexplained. This makes the
    /// symptom impossible regardless of the cause: a selection is only ever
    /// drawn against the engraving it was made on.
    @Published private(set) var selectionKey: String?
    private var geometryKey: String?

    /// The selection, but only if it belongs to what is on screen now.
    var activeSelection: ScoreSelection? {
        guard let selection, selectionKey != nil, selectionKey == geometryKey else { return nil }
        return selection
    }
    /// The drawn lasso per page index, in unit (0…1) page coordinates, so the
    /// outline survives zoom. Cleared with the selection.
    @Published var selectionPaths: [Int: [CGPoint]] = [:]
    /// The hit-test model for the engraving currently on screen, built from the
    /// same Verovio load that drew it.
    @Published var geometry: ScoreGeometry? {
        didSet { barPopulations = geometry?.barPopulations ?? [:] }
    }

    /// How many selectable addresses each bar-on-a-staff holds, cached with
    /// the geometry that produced it.
    ///
    /// Cached because the highlight asks on every zoom step and the answer is
    /// a walk of every address in the document -- 2724 of them on a nine-page
    /// quartet -- while it changes only when the engraving does.
    private(set) var barPopulations: [SelectionMerge.Key: Int] = [:]
    /// What each added mark already carries, by address — the chip's starting
    /// point, so a nudge builds on the file rather than on the default.
    @Published var markAdjustments: [ScoreAddress: ChordAdjustments.Adjustment] = [:]
    /// Bumped to ask the UI to open chat, with text for its input: how a
    /// finished lasso shows the user that the selection registered.
    /// The setlist being played, if the score was opened from one. It is what
    /// the transport's prev/next step through -- the one part of the transport
    /// that does something (NAVIGATION_SYSTEM.md §1).
    /// The score view's own chrome state.
    ///
    /// Here rather than in the view because the view is rebuilt whenever this
    /// object publishes -- which is on every scroll, since the page counters
    /// read the visible rect -- and @State inside it was being reset under the
    /// user. A menu that will not open is the visible symptom; the cause is
    /// that the thing remembering "it is open" did not survive the next frame.
    @Published var scoreMode: ScoreMode = .read
    @Published var titleMenuOpen = false

    @Published var currentSetlist: String?
    /// Which pages are on screen, reported by the canvas. Feeds the counters
    /// and the thumbnail strip's "you are here" (NAVIGATION_SYSTEM.md 12.11).
    /// The page unit on screen. The canvas shows this one page (or this pair
    /// with the spread on) and nothing else exists -- turning changes the
    /// index rather than scrolling a stack (NAV_MODAL_FREE_0.4.2 §6).
    @Published var pageIndex: Int = 0
    @Published var visiblePageIndices: [Int] = [0]
    /// Per page index, the slice of that page currently on screen, in PAGE
    /// (SVG user) coordinates. Reported by each page so the bar readout can say
    /// which bar the reader is actually looking at rather than which page they
    /// are on -- at 4x zoom those are very different answers.
    @Published var visibleBarRects: [Int: CGRect] = [:]
    // pageBoundaries is gone with the stack it described: a turn changes an
    // index now, so there is no offset to compute or preserve.
    @Published var chatOpenRequest = 0
    @Published var pendingChatInsert: String?
    /// How the next lasso combines with what is already selected. Replace until
    /// the user says otherwise; the two-finger add shortcut overrides it for
    /// one stroke without disturbing it.
    @Published var combineMode: SelectionCombine = .replace

    /// Carry a selection across a re-engrave, or drop it.
    ///
    /// An op makes a NEW VERSION of the same score, and the notes the user
    /// selected are still there -- so clearing the selection every time meant
    /// running two operations on the same passage required lassoing it twice.
    /// Addresses are durable by design (staff/measure/layer/kind#ordinal, not a
    /// rendered id), so they are simply looked up again in the new engraving.
    ///
    /// Only within one score: switching arrangement, or to an unrelated
    /// version, is a different subject and the selection goes.
    private func carrySelection(from previous: String?, to key: String,
                                into model: ScoreGeometry?) {
        guard let selection, !selection.isEmpty,
              selectionKey == previous,
              ScoreSelection.survivesReRender(from: previous, to: key,
                                              userPickedVersion: pinnedVersion != nil),
              let model else {
            clearSelection()
            return
        }
        let survived = selection.addresses.filter { model.element(at: $0) != nil }
        guard !survived.isEmpty else {
            clearSelection()
            selectionCarryNote = "The selection is gone: the edit removed everything in it."
            return
        }
        let lost = selection.addresses.count - survived.count
        self.selection = ScoreSelection(addresses: survived)
        selectionKey = key
        selectionPaths = [:]   // the drawn outline described the old engraving
        selectionCarryNote = lost == 0 ? nil
            : "\(lost) of \(selection.addresses.count) selected elements no longer exist."
    }

    /// Said once, on the chip, when an edit did not leave the selection whole.
    @Published var selectionCarryNote: String?

    // MARK: - Adjusting a chord symbol's size and position
    //
    // Taps accumulate here and commit ONCE, when the reader leaves the element.
    // The notation is versioned, so committing per tap would spend a version on
    // every button press. See docs/size-and-position-spec.md, "Committing".

    /// The adjustment in progress, or nil when nothing adjustable is selected.
    @Published var adjustSession: ChordAdjustSession?
    /// The element the session belongs to, so selecting another commits the
    /// first rather than silently retargeting it.
    @Published private(set) var adjustTarget: ScoreAddress?
    /// Groups the versions one sitting produces, the way a chat turn's steps
    /// are grouped -- four nudges should read as one adjustment, not four
    /// unrelated versions.
    private var adjustTurnID: String?
    private var adjustIdleTask: Task<Void, Never>?

    /// Three seconds of no further taps counts as leaving the element.
    static let adjustIdleCommit: Duration = .seconds(3)

    /// Hand the finished selection to chat. Called by the chip's confirm
    /// button, never by a gesture.
    func confirmSelectionForChat() {
        guard let selection = activeSelection, !selection.isEmpty else { return }
        pendingChatInsert = selection.chatReference
        chatOpenRequest += 1
    }

    /// Drop the active selection and its drawn lasso.
    ///
    /// The mode goes with it: it is meaningless without a selection, and
    /// leaving it set is what trapped the user in Subtract.
    func clearSelection() {
        // Leaving the element is what commits it. Dropping the selection with
        // an uncommitted nudge would throw the reader's work away silently.
        commitAdjustment()
        selection = nil
        selectionPaths = [:]
        selectionKey = nil
        combineMode = .replace
    }

    // MARK: - The adjustment session

    /// Point the session at whatever is selected now, committing whatever the
    /// last element had pending.
    ///
    /// Called whenever the selection changes. Selecting a second chord symbol
    /// while the first has an uncommitted nudge must WRITE the first, not
    /// retarget the pending values onto the new one.
    func retargetAdjustment() {
        guard let selection = activeSelection, selection.isAdjustable,
              let address = selection.addresses.first else {
            commitAdjustment()
            closeAdjustTurn()
            adjustSession = nil
            adjustTarget = nil
            return
        }
        if adjustTarget == address { return }
        commitAdjustment()
        closeAdjustTurn()
        let metric = AddedMark.sizeMetric(address.kind)
        adjustSession = ChordAdjustSession(
            size: markSize(at: address) ?? metric.defaultValue,
            committedDX: markOffset(at: address).dx,
            committedDY: markOffset(at: address).dy,
            metric: metric)
        adjustTarget = address
        adjustTurnID = nil
    }

    /// A tap on one of the chip's buttons: change the pending value, redraw
    /// locally, and restart the idle timer. Nothing reaches the engine here.
    func adjust(_ change: (inout ChordAdjustSession) -> Void) {
        guard var session = adjustSession else { return }
        change(&session)
        adjustSession = session
        scheduleAdjustCommit()
    }

    private func scheduleAdjustCommit() {
        adjustIdleTask?.cancel()
        adjustIdleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.adjustIdleCommit)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.commitAdjustment() }
        }
    }

    /// Write the pending adjustment, as ONE op. Safe to call when there is
    /// nothing pending -- an empty commit would still cost a version.
    func commitAdjustment() {
        adjustIdleTask?.cancel()
        adjustIdleTask = nil
        guard var session = adjustSession, let address = adjustTarget,
              let commit = session.commit(),
              let slug = selectedScore?.slug,
              let kind = AddedMark.engineKind(address.kind),
              let part = partName(forStaff: address.staff) else { return }
        adjustSession = session   // the commit clears what was pending
        // Group this sitting's versions the way a chat turn's steps are
        // grouped, using the SAME mechanism rather than a parallel one -- four
        // nudges should read as one adjustment in the version list, not as four
        // unrelated versions.
        let openTurn = adjustTurnID == nil
        adjustTurnID = adjustTurnID ?? UUID().uuidString
        let noun = AddedMark.noun(address.kind)
        let what = "Adjusted the \(noun) in bar \(address.measure)"
        Task {
            if openTurn {
                _ = try? await local.call(op: "begin-turn",
                                          args: ["score": slug, "prompt": what])
            }
            var args: [String: Any] = ["score": slug, "part": part,
                                       "kind": kind,
                                       "measure": address.measure,
                                       "ordinal": address.ordinal]
            if commit.reset {
                args["reset"] = true
            } else {
                // A relative rung is sent as `scale`, an absolute one as
                // `size`; the op refuses both at once, which is what keeps the
                // two interfaces from quietly meaning the same thing.
                if let size = commit.size {
                    // An absolute size stays an Int: it is written into the
                    // notation as a font-size, and a chord symbol nudged
                    // before 0.8.2 carries "14". Sending 14.0 would rewrite
                    // every one of them as "14.0" for no reader's benefit.
                    if commit.isRelative {
                        args["scale"] = Double(size) / 100
                    } else {
                        args["size"] = size
                    }
                }
                if let x = commit.offsetX { args["offset_x"] = x }
                if let y = commit.offsetY { args["offset_y"] = y }
            }
            do {
                _ = try await local.call(op: "adjust-element", args: args)
                await refresh()
                await renderIfNeeded(force: true)
            } catch {
                report("move that \(noun)", error)
            }
        }
    }

    // MARK: - Sending a mark to another bar
    //
    // The destination is a TAPPED BAR plus an offset stepper inside it. There
    // is no drag in this app, so there is no drag here.

    /// The move or duplicate in progress, or nil. While it is set, a tap on the
    /// canvas picks a BAR instead of selecting anything.
    @Published var placing: MoveDestination?

    /// True while a tap on the page means "that bar", not "that element".
    var isPlacingMark: Bool { placing != nil }

    /// Start one. The pending adjustment is committed first: the reader is
    /// about to move the thing they were nudging, and an uncommitted nudge
    /// would be written against the element's OLD bar afterwards.
    func beginPlacing(_ intent: MoveDestination.Intent) {
        guard let address = adjustTarget else { return }
        commitAdjustment()
        placing = MoveDestination(intent: intent, kind: address.kind,
                                  source: address)
    }

    func cancelPlacing() { placing = nil }

    func aimPlacement(atBar number: Int) {
        placing?.aim(atBar: number, barLength: barLength(ofMeasure: number))
    }

    func stepPlacement(by delta: Double) { placing?.step(by: delta) }

    func snapPlacement(to onset: Double) { placing?.snap(to: onset) }

    /// How long a bar is, in quarter notes, when the playback timeline knows.
    ///
    /// It is the only thing in the app that measures a bar, and it is there
    /// only when the score is playable. Nil is a fine answer: the stepper is
    /// then unclamped and `ops.move_element` is the authority, which it is in
    /// either case.
    func barLength(ofMeasure number: Int) -> Double? {
        guard let bar = playback.timeline.bars.first(where: { $0.measure == number })
        else { return nil }
        let length = bar.end - bar.start
        return length > 0 ? length : nil
    }

    /// Send it. A refusal is kept ON the destination rather than thrown at the
    /// notice bar, because the engine's refusal names the offsets that WOULD
    /// work and the chip turns them into buttons.
    func commitPlacement() {
        guard let destination = placing, let bar = destination.bar,
              let slug = selectedScore?.slug,
              let kind = AddedMark.engineKind(destination.kind),
              let part = partName(forStaff: destination.source.staff) else { return }
        let op = destination.intent == .move ? "move-element" : "duplicate-element"
        let args: [String: Any] = [
            "score": slug, "part": part, "kind": kind,
            "measure": destination.source.measure,
            "ordinal": destination.source.ordinal,
            "to_measure": bar, "to_offset": destination.offset]
        Task {
            do {
                _ = try await local.call(op: op, args: args)
                placing = nil
                // The element has moved, so the selection that pointed at it
                // points at nothing. Dropping it also closes the adjust row,
                // which would otherwise address the old bar.
                clearSelection()
                await refresh()
                await renderIfNeeded(force: true)
            } catch {
                // NOT reported to the notice bar, deliberately. The engine's
                // refusal names the offsets that WOULD work, and the chip
                // turns them into buttons -- a sentence in a bar that vanishes
                // would throw that away and leave the reader where they were.
                // `MoveDestination.refusalNote` is where it is rendered.
                placing?.refused(OperationReport.reason(error))
            }
        }
    }

    // MARK: - The part-wide default

    /// The size new chord symbols inherit. Per-element overrides are absolute
    /// points in the notation, so they survive this changing.
    @Published var chordDefaultSize: Int = ChordAdjustSession.defaultSize

    func canStepChordDefault(_ step: ChordAdjustSession.SizeStep) -> Bool {
        var probe = ChordAdjustSession(size: chordDefaultSize)
        return probe.canResize(step)
    }

    /// Set the part-wide default outright, which is what tapping a rung of the
    /// size ladder does. The stepper walks the same ladder one rung at a time.
    func setChordDefault(_ size: Int) {
        guard ChordAdjustSession.sizeLadder.contains(size),
              size != chordDefaultSize else { return }
        chordDefaultSize = size
        applyChordDefault()
    }

    func stepChordDefault(_ step: ChordAdjustSession.SizeStep) {
        var probe = ChordAdjustSession(size: chordDefaultSize)
        guard probe.canResize(step) else { return }
        probe.resize(step)
        chordDefaultSize = probe.pending.size
        applyChordDefault()
    }

    /// One op over every chord symbol in the part.
    private func applyChordDefault() {
        guard let slug = selectedScore?.slug, let part = chordPartName() else { return }
        Task {
            do {
                _ = try await local.call(op: "adjust-element",
                                         args: ["score": slug, "part": part,
                                                "kind": "harm", "all": true,
                                                "size": chordDefaultSize])
                await refresh()
                await renderIfNeeded(force: true)
            } catch { report("resize the chord symbols", error) }
        }
    }

    /// Put every chord symbol in the part back to the inherited size and no
    /// offset. The way out of a part someone has nudged ten symbols in.
    func resetAllChordAdjustments() {
        guard let slug = selectedScore?.slug, let part = chordPartName() else { return }
        chordDefaultSize = ChordAdjustSession.defaultSize
        Task {
            do {
                _ = try await local.call(op: "adjust-element",
                                         args: ["score": slug, "part": part,
                                                "kind": "harm", "all": true,
                                                "reset": true])
                await refresh()
                await renderIfNeeded(force: true)
            } catch { report("put the chord symbols back", error) }
        }
    }

    /// The part carrying chord symbols -- the selected one where the reader has
    /// picked a symbol, else the first part that has any.
    ///
    /// Internal, not private: the Options screen NAMES the part it is about to
    /// resize every chord symbol in. The size control was reported as doing
    /// nothing, and a part-wide op that says nothing about which part it hit
    /// is indistinguishable from one that did not run.
    func chordPartName() -> String? {
        if let address = adjustTarget, let named = partName(forStaff: address.staff) {
            return named
        }
        return selectedScore?.versions.last?.parts?.first?.name
    }

    /// End the grouping once the reader has moved on, so the NEXT element's
    /// adjustments are their own group rather than joining this one.
    private func closeAdjustTurn() {
        guard adjustTurnID != nil else { return }
        adjustTurnID = nil
        Task { _ = try? await local.call(op: "end-turn", args: [:]) }
    }

    /// The part a staff belongs to, which is what the op is addressed by.
    private func partName(forStaff staff: Int) -> String? {
        let parts = selectedScore?.versions.last?.parts ?? []
        guard staff >= 1, staff <= parts.count else { return parts.first?.name }
        return parts[staff - 1].name
    }

    /// What the notation already carries for this mark, in the unit its own
    /// row steps, so the session starts from the truth rather than the default.
    ///
    /// The file always holds POINTS -- MusicXML has no relative font size --
    /// so a relative ladder reads its rung back out by dividing by the same
    /// constant every renderer divides by.
    private func markSize(at address: ScoreAddress) -> Int? {
        guard let points = markAdjustments[address]?.size else { return nil }
        let metric = AddedMark.sizeMetric(address.kind)
        guard metric.isRelative else { return Int(points.rounded()) }
        return Int((points / ChordAdjustments.defaultChordPoints * 100).rounded())
    }

    private func markOffset(at address: ScoreAddress) -> (dx: Int, dy: Int) {
        let adjustment = markAdjustments[address]
        return (Int((adjustment?.dx ?? 0).rounded()), Int((adjustment?.dy ?? 0).rounded()))
    }

    /// A finished lasso: what it caught, drawn where it was drawn, handed to
    /// chat so the next prompt can refer to it.
    /// Put addresses into the selection. THE one writer every route goes
    /// through -- the lasso, a tap, and whatever comes next (§10.2).
    ///
    /// The lasso used to be the owner rather than a writer, and the tell was
    /// `selectionPaths`: the loop it drew was carried as though it were the
    /// selection. It is not. The selection is the ADDRESSES, drawn from
    /// geometry by `selectedFrames`; the loop is a receipt for one gesture.
    /// A route that produces no loop -- a tap -- must therefore clear the old
    /// one, or a note tapped after a lasso would appear inside a loop that
    /// caught something else entirely.
    @discardableResult
    func select(_ addresses: [ScoreAddress], mode: SelectionCombine = .replace,
                path: [CGPoint]? = nil, page: Int = 0) -> ScoreSelection? {
        let combined = (selection ?? ScoreSelection(addresses: []))
            .combining(addresses, mode: mode)

        if let path {
            // A gesture that drew something: keep its outline, and keep the
            // ones already drawn when it is adding to them.
            switch mode {
            case .replace: selectionPaths = [page: path]
            case .add, .subtract:
                selectionPaths = selectionPaths.merging([page: path]) { _, new in new }
            }
        } else {
            // A route with no outline of its own. The previous loop described
            // a different selection and must not be left over this one.
            selectionPaths = [:]
        }

        selection = combined.isEmpty ? nil : combined
        selectionKey = combined.isEmpty ? nil : geometryKey
        if combined.isEmpty { selectionPaths = [:] }
        // The adjust row follows the selection, through THIS writer, because
        // every route goes through it. It used to be retargeted from
        // `commitSelection` -- the lasso's route alone -- so a chord symbol
        // TAPPED at 2x selected fine, the chip appeared, and no adjust row
        // came with it: `adjustSession` was still nil and the row is drawn
        // only when it is not. Found by photographing the row: the picture was
        // of a selection with no row under it.
        retargetAdjustment()
        return selection
    }

    func commitSelection(_ elements: [ScoreElement], path: [CGPoint], page: Int,
                         adding: Bool = false) {
        // the two-finger shortcut adds for this stroke only; the chip's mode is
        // what the user set and is left alone
        let mode: SelectionCombine = adding ? .add : combineMode
        // Through `select`, like every other route: the lasso contributes the
        // addresses it caught and the outline it drew, and owns neither.
        let combined = select(elements.compactMap(\.address), mode: mode,
                              path: path, page: page)
        // the chip vanishes with the selection, so a mode left set here could
        // never be changed back
        combineMode = SelectionCombine.modeAfter(combineMode,
                                                 selectionIsEmpty: combined == nil)
        // Nothing is inserted into the chat box here any more (#4c). The user
        // builds the selection up -- lasso, add with a held finger, drop what
        // they did not mean -- and hands it over when it is right, by tapping
        // Use in chat on the chip. Auto-inserting on every lasso appended a
        // line each time and filled the box with references to selections that
        // had already been replaced. Chat is not opened either: a lasso is not
        // a request to start typing.
    }

    /// A Pencil tap on the page. One drops an element, two select the bar on
    /// that staff, three select the bar across all staves (#10b).
    ///
    /// Deliberate, and only deliberate: a bar can no longer be caught by a
    /// lasso or a stray single tap, because bar-like kinds are filtered out of
    /// everything else (#9, #10a). Asking for a bar is the only way to get one.
    @discardableResult
    func handleTap(at point: CGPoint, onPage index: Int, taps: Int,
                   modifierFingerDown: Bool = false) -> Bool {
        switch LassoGate.tap(count: taps) {
        case .dropElement:
            // A held finger turns a tap into "add this one", the same way it
            // turns a drag into "add what I enclose".
            if LassoGate.singleTap(modifierFingerDown: modifierFingerDown) == .addElement {
                return addToSelection(at: point, onPage: index)
            }
            return dropFromSelection(at: point, onPage: index)
        case .selectBar:
            return selectBar(at: point, onPage: index, allStaves: false)
        case .selectBarAllStaves:
            return selectBar(at: point, onPage: index, allStaves: true)
        }
    }

    /// The bar under a point, as a selection of everything in it.
    ///
    /// A bar selection is expressed as the ELEMENTS of the bar, not as the
    /// measure element itself: that is what makes it usable by an op scoped to
    /// addresses, and what keeps the highlight on the notes rather than
    /// painting a block over the system.
    @discardableResult
    func selectBar(at point: CGPoint, onPage index: Int,
                   allStaves: Bool) -> Bool {
        guard let geometry, let page = geometry.page(index) else { return false }
        let scaled = CGPoint(x: point.x * page.size.width, y: point.y * page.size.height)
        guard let bar = page.element(at: scaled, kinds: ScoreElementKind.barLike)?.address
        else { return false }

        // NOT bar.staff: a <measure> lives outside any <staff> in MEI, so its
        // address carries staff 0 and comparing against it matched no element
        // at all. A double-tap therefore selected nothing, and only the
        // triple-tap (every staff) ever appeared to work. The staff comes from
        // where the Pencil is instead.
        let wanted: Int? = allStaves ? nil
            : ScoreGeometry.staff(at: scaled.y,
                                  among: geometry.staffBands(inMeasure: bar.measure,
                                                             onPage: index))
        if !allStaves && wanted == nil { return false }

        let members = geometry.addresses.filter { address in
            guard address.measure == bar.measure,
                  !ScoreElementKind.barLike.contains(address.kind) else { return false }
            return allStaves || address.staff == wanted
        }
        guard !members.isEmpty else { return false }
        select(members, mode: .replace)
        combineMode = .replace
        return true
    }

    // MARK: - The armed lasso (§9.3)

    /// Whether one finger draws a loop. The state machine itself is
    /// `LassoArming`, which is pure and tested; this is where it lives.
    @Published var lassoArming: LassoArming = .off

    var lassoArmed: Bool { lassoArming.isArmed }

    func toggleLasso() { lassoArming = lassoArming.tapped }

    /// A loop landed.
    func lassoFinished() { lassoArming = lassoArming.afterOneLoop }

    /// Is there anything on the page under this point at all?
    ///
    /// The finger's tap asks before it acts, so a tap on blank paper can put
    /// the selection down instead of leaving it standing (§12's `.clear`). It
    /// is asked BEFORE the decision and handed in as a fact -- a turn that
    /// depended on what was under the thumb would be unpredictable, which is
    /// exactly what §12 rejected.
    /// The number of the bar under a point, without selecting anything.
    ///
    /// What a tap means while a move is being aimed: the reader is naming a
    /// DESTINATION, so the bar is the answer and the selection must not move
    /// -- it still points at the mark being sent.
    func barNumber(at point: CGPoint, onPage index: Int) -> Int? {
        guard let page = geometry?.page(index) else { return nil }
        let scaled = CGPoint(x: point.x * page.size.width, y: point.y * page.size.height)
        return page.element(at: scaled, kinds: ScoreElementKind.barLike)?
            .address?.measure
    }

    func hasElement(at point: CGPoint, onPage index: Int) -> Bool {
        guard let page = geometry?.page(index) else { return false }
        let scaled = CGPoint(x: point.x * page.size.width, y: point.y * page.size.height)
        return page.element(at: scaled) != nil
            || page.element(at: scaled, kinds: ScoreElementKind.barLike) != nil
    }

    /// Is the element under this point already selected?
    ///
    /// What makes a second tap mean the NOTE rather than the bar again: the
    /// reader has already said which bar, so the only thing left to say is
    /// which note in it (§9.1).
    func selectionContains(_ point: CGPoint, onPage index: Int) -> Bool {
        guard let selection, let page = geometry?.page(index) else { return false }
        let scaled = CGPoint(x: point.x * page.size.width, y: point.y * page.size.height)
        guard let hit = page.element(at: scaled)?.address else { return false }
        return selection.addresses.contains(hit)
    }

    /// Add the one element under the Pencil to the selection.
    @discardableResult
    func addToSelection(at point: CGPoint, onPage index: Int) -> Bool {
        guard let page = geometry?.page(index) else { return false }
        let scaled = CGPoint(x: point.x * page.size.width, y: point.y * page.size.height)
        guard let hit = page.element(at: scaled)?.address,
              !ScoreElementKind.barLike.contains(hit.kind) else { return false }
        select([hit], mode: .add)
        return true
    }

    /// Tapping a selected element drops just that one — the single correction
    /// a whole-region subtract is too blunt for.
    /// Returns true when something was dropped, so the caller knows the tap was
    /// used rather than passed through.
    @discardableResult
    func dropFromSelection(at point: CGPoint, onPage index: Int) -> Bool {
        guard let selection, !selection.isEmpty,
              let page = geometry?.page(index) else { return false }
        let scaled = CGPoint(x: point.x * page.size.width, y: point.y * page.size.height)
        guard let hit = page.element(at: scaled)?.address,
              selection.addresses.contains(hit) else { return false }
        // Through the writer, so the adjust row follows: dropping four of a
        // five-element selection leaves one mark, and that is a selection the
        // row belongs to.
        select(selection.dropping(hit).addresses, mode: .replace)
        combineMode = SelectionCombine.modeAfter(combineMode,
                                                 selectionIsEmpty: self.selection == nil)
        return true
    }

    /// PDFs currently being converted in the cloud — shown greyed out in the
    /// scores list with a live stage until they become real scores (or fail).
    struct PendingImport: Identifiable, Equatable {
        let id = UUID()
        let name: String
        /// The piece it is going into, so the library can show that piece
        /// filling up rather than the import vanishing (0.4.1 item 9).
        var piece: String?
        /// The ARRANGEMENT being transcribed, when this is OMR on demand on a
        /// scan the reader already has. Nil when the transcription is
        /// BECOMING an arrangement (a PDF from the share sheet), and nil for
        /// an import that is not a transcription at all.
        ///
        /// Without this there was nothing to scope the progress by, which is
        /// why the chip belonged to no arrangement: `PendingImport` recorded
        /// the file's name and the piece and not the thing being transcribed.
        var arrangement: String?
        /// Which list this row belongs in. A book is not an arrangement and
        /// its progress must not appear under Pieces (ImportProgress).
        var target: ImportTarget = .arrangement
        /// Whether this import is a TRANSCRIPTION and therefore in the OMR
        /// queue. A book being copied is an import and is not.
        var isTranscription = false
        /// In the queue but not started. Only a transcription waits.
        var waiting = false
        var stage: String = "uploading…"
        /// nil = indeterminate (spinner); 0…1 = determinate bar
        var fraction: Double? = nil
    }
    @Published var pendingImports: [PendingImport] = []

    /// The inputs of each queued transcription, by the id of the row that
    /// stands for it. Not published: the row is what the reader sees.
    private var omrWork: [UUID: OMRWork] = [:]

    /// What an import just brought in, for the root to OPEN (0.8.0 build
    /// 194, Ali's item 1): a reader who imported a score, from Files or from
    /// another app's share sheet, wants to see it, not the Pieces list. Set
    /// by every import path that yields an arrangement; the root clears it.
    @Published var openAfterImport: String?

    private func updatePending(_ id: UUID, stage: String, fraction: Double?) {
        print("SCORANGER-OMR \(stage)")
        if let i = pendingImports.firstIndex(where: { $0.id == id }) {
            pendingImports[i].stage = stage
            pendingImports[i].fraction = fraction
        }
    }
    @Published var modelCatalog: ModelCatalog?

    // chat, kept per score slug
    @Published var chatMessages: [String: [ChatDisplayMessage]] = [:]
    @Published var chatBusy = false
    /// Live checklist of tool calls for the in-flight chat turn, per slug.
    @Published var activeChatSteps: [String: [ChatStep]] = [:]
    var chatHistory: [String: String] = [:]

    static let defaultEngineURL: String = {
        #if targetEnvironment(simulator)
        return "http://localhost:8765"
        #else
        return (Bundle.main.object(forInfoDictionaryKey: "EngineDefaultURL") as? String)
            ?? "http://localhost:8765"
        #endif
    }()

    @AppStorage("engineURL") var engineURLString = AppState.defaultEngineURL
    @AppStorage("chatModel") var chatModel = ""
    /// true = embedded Python engine + Verovio (no laptop needed);
    /// false = remote `scor serve` over the network.
    @AppStorage("useLocalEngine") var useLocalEngine = true

    /// Arrangement tags [C14]: saved at once, no version. The counter is what
    /// views watch; the store is a file beside the library.
    @Published var arrangementTagsVersion = 0
    func arrangementTags(_ slug: String) -> [String] {
        ArrangementTags.shared.tags(for: tagKey(slug))
    }
    func setArrangementTags(_ slug: String, _ tags: [String]) {
        ArrangementTags.shared.set(tags, for: tagKey(slug))
        arrangementTagsVersion += 1
    }
    /// Every arrangement's tags by slug, for the library's rows and filters.
    var allArrangementTags: [String: [String]] {
        var out: [String: [String]] = [:]
        for score in manifest?.scores ?? [] {
            let tags = arrangementTags(score.slug)
            if !tags.isEmpty { out[score.slug] = tags }
        }
        return out
    }
    private func tagKey(_ slug: String) -> String {
        manifest?.scores.first { $0.slug == slug }?.uid ?? slug
    }
    /// Guards the one-time rename of the old seeded "Samples" setlist.
    @AppStorage("didMigrateSetlistNames") var didMigrateSetlistNames = false
    /// Session-scoped, deliberately not `@AppStorage`: re-running the
    /// annotation re-file costs one directory listing and is idempotent, and a
    /// persisted flag would skip it for ever on a device whose first run
    /// happened before the library finished importing.
    private var didMigrateAnnotationKeys = false
    /// How the score is laid out: one page, a spread, or continuous.
    ///
    /// One page by default: on one page the music is twice the size, which is
    /// what you want while playing. Stored as a string so a fourth layout
    /// costs nothing, and read through `layout` below.
    @AppStorage("scoreLayout") private var storedLayout = ScoreLayout.page.rawValue
    /// The spread preference this replaced. Read ONCE, to carry a reader who
    /// already had the spread on into the new setting; never written again.
    @AppStorage("twoPageSpread") private var legacySpread = false
    @AppStorage("didMigrateScoreLayout") private var didMigrateScoreLayout = false

    /// What the READER chose: what the layout control lights, what Settings
    /// shows, what is remembered between launches.
    var layoutChoice: ScoreLayout {
        get { ScoreLayout(rawValue: storedLayout) ?? .page }
        // `@AppStorage` inside an ObservableObject writes UserDefaults and
        // tells nobody, so the publish is made here. It used to arrive by
        // accident, from the `pageIndex = 0` the control set beside it.
        set {
            guard newValue.rawValue != storedLayout else { return }
            objectWillChange.send()
            storedLayout = newValue.rawValue
        }
    }

    /// The layout the score on screen is DRAWN with, which is the choice
    /// except while the canvas is still holding pages made for the other kind
    /// of engraving (`ScoreLayout.displayed`). Everything that draws reads
    /// this; only the control and Settings read the choice.
    ///
    /// Continuous is a different engraving of the same music and takes a
    /// second or three to make. Publishing the choice straight to the canvas
    /// drew the pages it already had under the new layout's rules for a frame
    /// -- a paged document as a strip, a strip squeezed into a page frame --
    /// which is Ali's "shows the WRONG view for a moment". One page and a
    /// spread share an engraving, so switching between those two still takes
    /// effect on the next frame and waits for nothing.
    var layout: ScoreLayout {
        // `awaiting`: an engrave for the CHOSEN engraving is actually in
        // flight. Without it the canvas holds the old engraving for as long as
        // the mismatch lasts, which is forever once a handover fails -- see
        // ScoreLayout.displayed.
        get {
            ScoreLayout.displayed(chosen: layoutChoice, engraved: renderedLayout,
                                  awaiting: engravingInFlight == layoutChoice.engraving)
        }
        set { layoutChoice = newValue }
    }

    /// The engraving an engrave is currently being made for, or nil when none
    /// is running. The canvas reads it to tell a handover in progress from one
    /// that never finished.
    @Published private(set) var engravingInFlight: ScoreLayout.Engraving?

    /// The layout the pages currently on the canvas were engraved for, or nil
    /// when the canvas is holding nothing. Set beside `pdfDocument`, in the
    /// same publish, so the document and the layout it is drawn with can never
    /// be one frame apart.
    @Published private(set) var renderedLayout: ScoreLayout?

    /// Kept so the twelve places that ask "is this a spread?" still can. It is
    /// DERIVED: setting it chooses between the two page layouts and can no
    /// longer disagree with `layout`.
    var twoPageSpread: Bool {
        get { layout == .spread }
        set { layout = newValue ? .spread : .page }
    }

    /// Carries the old boolean over the first time the new build runs.
    func migrateScoreLayout() {
        guard !didMigrateScoreLayout else { return }
        didMigrateScoreLayout = true
        if legacySpread, layout == .page { layout = .spread }
    }
    /// Cloud OMR service base URL (Audiveris on Cloud Run); empty = disabled.
    @AppStorage("omrURL") var omrURLString =
        (Bundle.main.object(forInfoDictionaryKey: "OMRDefaultURL") as? String) ?? ""

    /// Builds 4-5 shipped Cloud Run's "deterministic" hostname, which Google's
    /// edge routes unreliably (the PDF-conversion 502s). Rewrite it to the
    /// canonical a.run.app URL.
    func migrateStaleOMRURL() {
        if omrURLString.contains("789974749678.us-central1.run.app"),
           let canonical = Bundle.main.object(forInfoDictionaryKey: "OMRDefaultURL") as? String {
            omrURLString = canonical
        }
    }

    private var pollTask: Task<Void, Never>?
    private var renderedKey: String?

    /// Which engraving `pdfDocument` currently holds, as a string the canvas
    /// can key its rasters by.
    ///
    /// NOT the `PDFPage`'s object identity, which is what a raster cache would
    /// otherwise reach for: a page freed when the version changes can be
    /// replaced at the same address, and the canvas would then draw the
    /// previous score's music. NOT `renderedKey` either -- a forced re-render
    /// keeps that string and changes the pages under it -- so a stamp is
    /// added, allocated where the ENGRAVING is made. It therefore changes
    /// exactly when the pages change, and stays put when a held engraving is
    /// shown again, which is what keeps that engraving's rasters valid.
    ///
    /// Deliberately not `@Published`: it is set immediately before
    /// `pdfDocument`, whose publish is what rebuilds the canvas, so the canvas
    /// always reads the value belonging to the document it was handed. A second
    /// publish here would only invalidate the views this exists to spare.
    private(set) var engravingKey: String = ""
    private var engravingCount = 0

    /// An engraving and the stamp that names it.
    ///
    /// The stamp is allocated ONCE, when the engraving is made, and travels
    /// with it. That is what lets the two caches compose: coming back to an
    /// engraving already held gives back the same `engravingKey`, so the
    /// canvas rasters drawn from it are still valid. Stamping on every render
    /// instead -- which is what a plain counter did -- made returning to a
    /// held engraving free of Verovio and then redrew every one of its tiles,
    /// 101 rasters over six layout switches that should have needed none.
    struct HeldEngraving {
        let engraving: VerovioRenderer.Engraving
        let stamp: Int
    }

    /// Engravings already made, by "<slug>/<version>/<layout>".
    ///
    /// A version is IMMUTABLE -- every op writes a new one -- so an engraving
    /// of it can never go stale, and the only reason to throw one away is the
    /// memory it holds. Which is little: an eleven-page quartet's PDF is a
    /// couple of megabytes, against 3.1 s of Verovio and SwiftDraw to make it
    /// again.
    ///
    /// Four of them, roughly, at 24MB. Enough to hold both layouts of the
    /// version being read and both of the one before it, which is the pattern
    /// a reader comparing two versions actually makes.
    static let engravings = MemoCache<String, HeldEngraving>(budget: 24 << 20)

    /// What an engraving costs to hold. The PDF is nearly all of it; the
    /// geometry is a few thousand small structs, charged at a flat rate rather
    /// than walked, because walking it to size it would cost more than the
    /// entry is worth.
    static func engravingBytes(_ held: HeldEngraving) -> Int {
        held.engraving.pdf.count + 64 * 1024
    }

    var client: EngineClient { EngineClient(baseURLString: engineURLString) }
    let local = LocalEngine()

    /// A fresh Firebase ID token, or nil when nobody is signed in.
    ///
    /// A CLOSURE and not a call, because `AppState` may not touch Firebase:
    /// `Auth.auth()` traps when nothing has configured it, and
    /// `check_signed_out.py` keeps every such call inside `Account/`
    /// (`OMRIdentity`, which installs this). Nil is the ordinary answer -- a
    /// signed-out reader's OMR job goes up on the shared key and the service
    /// labels it `unattributed`, because there is no user to bill it to
    /// (design/FIREBASE.md §0.12).
    var omrToken: (() async -> String?)?

    /// Which shared set list entry is open, if the score on screen is one.
    ///
    /// Set while reading an entry and cleared on the way out, and it decides
    /// two things: where markup is filed, and whose markup is drawn under it
    /// (`SharedEntryCopies.inkNamespace`, design/FIREBASE.md §6.3).
    @Published var openSharedEntry: (setlist: String, entry: String)?

    /// Whose marks to draw. Everyone's, by default: the point of sharing a set
    /// list is seeing what the band wrote on it (§6.3).
    @Published var inkVisibility: InkLayers.Visibility = .everyone

    /// Where this device put its copy of each shared entry.
    let sharedCopies = SharedEntryCopies()

    /// An invitation link that has been opened and not yet acted on.
    ///
    /// Held here rather than claimed at the door, because claiming it is a
    /// decision -- joining downloads somebody else's copies -- and because it
    /// may arrive before there is an account to claim it with. `RootView`
    /// watches this and pushes the one confirmation screen (§6A.5); it is a
    /// hand-off, not a holding area, and it is cleared as soon as the screen
    /// has it.
    @Published var pendingInvite: String?
    /// Pencil markup state. Lives here because the pill drives it and the score
    /// pane only reacts, the same reason highlightMode moved up in build 116.
    let annotation = AnnotationController()
    /// Sound. Lives here for the same reason: the transport drives it and the
    /// canvas only follows the play head.
    let playback = PlaybackEngine()

    /// Sidebar grouping: each piece with its arrangements resolved to ScoreDocs
    /// (pieces with no resolvable arrangements are dropped here — the full list,
    /// including empty pieces, stays available via manifest.pieces).
    var pieceSections: [(piece: PieceDoc, arrangements: [ScoreDoc])] {
        guard let m = manifest, let pieces = m.pieces else { return [] }
        return pieces.compactMap { piece in
            let scores = piece.arrangements.compactMap { slug in
                m.scores.first { $0.slug == slug }
            }
            return scores.isEmpty ? nil : (piece: piece, arrangements: scores)
        }
    }

    /// Sidebar setlists: each setlist with its arrangements resolved.
    var setlistSections: [(setlist: SetlistDoc, arrangements: [ScoreDoc])] {
        guard let m = manifest, let setlists = m.setlists else { return [] }
        return setlists.map { s in
            (setlist: s,
             arrangements: s.arrangements.compactMap { slug in
                 m.scores.first { $0.slug == slug }
             })
        }
    }

    /// Arrangements that could still be added to a setlist.
    func arrangementsNotIn(setlist: SetlistDoc) -> [ScoreDoc] {
        let inIt = Set(setlist.arrangements)
        return (manifest?.scores ?? [])
            .filter { !inIt.contains($0.slug) }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// Where an arrangement sits in the hierarchy: the piece it is filed under
    /// and its 1-based number within that piece. That number is what the UI
    /// shows as "#N" and what chat prompts mean by "#3".
    func placement(of slug: String) -> (piece: PieceDoc, number: Int)? {
        guard let pieces = manifest?.pieces,
              let piece = pieces.first(where: { $0.arrangements.contains(slug) }),
              let index = piece.arrangements.firstIndex(of: slug) else { return nil }
        return (piece, index + 1)
    }

    /// Scores not filed under any piece.
    var unfiledScores: [ScoreDoc] {
        guard let m = manifest else { return [] }
        let filed = Set((m.pieces ?? []).flatMap(\.arrangements))
        return m.scores.filter { !filed.contains($0.slug) }
    }

    /// What is open. Strictly what `selectedSlug` points at: an implicit
    /// "fall back to the most recently updated score" used to make a row the
    /// user never picked render as selected, and nothing could clear it —
    /// moving an arrangement into a piece updates it, so the moved row was the
    /// one that stuck. The convenience it provided (opening on the last score
    /// you touched) now happens as a real selection, in `adoptDefaultSelection`.
    var selectedScore: ScoreDoc? {
        guard let scores = manifest?.scores, let slug = selectedSlug else { return nil }
        return scores.first { $0.slug == slug }
    }

    /// First manifest of the session: open the most recently updated score, as
    /// an explicit selection the user can change or clear.
    private var hasAdoptedDefault = false

    func adoptDefaultSelection() {
        guard !hasAdoptedDefault, selectedSlug == nil,
              let scores = manifest?.scores, !scores.isEmpty else { return }
        hasAdoptedDefault = true
        selectedSlug = scores.max {
            ($0.versions.last?.time ?? "") < ($1.versions.last?.time ?? "")
        }?.slug
    }

    /// The score the sidebar's Versions section describes: the previewed one,
    /// falling back to whatever is open in the detail pane.
    var previewedScore: ScoreDoc? {
        guard let scores = manifest?.scores else { return nil }
        if let slug = previewedSlug, let s = scores.first(where: { $0.slug == slug }) { return s }
        return selectedScore
    }

    var displayedVersionID: String? {
        guard let score = selectedScore else { return nil }
        if let pin = pinnedVersion, score.versions.contains(where: { $0.id == pin }) { return pin }
        return score.latest
    }

    var displayedVersion: VersionDoc? {
        selectedScore?.versions.first { $0.id == displayedVersionID }
    }

    /// `v012`, for anywhere a person reads it. `displayedVersionID` is opaque
    /// and belongs in keys and comparisons only.
    var displayedVersionLabel: String? { displayedVersion?.name }

    /// The folder import a reader is looking at before deciding to run it.
    @Published var folderImportPlan: FolderImportPlan?
    @Published var folderImportBusy = false
    /// Pieces the reader has deselected on the plan screen. A whole exported
    /// library usually holds something that does not belong -- a fake book, a
    /// lyrics sheet -- and taking it out at import is easier than unpicking it
    /// afterwards.
    @Published var folderImportExcluded: Set<String> = []
    /// What the last run actually did, so the screen can report rather than
    /// just closing and leaving the reader to count rows.
    @Published var folderImportResult: String?

    /// Read a folder and work out the pieces and arrangements in it. Writes
    /// nothing.
    @discardableResult
    func previewFolderImport(at url: URL) async -> Bool {
        folderImportBusy = true
        defer { folderImportBusy = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // Listed HERE, inside the scope the picker granted: Python cannot
        // enumerate a file-provider folder (FolderScan).
        let files = FolderScan.relativePaths(in: url)
        guard !files.isEmpty else {
            notice = "Nothing to import from \u{201C}\(url.lastPathComponent)\u{201D} \u{2014} "
                   + "the folder looks empty. If it lives in iCloud Drive, open it "
                   + "in Files and download it first."
            return false
        }
        do {
            let payload = try await local.bulkImport(folder: url, files: files,
                                                     commit: false)
            guard let plan = FolderImportPlan.decode(payload, folder: url) else {
                notice = "That folder could not be read as a library."
                return false
            }
            guard !plan.isEmpty else {
                notice = "No scores in \u{201C}\(url.lastPathComponent)\u{201D}: "
                       + "\(files.count) file\(files.count == 1 ? "" : "s") found, "
                       + "none of them notation or PDF."
                return false
            }
            folderImportPlan = plan
            folderImportExcluded = []
            folderImportResult = nil
            return true
        } catch {
            notice = "That folder could not be imported: \(error.localizedDescription)"
            return false
        }
    }

    /// Run the plan the reader just approved.
    func commitFolderImport() async {
        guard let plan = folderImportPlan else { return }
        folderImportBusy = true
        defer { folderImportBusy = false }
        let scoped = plan.folder.startAccessingSecurityScopedResource()
        defer { if scoped { plan.folder.stopAccessingSecurityScopedResource() } }
        do {
            let payload = try await local.bulkImport(
                folder: plan.folder,
                files: FolderScan.relativePaths(in: plan.folder), commit: true,
                exclude: Array(folderImportExcluded))
            let result = payload["result"] as? [String: Any]
            let imported = (result?["imported"] as? [Any])?.count ?? 0
            let failed = (result?["failed"] as? [Any])?.count ?? 0
            folderImportResult = failed == 0
                ? "Imported \(imported) arrangements."
                : "Imported \(imported); \(failed) could not be read."
            await refresh()
        } catch {
            report("import that folder", error)
        }
    }

    /// Notation or a scan. Read from the artifact's own filename, so it is
    /// right even for a library written before scans existed.
    var displayedArtifact: ScoreArtifact.Kind {
        ScoreArtifact.kind(ofFile: displayedVersion?.file ?? "")
    }

    /// One sidebar/menu row of version history: either a single version, or
    /// the run of versions one chat prompt produced (face = its final state).
    struct VersionGroup: Identifiable {
        var id: String
        var title: String
        var face: VersionDoc
        var subs: [VersionDoc]
    }

    /// Consecutive versions stamped with the same turn id collapse into one
    /// group titled by the prompt; unstamped versions stand alone. Newest first.
    func versionGroups(for score: ScoreDoc) -> [VersionGroup] {
        var groups: [VersionGroup] = []
        for v in score.versions {
            if let turn = v.turn,
               var last = groups.last, last.face.turn?.id == turn.id {
                last.subs.append(v)
                last.face = v
                groups[groups.count - 1] = last
            } else {
                groups.append(VersionGroup(id: v.id,
                                           title: VersionLabel.text(
                                               op: v.op, prompt: v.turn?.prompt),
                                           face: v,
                                           subs: v.turn != nil ? [v] : []))
            }
        }
        return groups.reversed()
    }

    func startPolling() {
        // A measurement run asks for the readings in the log (-perfDump);
        // nothing happens without it.
        PerfMetrics.shared.startConsoleDumpIfRequested()
        // The rasters the canvas holds are the first thing worth giving back
        // under pressure: every one of them can be drawn again, and being
        // killed cannot be undone. The engravings go with them -- 24MB is
        // worth handing back even at 3 s to make one again, when the
        // alternative is the app disappearing under the reader.
        CanvasRasters.observeMemoryWarnings { Self.engravings.clear() }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
    }

    /// Files -> On My iPad -> Scoranger -> inbox: anything dropped there is
    /// ingested automatically (scores import, PDFs convert via cloud OMR).
    func scanInbox() {
        guard useLocalEngine else { return }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let inbox = docs.appending(path: "inbox")
        seedInboxOnce(into: inbox)
        let staging = docs.appending(path: ".ingesting")
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        // Notation, PDFs, and pictures of a page. The image list comes from
        // ScoreArtifact rather than being typed again, so a format added there
        // is accepted here without anyone remembering to.
        // Derived from ScoreArtifact rather than typed again: the notation
        // half used to be a second copy of that list, and the comment claiming
        // otherwise was half true. A format added there is accepted here now.
        let supported = ScoreArtifact.notationSuffixes.sorted() + ["pdf"]
            + ScoreArtifact.imageSuffixes.sorted()
        for f in (try? FileManager.default.contentsOfDirectory(
            at: inbox, includingPropertiesForKeys: nil)) ?? []
        where supported.contains(f.pathExtension.lowercased()) {
            let staged = staging.appending(path: f.lastPathComponent)
            try? FileManager.default.removeItem(at: staged)
            // atomic move claims the file; skip if Files is still copying it
            guard (try? FileManager.default.moveItem(at: f, to: staged)) != nil else { continue }
            receiveFile(at: staged)
        }
    }

    /// `-seedInboxFixture`: a UI test drops the bundled sample into the inbox
    /// the way the share extension does, once per launch, so the path from
    /// "something arrived" to "it is open" can be driven without a share sheet.
    ///
    /// `-seedInboxImage`: the same, with a PHOTOGRAPH -- page 1 of the bundled
    /// scan rasterised to a real .jpeg -- because an image is its own kind of
    /// artifact in the engine and the app, and 0.8's build 193 shipped with
    /// both halves broken for it (no Make editable, Details save failing on
    /// a music21 parse of the JPEG) while every PDF test stayed green.
    private var inboxSeeded = false
    private func seedInboxOnce(into inbox: URL) {
        let arguments = ProcessInfo.processInfo.arguments
        let wantsScore = arguments.contains("-seedInboxFixture")
        let wantsImage = arguments.contains("-seedInboxImage")
        let wantsABC = arguments.contains("-seedInboxABC")
        guard !inboxSeeded, wantsScore || wantsImage || wantsABC else { return }
        inboxSeeded = true
        if wantsABC {
            // A tune, dropped in the inbox the way a download from
            // thesession.org arrives, so the photograph is of the REAL import
            // path rather than a score placed in the library behind its back.
            //
            // Written here rather than shipped in samples-seed for two
            // reasons: a bundled `.abc` would trip check_no_bundled_scores,
            // which is right to flag music in the app's resources, and this
            // is the only fixture in the repo that has to be ABC -- the
            // format is text and there is no ABC writer to make one with.
            // Eight bars, synthetic, nobody's transcription.
            let tune = """
            X: 1
            T: The Shot Reel
            R: reel
            M: 4/4
            L: 1/8
            K: Edor
            |:E2BE dEBE|E2BE AFDF|E2BE dEBE|1 BABc dAFD:|2 BABc d2 ef||
            |:g2fg edBd|gfed BAFA|d2cd BAFA|DEFD E2 ef:|
            """
            try? FileManager.default.createDirectory(at: inbox,
                                                     withIntermediateDirectories: true)
            let dropped = inbox.appending(path: "The Shot Reel.abc")
            try? FileManager.default.removeItem(at: dropped)
            try? tune.write(to: dropped, atomically: true, encoding: .utf8)
            print("SCORANGER-SEED dropped \(dropped.lastPathComponent) in the inbox")
        }
        guard let seed = Bundle.main.resourceURL?.appending(path: "samples-seed") else { return }
        let samples = ((try? FileManager.default.contentsOfDirectory(
            at: seed, includingPropertiesForKeys: nil)) ?? [])
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        if wantsScore, let sample = samples.first(where: { $0.pathExtension.lowercased() == "mxl" }) {
            let dropped = inbox.appending(path: "Inbox test " + sample.lastPathComponent)
            try? FileManager.default.removeItem(at: dropped)
            try? FileManager.default.copyItem(at: sample, to: dropped)
            print("SCORANGER-SEED dropped \(dropped.lastPathComponent) in the inbox")
        }
        if wantsImage, let scan = samples.first(where: { $0.pathExtension.lowercased() == "pdf" }),
           let page = PDFDocument(url: scan)?.page(at: 0) {
            // A phone photographs a page at a few thousand pixels a side;
            // 1654 x 2339 is A4 at 200 dpi, enough for OMR to read.
            let bounds = page.bounds(for: .mediaBox)
            let scale = 1654 / max(bounds.width, 1)
            let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            let image = page.thumbnail(of: size, for: .mediaBox)
            if let jpeg = image.jpegData(compressionQuality: 0.9) {
                let dropped = inbox.appending(path: "Photo test.jpeg")
                try? FileManager.default.removeItem(at: dropped)
                try? jpeg.write(to: dropped)
                print("SCORANGER-SEED dropped \(dropped.lastPathComponent) (\(jpeg.count) bytes) in the inbox")
            }
        }
    }

    /// One-time Documents layout: inbox/ for auto-ingest, plus the chat hook
    /// folders. No samples folder: the library is whatever the user imported.
    func prepareDocumentsFolders() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: docs.appending(path: "inbox"),
                                                 withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: docs.appending(path: "inbox-chat"),
                                                 withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: docs.appending(path: "outbox-chat"),
                                                 withIntermediateDirectories: true)
    }

    /// Test fixture: one PDF arrangement, on request.
    ///
    /// Deliberately NOT part of `seedLibraryIfEmpty`: dozens of tests assert
    /// against that library's shape, and adding an arrangement to it would
    /// change counts and row order under all of them. It is also outside that
    /// function's empty-library guard, because the suite relaunches into an
    /// already-seeded library and the guard would skip this every time.
    func seedScanArrangementIfRequested() async {
        guard useLocalEngine,
              ProcessInfo.processInfo.arguments.contains("-seedScanArrangement")
        else { return }
        do {
            let existing = try await local.manifest().scores
            guard !existing.contains(where: { $0.slug.hasPrefix("scanned-score") }) else {
                return          // already there; importing again would stack copies
            }
            guard let seed = Bundle.main.resourceURL?.appending(path: "samples-seed"),
                  let scan = ((try? FileManager.default.contentsOfDirectory(
                    at: seed, includingPropertiesForKeys: nil)) ?? [])
                    .filter({ $0.pathExtension.lowercased() == "pdf" })
                    .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
                    .first else { return }
            _ = try await local.call(op: "import-pdf",
                                     args: ["path": scan.path,
                                            "name": "Scanned score",
                                            "piece": "Scanned score"])
            // A SECOND scan, for the pair Ali named: one arrangement being
            // transcribed and another that is PDF-only and is not. Without
            // two, the "different arrangement" in that sentence has to be
            // notation, which has no Make editable row to contradict.
            if ProcessInfo.processInfo.arguments.contains("-seedSecondScan") {
                _ = try await local.call(op: "import-pdf",
                                         args: ["path": scan.path,
                                                "name": "Another scan",
                                                "piece": "Another scan"])
            }
            await refresh()
        } catch {
            print("SCORANGER-SEED scan failed: \(error.localizedDescription)")
        }
    }

    /// Test fixture: a transcription queue with nothing on the network.
    ///
    /// Three jobs against real arrangements -- one running with a stage and a
    /// bar, two waiting -- so the queue and the per-score chip can be
    /// photographed and driven without an OMR service, an API key or
    /// Audiveris. It seeds the ROWS only: no work is enqueued, so nothing is
    /// uploaded and nothing finishes.
    func seedOMRQueueIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("-seedOMRQueue"),
              !pendingImports.contains(where: \.isTranscription) else { return }
        // The running one is a SCAN, transcribed on demand -- the only kind of
        // arrangement that can be. The waiting two are PDFs on their way in,
        // which belong to no arrangement yet; that is the mix a reader who
        // hands the app several pieces at once actually produces.
        // By slug, so which scan is the running one does not depend on import
        // order and the photographs can be named truthfully.
        guard let scan = (manifest?.scores ?? []).filter({
            ScoreArtifact.canBeMadeEditable(
                ScoreArtifact.kind(ofFile: $0.versions.last?.file ?? ""))
        }).min(by: { $0.slug < $1.slug }) else { return }
        let running = MakeEditable.converting(page: 2, pages: 9)
        pendingImports.append(PendingImport(name: scoreName(scan.slug) ?? scan.slug,
                                            arrangement: scan.slug,
                                            isTranscription: true, waiting: false,
                                            stage: running.stage,
                                            fraction: running.fraction))
        for name in ["Valse d'Amelie.pdf", "Padam padam.pdf"] {
            pendingImports.append(PendingImport(name: name,
                                                isTranscription: true, waiting: true))
        }
        restateTheQueue()
        print("SCORANGER-SEED omr queue: \(OMRQueue.summary(omrEntries) ?? "none")")
    }

    /// Test fixture only. The app ships with no sample library: a fresh install
    /// starts empty and fills up from what the user imports. UI tests need
    /// deterministic content, so they pass -seedTestLibrary to get it.
    func seedLibraryIfEmpty() async {
        guard useLocalEngine,
              ProcessInfo.processInfo.arguments.contains("-seedTestLibrary") else { return }
        do {
            let m = try await local.manifest()
            guard m.scores.isEmpty else { return }
            guard let seed = Bundle.main.resourceURL?.appending(path: "samples-seed") else { return }
            let files = ((try? FileManager.default.contentsOfDirectory(
                at: seed, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension.lowercased() == "mxl" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard !files.isEmpty else { return }
            let pieceName = "Sous le ciel de Paris"
            for f in files {
                _ = try await local.call(op: "import",
                                         args: ["path": f.path,
                                                "name": f.deletingPathExtension().lastPathComponent,
                                                "piece": pieceName])
            }
            for score in (try await local.manifest()).scores {
                _ = try await local.call(op: "assign-setlist",
                                         args: ["setlist": "Test setlist",
                                                "score": score.slug])
            }
            print("SCORANGER-SEED imported \(files.count) sample score(s)")
            // A book in the seeded library, for the library sync test: books
            // sync like everything else (0.16.0).
            if ProcessInfo.processInfo.arguments.contains("-seedTestBook") {
                let url = FileManager.default.temporaryDirectory
                    .appending(path: "Seeded Tunebook.pdf")
                if BigBookFixture.write(to: url, pages: 4) {
                    _ = try? await local.call(op: "import-book",
                                              args: ["path": url.path, "name": "Seeded Tunebook"])
                }
            }
            // A version-less arrangement, for the test that proves such a thing
            // explains itself instead of spinning on "Opening…". It cannot be
            // made through the normal path any more -- create_score rolls back
            // -- so the fixture writes the row directly.
            if ProcessInfo.processInfo.arguments.contains("-seedBrokenArrangement") {
                _ = try? await local.call(op: "debug-orphan-arrangement",
                                          args: ["slug": "broken-arrangement",
                                                 "name": "Morrison's jig"])
            }
            // The library the reader actually has: arrangements OMR'd before
            // the engine guarded the way in, each with the file name written
            // into its notation. Nothing can produce this shape any more, so
            // the fixture makes it deliberately -- and every screenshot of the
            // repair is then taken against the real damage rather than a
            // description of it.
            if ProcessInfo.processInfo.arguments.contains("-seedPoisonedTitles") {
                for score in (try await local.manifest()).scores {
                    _ = try? await local.call(op: "debug-poison-title",
                                              args: ["score": score.slug,
                                                     "title": "v001.mxl"])
                }
                print("SCORANGER-SEED poisoned the titles")
            }
            // Chord symbols to nudge. Neither sample score carries any, and
            // the chip's position-and-size row only appears for a selection of
            // adjustable elements -- so without this there is nothing to test
            // it against.
            if ProcessInfo.processInfo.arguments.contains("-seedChordChart"),
               let first = (try await local.manifest()).scores
                    .sorted(by: { $0.slug < $1.slug }).first {
                // "#0" targets the first part by INDEX. Reading a name out of
                // the manifest's parts snapshot made the fixture depend on when
                // that projection is populated, and it silently added nothing.
                let chart = (1...8).map { ["measure": $0,
                                           "symbol": ["C", "Dm7", "G7", "Am"][($0 - 1) % 4]] }
                do {
                    _ = try await local.call(op: "set-chords",
                                             args: ["score": first.slug,
                                                    "part": "#0",
                                                    "chords": chart])
                    print("SCORANGER-SEED chord chart on \(first.slug)")
                } catch {
                    print("SCORANGER-SEED chord chart FAILED: \(error)")
                }
            }
            // A STAFF OF NOTHING BUT MARKS, so the adjust row can be
            // reached by a finger at all.
            //
            // The row appears for a selection of ONE added mark, and a mark
            // engraves a few points across. Landing a synthetic tap or lasso
            // on one is a property of the engraving rather than of the code:
            // measured, a pinch reaches 1.0, 1.37, 1.61, 5.42 or 5.53 from run
            // to run, so the bars on screen afterwards are not the same twice.
            // Three earlier attempts to assert through the lasso were deleted
            // as flaky for the same reason (BACKLOG.md).
            //
            // So the fixture removes the problem rather than the test working
            // around it: a dynamic under every other bar of the top part and a
            // text mark over the ones between, so the staff is crowded with
            // the one kind of thing the row is about.
            //
            // Two things it deliberately does NOT do. It does not empty the
            // staff first -- `strip-notes` has no route through bridge.py, so
            // the app cannot ask for it (noted; that is step 2's business).
            // And it does not scale the marks up to make them easier to hit:
            // measured, a text mark drawn at 4x keeps the HIT FRAME of its
            // engraved size, because `ChordAdjustments.applySizes` rewrites
            // the tspan's font-size in the drawn SVG and the geometry is read
            // from the box the parser computes for it. Scaling up moved the
            // picture and not the target.
            if ProcessInfo.processInfo.arguments.contains("-seedMarkChart"),
               let first = (try await local.manifest()).scores
                    .sorted(by: { $0.slug < $1.slug }).first {
                var outcome: [String] = []
                var steps: [(String, [String: Any])] = []
                for bar in stride(from: 1, through: 24, by: 2) {
                    steps.append(("add-element",
                                  ["score": first.slug, "part": "#0",
                                   "kind": "dynamic", "value": "mf",
                                   "measure": bar, "placement": "below"]))
                }
                for bar in stride(from: 2, through: 24, by: 2) {
                    steps.append(("add-element",
                                  ["score": first.slug, "part": "#0",
                                   "kind": "text", "value": "dolce",
                                   "measure": bar, "placement": "above"]))
                }
                for (op, args) in steps {
                    do {
                        _ = try await local.call(op: op, args: args)
                    } catch {
                        outcome.append("\(op)=FAILED(\(error.localizedDescription))")
                        break
                    }
                }
                // The outcome goes where the test can see it, not to stdout:
                // app stdout is not in the xcodebuild log, so a step that
                // failed would be invisible and the shot would be of a score
                // that never got its marks.
                seedOutcome = "marks:"
                    + (outcome.isEmpty ? "ok" : outcome.joined(separator: " "))
            }
            // A guitar tab, which is the other half of the pagination
            // fixture. Ali's report is that a chat op which ADDS material --
            // a staff, a tab, chords -- collapses the page layout to one long
            // squished system, and those three are exactly the transforms
            // that make `VerovioRenderer.engrave` reload the document from
            // rewritten MEI. Chords are already seeded above; this is the tab.
            //
            // Through the engine rather than a canned file, so the fixture is
            // whatever `guitar-tab` really produces today.
            if ProcessInfo.processInfo.arguments.contains("-seedGuitarTab"),
               let first = (try await local.manifest()).scores
                    .sorted(by: { $0.slug < $1.slug }).first {
                do {
                    _ = try await local.call(op: "guitar-tab",
                                             args: ["score": first.slug,
                                                    "part": "#0"])
                    print("SCORANGER-SEED guitar tab on \(first.slug)")
                } catch {
                    print("SCORANGER-SEED guitar tab FAILED: \(error)")
                }
            }
            // ALI'S ACTUAL PROMPT, as one fixture. IMG_0196/0197: "Add a
            // second staff and add guitar tabs and below that put the guitar
            // chords with the core diagrams", on a two-staff folk tune, and
            // the page counter came back "p. 1 / 1" with the fingering row
            // crammed and overlapping.
            //
            // The separate fixtures above each paginate fine -- chords 8
            // pages, a tab 11 -- so if this collapses it is the COMBINATION,
            // and most likely the added staff: a taller system is the one
            // input that could push Verovio into a degenerate layout, and a
            // crammed fingering row is what a system that no longer fits its
            // page looks like. pull-part is what "add a second staff" is.
            // The ACCORDION SOLO by name, not "the first score": Ali's is a
            // two-staff folk tune, and the quartet is four staves and 136
            // bars, which paginates whatever you do to it and so cannot show
            // his fault.
            if ProcessInfo.processInfo.arguments.contains("-seedCombinedOp"),
               (try await local.manifest()).scores.contains(where: {
                   $0.slug == "under-paris-skies-accordion-solo" }) {
                let slug = "under-paris-skies-accordion-solo"
                let steps: [(String, [String: Any])] = [
                    ("pull-part", ["score": slug, "from": "v001",
                                   "part": "#0", "as": "Guitar"]),
                    ("guitar-tab", ["score": slug, "part": "Guitar"]),
                    ("set-chords", ["score": slug, "part": "Guitar",
                                    "chords": (1...8).map {
                                        ["measure": $0,
                                         "symbol": ["G", "C", "D", "Em"][($0 - 1) % 4]] }]),
                    ("chord-diagrams", ["score": slug, "part": "Guitar"]),
                ]
                // THE OUTCOME GOES WHERE THE TEST CAN SEE IT. It printed and
                // continued, and app stdout is not in the xcodebuild log, so
                // a pull-part that failed was invisible: the fixture reported
                // nothing, the geometry came back identical to the untouched
                // score, and the test read that as "no collapse". Three
                // preconditions were written before one of them noticed.
                var outcome: [String] = []
                for (op, args) in steps {
                    do {
                        _ = try await local.call(op: op, args: args)
                        outcome.append("\(op)=ok")
                    } catch {
                        outcome.append("\(op)=FAILED(\(error.localizedDescription))")
                        break   // the rest depend on this one having landed
                    }
                }
                seedOutcome = outcome.joined(separator: " ")
                print("SCORANGER-SEED combined: \(seedOutcome ?? "-")")
            }
            // A book the size of a Real Book. The browser's two faults -- a
            // flick that stopped the main thread once per page, and a picture
            // store bounded by a count -- do not show on a ten-page fixture,
            // so the test that guards them gets the size that broke.
            // A set list that has been JOINED, without any Firebase at all: the
            // engine binds it to a share somebody else owns, which is exactly
            // the state a recipient's library is in after §6A.5. What a UI test
            // can then assert without signing in: the row reads as shared, and
            // its share control opens the shared screen rather than re-sharing.
            if ProcessInfo.processInfo.arguments.contains("-seedSharedSetlist") {
                do {
                    let r = try await local.call(op: "create-setlist",
                                                 args: ["name": "Tuesday at the Ship"])
                    if let slug = r["slug"] as? String {
                        _ = try await local.call(op: "bind-setlist-share",
                                                 args: ["setlist": slug,
                                                        "shareId": "seed-share-tuesday",
                                                        "ownerUid": "seed-owner-somebody-else"])
                        for score in (try await local.manifest()).scores.prefix(2) {
                            _ = try await local.call(op: "assign-setlist",
                                                     args: ["setlist": slug, "score": score.slug])
                        }
                        print("SCORANGER-SEED shared set list \(slug)")
                    }
                } catch {
                    print("SCORANGER-SEED shared set list failed: \(error.localizedDescription)")
                }
            }
            if ProcessInfo.processInfo.arguments.contains("-seedBigBook") {
                await seedBigBook()
            }
            // The SHAPE of a real library, for the pictures Ali's list is
            // about: enough rows that the top of the list is off-screen, and
            // an arrangement filed under no piece beside the pieces -- the
            // two row kinds that contradicted each other on his screen.
            if ProcessInfo.processInfo.arguments.contains("-seedLibraryShape") {
                await seedLibraryShape()
            }
            await refresh()
            // `-autoDrag`: the frame probe's scripted drag needs a score open
            // with nobody at the device; the first seeded arrangement opens
            // the way an import does, in the layout the arguments name.
            if ProcessInfo.processInfo.arguments.contains("-autoDrag"),
               let first = manifest?.scores.first?.slug {
                if ProcessInfo.processInfo.arguments.contains("-autoDragContinuous") {
                    layout = .continuous
                }
                openAfterImport = first
            }
        } catch {
            print("SCORANGER-SEED failed: \(error.localizedDescription)")
        }
    }

    /// Test fixture only: a library long enough to scroll, with one
    /// arrangement left unfiled.
    ///
    /// Both halves are photographic evidence, not product: a library of one
    /// piece can never show a naming row landing off-screen, and the seeded
    /// library files every score under a piece, so it can never show the
    /// unfiled arrangement row beside a piece row.
    private func seedLibraryShape() async {
        // Sixteen, not forty. Each one is a separate trip through the bridge
        // and costs seconds in the simulator; sixteen rows under sixteen
        // letter headers is already several screens of list, which is all the
        // fixture is for.
        let names = ["All Blues", "Balkan Ornaments", "Ciribiribin", "Djangology",
                     "El Choclo", "Fascination", "Gnossienne", "Hejira",
                     "Indifference", "Jeux d'enfants", "Kalinka", "La Foule",
                     "Nuages", "Orient Express", "Padam padam",
                     "Quelqu'un m'a dit"]
        // The unfiling FIRST. `assign_score_to_piece` drops every piece left
        // holding nothing, so unfiling after the pieces are made deletes all
        // of them -- which is how the first run of this fixture produced a
        // library of one piece.
        if let last = try? await local.manifest().scores
            .sorted(by: { $0.slug < $1.slug }).last {
            _ = try? await local.call(op: "unassign-piece",
                                      args: ["score": last.slug])
        }
        for name in names {
            _ = try? await local.call(op: "create-piece", args: ["name": name])
        }
        print("SCORANGER-SEED library shape: \(names.count) pieces, one unfiled")
    }

    /// Test fixture only: a several-hundred-page book, made on the spot and
    /// imported. See `BigBookFixture`.
    private func seedBigBook() async {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "big-book-fixture.pdf")
        guard BigBookFixture.write(to: url) else {
            print("SCORANGER-SEED big book could not be written")
            return
        }
        do {
            let slug = try await local.importBook(fileURL: url, name: "Big Fake Book")
            print("SCORANGER-SEED big book \(slug), "
                  + "\(BigBookFixture.defaultPages) pages")
        } catch {
            print("SCORANGER-SEED big book failed: \(error.localizedDescription)")
        }
        try? FileManager.default.removeItem(at: url)
    }

    #if DEBUG
    /// Headless chat hook for automated testing: drop {"score", "message",
    /// "model"?} JSON into Documents/inbox-chat; the reply lands in
    /// Documents/outbox-chat/<name>.result.json and the console logs
    /// SCORANGER-CHAT begin/done lines.
    private var chatHookBusy = false
    private func scanChatInbox() {
        guard !chatHookBusy else { return }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let inbox = docs.appending(path: "inbox-chat")
        let outbox = docs.appending(path: "outbox-chat")
        let staging = docs.appending(path: ".ingesting")
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        for f in (try? FileManager.default.contentsOfDirectory(
            at: inbox, includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension.lowercased() == "json" {
            let staged = staging.appending(path: f.lastPathComponent)
            try? FileManager.default.removeItem(at: staged)
            // atomic move claims the file; skip if it's still being copied
            guard (try? FileManager.default.moveItem(at: f, to: staged)) != nil else { continue }
            guard let data = try? Data(contentsOf: staged),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let slug = obj["score"] as? String,
                  let message = obj["message"] as? String else {
                try? FileManager.default.removeItem(at: staged)
                continue
            }
            let model = obj["model"] as? String
            let name = f.lastPathComponent
            let result = outbox.appending(
                path: "\(f.deletingPathExtension().lastPathComponent).result.json")
            chatHookBusy = true
            print("SCORANGER-CHAT begin \(name)")
            Task {
                defer { chatHookBusy = false }
                var payload: [String: Any]
                var okText = "ok=true"
                do {
                    let turn = try await LocalChat().run(
                        slug: slug, message: message, modelAlias: model, historyJSON: nil,
                        context: chatContext(for: slug))
                    payload = ["ok": true, "reply": turn.reply]
                } catch {
                    payload = ["ok": false, "error": error.localizedDescription]
                    okText = "ok=false \(error.localizedDescription)"
                }
                if let d = try? JSONSerialization.data(withJSONObject: payload) {
                    try? d.write(to: result)
                }
                try? FileManager.default.removeItem(at: staged)
                print("SCORANGER-CHAT done \(okText)")
                await refresh()
            }
            break  // one request at a time
        }
    }
    #endif

    func refresh() async {
        // whatever happens below, we will have looked
        defer { libraryLoaded = true }
        scanInbox()
        #if DEBUG
        scanChatInbox()
        #endif
        do {
            let manifestSpan = PerfMetrics.shared.begin(PerfMetrics.Name.manifest)
            let m = useLocalEngine ? try await local.manifest() : try await client.manifest()
            manifestSpan?.end()
            // Only publish a manifest that differs. The poll runs every 1.5s,
            // and republishing an identical library rebuilt the whole sidebar
            // — including any open context menu — twice a second, which is why
            // a long-press could keep the app from ever going idle.
            if manifest != m { manifest = m }
            engineOK = true
            reportedEngineFailure = nil   // a later outage speaks again
            // Once per launch, and only after a manifest has arrived: the
            // manifest is what carries every old name beside its new one -- a
            // version's `vNNN` beside its opaque id, a score's slug beside its
            // uid -- so it is the only thing that can re-file a reader's pencil
            // marks onto the new key. Cheap when there is nothing to do.
            if !didMigrateAnnotationKeys {
                DrawingStore.shared.migrateKeys(manifest: m)
                didMigrateAnnotationKeys = true
            }
            // a selection pointing at a deleted score would otherwise leave the
            // canvas showing nothing with no row highlighted
            if let slug = selectedSlug, !m.scores.contains(where: { $0.slug == slug }) {
                selectedSlug = nil
                pinnedVersion = nil
            }
            adoptDefaultSelection()
            if modelCatalog == nil {
                if useLocalEngine {
                    modelCatalog = ModelCatalog(default: LocalChat.defaultModel,
                                                models: LocalChat.models)
                } else {
                    modelCatalog = try? await client.models()
                }
                if chatModel.isEmpty, let def = modelCatalog?.default { chatModel = def }
            }
            await renderIfNeeded()
        } catch {
            engineOK = false
            // Once per failure, not once per poll. `refresh` runs every two
            // seconds, so reporting each one would put the bar back a second
            // after it was dismissed -- and staying silent is how a Python
            // import error at launch became "the app does nothing".
            if useLocalEngine {
                let said = OperationReport.failure("reach the score engine", error: error)
                if reportedEngineFailure != said {
                    reportedEngineFailure = said
                    notice = said
                }
            }
        }
    }

    /// Re-fetch the PDF when the displayed (score, version) changes.
    func renderIfNeeded(force: Bool = false) async {
        guard let score = selectedScore, let vid = displayedVersionID else { return }
        // The LAYOUT is part of the key: continuous is a different engraving of
        // the same music, so switching to it has to re-engrave. The slug is
        // still the first component, so RenderTransition reads this as the
        // same score and keeps the current pages up until the new ones arrive
        // rather than blanking the canvas (#44).
        // The ENGRAVING, not the layout: one page and a spread are the same
        // pages counted out differently, so they share a key and a reader
        // toggling between them pays no engrave at all. Continuous is a
        // different document and has its own.
        let key = "\(score.slug)/\(vid)/\(layoutChoice.engraving.rawValue)"
        // Read ONCE, here, and used for both the engrave and the record of
        // what was engraved. Reading `layoutChoice` again after the await is
        // how a continuous engraving got recorded as a paged one.
        let engravedWith = layoutChoice
        guard force || key != renderedKey else { return }
        // A forced render is asked for when the FILE behind the key changed
        // under it, which is the one thing the cache cannot see.
        if force { Self.engravings.forget(key) }
        // Nothing, rather than the wrong thing -- but only when the thing has
        // actually changed.
        //
        // The document was only swapped once the new engrave arrived, so the
        // PREVIOUS score stayed on screen until then: opening an arrangement
        // showed the last one you had open, then flipped. A blank canvas for a
        // moment is honest about a score you have not opened yet.
        //
        // It is NOT honest about the score you are editing. Every op makes a
        // version, so this branch also fired on "transpose these bars up a
        // tone" -- blanking the whole page, throwing away which page the reader
        // was on, and clearing the selection the op had just been run on, which
        // `carrySelection` was then unable to carry because there was nothing
        // left to carry (#44). The previous engraving of the same music is the
        // best thing to show until the next one is ready.
        let transition = RenderTransition.between(previous: renderedKey, next: key)
        if transition.blanksTheCanvas {
            pageIndex = 0
            pdfDocument = nil
            renderedLayout = nil
            geometry = nil
            geometryKey = nil
            clearSelection()
        }
        renderedKey = key
        // Claimed for the WHOLE of this call, and released whatever happens to
        // it. While this is set the canvas knows a handover is in progress and
        // may keep drawing the engraving it has; cleared, a mismatch means the
        // handover failed and the choice wins instead.
        let engravingWanted = layoutChoice.engraving
        engravingInFlight = engravingWanted
        defer { if engravingInFlight == engravingWanted { engravingInFlight = nil } }
        loadingPDF = true
        defer { loadingPDF = false }
        // A render that does not finish must not claim the key. `renderedKey`
        // is set before the work so a second call cannot start the same
        // engrave, but if the work throws, the key names a render that never
        // happened -- and `key != renderedKey` is then false for ever, so the
        // geometry can never refresh. Stale geometry is exactly what a lasso
        // that draws but catches nothing looks like.
        var rendered = false
        defer { if !rendered && renderedKey == key { renderedKey = nil } }
        let renderSpan = PerfMetrics.shared.begin(PerfMetrics.Name.render)
        defer { renderSpan?.end() }
        do {
            let data: Data
            var model: ScoreGeometry?
            var engravedAdjustments: [ScoreAddress: ChordAdjustments.Adjustment] = [:]
            /// Which engraving this is, for the canvas's raster keys. Bumped
            /// only where a new one is actually made.
            var stamp = 0
            if useLocalEngine {
                let path = try await local.versionFilePath(score: score.slug, version: vid)
                let artifact = ScoreArtifact.kind(ofFile: path)
                if !artifact.isNotation {
                    // A scan the reader brought in -- a PDF or a photograph of
                    // a page. There is nothing to engrave: the artifact IS the
                    // pages, so it is shown exactly as it arrived. No geometry,
                    // which is what makes selection and chat editing
                    // unavailable until OMR turns it into notation.
                    //
                    // `isNotation` and not `== .scan`: there are two kinds of
                    // scan now, and an image falling through to the engraver
                    // would hand a JPEG to Verovio.
                    let raw = try Data(contentsOf: URL(fileURLWithPath: path))
                    guard let shown = ScanImage.displayable(raw, kind: artifact)
                    else { throw ScanImageError.undecodable }
                    data = shown
                    model = nil
                } else {
                    // one engrave: the pages drawn and the model hit-tested are
                    // the same Verovio load, or a lasso would select from a
                    // stale page
                    //
                    // ...and the same engrave twice is one engrave. `key`
                    // names the slug, the version AND the layout, so a reader
                    // toggling page / continuous / page paid three full
                    // engraves for two pictures -- and an engrave is the
                    // largest single cost in the app, 3.1 s median in a
                    // RELEASE build. Held here rather than inside the renderer
                    // because the actor is a toolkit, not a memory.
                    let held = try await Self.engravings.asyncValue(
                        for: key, cost: Self.engravingBytes,
                        make: {
                            let made = try await VerovioRenderer.shared.engrave(
                                musicXMLPath: path, layout: layoutChoice)
                            engravingCount += 1
                            return HeldEngraving(engraving: made,
                                                 stamp: engravingCount)
                        })
                    data = held.engraving.pdf
                    model = held.engraving.geometry
                    engravedAdjustments = held.engraving.markAdjustments
                    stamp = held.stamp
                }
            } else {
                data = try await client.exportPDF(score: score.slug, version: vid)
            }
            if renderedKey == key {  // selection may have moved while fetching
                rendered = true
                // Before the document, so the canvas the publish rebuilds
                // reads the key belonging to the pages it is handed.
                if stamp == 0 { engravingCount += 1; stamp = engravingCount }
                engravingKey = "\(key)#\(stamp)"
                pdfDocument = PDFDocument(data: data)
                // In the SAME publish as the document, or the canvas draws
                // one of them a frame before the other -- which is the flash
                // this pair exists to close.
                // The layout these pages were ENGRAVED with, captured with
                // `key` before the await -- not `layoutChoice`, which the
                // reader may have moved during a 3-second engrave, and which
                // would then record a continuous engraving as a paged one.
                renderedLayout = engravedWith
                // The reader's page is kept across an op, and an op can make
                // the score shorter -- an index past the end renders as no
                // pages at all, which is the blank canvas this was avoiding.
                pageIndex = PagedCanvas.clampedIndex(pageIndex,
                                                     pageCount: pdfDocument?.pageCount ?? 0)
                geometry = model
                markAdjustments = engravedAdjustments
                let previousKey = geometryKey
                geometryKey = key
                carrySelection(from: previousKey, to: key, into: model)
                // the addresses survived the re-render, so the session follows
                // them: nudge, commit, nudge again on the same symbol
                retargetAdjustment()
                // The sound is NOT carried over. A selection survives an op
                // because it still points at the same music; a performance
                // does not -- the op changed the notes. Rebuilding it is the
                // reader's next press of play, not this render's business.
                invalidatePlaybackIfStale()
                lastError = nil
            }
        } catch let e as EngineError {
            lastError = e.error
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Playback

    /// The version being listened to, which must be the version being LOOKED
    /// at. Audio from a version the reader has moved off is a lie the ear has
    /// no way to catch.
    private var playbackKey: String? {
        guard let slug = selectedScore?.slug, let vid = displayedVersionID else { return nil }
        return "\(slug)/\(vid)"
    }

    /// Is the mixer on screen, and where is it parked.
    ///
    /// Here rather than in the view because the transport opens it and the
    /// canvas draws it, the same reason the ink controller lives here.
    /// What the test-only combined-op seed did, step by step.
    ///
    /// Published so it can be surfaced beside the geometry probe: a fixture
    /// that silently failed is worse than one that never ran, because the
    /// test then measures an untouched score and calls it a pass.
    @Published var seedOutcome: String?

    @Published var pageFollow = PageFollow()

    /// True while the engine is writing the MIDI. A long score takes a moment
    /// and a dead play button reads as a dead app.
    @Published var playbackPreparing = false

    /// Whether the arrangement on screen can be played at all.
    ///
    /// A scan cannot: there is no notation behind it until OMR has run, which
    /// is the same reason selection and chat editing are unavailable on one.
    /// The remote engine cannot either -- `playback` is a bridge op, and
    /// `scor serve` has no route for it -- and the transport says so rather
    /// than offering a button that does nothing.
    var playbackAvailability: PlaybackAvailability {
        .of(artifact: displayedArtifact, omrBusy: omrBusy, localEngine: useLocalEngine)
    }

    /// The remedy the transport is offering, performed.
    ///
    /// The transport is a second way in, not a replacement: "Make editable" in
    /// the More screen still does the same thing, and keeping it is the rule --
    /// never remove the current access path in the build that adds a new one.
    func resolvePlaybackAvailability() {
        switch playbackAvailability {
        case .needsTranscription: makeEditable()
        // Settings belongs to the view that owns the screen stack; ContentView
        // handles that case before calling this.
        case .needsLocalEngine:   break
        case .available, .transcribing: break
        }
    }

    /// Build the performance for the version on screen, unless it is already
    /// built.
    ///
    /// Never awaited by `renderIfNeeded`, and never started by it: opening a
    /// score must not wait on music21 writing a MIDI file. This runs when the
    /// reader shows the transport or presses play, which is the first moment
    /// anyone wants the sound.
    func preparePlayback() async {
        guard playbackAvailability.canPlay, let key = playbackKey,
              let score = selectedScore else { return }
        guard playback.loadedKey != key, !playbackPreparing else { return }
        playbackPreparing = true
        defer { playbackPreparing = false }
        do {
            let performance = try await local.playback(score: score.slug,
                                                       version: displayedVersionID)
            // The reader may have moved to another version while music21 was
            // writing. Loading it now would put the previous arrangement under
            // the play head, which is exactly the lie this key exists to stop.
            guard playbackKey == key else { return }
            try playback.load(midi: performance.midi, timeline: performance.timeline,
                              key: key, slug: score.slug)
            playback.report(unavailable: nil)
            // A new performance is a new start: following is on. Nothing else
            // ever turned it back on -- `loadedSomethingElse()` existed and was
            // never called -- so one pan during playback switched the continuous
            // strip's following off for the rest of the session, across every
            // score, until the Sync chip was tapped. "The score doesn't scroll."
            pageFollow.loadedSomethingElse()
        } catch {
            // Said in the TRANSPORT, which is where someone who just pressed
            // play is looking, and not also in a notice: one failure, one
            // report. A failure to build the audio graph used to leave a play
            // button that did nothing and a voice list with nothing in it.
            playback.report(unavailable: OperationReport.reason(error))
        }
    }

    /// Press play. Prepares first when nothing is loaded, so the reader's
    /// first press is the only thing they have to do.
    func togglePlayback() {
        if playback.isPlaying { playback.stop(); return }
        // Pressing Play asks to be shown where the music is: the DAW rule, and
        // the way back from a pan that switched following off. The Sync chip
        // stays for asking without stopping.
        pageFollow.syncTapped()
        if playback.canPlay, playback.loadedKey == playbackKey {
            playback.play()
            return
        }
        Task {
            await preparePlayback()
            if playback.canPlay { playback.play() }
        }
    }

    /// Drop a performance that no longer matches the page.
    ///
    /// Every op makes a version, so this fires on "transpose these bars up a
    /// tone" as well as on switching arrangement -- and it should. The sound
    /// belonged to music that is no longer on screen.
    /// The reader turned a page themselves. Following yields until they ask
    /// for it back; the music is untouched.
    func readerTurnedPage() {
        guard playback.isPlaying, pageFollow.isFollowing else { return }
        pageFollow.readerTurnedPage()
    }

    func invalidatePlaybackIfStale() {
        guard let loaded = playback.loadedKey else { return }
        guard loaded != playbackKey else { return }
        playback.forget()
    }

    /// Run OMR on the scan being read, and add the transcription as the next
    /// version of the SAME arrangement.
    ///
    /// Only meaningful for a scan: notation is already editable.
    /// The slugs whose convert offer (SC13) has had an answer, either way.
    ///
    /// Persisted: a question answered on Tuesday must not be asked again on
    /// Wednesday just because the app was relaunched. In UserDefaults rather
    /// than in the workspace because it is a reader's preference about one
    /// device, not a fact about the arrangement -- and `TestReset` clears the
    /// whole domain, so a seeded test library starts unanswered.
    private static let convertAnsweredKey = "convertOfferAnswered"

    var convertOfferAnswered: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.convertAnsweredKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: Self.convertAnsweredKey) }
    }

    func recordConvertAnswer(for slug: String) {
        guard !slug.isEmpty else { return }
        var answered = convertOfferAnswered
        guard answered.insert(slug).inserted else { return }
        convertOfferAnswered = answered
    }

    func makeEditable() {
        guard let slug = selectedSlug,
              let version = displayedVersion,
              ScoreArtifact.canBeMadeEditable(ScoreArtifact.kind(ofFile: version.file))
        else { return }
        // One transcription per arrangement. Two of the same scan is two
        // versions of the same draft and twice the wait; asking again while it
        // is queued is a tap that must do nothing.
        guard omrStatus(for: slug) == nil else { return }
        // The place in the queue is claimed HERE, not inside `convertPDF`:
        // fetching the artifact's path is a round trip to the engine, and
        // until something was set both ways in -- the More screen's switch and
        // the transport's button -- read as idle and a second tap started a
        // second run on the same page.
        let claim = PendingImport(name: scoreName(slug) ?? slug, arrangement: slug,
                                  isTranscription: true, waiting: true,
                                  stage: "reading the scan…")
        pendingImports.append(claim)
        Task {
            do {
                let path = try await local.versionFilePath(score: slug, version: version.id)
                convertPDF(at: URL(fileURLWithPath: path), intoScore: slug,
                           claiming: claim.id)
            } catch {
                pendingImports.removeAll { $0.id == claim.id }
                notice = "That scan could not be opened for transcription: "
                       + OperationReport.reason(error)
            }
        }
    }

    /// What an arrangement is called, for a queue row that stands for it.
    private func scoreName(_ slug: String) -> String? {
        guard let score = manifest?.scores.first(where: { $0.slug == slug })
        else { return nil }
        return ScoreTitle.arrangementName(title: score.title, name: score.name,
                                          slug: score.slug)
    }

    /// Books opened for browsing, by slug. Not published: nothing redraws
    /// because a document was cached, and BookScreen holds its own.
    private var openBooks: [String: PDFDocument] = [:]

    /// The book itself, so it can be looked through.
    ///
    /// Held open while the screen showing it is: PDFKit reads pages lazily, so
    /// a four-hundred-page fake book costs a file handle rather than four
    /// hundred rasters, and `ThumbnailCache` bounds what is drawn from it.
    /// Keyed by slug because a reader flipping between two books should not
    /// pay to reopen either.
    ///
    /// nil where the file cannot be reached, which the screen says rather than
    /// showing an empty frame: the range fields still work, and a book you
    /// cannot see is exactly the state this feature exists to fix.
    func bookDocument(_ book: String) async -> PDFDocument? {
        if let open = openBooks[book] { return open }
        guard useLocalEngine else { return nil }
        do {
            let path = try await local.bookFilePath(book)
            guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else {
                return nil
            }
            openBooks[book] = document
            return document
        } catch {
            return nil
        }
    }

    /// Take a page range out of a book as a new arrangement.
    ///
    /// Returns the slug so the caller can open what it just made. The book is
    /// unchanged: the pages are copied.
    @discardableResult
    func extractFromBook(_ book: String, from: Int, to: Int, name: String,
                         piece: String?) async -> String? {
        do {
            let slug = try await local.extractFromBook(book, from: from, to: to,
                                                       name: name, piece: piece)
            await refresh()
            return slug
        } catch {
            // Said out loud, like the import above it. BookScreen shows a note
            // when it works and showed NOTHING when it did not.
            let reason = OperationReport.reason(error)
            notice = BookImportStage.extractionFailure(name: name, reason: reason)
            return nil
        }
    }

    /// Import a PDF as a BOOK: a collection to take arrangements out of.
    ///
    /// It says so on screen while it runs and says so when it fails. Both were
    /// missing: a fake book is a big file and the copy alone takes a while, so
    /// a silent Task looked exactly like a broken one -- and the failure it
    /// was actually hitting (pypdf was not vendored into the app) landed in
    /// `lastError`, which the library does not display.
    func importBook(at url: URL) {
        let name = url.deletingPathExtension().lastPathComponent
        let pending = PendingImport(name: name, target: .book,
                                    stage: BookImportStage.copying)
        pendingImports.append(pending)
        Task {
            defer { pendingImports.removeAll { $0.id == pending.id } }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let tmp = FileManager.default.temporaryDirectory
                    .appending(path: url.lastPathComponent)
                try await IncomingCopy.make(url, at: tmp)
                updatePending(pending.id, stage: BookImportStage.reading, fraction: nil)
                let slug = try await local.importBook(fileURL: tmp, name: name)
                try? FileManager.default.removeItem(at: tmp)
                await refresh()
                // 0.14.0: the book opens on its proposed contents. Nothing is
                // written by finding them -- the reader keeps them, takes the
                // tunes out, or discards the list.
                _ = await findTunes(in: slug, pending: pending.id)
                openBookAfterImport = slug
            } catch {
                let reason = OperationReport.reason(error)
                notice = BookImportStage.failure(name: name, reason: reason)
            }
        }
    }

    /// What `book-detect` proposed for a book, until the reader keeps it, takes
    /// the tunes out, or discards it. Held here rather than on the screen so
    /// the proposal made during an import is waiting when the book opens.
    @Published var bookProposals: [String: BookProposal] = [:]

    /// A book that was just imported, for the root to open on its proposal.
    @Published var openBookAfterImport: String?

    /// Where a book's tune-finding is, by slug, while it runs.
    @Published var findingTunes: [String: String] = [:]

    /// Propose a book's contents: bookmarks and text layer first, then Vision
    /// over the pages the engine says have neither, then the engine again
    /// with those lines. The judging is the engine's; this only reads pages.
    @discardableResult
    func findTunes(in slug: String, pending: UUID? = nil) async -> BookProposal? {
        let name = (manifest?.books ?? []).first { $0.slug == slug }?.name ?? "The book"
        func say(_ stage: String) {
            findingTunes[slug] = stage
            if let pending { updatePending(pending, stage: stage, fraction: nil) }
        }
        defer { findingTunes[slug] = nil }
        do {
            say(BookImportStage.finding)
            var proposal = try await local.bookDetect(slug)
            if !proposal.needsOcr.isEmpty, let document = await bookDocument(slug) {
                let ocr = await BookOCR.read(pages: proposal.needsOcr, of: document) { done, total in
                    Task { @MainActor in say(BookImportStage.scanning(done, of: total)) }
                }
                say(BookImportStage.finding)
                proposal = try await local.bookDetect(slug, ocr: ocr)
            }
            bookProposals[slug] = proposal
            return proposal
        } catch {
            notice = BookImportStage.detectionFailure(name: name,
                                                      reason: OperationReport.reason(error))
            return nil
        }
    }

    /// Keep the tunes as the book's contents: the book stays one book, read a
    /// tune at a time. nil clears them.
    func keepContents(of slug: String, _ entries: [BookEntry]?) async -> Bool {
        let name = (manifest?.books ?? []).first { $0.slug == slug }?.name ?? "the book"
        do {
            try await local.setBookContents(slug, entries: entries)
            bookProposals[slug] = nil
            await refresh()
            return true
        } catch {
            notice = BookImportStage.contentsFailure(name: name,
                                                     reason: OperationReport.reason(error))
            return false
        }
    }

    /// Take the tunes out as arrangements, each under a piece of its name.
    func takeOutTunes(of slug: String, _ entries: [BookEntry]) async -> BookSplitReport? {
        let name = (manifest?.books ?? []).first { $0.slug == slug }?.name ?? "the book"
        do {
            let report = try await local.splitBook(slug, entries: entries)
            bookProposals[slug] = nil
            await refresh()
            return report
        } catch {
            notice = BookImportStage.splitFailure(name: name,
                                                  reason: OperationReport.reason(error))
            return nil
        }
    }

    // MARK: Import as... (0.14.0 §1)

    /// Files shared into the app, waiting for the reader to say what they are.
    struct ImportOffer: Equatable {
        var urls: [URL]
        var canBeBook: Bool { ImportChoice.bookAvailable(for: urls) }
        var summary: String {
            urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent
                            : "\(urls.count) files"
        }
    }
    @Published var importOffer: ImportOffer?

    /// A file handed to the app from outside -- the share sheet, Open in,
    /// AirDrop. It is ASKED about rather than imported: until 0.14.0 a shared
    /// PDF could only become a scan arrangement, so a book could not be shared
    /// in at all. A bundle keeps its own offer (it is a library, not a file),
    /// and files arriving together are asked about together.
    func offerImport(_ url: URL) {
        if url.pathExtension.lowercased() == "scorbundle" {
            receiveFile(at: url)
            return
        }
        // Hold the file past the call: a security-scoped URL from another
        // app's share sheet is only good while it is being accessed.
        // The offer appears once the copy is made -- off the main thread, so
        // a big file arriving does not stall the screen (0.14.1).
        Task {
            let held = await holdIncoming(url) ?? url
            if var offer = importOffer {
                offer.urls.append(held)
                importOffer = offer
            } else {
                importOffer = ImportOffer(urls: [held])
            }
        }
    }

    func acceptImport(_ choice: ImportChoice) {
        guard let offer = importOffer else { return }
        importOffer = nil
        switch choice {
        case .newPiece:
            for url in offer.urls { receiveFile(at: url) }
        case .existingPiece(let piece):
            for url in offer.urls { receiveFile(at: url, intoPiece: piece) }
        case .newBook:
            guard offer.canBeBook else { return }
            importBook(at: offer.urls[0])
        }
    }

    func declineImport() {
        importOffer = nil
    }

    /// A copy of an incoming file in our own temporary directory, so the offer
    /// can wait on the reader without depending on the sender's grant.
    private func holdIncoming(_ url: URL) async -> URL? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dir = FileManager.default.temporaryDirectory.appending(path: "incoming")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let copy = dir.appending(path: url.lastPathComponent)
        do {
            try await IncomingCopy.make(url, at: copy)
            return copy
        } catch {
            return nil
        }
    }

    /// A file handed to us by the system (share sheet / "Open in").
    /// `piece` files the resulting arrangement under that piece (the sidebar's
    /// per-piece import); nil leaves it unfiled.
    /// Photographed pages: ONE arrangement of n pages, in the order picked
    /// (§15 ruling 2).
    ///
    /// Not n arrangements. Somebody photographing a score is photographing a
    /// piece, and the pages come back in selection order, which is the only
    /// ordering anyone could mean by tapping four pages of one chart.
    ///
    /// One page stays a picture, so it lands as an IMAGE arrangement exactly
    /// as a shared-in photograph does. Several become one document, because a
    /// multi-page thing in this library IS one -- and it then behaves like any
    /// other scan: it opens as it is, takes markup, and reads through
    /// make-editable.
    ///
    /// A reader who picked pages of DIFFERENT pieces gets one draft rather
    /// than being interrogated up front, and the notice says where to undo
    /// that -- the Book screen already splits a collection into arrangements,
    /// so there is nothing new to learn and nothing lost.
    func receivePhotographedPages(_ urls: [URL]) {
        guard let first = urls.first else { return }
        guard urls.count > 1 else {
            receiveFile(at: first, intoPiece: nil)
            return
        }
        let pages = urls.compactMap { try? Data(contentsOf: $0) }
        guard pages.count == urls.count,
              let document = ScanImage.pdf(fromPages: pages) else {
            notice = "Those pictures could not be read."
            return
        }
        let name = first.deletingPathExtension().lastPathComponent
        let file = FileManager.default.temporaryDirectory
            .appending(path: "\(name)-\(urls.count)-pages.pdf")
        do {
            try document.write(to: file)
        } catch {
            notice = "Those pictures could not be saved."
            return
        }
        receiveFile(at: file, intoPiece: nil)
        notice = "\(urls.count) pages imported as one arrangement, in the "
               + "order you picked them. If they were different pieces, open "
               + "it under Books to split them."
    }

    /// Read a bundle and offer it. Nothing is imported here.
    ///
    /// A security-scoped URL from Files or AirDrop has to be opened before the
    /// engine can read the bytes, and closed afterwards -- and it is copied
    /// somewhere the engine owns first, because the scope can end while the
    /// reader is still deciding whether to accept.
    func offerBundle(at url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let inbox = FileManager.default.temporaryDirectory
            .appending(path: "bundles", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let local = inbox.appending(path: url.lastPathComponent)
        do {
            try await IncomingCopy.make(url, at: local)
        } catch {
            notice = "Couldn't read that bundle: \(error.localizedDescription)"
            return
        }

        let seen: [String: Any]
        do {
            seen = try await self.local.call(op: "bundle-inspect",
                                             args: ["path": local.path])
        } catch {
            notice = "Couldn't read that bundle: \(error.localizedDescription)"
            return
        }
        guard let arrangements = seen["arrangements"] as? [[String: Any]],
              !arrangements.isEmpty else {
            notice = "That file is not a Scoranger bundle."
            return
        }

        let titles = arrangements.compactMap { $0["name"] as? String }
        let ink = arrangements.reduce(0) { $0 + (($1["ink_pages"] as? Int) ?? 0) }
        let summary: String
        if let setlist = seen["setlist"] as? String {
            summary = "\(setlist) — a setlist of \(titles.count) "
                + (titles.count == 1 ? "arrangement" : "arrangements")
        } else {
            summary = titles.first ?? "An arrangement"
        }
        var parts = [titles.joined(separator: ", ")]
        if ink > 0 { parts.append("\(ink) page\(ink == 1 ? "" : "s") of markup") }
        // Whose work it is, said plainly and not acted on. §12.12: the
        // classification rides along so a person can decide; it blocks nothing.
        if arrangements.allSatisfy({ ($0["provenance"] as? String) == "imported" }) {
            parts.append("scanned or imported material")
        }
        bundleOffer = BundleOffer(url: local, summary: summary,
                                  detail: parts.joined(separator: " · "))
    }

    /// Take the offered bundle in. New arrangements, never a merge (§13.3).
    func acceptBundle() async {
        guard let offer = bundleOffer else { return }
        bundleOffer = nil
        let got: [String: Any]
        do {
            got = try await local.call(
                op: "bundle-import",
                args: ["path": offer.url.path, "ink": DrawingStore.shared.dir.path])
        } catch {
            notice = "Couldn't add that bundle: \(error.localizedDescription)"
            return
        }
        guard let imported = got["imported"] as? [[String: Any]] else {
            notice = "Couldn't add that bundle."
            return
        }
        try? FileManager.default.removeItem(at: offer.url)
        await refresh()
        let names = imported.compactMap { $0["title"] as? String }
        let duplicates = (got["duplicates"] as? [String]) ?? []
        var said = "Added \(names.count) arrangement\(names.count == 1 ? "" : "s")."
        if !duplicates.isEmpty {
            // Flagged, never merged: two divergent chains are §7 rule 2's fork
            // problem and not worth solving for a file that arrived by AirDrop.
            said += " You already had \(duplicates.joined(separator: ", "))"
                + " — this is a second copy, not a replacement."
        }
        notice = said
        if let first = imported.first?["slug"] as? String { selectedSlug = first }
    }

    /// Write an arrangement or a setlist out as one shareable file.
    ///
    /// Returns where it landed, for the share sheet to hand to AirDrop. Markup
    /// travels with it: principle 5 does not stop applying because the sharing
    /// went over AirDrop rather than a cloud (§13.2).
    func exportBundle(target: String, fullHistory: Bool = false) async -> URL? {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "export", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appending(path: "\(target).scorbundle")
        var args: [String: Any] = ["target": target, "out": out.path,
                                   "ink": DrawingStore.shared.dir.path]
        if fullHistory { args["full_history"] = true }
        do {
            let made = try await local.call(op: "bundle-export", args: args)
            guard let path = made["path"] as? String else {
                notice = "Couldn't make that bundle."
                return nil
            }
            return URL(fileURLWithPath: path)
        } catch {
            notice = "Couldn't make that bundle: \(error.localizedDescription)"
            return nil
        }
    }

    func receiveFile(at url: URL, intoPiece piece: String? = nil) {
        // A bundle is somebody else's library arriving, not a file to import as
        // an arrangement. It is READ first and imported only if the reader says
        // so: a file that lands in Files and imports itself is not something
        // anyone asked for (design/FIREBASE.md §13.3).
        if url.pathExtension.lowercased() == "scorbundle" {
            Task { await offerBundle(at: url) }
            return
        }
        // ONE PIPELINE for both image routes (§15 ruling 1). A picture from
        // Files and a picture from the camera roll are the same thing once
        // there is a file, so the normalisation that makes the picker's
        // `public.image` umbrella truthful happens HERE rather than in either
        // picker -- a conversion on one route only is the drift the ruling
        // forbids.
        var url = url
        if ScoreArtifact.kind(ofFile: url.lastPathComponent) == .image
            || UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
            guard let usable = ScanImage.normalised(url) else {
                notice = "That picture could not be read."
                return
            }
            url = usable
        }
        if !ScoreArtifact.kind(ofFile: url.lastPathComponent).isNotation {
            // A scan comes in AS A SCAN -- a PDF or a photograph of a page.
            // It opens and takes markup immediately,
            // offline, with no service involved. It used to go straight to
            // cloud OMR, which meant a reader could not open their own scan
            // without a network and a wait, and got an imperfect transcription
            // instead of the page they know. `convertPDF` is kept: it is what
            // the explicit "make this editable" action will call.
            importPDF(at: url, intoPiece: piece)
        } else {
            importScore(from: url, intoPiece: piece)
        }
    }

    /// Import a PDF as a scan arrangement.
    func importPDF(at url: URL, intoPiece piece: String? = nil) {
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let tmp = FileManager.default.temporaryDirectory
                    .appending(path: url.lastPathComponent)
                try await IncomingCopy.make(url, at: tmp)
                let name = url.deletingPathExtension().lastPathComponent
                let slug = try await local.importPDF(fileURL: tmp, name: name, piece: piece)
                try? FileManager.default.removeItem(at: tmp)
                selectedSlug = slug
                previewedSlug = slug
                pinnedVersion = nil
                await refresh()
                openAfterImport = slug
            } catch {
                report("open that PDF", error)
            }
        }
    }

    /// PDF -> MusicXML through the cloud OMR service (Audiveris on Cloud Run),
    /// then import. Falls back to saving into Documents/intake when no
    /// service is configured.
    ///
    /// `intoScore` is OMR ON DEMAND: the transcription becomes the next
    /// version of that arrangement rather than a new one, so the scan the
    /// reader knows stays as v001 and the two can be compared with the version
    /// control. Without it, this is the old share-sheet path: a new
    /// arrangement from a PDF handed to the app from outside.
    ///
    /// It ENQUEUES. See `OMRQueue`: the work is serial on the service, so the
    /// client keeps an ordered queue of one at a time and every score says
    /// where in it its own transcription is.
    private func convertPDF(at url: URL, intoPiece piece: String? = nil,
                            intoScore: String? = nil,
                            claiming claimed: UUID? = nil) {
        let scoped = url.startAccessingSecurityScopedResource()
        let raw = try? Data(contentsOf: url)
        let name = url.deletingPathExtension().lastPathComponent
        if scoped { url.stopAccessingSecurityScopedResource() }

        /// Give the reader the reason and take the row back out of the queue.
        func abandon(_ why: String?) {
            if let claimed { pendingImports.removeAll { $0.id == claimed } }
            if let why { notice = why }
        }

        guard let raw else { return abandon("Couldn't read the scan.") }
        // The OMR service is handed `Content-Type: application/pdf`, so a
        // photograph is wrapped into a one-page PDF here rather than the
        // service learning about images. One helper does this and the score
        // view's own display, so what is transcribed is what was looked at.
        let kind = ScoreArtifact.kind(ofFile: url.lastPathComponent)
        guard let pdfData = ScanImage.displayable(raw, kind: kind) else {
            return abandon(ScanImageError.undecodable.errorDescription)
        }
        guard let endpoint = URL(string: omrURLString), !omrURLString.isEmpty else {
            abandon(nil)
            saveToIntake(pdfData, filename: url.lastPathComponent)
            return
        }
        // Notation software exports pages OMR cannot read: oversized, vector,
        // no raster layer. Re-render those before they go anywhere.
        let preflight = PDFPreflight.prepare(pdfData)
        if let note = preflight.note { print("SCORANGER-OMR preflight: \(note)") }

        // The bytes go to a file, not into the queue. A queue of scans held as
        // Data is a queue of tens of megabytes, and the reader is invited to
        // put several pieces in it.
        let spool: URL
        do {
            spool = try spoolOMRUpload(preflight.data, id: claimed ?? UUID())
        } catch {
            return abandon("Couldn't hold on to that scan: "
                           + OperationReport.reason(error))
        }

        let id: UUID
        if let claimed, pendingImports.contains(where: { $0.id == claimed }) {
            id = claimed
        } else {
            let pending = PendingImport(name: name, piece: piece,
                                        arrangement: intoScore,
                                        isTranscription: true, waiting: true,
                                        stage: OMRStatus.waiting(place: 1, of: 1).detail)
            pendingImports.append(pending)
            id = pending.id
        }
        omrWork[id] = OMRWork(id: id, name: name, piece: piece,
                              arrangement: intoScore, endpoint: endpoint,
                              spool: spool, preflightNote: preflight.note)
        restateTheQueue()
        pumpOMRQueue()
    }

    /// One transcription's inputs, held while it waits its turn. Not
    /// published: nothing on screen reads it, and the row beside it in
    /// `pendingImports` is what the reader sees.
    private struct OMRWork {
        let id: UUID
        let name: String
        let piece: String?
        /// The arrangement this becomes a new version of, or nil when it is
        /// becoming an arrangement of its own.
        let arrangement: String?
        let endpoint: URL
        /// The preflighted upload bytes, on disk.
        let spool: URL
        let preflightNote: String?
    }

    private func spoolOMRUpload(_ data: Data, id: UUID) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "omr-queue")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "\(id.uuidString).pdf")
        try data.write(to: file, options: .atomic)
        return file
    }

    /// Say where each waiting job is, so a row that has not started still
    /// reads as something rather than as a stalled upload.
    private func restateTheQueue() {
        let entries = omrEntries
        for (index, pending) in pendingImports.enumerated() where pending.isTranscription && pending.waiting {
            guard let status = OMRQueue.status(of: pending.id, in: entries) else { continue }
            let said = MakeEditable.detailText(status)
            if pendingImports[index].stage != said { pendingImports[index].stage = said }
            if pendingImports[index].fraction != nil { pendingImports[index].fraction = nil }
        }
    }

    /// Start the next transcription if a slot is free. Called when one is
    /// added and when one finishes; `OMRQueue.next` owns the decision.
    private func pumpOMRQueue() {
        guard let id = OMRQueue.next(in: omrEntries), let work = omrWork[id] else { return }
        guard let index = pendingImports.firstIndex(where: { $0.id == id }) else {
            omrWork[id] = nil
            return
        }
        pendingImports[index].waiting = false
        pendingImports[index].stage = "uploading…"
        pendingImports[index].fraction = 0
        Task { await runTranscription(work) }
    }

    private func finishTranscription(_ id: UUID) {
        if let spool = omrWork[id]?.spool { try? FileManager.default.removeItem(at: spool) }
        omrWork[id] = nil
        pendingImports.removeAll { $0.id == id }
        restateTheQueue()
        pumpOMRQueue()
    }

    private func runTranscription(_ work: OMRWork) async {
        defer { finishTranscription(work.id) }
        let endpoint = work.endpoint
        let name = work.name
        let uploadData: Data
        do {
            uploadData = try Data(contentsOf: work.spool)
        } catch {
            notice = "That scan is no longer where it was put: "
                   + OperationReport.reason(error)
            return
        }
            do {
                // stored key if present, baked-in default otherwise; a 401
                // self-heals below by falling back to the baked key
                let bakedKey = Self.bakedOMRKey
                var apiKey = Self.effectiveOMRKey

                // -- 1. submit the job (upload with byte progress) ------------
                var request = URLRequest(url: endpoint.appending(path: "jobs"))
                request.httpMethod = "POST"
                request.timeoutInterval = 120
                request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
                request.setValue("application/pdf", forHTTPHeaderField: "Content-Type")
                // BOTH headers while old builds are still in the field: every
                // install shipped so far sends only the key, so the service
                // accepts either and prefers the token. The key drops out of
                // here once those builds are gone, and not before -- a hard
                // cutover would 401 every existing iPad.
                if let bearer = await omrToken?() {
                    request.setValue("Bearer \(bearer)",
                                     forHTTPHeaderField: "Authorization")
                }

                let progressDelegate = UploadProgressDelegate { [weak self] sent in
                    Task { @MainActor in
                        self?.updatePending(work.id, stage: "uploading…", fraction: sent)
                    }
                }

                // Retry transient failures on a FRESH session each attempt:
                // a pooled HTTP/2 connection re-hits the same dead backend.
                var submitted: [String: Any] = [:]
                var attempt = 0
                while true {
                    attempt += 1
                    do {
                        let session = URLSession(configuration: .ephemeral)
                        defer { session.finishTasksAndInvalidate() }
                        let (d, response) = try await session.upload(
                            for: request, from: uploadData, delegate: progressDelegate)
                        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                        let body = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
                        if code == 202 { submitted = body; break }
                        if code == 401, !bakedKey.isEmpty, apiKey != bakedKey {
                            // stored key is wrong — self-heal with the baked one
                            apiKey = bakedKey
                            KeychainStore.omrKey = bakedKey
                            request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
                            continue
                        }
                        // 429 = single-instance service momentarily saturated
                        if code >= 500 || code == 429, attempt < 4 {
                            try await Task.sleep(for: .seconds(code == 429 ? 15 : 3))
                            continue
                        }
                        throw LocalEngineError.engine(
                            body["error"] as? String ?? "OMR service error (HTTP \(code))")
                    } catch let e as LocalEngineError {
                        throw e
                    } catch where attempt < 3 {
                        try await Task.sleep(for: .seconds(3))
                    }
                }
                guard let jobID = submitted["job"] as? String else {
                    throw LocalEngineError.engine("OMR service returned no job id")
                }

                // -- 2. poll for progress ------------------------------------
                let statusURL = endpoint.appending(path: "jobs/\(jobID)")
                var pollFailures = 0
                let pollDeadline = Date().addingTimeInterval(900)
                poll: while Date() < pollDeadline {
                    try await Task.sleep(for: .seconds(2))
                    var statusReq = URLRequest(url: statusURL)
                    statusReq.timeoutInterval = 15
                    statusReq.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
                    do {
                        let (d, _) = try await URLSession.shared.data(for: statusReq)
                        guard let s = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                              let state = s["state"] as? String else {
                            pollFailures += 1
                            if pollFailures > 10 { throw LocalEngineError.engine("lost contact with the OMR service") }
                            continue
                        }
                        pollFailures = 0
                        let page = s["page"] as? Int ?? 0
                        let pages = s["pages"] as? Int ?? 0
                        switch state {
                        case "queued":
                            let queue = s["queue"] as? Int ?? 0
                            updatePending(work.id,
                                          stage: queue > 0 ? "waiting (\(queue) ahead)…" : "waiting for converter…",
                                          fraction: nil)
                        case "converting":
                            // One place decides how converting reads, and it
                            // is unit-tested: `page` is the sheet being WORKED
                            // ON, so the bar behind it is `page - 1` and it
                            // never fills here (MakeEditable.converting).
                            let progress = MakeEditable.converting(page: page, pages: pages)
                            updatePending(work.id, stage: progress.stage,
                                          fraction: progress.fraction)
                        case "done":
                            break poll
                        case "failed":
                            throw LocalEngineError.engine(s["error"] as? String ?? "conversion failed")
                        default:
                            break
                        }
                    } catch let e as LocalEngineError {
                        throw e
                    } catch {
                        pollFailures += 1
                        if pollFailures > 10 { throw LocalEngineError.engine("lost contact with the OMR service") }
                    }
                }

                // -- 3. fetch result, import ---------------------------------
                updatePending(work.id, stage: "downloading…", fraction: nil)
                var resultReq = URLRequest(url: endpoint.appending(path: "jobs/\(jobID)/result"))
                resultReq.timeoutInterval = 60
                resultReq.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
                let (data, resultResp) = try await URLSession.shared.data(for: resultReq)
                guard (resultResp as? HTTPURLResponse)?.statusCode == 200 else {
                    let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                    throw LocalEngineError.engine(detail ?? "couldn't fetch the converted score")
                }

                updatePending(work.id, stage: "importing…", fraction: nil)
                let tmp = FileManager.default.temporaryDirectory.appending(path: "\(work.name).mxl")
                try? FileManager.default.removeItem(at: tmp)
                try data.write(to: tmp)
                let slug: String
                if let intoScore = work.arrangement {
                    // Prove it can be DRAWN before it becomes a version.
                    //
                    // OMR output is a draft and some of it cannot be engraved
                    // at all. Adding such a version made the arrangement open
                    // on "Render failed" with no way back -- and on a scan
                    // that is a strict loss, because the PDF the reader
                    // imported was perfectly readable a moment earlier. A
                    // transcription that cannot be drawn is not offered.
                    do {
                        _ = try await VerovioRenderer.shared.engrave(musicXMLPath: tmp.path)
                    } catch {
                        try? FileManager.default.removeItem(at: tmp)
                        notice = "That page could not be read into notation. "
                            + "The PDF is unchanged."
                        return
                    }
                    // the transcription joins the scan's own history
                    _ = try await local.addVersion(from: tmp, score: intoScore,
                                                   recordedAs: "omr")
                    slug = intoScore
                } else {
                    slug = try await local.importScore(fileURL: tmp, name: work.name, piece: work.piece)
                }
                try? FileManager.default.removeItem(at: tmp)
                // Follow it ONLY if the reader is already there, or if it is
                // brand new. With a queue a transcription can land while the
                // reader is reading something else, and jumping them off the
                // page they are on is what a background job must never do.
                // A new arrangement still opens: an import the reader asked
                // for wants to be seen (0.8.0 build 194, item 1).
                if work.arrangement == nil || selectedSlug == slug {
                    selectedSlug = slug
                    previewedSlug = slug
                    // follow the newest version, which is the transcription
                    pinnedVersion = nil
                }
                await refresh()
            } catch {
                notice = PDFPreflight.advice(name: name, error: error,
                                             preflight: work.preflightNote)
            }
    }

    /// Reports upload byte progress for the OMR job submission.
    final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate {
        let onProgress: (Double) -> Void
        init(onProgress: @escaping (Double) -> Void) { self.onProgress = onProgress }
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didSendBodyData bytesSent: Int64,
                        totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
            guard totalBytesExpectedToSend > 0 else { return }
            onProgress(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
        }
    }

    private func saveToIntake(_ data: Data, filename: String) {
        let intake = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "intake")
        try? FileManager.default.createDirectory(at: intake, withIntermediateDirectories: true)
        do {
            try data.write(to: intake.appending(path: filename))
            notice = "No OMR service configured (Settings) — PDF saved to Files → Scoranger → intake."
        } catch {
            notice = "Couldn't save the PDF: \(error.localizedDescription)"
        }
    }

    /// Import a MusicXML/MXL/MIDI file picked in the Files UI (local engine only).
    func importScore(from url: URL, intoPiece piece: String? = nil) {
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let tmp = FileManager.default.temporaryDirectory
                    .appending(path: url.lastPathComponent)
                try await IncomingCopy.make(url, at: tmp)
                let name = url.deletingPathExtension().lastPathComponent
                let slug = try await local.importScore(fileURL: tmp, name: name, piece: piece)
                try? FileManager.default.removeItem(at: tmp)
                selectedSlug = slug
                previewedSlug = slug
                pinnedVersion = nil
                await refresh()
                openAfterImport = slug
            } catch {
                report("import that file", error)
            }
        }
    }

    /// Open a score in the detail pane, optionally pinned to a version
    /// (nil = follow latest).
    // Navigation on compact is driven explicitly by ContentView's
    // preferredCompactColumn — no List-selection tricks needed here.
    func select(slug: String, version: String? = nil) {
        // A selection describes elements of the engraving it was drawn on, so
        // it goes when the subject changes: another arrangement, or a version
        // the user deliberately picked.
        //
        // The distinction #8 needs, and which this is half of: a selection
        // SURVIVES the new version an op produces, because that is the same
        // passage a moment later and the user is likely to run another op on
        // it. It does NOT survive being taken somewhere else. Both arrive as
        // "the version changed"; only this path is the user asking for it.
        if slug != selectedSlug || version != nil {
            clearSelection()
        }
        selectedSlug = slug
        previewedSlug = slug
        pinnedVersion = version
        Task { await renderIfNeeded() }
    }

    /// The OMR key baked in at build time (gitignored .omr-api-key), and the
    /// key the app actually sends: a saved one wins, the built-in one is the
    /// fallback. Settings tests this value rather than whatever is typed in the
    /// field, which is empty precisely when the built-in key is in use.
    static let bakedOMRKey: String =
        (Bundle.main.url(forResource: "omr-default-key", withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

    static var effectiveOMRKey: String {
        let stored = KeychainStore.omrKey
        return stored.isEmpty ? bakedOMRKey : stored
    }

    /// The metadata as it stands in the notation of a version -- which is what
    /// engraves on the page. The score doc carries a copy, but only versions
    /// written since the projection landed, so the sheet asks the engine.
    struct ScoreMetadata: Equatable {
        var title: String?
        var composer: String?
        var arranger: String?
    }

    func scoreMetadata(slug: String, version: String? = nil) async -> ScoreMetadata? {
        guard useLocalEngine else { return nil }
        var args: [String: Any] = ["score": slug]
        if let version { args["version"] = version }
        guard let r = try? await local.call(op: "info", args: args) else { return nil }
        return ScoreMetadata(title: r["title"] as? String,
                             composer: r["composer"] as? String,
                             arranger: r["arranger"] as? String)
    }

    /// Edit an arrangement's metadata. The title is one value: the name in the
    /// library and the title engraved at the top of the page. Because the
    /// engraved title lives in the notation, the engine appends a version, so
    /// this clears any pin to put the freshly engraved version on screen.
    /// Pass nil to leave a field alone, "" to clear a credit.
    @discardableResult
    func setScoreMetadata(slug: String, title: String? = nil,
                          composer: String? = nil, arranger: String? = nil) async -> Bool {
        var args: [String: Any] = ["score": slug]
        if let title {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            args["title"] = trimmed
        }
        if let composer { args["composer"] = composer.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let arranger { args["arranger"] = arranger.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard args.count > 1 else { return false }
        do {
            _ = try await local.call(op: "set-metadata", args: args)
            if slug == selectedSlug { pinnedVersion = nil }
            await refresh()
            return true
        } catch {
            report("save those details", error)
        }
        return false
    }

    /// Arrangements engraving an internal file name instead of a title.
    ///
    /// Read from the library every time it is asked, never remembered: see
    /// TitleRepair for why a flag would be the wrong shape.
    var titleRepairsNeeded: [String] {
        TitleRepair.affected(manifest?.scores ?? [])
    }

    /// Fix them, the legitimate way: the engine adds a corrected version to
    /// each. Returns (repaired, failed).
    func repairTitles() async -> (repaired: Int, failed: Int) {
        do {
            let r = try await local.call(op: "repair-titles", args: ["apply": true])
            let affected = (r["affected"] as? Int) ?? 0
            let failed = ((r["failed"] as? [Any]) ?? []).count
            pinnedVersion = nil
            await refresh()
            return (affected, failed)
        } catch {
            report("fix those titles", error)
            return (0, 0)
        }
    }

    /// The arrangement's title. Kept as its own call because renaming is what
    /// callers ask for; the work is setScoreMetadata's, so a rename can never
    /// leave the page saying something else.
    @discardableResult
    func renameScore(slug: String, name: String) async -> Bool {
        await setScoreMetadata(slug: slug, title: name)
    }

    /// Where a moved arrangement went. A pushed screen holds the slug it was
    /// opened with, and moving the arrangement is something you do ON that
    /// screen -- without this the screen and everything above it resolve to
    /// nothing the instant the move lands.
    @Published var movedSlugs: [String: String] = [:]

    /// Follows a chain of moves to whatever the slug is called now.
    func currentSlug(for slug: String) -> String {
        var now = slug
        var hops = 0
        while let next = movedSlugs[now], hops < 8 { now = next; hops += 1 }
        return now
    }

    /// Change the slug an arrangement is filed under.
    ///
    /// The engine moves the artifacts and rewrites every reference it owns; the
    /// app owns three things keyed by slug — the current selection, the pencil
    /// annotations and the mixer's instrument choices — and moves those here.
    /// Returns the slug actually used (it is normalized), or nil if the rename
    /// was refused.
    @discardableResult
    func renameSlug(slug: String, to newSlug: String) async -> String? {
        let trimmed = newSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            let r = try await local.call(op: "rename-slug",
                                        args: ["score": slug, "to": trimmed])
            guard let now = r["score"] as? String else { return nil }
            if now != slug {
                movedSlugs[slug] = now
                DrawingStore.shared.rename(fromPrefix: slug, toPrefix: now)
                PlaybackInstrumentStore.shared.rename(from: slug, to: now)
                if selectedSlug == slug { selectedSlug = now }
                if previewedSlug == slug { previewedSlug = now }
                renderedKey = nil   // the render is keyed by slug/version
            }
            await refresh()
            return now
        } catch {
            report("change that arrangement's short name", error)
        }
        return nil
    }

    /// Rename a part (the staff label, engraved on every system).
    @discardableResult
    func renamePart(slug: String, part: String, name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != part else { return false }
        do {
            _ = try await local.call(op: "rename-part",
                                     args: ["score": slug, "part": part, "name": trimmed])
            if slug == selectedSlug { pinnedVersion = nil }
            await refresh()
            return true
        } catch {
            report("rename that part", error)
        }
        return false
    }

    /// Bring the Newzik metadata across, once.
    ///
    /// The library arrived as a folder of PDFs, which carry none: the composer,
    /// the tags and the corrected spellings lived in Newzik and reached the
    /// export only as folder names. This matches them back onto the pieces by
    /// name (`MetadataMigration`) and writes what is missing.
    ///
    /// It fills in; it does not overwrite. A piece that already carries a
    /// composer or tags keeps them, so running it again after importing more
    /// pieces does the new ones and leaves the rest alone. The flag is only
    /// there to keep it off the startup path forever.
    @discardableResult
    func applyBundledMetadataIfNeeded(force: Bool = false) async -> Int {
        let key = "newzik-metadata-applied"
        if !force && UserDefaults.standard.bool(forKey: key) { return 0 }
        let entries = MetadataMigration.bundled()
        guard !entries.isEmpty else { return 0 }
        guard let pieces = manifest?.pieces, !pieces.isEmpty else { return 0 }

        let plan = MetadataMigration.plan(entries: entries, pieces: pieces)
        var written = 0
        for action in plan.actions {
            do {
                if let rename = action.rename {
                    _ = try await local.call(op: "rename-piece",
                                             args: ["piece": action.slug, "name": rename])
                }
                var args: [String: Any] = ["piece": action.slug]
                if !action.composer.isEmpty { args["composer"] = action.composer }
                if !action.arranger.isEmpty { args["arranger"] = action.arranger }
                if !action.tags.isEmpty { args["tags"] = action.tags }
                if args.count > 1 {
                    _ = try await local.call(op: "set-piece-metadata", args: args)
                }
                written += 1
            } catch {
                // INTERNAL, deliberately silent. One piece failing is not a
                // reason to abandon the other 39, and this migration is not
                // something the reader asked for -- a bar apiece, forty times,
                // over work nobody requested, is worse than saying nothing.
                // What it did NOT write stays visibly blank on the piece.
                print("SCORANGER-MIGRATE piece \(action.slug): \(error)")
            }
        }
        UserDefaults.standard.set(true, forKey: key)
        if written > 0 { await refresh() }
        return written
    }

    /// Set a piece's own composer, arranger and tags.
    @discardableResult
    func setPieceMetadata(_ slug: String, composer: String? = nil,
                          arranger: String? = nil, tags: [String]? = nil) async -> Bool {
        var args: [String: Any] = ["piece": slug]
        if let composer { args["composer"] = composer }
        if let arranger { args["arranger"] = arranger }
        if let tags { args["tags"] = tags }
        do {
            _ = try await local.call(op: "set-piece-metadata", args: args)
            await refresh()
            return true
        } catch {
            report("save that piece's details", error)
        }
        return false
    }

    /// Rename a piece (the grouping). Its slug is immutable, like a score's.
    @discardableResult
    func renamePiece(piece: String, name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            _ = try await local.call(op: "rename-piece",
                                     args: ["piece": piece, "name": trimmed])
            await refresh()
            return true
        } catch {
            report("rename that piece", error)
        }
        return false
    }

    /// Duplicate an arrangement into a new independent copy (new slug, its own
    /// history, filed under the same piece). Returns the copy's slug.
    @discardableResult
    /// Write an arrangement out as a file the user can share.
    ///
    /// The file is named for the arrangement, not for its version id, because
    /// it is about to leave the app: "v003.musicxml" tells nobody anything once
    /// it is sitting in Files. A PINNED version is named too, since that is
    /// part of what the file is.
    ///
    /// PDF is engraved HERE rather than in the bridge. That is the one thing to
    /// keep straight in this function: chord-symbol adjustments and whistle
    /// fingerings are applied in the Swift render pass, so a PDF from anywhere
    /// else would not match the page on screen. `bridge.py` refuses PDF for the
    /// same reason.
    func exportFile(slug: String, version: String?,
                    format: ScoreExport.Format) async -> URL? {
        guard let score = manifest?.scores.first(where: { $0.slug == slug }) else {
            notice = "Couldn't export: there is no arrangement '\(slug)'."
            return nil
        }
        // The version LABEL, not the id: this becomes the filename the reader
        // sees in Files and mails to someone, and
        // "Quartet 01M1AK5E1YN2NQS5W2VEC214T8.pdf" is not a name anybody can use.
        let name = ScoreExport.filename(
            title: ScoreTitle.arrangementName(title: score.title, name: score.name,
                                              slug: score.slug),
            version: version.flatMap { v in score.versions.first { $0.id == v }?.name } ?? version,
            format: format)
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("export", isDirectory: true)
            .appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            if format.isRenderedOnDevice {
                guard useLocalEngine else {
                    let data = try await client.exportPDF(score: slug, version: version)
                    try data.write(to: dest)
                    return dest
                }
                let source = try await local.versionFilePath(score: slug, version: version)
                let data = try await VerovioRenderer.shared.renderPDF(musicXMLPath: source)
                try data.write(to: dest)
            } else {
                let produced = try await local.exportFile(score: slug, version: version,
                                                          format: format.rawValue)
                try FileManager.default.copyItem(at: URL(fileURLWithPath: produced), to: dest)
            }
            return dest
        } catch {
            report("export that arrangement", error)
        }
        return nil
    }

    func duplicateScore(slug: String, name: String? = nil) async -> String? {
        do {
            var args: [String: Any] = ["score": slug]
            if let name { args["name"] = name }
            let r = try await local.call(op: "duplicate", args: args)
            await refresh()
            return r["score"] as? String
        } catch {
            report("duplicate that arrangement", error)
        }
        return nil
    }

    /// File a score under a piece (nil = remove from its piece). The piece is
    /// created on the engine side if it doesn't exist yet.
    func assignToPiece(scoreSlug: String, piece: String?) {
        Task {
            do {
                if let piece {
                    _ = try await local.call(op: "assign-piece",
                                             args: ["score": scoreSlug, "piece": piece])
                } else {
                    _ = try await local.call(op: "unassign-piece", args: ["score": scoreSlug])
                }
                await refresh()
            } catch {
                report("file that arrangement", error)
            }
        }
    }

    /// Create a blank arrangement (one part, one empty 4/4 bar) filed under a
    /// piece. Returns the new score's slug so the caller can open it.
    func createArrangement(pieceSlug: String, name: String? = nil) async -> String? {
        do {
            var args: [String: Any] = ["piece": pieceSlug]
            if let name { args["name"] = name }
            let r = try await local.call(op: "create-arrangement", args: args)
            await refresh()
            return r["score"] as? String
        } catch {
            report("create the arrangement", error)
        }
        return nil
    }

    #if DEBUG
    /// Test fixture: run several ops inside one chat turn, so the sidebar has a
    /// prompt group with intermediate steps to expand. Only reachable under
    /// -seedTestLibrary, alongside the rest of the test scaffolding.
    func seedMultiStepTurnIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("-seedTestLibrary"),
              let slug = manifest?.scores.first(where: { $0.versions.count == 1 })?.slug
        else { return }
        do {
            _ = try await local.call(op: "begin-turn",
                                     args: ["score": slug,
                                            "prompt": "transpose up then back down"])
            _ = try await local.call(op: "transpose", args: ["score": slug, "interval": "2"])
            _ = try await local.call(op: "transpose", args: ["score": slug, "interval": "-2"])
            _ = try await local.call(op: "end-turn", args: [:])
            await refresh()
            print("SCORANGER-SEED multi-step turn on \(slug)")
        } catch {
            print("SCORANGER-SEED turn failed: \(error.localizedDescription)")
        }
    }
    #endif

    /// One-time cleanup for devices carrying the setlist the old seeding made.
    /// The samples concept is gone (build 116) but the row it created lives in
    /// the on-device workspace, which app updates do not touch, so it has to be
    /// renamed in place. Exact-name match only, and it runs once.
    func migrateSeededSetlistName() async {
        guard useLocalEngine, !didMigrateSetlistNames else { return }
        guard let setlists = manifest?.setlists else { return }  // retry next refresh
        didMigrateSetlistNames = true
        guard let stale = setlists.first(where: { $0.name == "Samples" }) else { return }
        if await renameSetlist(setlist: stale.slug, name: "Set List 1") {
            print("SCORANGER-MIGRATE renamed setlist 'Samples' -> 'Set List 1'")
        }
    }

    /// Create an empty setlist. Returns the slug the engine filed it under,
    /// which is not always slugify(name) — a second "Gig night" becomes
    /// "gig-night-2", and the caller needs the real one to fill it.
    @discardableResult
    func createSetlist(name: String) async -> String? {
        do {
            let r = try await local.call(op: "create-setlist", args: ["name": name])
            await refresh()
            return r["slug"] as? String
        } catch {
            report("create that set list", error)
        }
        return nil
    }

    /// Add an arrangement to a setlist (no-op if already in it).
    @discardableResult
    func addToSetlist(setlist: String, score: String) async -> Bool {
        await runSetlistOp(op: "assign-setlist",
                           args: ["setlist": setlist, "score": score])
    }

    /// Drop an arrangement from a setlist. The arrangement itself is untouched.
    @discardableResult
    func removeFromSetlist(setlist: String, score: String) async -> Bool {
        await runSetlistOp(op: "unassign-setlist",
                           args: ["setlist": setlist, "score": score])
    }

    @discardableResult
    func renameSetlist(setlist: String, name: String) async -> Bool {
        await runSetlistOp(op: "rename-setlist", args: ["setlist": setlist, "name": name])
    }

    /// Rename a book, which is a LABEL and nothing else: the slug names the
    /// stored PDF and every extraction's recorded args, so the engine refuses
    /// to move it (`workspace.rename_book`). The row's title is the only thing
    /// a reader is changing, and no UI here may suggest otherwise.
    @discardableResult
    func renameBook(_ book: String, name: String) async -> Bool {
        do {
            try await local.renameBook(book, name: name)
            await refresh()
            return true
        } catch {
            report("rename that book", error)
        }
        return false
    }

    /// Delete a setlist. Only the grouping goes; pieces and arrangements stay.
    @discardableResult
    func deleteSetlist(_ setlist: String) async -> Bool {
        await runSetlistOp(op: "delete-setlist", args: ["setlist": setlist])
    }

    /// Leave a shared set list: membership first, then the local row.
    ///
    /// Both halves, in that order, because they used to be one half each in
    /// two different places. "Leave this set list" on the shared screen
    /// removed the membership and left the row in the library; Edit-mode
    /// delete removed the row and left the membership. Either way a person
    /// ended up with something they could not get rid of -- Ali's wife with a
    /// joined set list of 0 arrangements that nothing would delete.
    ///
    /// The membership goes FIRST so a failure there leaves the row, which is
    /// the state that can be retried; the reverse leaves a phantom membership
    /// with no row to act on it from.
    func leaveSharedSetlist(_ setlist: SetlistDoc, shared: SharedSetlists,
                            uid: String) async -> Bool {
        guard let shareId = setlist.shareId else { return await deleteSetlist(setlist.slug) }
        do {
            try await shared.removeMember(uid, from: shareId)
        } catch {
            report("leave that set list", error)
            return false
        }
        return await deleteSetlist(setlist.slug)
    }

    /// Delete a shared set list for everybody: the document, then the local
    /// row. The owner's alone (`SetlistPermission`), and the shared screen says
    /// so in those words before it lets them.
    func deleteSharedSetlistEverywhere(_ setlist: SetlistDoc, shared: SharedSetlists,
                                       remote: SharedSetlists.Setlist) async -> Bool {
        do {
            try await shared.delete(remote)
        } catch {
            report("delete that set list", error)
            return false
        }
        return await deleteSetlist(setlist.slug)
    }

    /// This device's copy of a shared set list entry, importing it if this is
    /// the first time the entry has been opened here.
    ///
    /// Once imported it is an ORDINARY ARRANGEMENT: the same reader, the same
    /// pencil, the same playback, readable offline forever. That is principle
    /// 1 of design/FIREBASE.md §0 taken literally rather than a shortcut -- a
    /// separate read-only viewer for cloud scores would be a second reader to
    /// keep in step with the first, and the first is the whole app.
    ///
    /// Idempotent, and cheap on every call after the first: the entry's local
    /// slug is remembered per device (`SharedEntryCopies`), and re-checked
    /// against the manifest because the reader may since have deleted it.
    ///
    /// `download` is passed in rather than reached for, so this function has
    /// no opinion about Firebase and can be exercised without it.
    func adoptSharedEntry(_ entryId: String, title: String,
                          download: () async throws -> URL) async -> String? {
        if let slug = sharedCopies.localSlug(forEntry: entryId),
           (manifest?.scores ?? []).contains(where: { $0.slug == slug }) {
            return slug
        }
        do {
            let file = try await download()
            // Through the ordinary import, which is what gives it a uid of its
            // own. Two devices importing the same shared copy must NOT claim
            // the same identity: it arrived from outside, and that is what
            // `bundle.ARRIVED_FROM_OUTSIDE` records about it.
            //
            // WHICH import, and WHERE the slug is, are SharedEntryImport's --
            // pinned there against the shapes the bridge returns, because
            // both were wrong here: a PDF went to the notation parser, and
            // the slug was read as a dictionary when it is a string, so six
            // successful imports were reported as failures and none was filed.
            let result = try await local.call(op: SharedEntryImport.op(for: file),
                                              args: ["path": file.path,
                                                     "name": title])
            guard let slug = SharedEntryImport.slug(in: result) else {
                report("open that arrangement",
                       SharedSetlists.Trouble.unusablePayload)
                return nil
            }
            sharedCopies.remember(entryId: entryId, localSlug: slug)
            await refresh()
            return slug
        } catch {
            report("open that arrangement", error)
            return nil
        }
    }

    /// Join a shared set list: claim the invitation, then MAKE IT A SET LIST
    /// HERE (design/FIREBASE.md §6A.5).
    ///
    /// This is the half that was missing. `claim` alone makes the person a
    /// member in Firestore and nothing else, and the library lists set lists
    /// from the local manifest -- so the recipient tapped "Add to my set lists"
    /// and their set lists gained nothing; the shared screen they landed on
    /// was unreachable once they left it. Ali's wife and son would have seen
    /// nothing.
    ///
    /// Order of the writes, and why:
    ///   1. claim, server-side -- membership is the server's to grant;
    ///   2. read the document's name and owner, once;
    ///   3. create the local set list and BIND it straight away -- the
    ///      membership already exists, so the row is genuinely shared from
    ///      its first moment, and if adopting the music fails part way the
    ///      row still opens the shared screen where the rest can be fetched;
    ///   4. adopt each entry through the ordinary import (`adoptSharedEntry`)
    ///      and file it into the local running order.
    ///
    /// Idempotent: a set list already bound to this share is returned as it
    /// is, which is the spec's "already a member (which opens it instead)".
    /// Returns the LOCAL slug, so the caller can land on an ordinary row.
    func joinSharedSetlist(inviteId: String, shared: SharedSetlists,
                           progress: @MainActor (Int, Int) -> Void = { _, _ in })
                           async throws -> String {
        let setlistId = try await shared.claim(inviteId: inviteId)
        let remote = try await shared.fetch(setlistId)
        let entries = try await shared.fetchEntries(setlistId)

        // Already joined: keep the row, but STILL walk the entries below. Both
        // halves of adoption are idempotent -- a copy this device already has
        // is found by its entry id, and filing an arrangement twice is a no-op
        // -- so tapping the link again repairs a set list that arrived with
        // its music missing, which is exactly what build 188 produced.
        let slug: String
        if let mine = manifest?.setlists?.first(where: { $0.shareId == setlistId }) {
            slug = mine.slug
        } else {
            let created = try await local.call(op: "create-setlist", args: ["name": remote.name])
            guard let made = created["slug"] as? String else {
                throw SharedSetlists.Trouble.unusablePayload
            }
            _ = try await local.call(op: "bind-setlist-share",
                                     args: ["setlist": made, "shareId": setlistId,
                                            "ownerUid": remote.ownerId])
            await refresh()
            slug = made
        }

        progress(0, entries.count)
        for (index, entry) in entries.enumerated() {
            if let local = await adoptSharedEntry(entry.id, title: entry.title,
                                                  download: { try await shared.download(entry) }) {
                _ = try await self.local.call(op: "assign-setlist",
                                              args: ["setlist": slug, "score": local])
            }
            progress(index + 1, entries.count)
        }
        await refresh()
        shared.watchMemberships()
        return slug
    }

    /// What a shared set list entry carries for one of my arrangements.
    ///
    /// Asked of the ENGINE rather than assembled here: which version is pinned,
    /// where its file is and where its ink sits are the engine's facts, and a
    /// second answer computed in Swift would drift from the first
    /// (`bundle.share_payload`, design/FIREBASE.md §4.3). It also refuses a
    /// book or a source, which have no share path at all.
    func sharePayload(for slug: String) async throws -> [String: Any] {
        try await local.call(op: "share-payload", args: ["score": slug])
    }

    private func runSetlistOp(op: String, args: [String: Any]) async -> Bool {
        do {
            _ = try await local.call(op: op, args: args)
            await refresh()
            return true
        } catch {
            report("change that set list", error)
        }
        return false
    }

    /// Drop an arrangement into a piece at a chosen position.
    ///
    /// Filing and ordering are two engine ops, and the second needs the first
    /// to have landed — a drag from another piece that fired them in parallel
    /// reordered a list the arrangement was not in yet, and the row appeared
    /// at the bottom. `order` is built from the piece as it will be, so the
    /// call is correct whether the arrangement is already in this piece or is
    /// arriving from elsewhere.
    ///
    /// `before` is the slug the dragged row should displace; nil appends.
    func placeInPiece(scoreSlug: String, piece: String, before target: String?) {
        Task {
            do {
                // the piece document holds the order; the score list does not
                let current = (manifest?.pieces ?? [])
                    .first { $0.slug == piece }?.arrangements ?? []
                if !current.contains(scoreSlug) {
                    _ = try await local.call(op: "assign-piece",
                                             args: ["score": scoreSlug, "piece": piece])
                }
                var order = current.filter { $0 != scoreSlug }
                let index = target.flatMap { order.firstIndex(of: $0) } ?? order.count
                order.insert(scoreSlug, at: index)
                _ = try await local.call(op: "reorder-piece",
                                         args: ["piece": piece, "order": order])
                await refresh()
            } catch {
                report("move that arrangement", error)
            }
        }
    }

    /// Persist a piece's arrangement order (the sidebar numbering).
    /// Set a set list's running order. The engine keeps the order on the
    /// setlist document, so this is one reorder op rather than a remove and
    /// re-add, which would lose the position of everything after it.
    @discardableResult
    func reorderSetlist(_ setlist: String, order: [String]) async -> Bool {
        do {
            _ = try await local.call(op: "reorder-setlist",
                                    args: ["setlist": setlist, "order": order])
            await refresh()
            return true
        } catch {
            report("reorder that set list", error)
        }
        return false
    }

    func reorderPiece(piece: String, order: [String]) {
        Task {
            do {
                _ = try await local.call(op: "reorder-piece",
                                         args: ["piece": piece, "order": order])
                await refresh()
            } catch {
                report("reorder that piece", error)
            }
        }
    }

    /// Piece context handed to the chat agent: which piece this arrangement
    /// belongs to and its numbered siblings. The numbers are the "#N" the user
    /// sees in the sidebar and types in prompts; each maps to an 'arr:<slug>'
    /// ref that pull_part accepts.
    func chatContext(for slug: String) -> String? {
        guard let m = manifest,
              let score = m.scores.first(where: { $0.slug == slug }),
              let pieceSlug = score.piece,
              let piece = (m.pieces ?? []).first(where: { $0.slug == pieceSlug }),
              !piece.arrangements.isEmpty else { return nil }
        let numbered = piece.arrangements.enumerated().map { i, s -> String in
            let name = m.scores.first { $0.slug == s }?.name ?? s
            let marker = s == slug ? " (THIS arrangement)" : ""
            return "#\(i + 1) = '\(name)' (ref arr:\(s))\(marker)"
        }
        return "This arrangement belongs to the piece '\(piece.name)'. "
            + "The piece's arrangements are numbered, and the user refers to them "
            + "by number with a '#' prefix: " + numbered.joined(separator: ", ") + ". "
            + "So \"take the violin part from #3\" means pull_part with the arr: ref "
            + "listed for #3. Numbers refer only to arrangements of this piece, never "
            + "to versions or measures."
    }

    /// Chat context plus the active selection, if any, so a prompt can say
    /// "the selection" and mean exactly the elements the user lassoed.
    func chatContextWithHighlight(for slug: String) -> String? {
        var pieces: [String] = []
        if let base = chatContext(for: slug) { pieces.append(base) }
        if let selection = activeSelection, !selection.isEmpty {
            // The addresses themselves, not a bar range.
            //
            // This used to say "pass from_measure/to_measure", which is why
            // Ali selected one chord, asked to move those notes up, and the
            // whole bar moved: the selection was degraded to its bar number
            // before the model ever saw it, and the op did exactly what it was
            // told. The addresses are what the lasso actually caught.
            let list = selection.addressList.joined(separator: ", ")
            pieces.append(
                "The user has selected \(selection.headline)"
                + (selection.placeLine.map { " (\($0))" } ?? "") + ". "
                + "Their addresses are: \(list). "
                + "'The selection', 'these notes' and 'the highlighted passage' mean "
                + "EXACTLY those elements. Use transpose_elements with that exact list "
                + "of addresses. Do NOT use transpose with from_measure/to_measure for a "
                + "selection: that moves every note in the bar, including ones the user "
                + "did not select. Ask before making whole-piece changes while a "
                + "selection is active.")
        }
        return pieces.isEmpty ? nil : pieces.joined(separator: " ")
    }

    /// Create a new piece by name and file the score under it (assign-piece
    /// creates missing pieces).
    /// Create a piece and return its slug.
    ///
    /// It holds nothing for the moment between this and the first arrangement
    /// arriving, which is legitimate and is why the empty-piece sweep runs
    /// where an arrangement LEAVES rather than on every rebuild.
    @discardableResult
    func createPiece(named name: String) async -> String? {
        do {
            let r = try await local.call(op: "create-piece", args: ["name": name])
            await refresh()
            return (r["piece"] as? [String: Any])?["slug"] as? String
                ?? r["slug"] as? String
        } catch {
            report("create that piece", error)
        }
        return nil
    }

    func createPieceAndAssign(name: String, scoreSlug: String) {
        Task {
            do {
                _ = try await local.call(op: "assign-piece",
                                         args: ["score": scoreSlug, "piece": name])
                await refresh()
            } catch {
                report("file that arrangement under a new piece", error)
            }
        }
    }

    /// Irreversibly delete a score and all its versions.
    /// Delete a piece, and its arrangements with it.
    ///
    /// This is what deleting a folder means to the person doing it. The old
    /// path looped over `piece.arrangements` and deleted each -- which for a
    /// piece holding nothing is an empty loop, so the button did nothing at
    /// all. The engine drops the piece document itself.
    func deletePiece(_ slug: String, withArrangements: Bool = true) {
        Task {
            do {
                _ = try await local.call(op: "delete-piece",
                                        args: ["piece": slug,
                                               "with_arrangements": withArrangements])
                await refresh()
            } catch {
                report("delete that piece", error)
            }
        }
    }

    /// Fold several pieces into one. ONE engine call, not N.
    ///
    /// Doing it client-side would be one `assign-piece` per arrangement, each
    /// rebuilding the manifest and sweeping empty pieces, all of it racing the
    /// manifest poll -- the same trap `placeInPiece` documents for filing and
    /// ordering. The engine does it in one step and reports what it did.
    ///
    /// There is no undo, which is why the only route to here is a screen that
    /// says so.
    @discardableResult
    func combinePieces(_ slugs: [String], name: String? = nil) async -> String? {
        guard slugs.count > 1 else { return nil }
        do {
            var args: [String: Any] = ["pieces": slugs]
            if let name { args["name"] = name }
            let r = try await local.call(op: "combine-pieces", args: args)
            await refresh()
            return r["piece"] as? String
        } catch {
            report("combine those pieces", error)
        }
        return nil
    }

    /// What was just deleted and can still be put back (§5.2).
    ///
    /// The engine marks rather than unlinks, so undo is a restore rather than a
    /// re-import. The bar's countdown is cosmetic -- what actually decides is
    /// the engine's window, and the sweep is what reclaims.
    struct UndoableDelete: Identifiable, Equatable {
        let id = UUID()
        let slug: String
        let what: String
        let isSetlist: Bool
    }
    @Published var undoableDelete: UndoableDelete?

    /// A bundle somebody sent, read but not yet imported. §13.3.
    struct BundleOffer: Equatable {
        let url: URL
        let summary: String
        let detail: String
    }
    @Published var bundleOffer: BundleOffer?

    func restoreDeleted() {
        guard let undo = undoableDelete else { return }
        undoableDelete = nil
        Task {
            _ = try? await local.call(op: "restore-score", args: ["score": undo.slug])
            await refresh()
        }
    }

    /// Reclaim anything whose window has passed. On launch, and after a delete.
    func sweepDeleted() async {
        _ = try? await local.call(op: "sweep", args: [:])
    }

    /// Sweep up pieces left holding nothing by a build that had no such rule.
    func tidyPieces() async {
        _ = try? await local.call(op: "tidy-pieces", args: [:])
        await refresh()
    }

    /// Number every arrangement's first full bar 1 (0.17.0). ABC tunes with no
    /// pickup came in numbered from 0, so "bar 1" in chat was the page's
    /// second bar. A new version per affected arrangement, once.
    func numberBarsFromOne() async {
        _ = try? await local.call(op: "number-bars-from-one", args: [:])
        await refresh()
    }

    func deleteScore(slug: String, undoable: Bool = true) {
        let name = manifest?.scores.first { $0.slug == slug }
            .map { ScoreTitle.arrangementName(title: $0.title, name: $0.name,
                                              slug: $0.slug) } ?? slug
        Task {
            do {
                try await local.deleteScore(slug)
                if undoable {
                    undoableDelete = UndoableDelete(slug: slug, what: name,
                                                    isSetlist: false)
                }
                if previewedSlug == slug { previewedSlug = nil }
                if selectedSlug == slug {
                    selectedSlug = nil
                    pinnedVersion = nil
                }
                await refresh()
            } catch {
                report("delete that arrangement", error)
            }
        }
    }

    func transpose(semitones: Int) {
        guard let slug = selectedScore?.slug else { return }
        Task {
            do {
                if useLocalEngine {
                    try await local.transpose(score: slug, semitones: semitones)
                } else {
                    try await client.transpose(score: slug, semitones: semitones)
                }
                pinnedVersion = nil
                await refresh()
            } catch {
                report("transpose the score", error)
            }
        }
    }

    /// Respell the whole score enharmonically (flats vs sharps). Creates a
    /// new version, like any other op.
    func respell(preferFlats: Bool) {
        guard let slug = selectedScore?.slug else { return }
        Task {
            do {
                _ = try await local.call(op: "respell",
                                         args: ["score": slug,
                                                "prefer": preferFlats ? "flats" : "sharps"])
                pinnedVersion = nil
                await refresh()
            } catch {
                report("respell the score", error)
            }
        }
    }

    func sendChat(_ text: String) {
        guard let slug = selectedScore?.slug, !chatBusy else { return }
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        chatMessages[slug, default: []].append(.init(role: .user, text: message))
        chatBusy = true
        activeChatSteps[slug] = []
        Task {
            defer {
                chatBusy = false
                activeChatSteps[slug] = nil
            }
            do {
                if useLocalEngine {
                    let turn = try await LocalChat().run(
                        slug: slug, message: message,
                        modelAlias: chatModel.isEmpty ? nil : chatModel,
                        historyJSON: chatHistory[slug],
                        context: chatContextWithHighlight(for: slug),
                        onEvent: { [weak self] event in
                            guard let self else { return }
                            switch event {
                            case .toolStarted(let title):
                                self.activeChatSteps[slug, default: []]
                                    .append(ChatStep(title: title, detail: nil, done: false))
                            case .toolFinished(let detail):
                                if let i = self.activeChatSteps[slug]?.lastIndex(where: { !$0.done }) {
                                    self.activeChatSteps[slug]?[i].done = true
                                    self.activeChatSteps[slug]?[i].detail = detail
                                }
                            }
                        })
                    chatHistory[slug] = turn.historyJSON
                    // keep the checklist in the transcript with the reply
                    let steps = activeChatSteps[slug]
                    chatMessages[slug, default: []].append(
                        .init(role: .agent, text: turn.reply,
                              steps: (steps?.isEmpty == false) ? steps : nil))
                } else {
                    let resp = try await client.chat(score: slug, message: message,
                                                     model: chatModel.isEmpty ? nil : chatModel,
                                                     history: chatHistory[slug])
                    chatHistory[slug] = resp.history
                    chatMessages[slug, default: []].append(.init(role: .agent, text: resp.reply))
                }
                pinnedVersion = nil
                await refresh()
            } catch let e as EngineError {
                chatMessages[slug, default: []].append(.init(role: .error, text: e.error))
            } catch {
                chatMessages[slug, default: []].append(.init(role: .error, text: error.localizedDescription))
            }
        }
    }
}


/// A scan the app could not turn into pages.
///
/// Its own error so the notice can say what happened. A photograph that will
/// not decode is a real thing -- a truncated download, a format the OS does
/// not know -- and "could not open" with no reason sends the reader looking
/// for a fault in the app.
enum ScanImageError: LocalizedError {
    case undecodable
    var errorDescription: String? {
        "This image could not be opened. It may be damaged, or in a format "
        + "this iPad does not read."
    }
}
