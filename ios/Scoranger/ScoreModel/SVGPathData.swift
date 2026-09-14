import CoreGraphics
import Foundation

/// An SVG `d` attribute turned into a `CGPath`.
///
/// This is the half of SVG path parsing `SVGPathBounds` deliberately does not
/// do. The two answer different questions and so share no code: bounds fold
/// every control point into a box and are allowed to over-estimate, while this
/// has to be right about the curve between them and about the reflected
/// control point an `S` or a `T` implies.
///
/// Measured against the Verovio output this app actually produces (both sample
/// scores, every page): the commands that appear are M m L l H h V v C c S s
/// Q q Z z. Arcs never appear, so `A` is recorded as unsupported and drawn as
/// a line to its endpoint rather than silently dropped.
enum SVGPathData {

    /// A command the builder met and did not draw faithfully.
    enum Unsupported: String, Equatable {
        /// Elliptical arc: approximated by a straight line to the endpoint.
        case arc
    }

    struct Result {
        let path: CGPath
        let unsupported: [Unsupported]
    }

    /// nil when `d` holds no drawable command at all.
    static func path(from d: String) -> Result? {
        let path = CGMutablePath()
        var unsupported: [Unsupported] = []
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var started = false
        /// The previous cubic's second control point, for `S`, and the
        /// previous quadratic's control point, for `T`. Reset by any other
        /// command, which is what the spec means by "assume the control point
        /// is coincident with the current point".
        var lastCubicControl: CGPoint?
        var lastQuadControl: CGPoint?

        func move(to p: CGPoint) {
            path.move(to: p)
            current = p
            subpathStart = p
            started = true
        }

        for (command, numbers) in tokens(of: d) {
            let relative = command.isLowercase
            let c = Character(command.uppercased())
            var i = 0
            func next() -> Double { defer { i += 1 }; return i < numbers.count ? numbers[i] : 0 }
            func point() -> CGPoint {
                let x = next(), y = next()
                return relative ? CGPoint(x: current.x + x, y: current.y + y)
                                : CGPoint(x: x, y: y)
            }
            // A path that opens with anything but a move is malformed; the
            // origin is the only defensible current point for it.
            if !started, c != "M" { move(to: .zero) }

            switch c {
            case "M":
                var first = true
                while i + 1 < numbers.count {
                    let p = point()
                    // Subsequent pairs after a moveto are IMPLICIT LINETOS
                    // (SVG 1.1 §8.3.2), which is how Verovio's glyph outlines
                    // read; treating them as moves breaks every filled glyph.
                    if first { move(to: p); first = false } else { path.addLine(to: p); current = p }
                }
                lastCubicControl = nil; lastQuadControl = nil

            case "L":
                while i + 1 < numbers.count {
                    let p = point(); path.addLine(to: p); current = p
                }
                lastCubicControl = nil; lastQuadControl = nil

            case "H":
                while i < numbers.count {
                    let x = next()
                    current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                    path.addLine(to: current)
                }
                lastCubicControl = nil; lastQuadControl = nil

            case "V":
                while i < numbers.count {
                    let y = next()
                    current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                    path.addLine(to: current)
                }
                lastCubicControl = nil; lastQuadControl = nil

            case "C":
                while i + 5 < numbers.count {
                    let c1 = point(), c2 = point(), end = point()
                    path.addCurve(to: end, control1: c1, control2: c2)
                    current = end; lastCubicControl = c2; lastQuadControl = nil
                }

            case "S":
                while i + 3 < numbers.count {
                    let c1 = reflect(lastCubicControl, about: current)
                    let c2 = point(), end = point()
                    path.addCurve(to: end, control1: c1, control2: c2)
                    current = end; lastCubicControl = c2; lastQuadControl = nil
                }

            case "Q":
                while i + 3 < numbers.count {
                    let control = point(), end = point()
                    path.addQuadCurve(to: end, control: control)
                    current = end; lastQuadControl = control; lastCubicControl = nil
                }

            case "T":
                while i + 1 < numbers.count {
                    let control = reflect(lastQuadControl, about: current)
                    let end = point()
                    path.addQuadCurve(to: end, control: control)
                    current = end; lastQuadControl = control; lastCubicControl = nil
                }

            case "A":
                // Never emitted by Verovio in anything this app engraves. A
                // line to the endpoint keeps the subpath closed and the
                // report says what was lost, which is better than a gap
                // nobody can account for.
                while i + 6 < numbers.count {
                    _ = next(); _ = next(); _ = next(); _ = next(); _ = next()
                    let end = point()
                    path.addLine(to: end)
                    current = end
                }
                unsupported.append(.arc)
                lastCubicControl = nil; lastQuadControl = nil

            case "Z":
                path.closeSubpath()
                current = subpathStart
                lastCubicControl = nil; lastQuadControl = nil

            default:
                break
            }
        }
        guard started, !path.isEmpty else { return nil }
        return Result(path: path.copy() ?? path, unsupported: unsupported)
    }

    /// The control point an `S`/`T` implies: the previous one mirrored through
    /// the current point, or the current point when there was no previous one.
    private static func reflect(_ previous: CGPoint?, about current: CGPoint) -> CGPoint {
        guard let previous else { return current }
        return CGPoint(x: 2 * current.x - previous.x, y: 2 * current.y - previous.y)
    }

    /// `d` split into (command letter, its numbers).
    ///
    /// Scanning is the same shape as `SVGPathBounds`: a sign may separate two
    /// numbers with no whitespace ("100-25"), and exponents are legal.
    private static func tokens(of d: String) -> [(Character, [Double])] {
        var out: [(Character, [Double])] = []
        var command: Character?
        var numbers: [Double] = []
        var index = d.startIndex

        func flush() {
            guard let command else { return }
            out.append((command, numbers))
            numbers = []
        }

        while index < d.endIndex {
            let ch = d[index]
            if ch.isLetter {
                flush()
                command = ch
                index = d.index(after: index)
            } else if ch == "-" || ch == "+" || ch == "." || ch.isNumber {
                var end = index
                if d[end] == "-" || d[end] == "+" { end = d.index(after: end) }
                var sawDot = false
                while end < d.endIndex {
                    let c = d[end]
                    if c.isNumber {
                        end = d.index(after: end)
                    } else if c == "." {
                        // a second dot starts a new number: "1.5.5" is two
                        if sawDot { break }
                        sawDot = true
                        end = d.index(after: end)
                    } else if c == "e" || c == "E" {
                        end = d.index(after: end)
                        if end < d.endIndex, d[end] == "-" || d[end] == "+" {
                            end = d.index(after: end)
                        }
                    } else {
                        break
                    }
                }
                if let value = Double(d[index..<end]) { numbers.append(value) }
                index = end
            } else {
                index = d.index(after: index)
            }
        }
        flush()
        return out
    }
}
