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
// The rules -- where a dragged row lands, when a movement is a swipe rather
// than a scroll -- are `RowReorder` and `RowSwipe`, pure and tested. This
// file is the gestures and the drawing.

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
    case moved(CGSize)
    case dropped(CGSize)
    /// The touch ended, by a drop or by being cancelled. A cancelled drag
    /// gets no `dropped`, and a row left held would stay lifted for good.
    case released
}

/// True while a row's ☰ drag or sideways swipe has the finger, so the page
/// holds still under it. `Screen` reads it onto its ScrollView: a page that
/// scrolls while a row is dragged moves the slots out from under the row,
/// and one that drifts while a row is swiped reads as the row slipping.
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

    @State private var heights: [AnyHashable: CGFloat] = [:]
    @State private var held: Held?
    /// This touch on a ☰ is not a drag: it went sideways (the row's swipe has
    /// it), or the list could not be measured.
    @State private var gripRefused = false
    @State private var pending: [Item]?
    /// The row resting open on its trash button. One at a time.
    @State private var open: Item?
    /// The row under the finger while it is swiped.
    @State private var sliding: Sliding?

    private struct Held: Equatable {
        let item: Item
        let reorder: RowReorder
        var translation: CGFloat
        var landing: Int
    }

    private struct Sliding: Equatable {
        let item: Item
        let start: CGFloat
        var offset: CGFloat
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
        .preference(key: RowGestureHoldsScroll.self, value: held != nil || sliding != nil)
        .sensoryFeedback(.selection, trigger: held?.landing)
    }

    private func unit(_ item: Item, at index: Int) -> some View {
        let isHeld = held?.item == item
        let handle = ReorderableRowHandle(
            index: index, count: shown.count, canReorder: canReorder,
            grip: { gripped($0, item: item, index: index) },
            step: { by in commit(item, from: index, to: index + by) },
            deletion: deletion(item))
        let offset = swipeOffset(item)
        return VStack(spacing: 0) {
            row(item, handle)
                // While a row rests open, a tap anywhere else in the list
                // closes it rather than doing what that tap would do.
                .overlay { if open != nil { closer } }
                .offset(x: offset)
                // Pinned to the row's own frame, not the sliding content's:
                // the button fills exactly the strip the row uncovers.
                .overlay(alignment: .trailing) {
                    if offset < 0, let deletion = handle.deletion {
                        trash(deletion, width: -offset)
                    }
                }
                // The row slides off its leading edge, not over the page
                // margin beside the column.
                .clipped()
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
        .contentShape(Rectangle())
        .modifier(RowSwipeGesture(enabled: handle.deletion != nil,
                                  moved: { swipeMoved(item, dx: $0) },
                                  ended: { swipeEnded(item, dx: $0, velocity: $1) }))
    }

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

    // MARK: - where each row is drawn

    private func verticalOffset(_ item: Item, at index: Int) -> CGFloat {
        guard let held else { return 0 }
        if held.item == item { return held.translation }
        return held.reorder.displacement(ofRow: index, landing: held.landing)
    }

    private func swipeOffset(_ item: Item) -> CGFloat {
        if let sliding, sliding.item == item { return sliding.offset }
        return open == item ? -RowSwipe.revealWidth : 0
    }

    private var slide: Animation? { reduceMotion ? nil : .easeOut(duration: 0.18) }

    // MARK: - the ☰ drag

    private func gripped(_ event: ReorderGripEvent, item: Item, index: Int) {
        switch event {
        case .moved(let travel):
            if let current = held {
                guard current.item == item else { return }
                let landing = current.reorder.landing(translation: travel.height)
                if landing != current.landing {
                    withAnimation(slide) { held?.landing = landing }
                }
                held?.translation = current.reorder.clamped(travel.height)
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
            withAnimation(slide) {
                open = nil
                sliding = nil
            }
            held = Held(item: item, reorder: reorder,
                        translation: reorder.clamped(travel.height),
                        landing: reorder.landing(translation: travel.height))
        case .dropped(let travel):
            guard let current = held, current.item == item else { return }
            let to = current.reorder.landing(translation: travel.height)
            if to == current.reorder.from {
                withAnimation(slide) { held = nil }
            } else {
                commit(item, from: current.reorder.from, to: to)
            }
        case .released:
            gripRefused = false
            if held != nil { withAnimation(slide) { held = nil } }
        }
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

    // MARK: - the swipe

    private func swipeMoved(_ item: Item, dx: CGFloat) {
        guard held == nil else { return }
        if sliding?.item != item {
            let start: CGFloat = open == item ? -RowSwipe.revealWidth : 0
            if open != nil, open != item { withAnimation(slide) { open = nil } }
            sliding = Sliding(item: item, start: start, offset: start)
        }
        guard var current = sliding else { return }
        current.offset = RowSwipe.offset(start: current.start, dx: dx)
        sliding = current
    }

    /// The finger lifted, or the system took the touch away (velocity 0):
    /// the row rests open or closed, never half-way.
    private func swipeEnded(_ item: Item, dx: CGFloat, velocity: CGFloat) {
        guard let current = sliding, current.item == item else { return }
        let resting = RowSwipe.offset(start: current.start,
                                      dx: RowSwipe.projected(dx: dx, velocity: velocity))
        withAnimation(slide) {
            open = RowSwipe.restsOpen(predicted: resting) ? item : nil
            sliding = nil
        }
    }
}

/// A sideways pan on a row that leaves every other pan to the page.
///
/// A SwiftUI DragGesture on a row inside a ScrollView takes the touch from the
/// scroll view, even as a simultaneous gesture: measured on an iPhone held
/// sideways (iOS 27), a vertical drag that started on a row did not scroll the
/// page at all, and the same drag beside the rows did. So from iOS 18, where
/// SwiftUI can host one, the swipe is a UIKit pan whose delegate lets it BEGIN
/// only when the movement is sideways (`RowSwipe.isSideways`); a vertical pan
/// fails it at once and the scroll view has the touch as if the row had no
/// gesture. iOS 17 keeps the SwiftUI drag, which decides its axis on its first
/// movement and ignores the rest of a vertical one. That path is not measured:
/// this Mac has no iOS 17 runtime.
private struct RowSwipeGesture: ViewModifier {
    let enabled: Bool
    let moved: (CGFloat) -> Void
    /// Sideways travel and speed at the lift. A cancelled touch reports a
    /// speed of 0, so the row settles where it is.
    let ended: (CGFloat, CGFloat) -> Void

    @State private var axis: RowSwipe.Axis?
    @State private var lastDX: CGFloat = 0
    @GestureState private var touching = false

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.gesture(SidewaysPan(enabled: enabled, moved: moved, ended: ended))
        } else {
            content
                .simultaneousGesture(drag, including: enabled ? .all : .subviews)
                .onChange(of: touching) { _, now in
                    guard !now else { return }
                    // After `onEnded`: a swipe that ended has settled already,
                    // and one the system cancelled has not.
                    DispatchQueue.main.async {
                        if axis == .horizontal { ended(lastDX, 0) }
                        axis = nil
                    }
                }
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: RowSwipe.decisionDistance)
            .updating($touching) { _, touching, _ in touching = true }
            .onChanged { value in
                if axis == nil {
                    axis = RowSwipe.axis(dx: value.translation.width, dy: value.translation.height)
                }
                guard axis == .horizontal else { return }
                lastDX = value.translation.width
                moved(value.translation.width)
            }
            .onEnded { value in
                if axis == .horizontal { ended(value.translation.width, value.velocity.width) }
                axis = nil
            }
    }
}

@available(iOS 18.0, *)
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
                    .onChanged { handle.grip(.moved($0.translation)) }
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
