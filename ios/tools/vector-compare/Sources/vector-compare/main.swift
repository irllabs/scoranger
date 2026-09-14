import CoreGraphics
import Foundation
import ImageIO
import SwiftDraw

// The same page of the same engraving, drawn twice, written out for a person
// to look at.
//
//   vector-compare page.svg [more.svg …] [--width 972] [--pixel-scale 2]
//                           [--out <directory>]
//
// For each input it writes four PNGs and prints what the vector path did not
// draw. The build this belongs to is gated on the pictures, not on the numbers
// underneath them: a difference count says how much two pages disagree, never
// whether the disagreement matters to somebody reading music off one of them.

// MARK: - Arguments

struct Options {
    var inputs: [URL] = []
    var width: CGFloat = 972            // the app's engraved page width in points
    var pixelScale: CGFloat = 2         // as PDFPageImage's floor: 2x for crispness
    var out = URL(fileURLWithPath: "/tmp/scoranger-vector-compare")
    /// Also write the SVG the bitmap path actually draws, which is not the
    /// SVG Verovio produced: `SVGForSwiftDraw` rewrites it substantially.
    var dumpPrepared = false
}

func parseArguments() throws -> Options {
    var options = Options()
    // `CommandLine` is also a type in SwiftDraw, which this links.
    var arguments = Array(Swift.CommandLine.arguments.dropFirst())
    while let argument = arguments.first {
        arguments.removeFirst()
        switch argument {
        case "--width":
            guard let value = arguments.first.flatMap(Double.init) else {
                throw Failure("--width needs a number")
            }
            options.width = CGFloat(value); arguments.removeFirst()
        case "--pixel-scale":
            guard let value = arguments.first.flatMap(Double.init) else {
                throw Failure("--pixel-scale needs a number")
            }
            options.pixelScale = CGFloat(value); arguments.removeFirst()
        case "--dump-prepared":
            options.dumpPrepared = true
        case "--out":
            guard let value = arguments.first else { throw Failure("--out needs a directory") }
            options.out = URL(fileURLWithPath: value); arguments.removeFirst()
        default:
            guard !argument.hasPrefix("--") else { throw Failure("unknown option \(argument)") }
            options.inputs.append(URL(fileURLWithPath: argument))
        }
    }
    guard !options.inputs.isEmpty else {
        throw Failure("usage: vector-compare <page.svg> … [--width N] [--pixel-scale N] [--out DIR]")
    }
    return options
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - Rasters

/// An 8-bit grey bitmap on white. Grey because both paths draw black on paper
/// and nothing else, so a colour buffer would be three times the memory to
/// hold the same one number per pixel.
func paperContext(pixels: CGSize) throws -> CGContext {
    guard let context = CGContext(
        data: nil, width: Int(pixels.width), height: Int(pixels.height),
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGImageAlphaInfo.none.rawValue)
    else { throw Failure("could not allocate a \(Int(pixels.width))x\(Int(pixels.height)) bitmap") }
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(origin: .zero, size: pixels))
    return context
}

/// THE PATH THAT SHIPS: Verovio SVG -> SwiftDraw -> PDF -> raster.
///
/// `SVGForSwiftDraw.prepare` and `SVG(data:)/pdfData()` are exactly what
/// `PageRasteriser.rasterise(number:svg:)` does; the raster after it is what
/// `PDFPageImage` asks `PDFPage.thumbnail` for. PDFKit is not used here
/// because it is a wrapper over the same `CGPDFPage` draw and it is not
/// available to a plain SwiftPM tool.
func bitmapPathRaster(svg: String, pixels: CGSize) throws -> CGContext {
    let prepared = SVGForSwiftDraw.prepare(svg)
    guard !prepared.isEmpty else { throw Failure("the SwiftDraw rewrite came out empty") }
    guard let parsed = SVG(data: Data(prepared.utf8)) else {
        throw Failure("SwiftDraw would not parse the rewritten page")
    }
    let pdf = try parsed.pdfData()
    guard let provider = CGDataProvider(data: pdf as CFData),
          let document = CGPDFDocument(provider),
          let page = document.page(at: 1)
    else { throw Failure("the drawn page is not a readable PDF") }

    let context = try paperContext(pixels: pixels)
    context.interpolationQuality = .high
    context.setRenderingIntent(.defaultIntent)
    context.drawPDFPage(page, fitting: pixels)
    return context
}

/// THE PATH UNDER TEST: Verovio SVG -> display list -> Core Graphics.
func vectorPathRaster(svg: String, pixels: CGSize) throws -> (CGContext, VectorPage) {
    let page = try VectorPageParser.parse(svg)
    let context = try paperContext(pixels: pixels)
    // A CGBitmapContext counts y upwards and SVG counts it downwards.
    VectorPageRenderer.flip(context, height: pixels.height)
    VectorPageRenderer.draw(page, in: context, width: pixels.width)
    return (context, page)
}

extension CGContext {
    /// Draw a PDF page scaled to fill `size`, aspect preserved.
    func drawPDFPage(_ page: CGPDFPage, fitting size: CGSize) {
        let media = page.getBoxRect(.mediaBox)
        guard media.width > 0, media.height > 0 else { return }
        saveGState()
        let scale = min(size.width / media.width, size.height / media.height)
        translateBy(x: (size.width - media.width * scale) / 2,
                    y: (size.height - media.height * scale) / 2)
        scaleBy(x: scale, y: scale)
        translateBy(x: -media.minX, y: -media.minY)
        drawPDFPage(page)
        restoreGState()
    }
}

// MARK: - Comparison

struct Difference {
    let inkInBoth: Int
    let inkInBitmapOnly: Int
    let inkInVectorOnly: Int
    let image: CGImage

    var bitmapInk: Int { inkInBoth + inkInBitmapOnly }
    var vectorInk: Int { inkInBoth + inkInVectorOnly }
}

/// Where the two pages disagree, as a picture and as three counts.
///
/// A pixel is INK below `threshold` on a 0-255 grey. The threshold is generous
/// on purpose: the two paths antialias the same stem differently, and counting
/// every faint edge pixel as a disagreement would bury the missing hairpin in
/// a million harmless ones.
func compare(bitmap: CGContext, vector: CGContext, threshold: UInt8 = 160) throws -> Difference {
    let width = bitmap.width, height = bitmap.height
    guard vector.width == width, vector.height == height,
          let a = bitmap.data, let b = vector.data
    else { throw Failure("the two rasters are not the same size") }
    let aRow = bitmap.bytesPerRow, bRow = vector.bytesPerRow
    let aBytes = a.assumingMemoryBound(to: UInt8.self)
    let bBytes = b.assumingMemoryBound(to: UInt8.self)

    var both = 0, bitmapOnly = 0, vectorOnly = 0
    var rgb = [UInt8](repeating: 255, count: width * height * 3)
    for y in 0..<height {
        for x in 0..<width {
            let inBitmap = aBytes[y * aRow + x] < threshold
            let inVector = bBytes[y * bRow + x] < threshold
            let out = (y * width + x) * 3
            switch (inBitmap, inVector) {
            case (true, true):
                both += 1
                rgb[out] = 170; rgb[out + 1] = 170; rgb[out + 2] = 170
            case (true, false):
                // ONLY on the page that ships: what the vector path lost.
                bitmapOnly += 1
                rgb[out] = 200; rgb[out + 1] = 30; rgb[out + 2] = 30
            case (false, true):
                // ONLY on the new page: what it invented or moved.
                vectorOnly += 1
                rgb[out] = 30; rgb[out + 1] = 70; rgb[out + 2] = 200
            case (false, false):
                break
            }
        }
    }
    guard let provider = CGDataProvider(data: Data(rgb) as CFData),
          let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                              bitsPerPixel: 24, bytesPerRow: width * 3,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: false,
                              intent: .defaultIntent)
    else { throw Failure("could not build the difference image") }
    return Difference(inkInBoth: both, inkInBitmapOnly: bitmapOnly,
                      inkInVectorOnly: vectorOnly, image: image)
}

/// The two pages side by side, which is the picture the decision is made from.
func sideBySide(left: CGImage, right: CGImage) throws -> CGImage {
    let gutter = 24
    let size = CGSize(width: left.width + gutter + right.width,
                      height: max(left.height, right.height))
    let context = try paperContext(pixels: size)
    context.setFillColor(gray: 0.75, alpha: 1)
    context.fill(CGRect(x: left.width, y: 0, width: gutter, height: Int(size.height)))
    context.draw(left, in: CGRect(x: 0, y: 0, width: left.width, height: left.height))
    context.draw(right, in: CGRect(x: left.width + gutter, y: 0,
                                   width: right.width, height: right.height))
    guard let image = context.makeImage() else { throw Failure("could not compose the pair") }
    return image
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, "public.png" as CFString, 1, nil)
    else { throw Failure("could not write \(url.path)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw Failure("could not finalise \(url.path)")
    }
}

// MARK: - Run

do {
    let options = try parseArguments()
    try FileManager.default.createDirectory(at: options.out, withIntermediateDirectories: true)
    for input in options.inputs {
        let svg = try String(contentsOf: input, encoding: .utf8)
        let name = input.deletingPathExtension().lastPathComponent

        // Both paths are told the same page size in points and the same
        // pixels per point, so a difference in the pictures is a difference in
        // the drawing and never in the sampling.
        let parsed = try VectorPageParser.parse(svg)
        let aspect = parsed.size.height / parsed.size.width
        let pixels = CGSize(width: (options.width * options.pixelScale).rounded(),
                            height: (options.width * aspect * options.pixelScale).rounded())

        if options.dumpPrepared {
            try SVGForSwiftDraw.prepare(svg)
                .write(to: options.out.appending(path: "\(name)-prepared.svg"),
                       atomically: true, encoding: .utf8)
        }
        let bitmap = try bitmapPathRaster(svg: svg, pixels: pixels)
        let (vector, page) = try vectorPathRaster(svg: svg, pixels: pixels)
        guard let bitmapImage = bitmap.makeImage(), let vectorImage = vector.makeImage() else {
            throw Failure("could not read back a raster")
        }
        let difference = try compare(bitmap: bitmap, vector: vector)

        try writePNG(bitmapImage, to: options.out.appending(path: "\(name)-bitmap.png"))
        try writePNG(vectorImage, to: options.out.appending(path: "\(name)-vector.png"))
        try writePNG(try sideBySide(left: bitmapImage, right: vectorImage),
                     to: options.out.appending(path: "\(name)-side-by-side.png"))
        try writePNG(difference.image, to: options.out.appending(path: "\(name)-difference.png"))

        let total = Double(difference.bitmapInk)
        let lost = total > 0 ? Double(difference.inkInBitmapOnly) / total * 100 : 0
        let gained = total > 0 ? Double(difference.inkInVectorOnly) / total * 100 : 0
        print("""
        \(name)
          page          \(Int(page.size.width)) x \(Int(page.size.height)) pt, \
        drawn at \(Int(pixels.width)) x \(Int(pixels.height)) px
          display list  \(page.items.count) items
          ink           bitmap \(difference.bitmapInk)  vector \(difference.vectorInk)
          disagreement  \(difference.inkInBitmapOnly) px only on the bitmap page (\
        \(String(format: "%.1f", lost))% of its ink), \
        \(difference.inkInVectorOnly) px only on the vector page (\
        \(String(format: "%.1f", gained))%)
        """)
        if page.undrawn.isEmpty {
            print("  not drawn    nothing the parser could name")
        } else {
            for undrawn in page.undrawn {
                print("  not drawn    \(undrawn.count) x \(undrawn.reason)")
            }
        }
        print("  written to    \(options.out.path)")
    }
} catch {
    FileHandle.standardError.write(Data("vector-compare: \(error)\n".utf8))
    exit(1)
}
