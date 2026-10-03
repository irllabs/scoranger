import Foundation

/// The line the reader watches while the agent works.
///
/// Lifted out of LocalChat so it can be tested: the test bundle has no host
/// app and compiles ScoreModel in whole, while LocalChat itself pulls in the
/// embedded engine, the Keychain and the network. The titles are pure over the
/// tool name and its arguments, so there is nothing here that needs any of it.
///
/// They say what the MUSIC is doing, not what the tool is called: a reader who
/// asked for a line a sixth below should see "Transposing a sixth below, in
/// key" and not "Transpose diatonic".
enum ChatSteps {

    static func stepTitle(name: String, argsJSON: String) -> String {
        let args = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8)) as? [String: Any]) ?? [:]
        func s(_ key: String) -> String? { args[key] as? String }
        /// A number the model may have written either way: JSON `3` or the
        /// string "3". Both arrive from real providers.
        func n(_ key: String) -> String? {
            if let v = args[key] as? String { return v }
            if let v = args[key] as? NSNumber { return v.stringValue }
            return nil
        }
        /// A flag the model may have written as JSON `true` or as "true".
        func flag(_ key: String) -> Bool {
            (args[key] as? Bool) == true || (args[key] as? String) == "true"
        }
        /// The four marks `add_element` writes, named the way a reader would
        /// say them rather than the way the tool spells them.
        func mark(_ kind: String?) -> String {
            switch kind {
            case "dynamic": return "dynamic"
            case "text": return "text mark"
            case "fermata": return "fermata"
            case "articulation": return "articulation"
            case "diagram": return "chord diagram"
            case "tab": return "tab column"
            default: return "chord name"
            }
        }
        switch name {
        case "get_score_info": return "Reading the score"
        case "list_versions": return "Checking version history"
        case "analyze_harmony": return "Analyzing the harmony"
        case "transpose": return "Transposing \(s("interval") ?? "")"
        case "respell": return "Respelling with \(s("prefer") ?? "flats")"
        case "change_instrument": return "\(s("part") ?? "part") → \(s("to_instrument") ?? "new instrument")"
        case "rename_part": return "Renaming \(s("part") ?? "part") to \(s("name") ?? "")"
        // Both read numbers through `n` and flags through `flag`: a provider
        // sends `4` and `true`, not "4" and "true", and reading them as strings
        // left every one of these lines on its fallback.
        case "staff_spacing":
            if flag("reset") { return "Putting the spacing back" }
            if let rows = n("fingering_rows") { return "Giving the fingerings \(rows) rows" }
            return "Respacing the staves"
        case "paginate":
            if flag("clear") { return "Letting the engraver lay it out" }
            if let per = n("measures_per_line") { return "Laying it out \(per) bars to a line" }
            if args["remove_at"] != nil { return "Taking a line break off" }
            if let ends = args["end_at"] as? [Any], let bar = ends.first {
                return "Ending the line at bar \(bar)"
            }
            if args["break_at"] != nil { return "Starting a new line" }
            return "Laying out the lines"
        case "measure_numbers":
            if flag("none") { return "Taking the measure numbers off" }
            if let every = n("every") {
                return every == "1" ? "Numbering every bar" : "Numbering every \(every) bars"
            }
            return "Numbering each line's first bar"
        case "set_structure":
            let what = s("kind") ?? "mark"
            if s("remove") == "true" { return "Removing the \(what)" }
            if let to = s("move_to") { return "Moving the \(what) to bar \(to)" }
            return "Adding \(what) at bar \(s("measure") ?? "?")"
        case "adjust_element":
            let what = mark(s("kind"))
            if s("reset") == "true" || args["reset"] as? Bool == true {
                return "Putting the \(what) back"
            }
            // Relative first, because relative is the interface: "make it
            // bigger" is a multiple of the engraved size, and a point value
            // only arrives from a caller that already holds one.
            if let scale = n("scale") { return "Resizing the \(what) to \(scale)x" }
            if let size = n("size") { return "Setting the \(what) to \(size)pt" }
            return "Moving the \(what)"
        case "add_element":
            return "Adding a \(mark(s("kind"))) at bar \(n("measure") ?? "?")"
        case "move_element":
            return "Moving the \(mark(s("kind"))) to bar \(n("to_measure") ?? "?")"
        case "duplicate_element":
            return "Copying the \(mark(s("kind"))) into bar \(n("to_measure") ?? "?")"
        case "strip_notes":
            return "Clearing the notes from \(s("part") ?? "the part")"
        case "guitar_tablature":
            return s("clear") == "true"
                ? "Removing the tab from \(s("part") ?? "the part")"
                : "Writing tab under \(s("part") ?? "the part")"
        case "guitar_chord_diagrams":
            return s("clear") == "true"
                ? "Removing chord diagrams from \(s("part") ?? "the part")"
                : "Drawing chord diagrams over \(s("part") ?? "the part")"
        case "penny_whistle_fingerings":
            return s("clear") == "true"
                ? "Removing whistle fingerings from \(s("part") ?? "the part")"
                : "Writing whistle fingerings under \(s("part") ?? "the part")"
        case "set_metadata":
            if let t = s("title") { return "Titling the arrangement \u{201C}\(t)\u{201D}" }
            return "Updating the arrangement's credits"
        case "transpose_diatonic", "transpose_diatonic_elements":
            // What this op does is MOVE a line and keep it in the key. It said
            // "Harmonising" instead, because the case that prompted it was a
            // harmony a sixth below -- but a harmony is two lines, and this op
            // writes no staff and adds no note (the CLI reference says so:
            // pull-part first, then this). So a reader who lassoed five notes
            // and asked to transpose them up an octave watched it say
            // "Harmonising an octave above" over a sentence that correctly
            // read "Transposed the 10 selected notes up one octave".
            //
            // "Transposing" is the musician's word for what happened and is
            // true of both readings; ", in key" is what still distinguishes it
            // from the chromatic `transpose` beside it.
            let degrees = s("degrees") ?? ""
            let steps = Int(degrees.replacingOccurrences(of: "+", with: ""))
            let named = steps.map { step -> String in
                let names = [2: "second", 3: "third", 4: "fourth", 5: "fifth",
                             6: "sixth", 7: "seventh", 8: "octave", 9: "ninth",
                             10: "tenth", 12: "twelfth"]
                let where_ = step < 0 ? "below" : "above"
                guard let name = names[abs(step)] else {
                    // no article: "13 steps below" reads, "a 13 steps below" does not
                    return "\(abs(step)) steps \(where_)"
                }
                let article = "aeiou".contains(name.first ?? "x") ? "an" : "a"
                return "\(article) \(name) \(where_)"
            } ?? degrees
            return "Transposing \(named), in key"
        case "change_clef": return "Setting \(s("part") ?? "part") to \(s("clef") ?? "") clef"
        case "keep_parts", "remove_parts":
            let parts = (args["parts"] as? [String])?.joined(separator: ", ") ?? ""
            return name == "keep_parts" ? "Keeping only \(parts)" : "Removing \(parts)"
        case "merge_parts": return "Merging into \(s("new_name") ?? "one staff")"
        case "split_bass": return "Splitting bass and chords"
        case "octave_shift": return "Octave shift: \(s("part") ?? "part")"
        case "check_range": return "Checking range of \(s("part") ?? "part")"
        case "set_chords": return "Writing chord symbols"
        case "chart_style": return "Applying chart styling"
        case "pull_part": return "Pulling \(s("part") ?? "part") from \(s("from_ref") ?? "source")"
        case "absorb_part": return "Folding \(s("source") ?? "part") into \(s("target") ?? "part")"
        case "flatten_voices": return "Flattening voices in \(s("part") ?? "part")"
        case "consolidate_ties": return "Cleaning up ties"
        case "limit_part": return "Limiting \(s("part") ?? "part") for playability"
        case "simplify_repeats": return "Simplifying repeated bass notes"
        // The MODE is the step: augmenting keeps every note and thinning
        // throws some away, and a reader watching should be told which.
        case "simplify_rhythm":
            if s("mode") == "augment" { return "Doubling every note value" }
            return "Thinning \(s("part") ?? "the rhythm") to \(s("unit") ?? "eighth")s"
        default:
            return name.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    // MARK: - What a failed step says

    /// How far a refusal reaches into the step line before it is cut.
    static let reasonLimit = 100

    /// The reader's half of a tool failure.
    ///
    /// The engine reports a refusal as `"<ExceptionClass>: <message>"`, which
    /// is right for the model -- it goes back in the transcript unchanged and
    /// the model corrects itself off it -- and wrong for the step line a
    /// musician reads. Ali was shown `ValueError: No par…`: sixty characters
    /// of which eleven were a Python class name and the rest was cut off
    /// before it could say which part.
    ///
    /// So the class name is dropped and the message kept. NOTHING IS
    /// SWALLOWED: the full text still goes to the model as the tool result,
    /// and the message here is the engine's own words -- "No part named
    /// 'Violin 1'. Score has: Violin I, Violin II, Viola, Violoncello" --
    /// which is the half that tells the reader what happened.
    ///
    /// A traceback names its failure on the LAST line; the frames above it
    /// are for a log, not for someone holding an iPad.
    static func readableError(_ raw: String) -> String {
        let lines = raw.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var text = lines.last ?? raw.trimmingCharacters(in: .whitespaces)
        text = strippingExceptionClass(text)
        if text.isEmpty { return "the engine gave no reason" }
        if text.count > reasonLimit {
            return String(text.prefix(reasonLimit)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return text
    }

    /// Drop a leading Python exception class name. Matched by SHAPE -- one
    /// unspaced identifier ending in Error or Exception, then ": ", then
    /// something -- so a refusal that happens to contain a colon ("Measure 3:
    /// nothing starts there") keeps all of itself.
    private static func strippingExceptionClass(_ text: String) -> String {
        guard let colon = text.firstIndex(of: ":") else { return text }
        let head = String(text[text.startIndex..<colon])
        guard !head.isEmpty, head.count <= 40,
              head.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }),
              head.first?.isUppercase == true,
              head.hasSuffix("Error") || head.hasSuffix("Exception") else { return text }
        let rest = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        // A class name and nothing else is all the reason there is; keep it
        // rather than hand the reader an empty line.
        return rest.isEmpty ? text : rest
    }
}
