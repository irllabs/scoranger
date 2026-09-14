import Foundation

/// Which path draws the score: the PDF raster that ships, or the display list
/// drawn straight into the canvas.
///
/// **Off by default, and it stays off.** The bitmap path -- Verovio SVG,
/// SwiftDraw, PDF, PDFKit, re-rastered at the settled zoom -- is what Ali
/// reads music from on stage, and it is adequate: a page is sharp at whatever
/// zoom it settles at. Nothing about this switch being present changes what
/// that path draws. The gate on turning it on is not a passing test: it is Ali
/// reading from both on his own scores and saying which he would rather play
/// from (`design/VECTOR_RENDER.md`, `ios/project.yml` 0.8.3).
///
/// A plain `UserDefaults` read, the same shape as `TouchDiagnostics` and
/// `PerfMetrics`, because those are the two switches this app already has for
/// "a thing the reader can turn on that is not a feature". A build-time
/// `#if` would be worse: it cannot be flipped on the iPad that has the scores
/// on it, which is the only place the comparison can be made.
enum VectorRendering {

    /// The Settings toggle's key. Diagnostics, beside the other two.
    static let defaultsKey = "vectorRendering"

    static var isOn: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }
}
