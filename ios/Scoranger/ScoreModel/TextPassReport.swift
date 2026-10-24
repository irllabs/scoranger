import Foundation

/// What a reader is told after a PDF is transcribed (0.21.0).
///
/// The engine's text-layer pass (`pdftext.correct`) puts the words and chord
/// names a PDF prints on the notes the scanner read, and takes the lines
/// printed under the music -- stanzas, credits -- off the notes the scanner
/// hung them on. The reader is owed both halves: what now comes from the
/// page, and what was left off it. Nil when there is nothing to say.
enum TextPassReport {

    static func notice(from pass: [String: Any]?) -> String? {
        guard let pass else { return nil }
        if pass["failed"] != nil {
            return "The PDF's printed words could not be read, so the words and "
                + "chords are as the scanner read them."
        }
        var sentences: [String] = []
        if (pass["pages_lined_up"] as? Int ?? 0) > 0 {
            let words = pass["syllables"] as? Int ?? 0
            let chords = pass["chords"] as? Int ?? 0
            sentences.append("Words and chord names are as the PDF prints them: "
                             + "\(count(words, "syllable")) and \(count(chords, "chord"))."
            )
        } else if (pass["pages_misaligned"] as? Int ?? 0) > 0 {
            // Only when the PDF prints the words the scanner read and they did
            // not line up. A text layer holding nothing but a header is not
            // "printed words" (The Cat's Meow, 0.23.2), and says nothing.
            sentences.append("The PDF's printed words did not line up with the music, "
                             + "so the words are as the scanner read them.")
        }
        let below = (pass["text_below_music"] as? [Any])?.count ?? 0
        if below > 0 {
            sentences.append(below == 1
                ? "1 line printed below the music is not a lyric and was left off."
                : "\(below) lines printed below the music are not lyrics and were left off.")
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    private static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }
}
