import CoreGraphics
import Foundation

/// One page of engraved music as orders to a graphics context, rather than as
/// a picture of itself.
///
/// This is the display list the direct-vector path draws from. It is built
/// from the SAME Verovio SVG the bitmap path rewrites for SwiftDraw and the
/// same SVG `SVGGeometryParser` measures for hit-testing, so all three describe
/// one engraving; nothing here re-engraves anything.
///
/// Coordinates are the ROOT `<svg>`'s user units -- 972 x 1258 for this app's
/// page options -- with y increasing downwards, which is both SVG's convention
/// and Core Graphics' when the context is flipped. `VectorPageRenderer` owns
/// that flip; this type states the space and nothing else.
struct VectorPage: Equatable {

    /// How a shape meets the page. Verovio's subset needs no gradients, no
    /// opacity and one colour, so this is the whole of it.
    enum Paint: Equatable {
        case fill
        case stroke(width: CGFloat, cap: CGLineCap, join: CGLineJoin)
        /// Slurs and ties are CLOSED outlines that Verovio both fills and
        /// strokes; drawing either half alone makes them visibly thin.
        case fillAndStroke(width: CGFloat, cap: CGLineCap, join: CGLineJoin)
    }

    struct Item: Equatable {
        let path: CGPath
        let paint: Paint
        /// The class of the nearest enclosing classed `<g>`, kept so a
        /// comparison can say WHICH parts of a page are wrong rather than
        /// only that it is. Not used for drawing.
        let owner: String

        static func == (a: Item, b: Item) -> Bool {
            a.path == b.path && a.paint == b.paint && a.owner == b.owner
        }
    }

    /// Something the document asked for that this page does not draw.
    ///
    /// The point of carrying it is that a renderer which silently omits half a
    /// score looks, from a distance, exactly like one that is finished. A
    /// comparison harness prints this beside the image.
    struct Undrawn: Equatable {
        let reason: String
        var count: Int
    }

    /// The page in the root `<svg>`'s user units.
    let size: CGSize
    let items: [Item]
    let undrawn: [Undrawn]

    /// Everything drawn, in page units. Empty when the page is empty.
    var contentBounds: CGRect {
        items.reduce(CGRect.null) { $0.union($1.path.boundingBoxOfPath) }
    }
}
