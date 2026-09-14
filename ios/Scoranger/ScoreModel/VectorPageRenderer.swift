import CoreGraphics
import Foundation

/// A `VectorPage` drawn into a graphics context.
///
/// One loop over the display list. Everything is black on transparent, which
/// is the whole of Verovio's colour model for this app's option set: the page's
/// own `<style>` says `stroke:currentColor` and `color="black"` sits on the
/// only element that sets it. Paper is drawn by whoever owns the background --
/// the canvas already does, and a renderer that painted its own white would
/// make a page that cannot be composited over anything.
///
/// The context is expected to be in TOP-LEFT coordinates (y down), which is
/// SVG's convention and what `UIGraphicsImageRenderer` gives on iOS. A
/// bottom-up context -- `CGContext(data:…)` on either platform, or a PDF
/// context -- has to be flipped by the caller; `flip(_:height:)` is here so
/// that flip is written once.
enum VectorPageRenderer {

    /// Draw `page` scaled so that its full width is `width` points.
    ///
    /// Scale is applied to the CONTEXT rather than to the paths, so one parse
    /// serves every zoom. That is the property the whole exercise is for: the
    /// bitmap path has to re-rasterise a PDF at each settled zoom, and this
    /// does not.
    static func draw(_ page: VectorPage, in context: CGContext, width: CGFloat) {
        guard page.size.width > 0 else { return }
        draw(page, in: context, scale: width / page.size.width)
    }

    static func draw(_ page: VectorPage, in context: CGContext, scale: CGFloat) {
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(gray: 0, alpha: 1)
        context.setStrokeColor(gray: 0, alpha: 1)
        for item in page.items {
            context.addPath(item.path)
            switch item.paint {
            case .fill:
                context.fillPath()
            case .stroke(let width, let cap, let join):
                context.setLineWidth(width)
                context.setLineCap(cap)
                context.setLineJoin(join)
                context.strokePath()
            case .fillAndStroke(let width, let cap, let join):
                context.setLineWidth(width)
                context.setLineCap(cap)
                context.setLineJoin(join)
                context.drawPath(using: .fillStroke)
            }
        }
        context.restoreGState()
    }

    /// Turn a bottom-up context into the top-left one this draws into.
    static func flip(_ context: CGContext, height: CGFloat) {
        context.translateBy(x: 0, y: height)
        context.scaleBy(x: 1, y: -1)
    }
}
