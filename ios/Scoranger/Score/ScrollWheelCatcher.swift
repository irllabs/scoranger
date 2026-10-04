import SwiftUI
import UIKit

/// A trackpad's two-finger scroll and a mouse wheel, read over a SwiftUI view.
///
/// SwiftUI on iPadOS 17 has no scroll-wheel event for a view that is not a
/// scroll view, so the tempo knob -- which turns by DRAG -- did nothing under
/// a keyboard case's trackpad (BACKLOG, 0.18.2). This is a clear UIKit view
/// laid over the knob with a pan recognizer that accepts scrolls and NO
/// touches, and it refuses to be hit by anything but a scroll event, so a
/// finger still reaches the knob's own drag underneath
/// (TempoKnobTurnsBothWays drags through it).
struct ScrollWheelCatcher: UIViewRepresentable {
    var onBegan: () -> Void
    /// The scroll's travel since it began, in points, as a drag's would be.
    var onChanged: (CGSize) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.backgroundColor = .clear
        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.scrolled(_:)))
        pan.allowedScrollTypesMask = .all
        pan.allowedTouchTypes = []
        view.addGestureRecognizer(pan)
        return view
    }

    func updateUIView(_ view: CatcherView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject {
        var parent: ScrollWheelCatcher
        init(_ parent: ScrollWheelCatcher) { self.parent = parent }

        @objc func scrolled(_ pan: UIPanGestureRecognizer) {
            switch pan.state {
            case .began:
                parent.onBegan()
            case .changed:
                let travel = pan.translation(in: pan.view)
                parent.onChanged(CGSize(width: travel.x, height: travel.y))
            default:
                break
            }
        }
    }

    /// Hit only by scrolls: every touch passes through to the view beneath.
    final class CatcherView: UIView {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            event?.type == .scroll ? super.hitTest(point, with: event) : nil
        }
    }
}
