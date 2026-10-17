import Foundation

/// Reads the MEI that Verovio produces alongside the SVG and derives a durable
/// address for every element it can.
///
/// This is the half of the join that supplies meaning. Verovio's MEI carries
/// `xml:id` values identical to the ids in the SVG, plus the numbering the SVG
/// omits: `<measure n="7">`, `<staff n="1">`, `<layer n="1">`. So the SVG says
/// where a thing is drawn, the MEI says what it is, and the id ties them.
enum MEISemanticsParser {

    enum ParseError: Error, LocalizedError {
        case malformed(String)
        var errorDescription: String? {
            if case .malformed(let why) = self { return "Malformed MEI: \(why)" }
            return nil
        }
    }

    /// session id -> durable address.
    static func parse(_ mei: String) throws -> [String: ScoreAddress] {
        let delegate = Delegate()
        let parser = XMLParser(data: Data(mei.utf8))
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse() else {
            throw ParseError.malformed(parser.parserError?.localizedDescription ?? "unknown")
        }
        return delegate.addresses
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var addresses: [String: ScoreAddress] = [:]

        private var measure = 0
        /// Measures whose @n is missing or non-numeric still need a stable
        /// number, so fall back to counting them in document order.
        private var measureCount = 0
        private var staffStack: [Int] = []
        private var layerStack: [Int] = []
        /// (measure, staff, layer, kind) -> how many seen, for `ordinal`.
        private var counters: [String: Int] = [:]

        /// WORDS are numbered the ENGINE's way, not per layer (0.21.0).
        /// `ops._elements_in_measure(kind="lyric")` takes a bar's notes in
        /// document order across every voice -- a chord is one -- and each
        /// note's words in VERSE order. A verse's place in the MEI is neither
        /// of those: a word moved onto a note is appended after the verses it
        /// already had, and a lifted whistle column reorders a note's verses.
        /// So a bar's words are held until the bar ends and numbered then.
        private var notesInStaff: [Int: Int] = [:]
        private var chordDepth = 0
        private var currentNote = 0
        private var words: [(staff: Int, layer: Int, note: Int, verse: Int, id: String)] = []

        func parser(_ parser: XMLParser, didStartElement name: String,
                    namespaceURI: String?, qualifiedName: String?,
                    attributes attrs: [String: String]) {
            switch name {
            case "measure":
                measureCount += 1
                measure = Int(attrs["n"] ?? "") ?? measureCount
                notesInStaff = [:]
                words = []
            case "chord":
                let staff = staffStack.last ?? 0
                currentNote = notesInStaff[staff, default: 0]
                notesInStaff[staff] = currentNote + 1
                chordDepth += 1
            case "note" where chordDepth == 0:
                let staff = staffStack.last ?? 0
                currentNote = notesInStaff[staff, default: 0]
                notesInStaff[staff] = currentNote + 1
            case "staff":
                staffStack.append(Int(attrs["n"] ?? "") ?? (staffStack.last ?? 0) + 1)
            case "layer":
                layerStack.append(Int(attrs["n"] ?? "") ?? 1)
            default:
                break
            }

            guard let id = attrs["xml:id"], let kind = ScoreElementKind(meiTag: name) else {
                return
            }
            // Control events (harm, dynam, fermata, slur, tie) sit under
            // <measure> rather than inside a staff, and name their staff with
            // an attribute instead.
            let staff = staffStack.last ?? Int(attrs["staff"] ?? "") ?? 0
            let layer = layerStack.last ?? Int(attrs["layer"] ?? "") ?? 0
            if kind == .verse {
                // a fingering column (`wf`, packed `wf|...`) and a tab column
                // (`gt`, `gt@...`) are verses and are not words
                let label = attrs["label"] ?? ""
                if !label.hasPrefix("wf"), !label.hasPrefix("gt") {
                    words.append((staff, layer, currentNote, Int(attrs["n"] ?? "") ?? 0, id))
                }
                return
            }
            // A <dir> is held until its body has been read: a chord DIAGRAM is
            // a <dir> whose text is a six-fret shape, and giving one an
            // address would shift every later text mark's ordinal off the one
            // the engine counts (ops._elements_in_measure excludes them too).
            if kind == .text {
                pendingText = (id: id, staff: staff, layer: layer)
                pendingBody = ""
                return
            }
            assign(id, staff: staff, layer: layer, kind: kind)
        }

        /// A text mark's id and place, held while its words are read.
        private var pendingText: (id: String, staff: Int, layer: Int)?
        private var pendingBody = ""

        func parser(_ parser: XMLParser, foundCharacters text: String) {
            if pendingText != nil { pendingBody += text }
        }

        private func assign(_ id: String, staff: Int, layer: Int,
                            kind: ScoreElementKind) {
            let key = "\(measure)/\(staff)/\(layer)/\(kind.rawValue)"
            let ordinal = counters[key] ?? 0
            counters[key] = ordinal + 1
            addresses[id] = ScoreAddress(staff: staff, measure: measure,
                                         layer: layer, kind: kind, ordinal: ordinal)
        }

        func parser(_ parser: XMLParser, didEndElement name: String,
                    namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "staff": _ = staffStack.popLast()
            case "layer": _ = layerStack.popLast()
            case "chord": chordDepth = max(chordDepth - 1, 0)
            case "measure":
                for staff in Set(words.map(\.staff)) {
                    let mine = words.filter { $0.staff == staff }
                        .sorted { ($0.note, $0.verse) < ($1.note, $1.verse) }
                    for (ordinal, word) in mine.enumerated() {
                        addresses[word.id] = ScoreAddress(staff: staff, measure: measure,
                                                          layer: word.layer, kind: .verse,
                                                          ordinal: ordinal)
                    }
                }
                words = []
            case "dir":
                if let held = pendingText,
                   ChordDiagrams.parseShape(pendingBody) == nil {
                    assign(held.id, staff: held.staff, layer: held.layer,
                           kind: .text)
                }
                pendingText = nil
                pendingBody = ""
            default: break
            }
        }
    }
}
