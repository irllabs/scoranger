import CoreGraphics
import Foundation

/// An engraving as bytes, for keeping on disk between launches
/// (`EngravingStore`), and back.
///
/// The pages are stored as the PDF the engrave produced, byte for byte, and
/// the hit-test model as every field `ScorePage.init` takes, so what comes
/// back is the engraving that went in: the same PDF, and a geometry whose
/// derived parts (bar frames, the hit-test grid, the lookups) are recomputed
/// from the same inputs by the same code. `EngravingArchiveTests` holds the
/// round trip to `OpenTiming.canonicalJSON`, the form the open-speed fidelity
/// check compares.
///
/// A flat binary layout rather than `Codable`: "Espresso"'s model is several
/// thousand elements, and the point of keeping it is an open in well under
/// the 200 ms budget. Any mismatch on the way back in -- a short file, an
/// unknown kind, a newer format -- is nil, and the caller engraves.
enum EngravingArchive {

    struct Contents {
        var pdf: Data
        var failedPages: [Int]
        var geometry: ScoreGeometry?
        var marks: [ScoreAddress: ChordAdjustments.Adjustment]
    }

    private static let magic: UInt32 = 0x5343_454E   // "SCEN"
    private static let format: UInt32 = 1

    // MARK: - Writing

    static func encode(_ contents: Contents) -> Data {
        var w = Writer()
        w.u32(magic)
        w.u32(format)
        w.data(contents.pdf)
        w.u32(UInt32(contents.failedPages.count))
        for page in contents.failedPages { w.i64(page) }

        // every kind the archive names, once; elements refer to them by index
        var kinds: [ScoreElementKind] = []
        var kindIndex: [ScoreElementKind: Int] = [:]
        func index(of kind: ScoreElementKind) -> Int {
            if let i = kindIndex[kind] { return i }
            kindIndex[kind] = kinds.count
            kinds.append(kind)
            return kinds.count - 1
        }
        var body = Writer()
        func address(_ a: ScoreAddress, into w: inout Writer) {
            w.i64(a.staff); w.i64(a.measure); w.i64(a.layer)
            w.u16(UInt16(index(of: a.kind))); w.i64(a.ordinal)
        }
        if let geometry = contents.geometry {
            body.u8(1)
            body.u32(UInt32(geometry.pages.count))
            for page in geometry.pages {
                body.i64(page.index)
                body.f64(page.size.width); body.f64(page.size.height)
                body.i64(page.drawnSystems)
                body.u32(UInt32(page.elements.count))
                for e in page.elements {
                    body.string(e.sessionID)
                    body.u16(UInt16(index(of: e.kind)))
                    body.i64(e.pageIndex)
                    body.f64(e.frame.origin.x); body.f64(e.frame.origin.y)
                    body.f64(e.frame.size.width); body.f64(e.frame.size.height)
                    if let a = e.address { body.u8(1); address(a, into: &body) } else { body.u8(0) }
                }
            }
        } else {
            body.u8(0)
        }
        // in key order, so the same engraving is always the same bytes
        let marks = contents.marks.sorted { $0.key.description < $1.key.description }
        body.u32(UInt32(marks.count))
        for (a, adjustment) in marks {
            address(a, into: &body)
            for value in [adjustment.size, adjustment.dx, adjustment.dy] {
                if let value { body.u8(1); body.f64(value) } else { body.u8(0) }
            }
        }

        w.u32(UInt32(kinds.count))
        for kind in kinds { w.string(kind.rawValue) }
        w.bytes.append(body.bytes)
        return w.bytes
    }

    // MARK: - Reading

    static func decode(_ data: Data) -> Contents? {
        var r = Reader(data)
        guard r.u32() == magic, r.u32() == format,
              let pdf = r.data(), let failedCount = r.u32() else { return nil }
        var failed: [Int] = []
        for _ in 0..<failedCount {
            guard let n = r.i64() else { return nil }
            failed.append(n)
        }
        guard let kindCount = r.u32() else { return nil }
        var kinds: [ScoreElementKind] = []
        for _ in 0..<kindCount {
            guard let raw = r.string(), let kind = ScoreElementKind(rawValue: raw) else { return nil }
            kinds.append(kind)
        }
        func kind() -> ScoreElementKind? {
            guard let i = r.u16(), Int(i) < kinds.count else { return nil }
            return kinds[Int(i)]
        }
        func address() -> ScoreAddress? {
            guard let staff = r.i64(), let measure = r.i64(), let layer = r.i64(),
                  let k = kind(), let ordinal = r.i64() else { return nil }
            return ScoreAddress(staff: staff, measure: measure, layer: layer, kind: k,
                                ordinal: ordinal)
        }

        var geometry: ScoreGeometry?
        guard let hasGeometry = r.u8() else { return nil }
        if hasGeometry == 1 {
            guard let pageCount = r.u32() else { return nil }
            var pages: [ScorePage] = []
            pages.reserveCapacity(Int(pageCount))
            for _ in 0..<pageCount {
                guard let index = r.i64(), let width = r.f64(), let height = r.f64(),
                      let drawn = r.i64(), let elementCount = r.u32() else { return nil }
                var elements: [ScoreElement] = []
                elements.reserveCapacity(Int(elementCount))
                for _ in 0..<elementCount {
                    guard let id = r.string(), let k = kind(), let pageIndex = r.i64(),
                          let x = r.f64(), let y = r.f64(), let w = r.f64(), let h = r.f64(),
                          let hasAddress = r.u8() else { return nil }
                    var a: ScoreAddress?
                    if hasAddress == 1 {
                        guard let read = address() else { return nil }
                        a = read
                    }
                    elements.append(ScoreElement(sessionID: id, kind: k, address: a,
                                                 pageIndex: pageIndex,
                                                 frame: CGRect(x: x, y: y, width: w, height: h)))
                }
                pages.append(ScorePage(index: index, size: CGSize(width: width, height: height),
                                       elements: elements, drawnSystems: drawn))
            }
            geometry = ScoreGeometry(pages: pages)
        }
        guard let markCount = r.u32() else { return nil }
        var marks: [ScoreAddress: ChordAdjustments.Adjustment] = [:]
        for _ in 0..<markCount {
            guard let a = address() else { return nil }
            var values: [CGFloat?] = []
            for _ in 0..<3 {
                guard let flag = r.u8() else { return nil }
                if flag == 1 {
                    guard let v = r.f64() else { return nil }
                    values.append(v)
                } else {
                    values.append(nil)
                }
            }
            marks[a] = ChordAdjustments.Adjustment(size: values[0], dx: values[1], dy: values[2])
        }
        guard r.atEnd else { return nil }
        return Contents(pdf: pdf, failedPages: failed, geometry: geometry, marks: marks)
    }

    // MARK: - Bytes

    /// Little-endian fixed-width fields; strings and blobs carry their length.
    private struct Writer {
        var bytes = Data()

        mutating func u8(_ v: UInt8) { bytes.append(v) }
        mutating func u16(_ v: UInt16) { append(v.littleEndian) }
        mutating func u32(_ v: UInt32) { append(v.littleEndian) }
        mutating func i64(_ v: Int) { append(Int64(v).littleEndian) }
        mutating func f64(_ v: CGFloat) { append(Double(v).bitPattern.littleEndian) }
        mutating func string(_ s: String) {
            let utf8 = Data(s.utf8)
            u32(UInt32(utf8.count))
            bytes.append(utf8)
        }
        mutating func data(_ d: Data) {
            append(UInt64(d.count).littleEndian)
            bytes.append(d)
        }
        private mutating func append<T: FixedWidthInteger>(_ v: T) {
            withUnsafeBytes(of: v) { bytes.append(contentsOf: $0) }
        }
    }

    private struct Reader {
        private let bytes: [UInt8]
        private var at = 0

        init(_ data: Data) { bytes = [UInt8](data) }

        var atEnd: Bool { at == bytes.count }

        mutating func u8() -> UInt8? {
            guard at < bytes.count else { return nil }
            defer { at += 1 }
            return bytes[at]
        }
        mutating func u16() -> UInt16? { read(UInt16.self).map(UInt16.init(littleEndian:)) }
        mutating func u32() -> UInt32? { read(UInt32.self).map(UInt32.init(littleEndian:)) }
        mutating func i64() -> Int? {
            read(Int64.self).map { Int(Int64(littleEndian: $0)) }
        }
        mutating func f64() -> CGFloat? {
            read(UInt64.self).map { CGFloat(Double(bitPattern: UInt64(littleEndian: $0))) }
        }
        mutating func string() -> String? {
            guard let n = u32().map(Int.init), n <= bytes.count - at else { return nil }
            defer { at += n }
            return String(decoding: bytes[at..<(at + n)], as: UTF8.self)
        }
        mutating func data() -> Data? {
            guard let n64 = read(UInt64.self).map(UInt64.init(littleEndian:)),
                  n64 <= UInt64(bytes.count - at) else { return nil }
            let n = Int(n64)
            defer { at += n }
            return Data(bytes[at..<(at + n)])
        }
        private mutating func read<T: FixedWidthInteger>(_: T.Type) -> T? {
            let size = MemoryLayout<T>.size
            guard size <= bytes.count - at else { return nil }
            var value: T = 0
            withUnsafeMutableBytes(of: &value) { dest in
                for i in 0..<size { dest[i] = bytes[at + i] }
            }
            at += size
            return value
        }
    }
}
