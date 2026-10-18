import SwiftUI
import UIKit

// Rows in an order the reader sets: a piece's arrangements, a set list's
// running order. Ali, on build 214: "Enable touch and drag up/down on the
// hamburger to move the pieces up and down ... This gets rid of the 'Up' and
// 'Down'", and delete "like deleting in the kid apps ... swipe left on the row
// and that should show a delete icon that's a red trashcan on the right side".
//
// So the ☰ is two controls in one place: a TAP opens the row's actions as it
// always has, and a press that MOVES picks the row up. A swipe to the left
// slides the row aside to show a red trash button at its right-hand edge, and
// tapping that deletes. There is no confirm after it: the swipe and the tap
// are two deliberate gestures on a button that names what it does, which is
// the confirmation iOS itself uses in Mail and Reminders; deleting an
// arrangement still leaves the undo bar, and taking one out of a set list
// leaves the arrangement in the library.
//
// The swipe is its own modifier, `RowSwipeToDelete`, because the library's
// rows take it too (0.23.0) and they keep no order of the reader's to drag.
//
// The rules -- where a dragged row lands, when a movement is a swipe rather
// than a scroll, how fast a page scrolls under a row held at its edge -- are
// `RowReorder`, `RowSwipe` and `EdgeScroll`, pure and tested. This file is
// the gestures and the drawing.

/// What a swipe to the left offers on one row.
struct RowDeletion {
    /// On the revealed trash button: the identifier the row's Delete or
    /// Remove action carried before the swipe replaced it, so a test and
    /// VoiceOver keep their target.
    let identifier: String
    /// The trash button's accessibility label, naming the row:
    /// "Delete Sous le ciel quartet".
    let label: String
    /// The row's accessibility action, for a reader who cannot swipe:
    /// "Delete", "Remove from set list".
    let actionName: String
    let perform: () -> Void
}

/// One row moved: the item, where it was and where it went, and the whole
/// list in its new order. A list kept as an array persists `order`; a shared
/// set list, whose order is a key per entry, writes one key from `from` and
/// `to` (`SharedOrder.neighbours`).
struct RowMove<Item: Hashable> {
    let item: Item
    let from: Int
    let to: Int
    let order: [Item]
}

/// What `ReorderableRows` hands each row it draws: where the row stands, the
/// gesture for its ☰ (`reorderGrip`), and the accessibility actions for the
/// row's own element (`reorderableRowActions`).
struct ReorderableRowHandle {
    let index: Int
    let count: Int
    /// False where the reader may not reorder: the grip does nothing and the
    /// row offers no Move up or Move down.
    let canReorder: Bool
    fileprivate let grip: (ReorderGripEvent) -> Void
    fileprivate let step: (Int) -> Void
    fileprivate let deletion: RowDeletion?
}

fileprivate enum ReorderGripEvent {
    /// The finger's travel since the press, and where it is now, both in
    /// global coordinates: `RowDragScroll` judges the edges in them.
    case moved(CGSize, at: CGPoint)
    case dropped(CGSize)
    /// The touch ended, by a drop or by being cancelled. A cancelled drag
    /// gets no `dropped`, and a row left held would stay lifted for good.
    case released
}

/// True while a row's ☰ drag or sideways swipe has the finger, so the page
/// holds still under it. `Screen` and the library read it onto their
/// ScrollViews: a page the finger scrolls while a row is dragged moves the
/// slots out from under the row, and one that drifts while a row is swiped
/// reads as the row slipping. A held row scrolls the page itself, at its
/// edges, through `RowDragScroll`, which knows how far it has gone.
struct RowGestureHoldsScroll: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

/// A list whose rows reorder by dragging their ☰ and delete by swiping left.
///
/// The caller draws each row and puts `.reorderGrip(handle)` on its ☰ and
/// `.reorderableRowActions(handle)` on the row's own accessibility element.
/// The list moves the rows, measures them, and commits ONE move per drop.
struct ReorderableRows<Item: Hashable, Row: View>: View {
    let items: [Item]
    /// A dashed rule under each row, moving with it.
    var ruled = true
    /// False for a list this reader may only read.
    var canReorder = true
    /// Persist a move. True when it was taken: the list keeps the dropped
    /// order on screen until `items` arrives in it, so the row does not spring
    /// back for the length of an engine call. False puts the old order back.
    let reorder: (RowMove<Item>) async -> Bool
    /// What swiping a row to the left offers, or nil for a row that does not
    /// swipe.
    var deletion: (Item) -> RowDeletion? = { _ in nil }
    @ViewBuilder let row: (Item, ReorderableRowHandle) -> Row

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The page this list scrolls when a held row nears its edge. Nil where
    /// the list is not on a `Screen`'s scrolling page; it then scrolls nothing.
    @Environment(RowDragScroll.self) private var dragScroll: RowDragScroll?

    @State private var heights: [AnyHashable: CGFloat] = [:]
    @State private var held: Held?
    /// This touch on a ☰ is not a drag: it went sideways (the row's swipe has
    /// it), or the list could not be measured.
    @State private var gripRefused = false
    @State private var pending: [Item]?
    /// The row resting open on its trash button. One at a time.
    @State private var open: Item?

    private struct Held: Equatable {
        let item: Item
        let reorder: RowReorder
        /// The finger's own travel since the press.
        var travel: CGFloat
        /// `RowDragScroll.driven` at the press. What the page has scrolled
        /// since is added to the finger's travel: the row stays under a
        /// finger that holds still while the list moves beneath it.
        let scrollStart: CGFloat
        var translation: CGFloat
        var landing: Int
    }

    private var shown: [Item] { pending ?? items }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element) { index, item in
                unit(item, at: index)
            }
        }
        .onPreferenceChange(RowHeights.self) { heights = $0 }
        .onChange(of: items) { _, now in
            pending = nil
            if held != nil {
                // The list changed under the finger -- a sync, a delete
                // landing. The slots the drag was measured against are gone.
                held = nil
                gripRefused = true
            }
            if let open, !now.contains(open) { self.open = nil }
        }
        // Combined with the rows' own swipes, not written over them.
        .transformPreference(RowGestureHoldsScroll.self) { $0 = $0 || held != nil }
        .sensoryFeedback(.selection, trigger: held?.landing)
        .onChange(of: dragScroll?.driven) { _, _ in followHeldRow() }
    }

    private func unit(_ item: Item, at index: Int) -> some View {
        let isHeld = held?.item == item
        let handle = ReorderableRowHandle(
            index: index, count: shown.count, canReorder: canReorder,
            grip: { gripped($0, item: item, index: index) },
            step: { by in commit(item, from: index, to: index + by) },
            deletion: deletion(item))
        return VStack(spacing: 0) {
            row(item, handle)
                .rowSwipeToDelete(id: item, open: $open, deletion: handle.deletion,
                                  enabled: held == nil)
            if ruled { Theme.Rule() }
        }
        // Lifted: the page's own colour under it, so the rows it passes over
        // do not show through, and the one shadow a floating thing may cast
        // (§4). The shadow is the BACKGROUND's: on the row itself SwiftUI
        // gives every child its own, and the row's Open capsule stood up off
        // the row like a sticker. Neither changes the view's structure, which
        // would drop the gesture the finger is in the middle of.
        .background(
            Rectangle()
                .fill(isHeld ? Theme.Surface.panel : Color.clear)
                .shadow(color: Color(hex: 0x1A1917).opacity(isHeld ? 0.14 : 0), radius: 6, y: 2))
        .background(GeometryReader { geometry in
            Color.clear.preference(key: RowHeights.self,
                                   value: [AnyHashable(item): geometry.size.height])
        })
        .offset(y: verticalOffset(item, at: index))
        .zIndex(isHeld ? 1 : 0)
    }

    // MARK: - where each row is drawn

    private func verticalOffset(_ item: Item, at index: Int) -> CGFloat {
        guard let held else { return 0 }
        if held.item == item { return held.translation }
        return held.reorder.displacement(ofRow: index, landing: held.landing)
    }

    private var slide: Animation? { reduceMotion ? nil : .easeOut(duration: 0.18) }

    // MARK: - the ☰ drag

    private func gripped(_ event: ReorderGripEvent, item: Item, index: Int) {
        switch event {
        case .moved(let travel, let finger):
            if let current = held {
                guard current.item == item else { return }
                held?.travel = travel.height
                followHeldRow()
                dragScroll?.follow(fingerY: finger.y)
                return
            }
            guard canReorder, !gripRefused else { return }
            // Sideways from the ☰ is the row's swipe, which has the touch too.
            guard abs(travel.height) >= abs(travel.width),
                  let reorder = RowReorder(heights: shown.map { heights[AnyHashable($0)] ?? 0 },
                                           from: index) else {
                gripRefused = true
                return
            }
            withAnimation(slide) { open = nil }
            held = Held(item: item, reorder: reorder, travel: travel.height,
                        scrollStart: dragScroll?.driven ?? 0,
                        translation: reorder.clamped(travel.height),
                        landing: reorder.landing(translation: travel.height))
            dragScroll?.follow(fingerY: finger.y)
        case .dropped(let travel):
            guard let current = held, current.item == item else { return }
            dragScroll?.stop()
            let to = current.reorder.landing(translation: listTravel(travel.height, current))
            if to == current.reorder.from {
                withAnimation(slide) { held = nil }
            } else {
                commit(item, from: current.reorder.from, to: to)
            }
        case .released:
            gripRefused = false
            dragScroll?.stop()
            if held != nil { withAnimation(slide) { held = nil } }
        }
    }

    /// How far the held row has gone down the LIST: the finger's travel plus
    /// what the page has scrolled under it since the press.
    private func listTravel(_ travel: CGFloat, _ held: Held) -> CGFloat {
        travel + (dragScroll?.driven ?? held.scrollStart) - held.scrollStart
    }

    /// The held row put back under the finger, after the finger moved or the
    /// page scrolled.
    private func followHeldRow() {
        guard let current = held else { return }
        let travel = listTravel(current.travel, current)
        let landing = current.reorder.landing(translation: travel)
        if landing != current.landing {
            withAnimation(slide) { held?.landing = landing }
        }
        held?.translation = current.reorder.clamped(travel)
    }

    /// One move, from a drop or from VoiceOver's Move up / Move down.
    private func commit(_ item: Item, from: Int, to: Int) {
        let list = shown
        guard list.indices.contains(from), list.indices.contains(to), from != to else { return }
        let order = RowReorder.moving(list, from: from, to: to)
        withAnimation(slide) {
            pending = order
            held = nil
        }
        Task {
            let taken = await reorder(RowMove(item: item, from: from, to: to, order: order))
            guard pending == order else { return }
            if !taken {
                withAnimation(slide) { pending = nil }
                return
            }
            // Taken, and `items` has not caught up: a shared list's listener
            // is a round trip away. Give it a moment, then show the truth
            // whatever it is rather than hold an order nothing confirmed.
            try? await Task.sleep(for: .seconds(3))
            if pending == order { pending = nil }
        }
    }
}

/// A row that swipes left to uncover a red trash button at its right-hand
/// edge, and deletes with a tap on that button. `ReorderableRows` puts it on
/// each of its rows; the library's rows take it alone (0.23.0).
///
/// The LIST owns `open`, the row resting open on its button, so one row is
/// open at a time and, while one is, a tap anywhere else in the list closes it
/// rather than doing what that tap would do.
struct RowSwipeToDelete<ID: Hashable>: ViewModifier {
    let id: ID
    @Binding var open: ID?
    /// What the trash offers, or nil for a row that does not swipe.
    let deletion: RowDeletion?
    /// False while something else has the row: its ☰ drag.
    var enabled = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Where the row started and where it is, while the finger is on it.
    @State private var sliding: Sliding?

    private struct Sliding: Equatable {
        let start: CGFloat
        var offset: CGFloat
    }

    func body(content: Content) -> some View {
        let offset = currentOffset
        content
            .overlay { if open != nil { closer } }
            .offset(x: offset)
            // Pinned to the row's own frame, not the sliding content's: the
            // button fills exactly the strip the row uncovers.
            .overlay(alignment: .trailing) {
                if offset < 0, let deletion { trash(deletion, width: -offset) }
            }
            // The row slides off its leading edge, not over the page margin
            // beside it.
            .clipped()
            .contentShape(Rectangle())
            .gesture(SidewaysPan(enabled: enabled && deletion != nil,
                                 moved: moved, ended: ended))
            .transformPreference(RowGestureHoldsScroll.self) { $0 = $0 || sliding != nil }
    }

    private var currentOffset: CGFloat {
        if let sliding { return sliding.offset }
        return open == id ? -RowSwipe.revealWidth : 0
    }

    private var slide: Animation? { reduceMotion ? nil : .easeOut(duration: 0.18) }

    private var closer: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(slide) { open = nil } }
            .accessibilityHidden(true)
    }

    private func trash(_ deletion: RowDeletion, width: CGFloat) -> some View {
        Button {
            withAnimation(slide) {
                open = nil
                sliding = nil
            }
            deletion.perform()
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: width)
                .frame(maxHeight: .infinity)
                .background(Theme.Status.danger)
                .clipped()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(deletion.identifier)
        .accessibilityLabel(deletion.label)
    }

    private func moved(_ dx: CGFloat) {
        guard enabled else { return }
        if sliding == nil {
            let start: CGFloat = open == id ? -RowSwipe.revealWidth : 0
            if open != nil, open != id { withAnimation(slide) { open = nil } }
            sliding = Sliding(start: start, offset: start)
        }
        guard var current = sliding else { return }
        current.offset = RowSwipe.offset(start: current.start, dx: dx)
        sliding = current
    }

    /// The finger lifted, or the system took the touch away (velocity 0):
    /// the row rests open or closed, never half-way.
    private func ended(_ dx: CGFloat, _ velocity: CGFloat) {
        guard let current = sliding else { return }
        let resting = RowSwipe.offset(start: current.start,
                                      dx: RowSwipe.projected(dx: dx, velocity: velocity))
        withAnimation(slide) {
            open = RowSwipe.restsOpen(predicted: resting) ? id : nil
            sliding = nil
        }
    }
}

extension View {
    /// Swipe this row left for the red trash button `deletion` describes.
    /// `open` is the list's: the one row resting open, if any.
    func rowSwipeToDelete<ID: Hashable>(id: ID, open: Binding<ID?>,
                                        deletion: RowDeletion?,
                                        enabled: Bool = true) -> some View {
        modifier(RowSwipeToDelete(id: id, open: open, deletion: deletion, enabled: enabled))
    }
}

/// A sideways pan on a row that leaves every other pan to the page.
///
/// A SwiftUI DragGesture on a row inside a ScrollView takes the touch from the
/// scroll view, even as a simultaneous gesture: measured on an iPhone held
/// sideways (iOS 27), a vertical drag that started on a row did not scroll the
/// page at all, and the same drag beside the rows did. So the swipe is a UIKit
/// pan whose delegate lets it BEGIN only when the movement is sideways
/// (`RowSwipe.isSideways`); a vertical pan fails it at once and the scroll
/// view has the touch as if the row had no gesture.
private struct SidewaysPan: UIGestureRecognizerRepresentable {
    let enabled: Bool
    let moved: (CGFloat) -> Void
    let ended: (CGFloat, CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        pan.isEnabled = enabled
        return pan
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        recognizer.isEnabled = enabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let dx = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .began, .changed:
            moved(dx)
        case .ended:
            ended(dx, recognizer.velocity(in: recognizer.view).x)
        case .cancelled, .failed:
            ended(dx, 0)
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let travel = pan.translation(in: pan.view)
            let speed = pan.velocity(in: pan.view)
            return RowSwipe.isSideways(translation: CGSize(width: travel.x, height: travel.y),
                                       velocity: CGSize(width: speed.x, height: speed.y))
        }
    }
}

/// Each row's measured height, by item.
private struct RowHeights: PreferenceKey {
    static let defaultValue: [AnyHashable: CGFloat] = [:]
    static func reduce(value: inout [AnyHashable: CGFloat],
                       nextValue: () -> [AnyHashable: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

/// The ☰'s drag. A HIGH-PRIORITY gesture on the button, so a press that moves
/// is the drag and the page does not scroll under it, while a press that does
/// not move fails it and the button's own tap goes through.
private struct ReorderGrip: ViewModifier {
    let handle: ReorderableRowHandle
    @GestureState private var pressed = false

    func body(content: Content) -> some View {
        content
            .highPriorityGesture(
                // Global: the button moves with the row it drags, and a
                // translation measured in its own space would chase itself.
                DragGesture(minimumDistance: RowReorder.pickUpDistance, coordinateSpace: .global)
                    .updating($pressed) { _, pressed, _ in pressed = true }
                    .onChanged { handle.grip(.moved($0.translation, at: $0.location)) }
                    .onEnded { handle.grip(.dropped($0.translation)) })
            .onChange(of: pressed) { _, now in
                // After `onEnded`, so a drop is committed before the release
                // is read as a cancel.
                if !now { DispatchQueue.main.async { handle.grip(.released) } }
            }
    }
}

extension View {
    /// Makes this view -- a row's ☰ -- the handle that drags the row.
    func reorderGrip(_ handle: ReorderableRowHandle) -> some View {
        modifier(ReorderGrip(handle: handle))
    }

    /// Move up, Move down and the row's delete, as accessibility actions on
    /// the row's own element: VoiceOver and Switch Control cannot drag a ☰ or
    /// swipe a row, and neither may be the only way to do something.
    func reorderableRowActions(_ handle: ReorderableRowHandle) -> some View {
        accessibilityActions {
            if handle.canReorder, handle.index > 0 {
                Button("Move up") { handle.step(-1) }
            }
            if handle.canReorder, handle.index + 1 < handle.count {
                Button("Move down") { handle.step(1) }
            }
            if let deletion = handle.deletion {
                Button(deletion.actionName, action: deletion.perform)
            }
        }
    }
}

/// The page a row held by its ☰ scrolls when the finger nears the page's top
/// or bottom edge (0.23.0). `Screen` makes one for its ScrollView, keeps its
/// geometry current and binds `position`; `ReorderableRows` finds it in the
/// environment, tells it where the finger is, and adds what `driven` has
/// grown by since the press to the held row's travel.
///
/// The page is driven a step at a time at `EdgeScroll.speed`, which is pure
/// and tested. It drives the page while it is held still: `Screen` disables
/// the reader's own scrolling for the length of a drag
/// (`RowGestureHoldsScroll`), and a scroll position set in code is not the
/// reader's scrolling.
@MainActor @Observable
final class RowDragScroll {
    /// Bound to the ScrollView with `.scrollPosition`.
    var position = ScrollPosition()
    /// How far this has scrolled the page, in all, down positive. The one
    /// value a list observes: it changes only while a held row drives the
    /// page, so the reader's own scrolling redraws nothing through here.
    private(set) var driven: CGFloat = 0

    /// The page's content offset, as the ScrollView last reported it or as
    /// this last set it, and the offsets it can scroll between.
    @ObservationIgnored private(set) var offset: CGFloat = 0
    @ObservationIgnored private var minOffset: CGFloat = 0
    @ObservationIgnored private var maxOffset: CGFloat = 0
    /// The ScrollView's frame in global coordinates, the space the ☰'s drag
    /// reports the finger in.
    @ObservationIgnored var viewport: CGRect = .zero

    @ObservationIgnored private var fingerY: CGFloat?
    @ObservationIgnored private var driver: Task<Void, Never>?

    /// The finger is at `fingerY`. Starts the page moving if that is inside a
    /// band, and leaves it to stop by itself when the finger leaves it.
    func follow(fingerY: CGFloat) {
        self.fingerY = fingerY
        guard driver == nil, speed != 0 else { return }
        driver = Task { [weak self] in
            var last = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                guard let self, !Task.isCancelled else { return }
                let now = ContinuousClock.now
                let elapsed = last.duration(to: now)
                last = now
                let speed = self.speed
                let seconds = CGFloat(elapsed.components.seconds)
                    + CGFloat(elapsed.components.attoseconds) / 1e18
                let next = EdgeScroll.step(offset: self.offset, speed: speed,
                                           seconds: seconds,
                                           minOffset: self.minOffset, maxOffset: self.maxOffset)
                if speed == 0 || next == self.offset { break }
                self.driven += next - self.offset
                self.offset = next
                self.position.scrollTo(y: next)
            }
            self?.driver = nil
        }
    }

    /// What `Screen` reads off its ScrollView for this.
    struct Metrics: Equatable {
        let offset: CGFloat
        let minOffset: CGFloat
        let maxOffset: CGFloat

        init(_ geometry: ScrollGeometry) {
            offset = geometry.contentOffset.y
            minOffset = -geometry.contentInsets.top
            maxOffset = geometry.contentSize.height + geometry.contentInsets.bottom
                - geometry.containerSize.height
        }
    }

    func take(_ metrics: Metrics) {
        offset = metrics.offset
        minOffset = metrics.minOffset
        maxOffset = metrics.maxOffset
    }

    /// The drag ended: the page stops where it is.
    func stop() {
        fingerY = nil
        driver?.cancel()
        driver = nil
    }

    private var speed: CGFloat {
        guard let fingerY, viewport.height > 0 else { return 0 }
        return EdgeScroll.speed(y: fingerY, top: viewport.minY, bottom: viewport.maxY)
    }
}
