import PDFKit
import UIKit

/// Print the score as it is engraved (0.17.0).
///
/// Ali: "make it really easy to print ... use the standard print so that I can
/// print whatever view I'm looking at ... available in single page view and
/// double page view", and never in the continuous strip, which is one system
/// on one endless page and has nothing a printer can take.
///
/// What prints is the engraved PDF the canvas is showing -- every page of the
/// version on screen, at the page size it was engraved for; the system sheet
/// chooses the printer, the copies and the range. Pencil markup is NOT on it
/// yet: ink is kept in the coordinates of the page as it was drawn on, not in
/// the PDF's (BACKLOG).
enum ScorePrinting {

    /// Whether this layout can be printed at all.
    static func available(in layout: ScoreLayout) -> Bool { !layout.isContinuous }

    @MainActor
    static func present(_ document: PDFDocument?, title: String) {
        guard let data = document?.dataRepresentation() else { return }
        let info = UIPrintInfo(dictionary: nil)
        info.outputType = .general
        info.jobName = title
        let controller = UIPrintInteractionController.shared
        controller.printInfo = info
        controller.printingItem = data
        controller.present(animated: true)
    }
}
