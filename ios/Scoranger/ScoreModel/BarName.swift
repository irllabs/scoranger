import Foundation

/// How the app names a bar to a reader: "bar 12", and a pickup is "pickup".
///
/// The Swift half of `ops.bar_label`. Since 0.17.0 an imported tune's first
/// full bar is bar 1, so a bar 0 is only ever the upbeat before it -- and no
/// page prints a bar 0, so a readout saying "bar 0" names a bar the reader
/// cannot find. Found on Amazing Grace in the App Store screenshots: the
/// transport and the page header both read "bar 0" on its one-note pickup.
///
/// For what the READER sees. Op arguments and chat context keep the number:
/// an address may say `m0`, and the agent passes numbers back.
enum BarName {

    /// "bar 12", or "pickup".
    static func text(_ bar: Int) -> String {
        bar == 0 ? "pickup" : "bar \(bar)"
    }

    /// As the object of a phrase: "bar 12", or "the pickup".
    static func phrase(_ bar: Int) -> String {
        bar == 0 ? "the pickup" : "bar \(bar)"
    }

    /// A run of bars: "bar 3", "bars 3–8", or "the pickup to bar 8".
    static func range(_ first: Int, _ last: Int) -> String {
        if first == last { return phrase(first) }
        return first == 0 ? "the pickup to bar \(last)" : "bars \(first)–\(last)"
    }
}
