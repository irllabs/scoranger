import Foundation

/// What deleting this account will actually do, said before it is done.
///
/// design/FIREBASE.md §6.6, and Apple's App Review guideline 5.1.1(v), which
/// requires an app that creates accounts to delete them from inside the app.
///
/// **This type is the client's opinion and it is not the enforcement**, in
/// exactly the sense `SetlistPermission` is not: the `deleteAccount` Cloud
/// Function decides what happens, because membership is server-authoritative
/// (§4.4) and a client cannot write a membership map. What this exists for is
/// the sentence in front of the button. A destructive confirm that does not
/// say which set lists are about to be destroyed is not a confirm, and the two
/// have to agree, so the rule they must agree on is written once here where a
/// test can read it.
///
/// It is Firebase-free on purpose -- no import, no `Auth`, no `Firestore` --
/// which is what lets it be compiled into `ScorangerTests`, a bundle with no
/// host app that cannot link the SDK.
enum AccountDeletionPlan {

    /// One shared set list this person is in, as the app already knows it.
    ///
    /// `memberCount` INCLUDES them. It is the size of the set list's `members`
    /// map, which is what `SharedSetlists.Setlist` carries, so nothing has to
    /// be fetched to answer the question.
    struct Standing: Equatable {
        let name: String
        let isOwner: Bool
        let memberCount: Int

        init(name: String, isOwner: Bool, memberCount: Int) {
            self.name = name
            self.isOwner = isOwner
            self.memberCount = memberCount
        }
    }

    /// What happens to one set list.
    enum Fate: Equatable {
        /// Theirs, and other people are in it. It passes to the next person
        /// invited (§6.6). Nobody's music leaves anybody's library.
        case handedOn
        /// Theirs, and they are the last member. There is no other person's
        /// work in it to protect, so it goes with the account.
        case destroyed
        /// Somebody else's. It carries on without them.
        case left
    }

    /// What will happen, per set list and in total.
    struct Outcome: Equatable {
        let handedOn: [String]
        let destroyed: [String]
        let left: [String]

        var isEmpty: Bool { handedOn.isEmpty && destroyed.isEmpty && left.isEmpty }
    }

    static func fate(of standing: Standing) -> Fate {
        guard standing.isOwner else { return .left }
        // `memberCount` counts them, so 1 means nobody else. Anything under 1
        // is a set list this person is not in, which cannot happen and is
        // treated as the safe answer rather than as a reason to destroy.
        return standing.memberCount > 1 ? .handedOn : .destroyed
    }

    static func outcome(for standings: [Standing]) -> Outcome {
        var handedOn: [String] = []
        var destroyed: [String] = []
        var left: [String] = []
        for standing in standings {
            switch fate(of: standing) {
            case .handedOn:  handedOn.append(standing.name)
            case .destroyed: destroyed.append(standing.name)
            case .left:      left.append(standing.name)
            }
        }
        return Outcome(handedOn: handedOn, destroyed: destroyed, left: left)
    }

    // MARK: - what the reader is told

    /// The question, on the confirm.
    ///
    /// It names the irreversibility and nothing else: the detail belongs in
    /// `consequence`, where there is room to be specific, and a question that
    /// tries to carry both is one nobody finishes reading.
    static func question() -> String { "Delete your account?" }

    /// The sentence -- sentences, here -- naming the consequence.
    ///
    /// Built from the outcome rather than written once, because "some of your
    /// set lists are destroyed" is a different warning from "none are", and a
    /// reader who owns one set list alone is entitled to see its name before
    /// they press a red button.
    ///
    /// DESTROYED FIRST. It is the only irreversible loss of somebody's music
    /// in the list, and the one thing a person might stop for.
    static func consequence(for outcome: Outcome) -> String {
        var parts: [String] = []

        if !outcome.destroyed.isEmpty {
            let n = outcome.destroyed.count
            parts.append("\(list(outcome.destroyed)) "
                + (n == 1 ? "is deleted" : "are deleted")
                + ", because nobody else is in "
                + (n == 1 ? "it." : "them."))
        }
        if !outcome.handedOn.isEmpty {
            let n = outcome.handedOn.count
            parts.append("\(list(outcome.handedOn)) "
                + (n == 1 ? "passes" : "pass")
                + " to the next person invited, so the band keeps "
                + (n == 1 ? "it." : "them."))
        }
        if !outcome.left.isEmpty {
            let n = outcome.left.count
            parts.append("You come out of \(list(outcome.left)), which "
                + (n == 1 ? "carries" : "carry") + " on without you.")
        }
        // Said whenever there is a shared set list at all, because the marks
        // are the thing a person would not think to ask about.
        if !outcome.isEmpty {
            parts.append("Your pencil marks on shared set lists go with it.")
        }
        parts.append("This cannot be undone.")
        return parts.joined(separator: " ")
    }

    /// The promise, next to the button, in the words `account-signout-keeps`
    /// uses for signing out.
    ///
    /// The music is on the iPad and deleting the account does not reach it.
    /// This is not reassurance, it is the truth about a local-first app, and
    /// saying it is what stops "delete my account" reading as "delete my
    /// library".
    static let keepsLocalLibrary =
        "Your library stays on this iPad. Deleting your account removes you "
        + "from Scoranger's servers, deletes the copy of your library kept "
        + "there for your other devices, and takes you off every shared set "
        + "list; it does not touch the music, the arrangements or the markup "
        + "held here."

    /// Names, in prose. Two get named; after that it is a count, because a
    /// confirm that lists nine set lists is one nobody reads.
    static func list(_ names: [String]) -> String {
        let shown = names.map { $0.isEmpty ? "an unnamed set list" : $0 }
        switch shown.count {
        case 0: return ""
        case 1: return shown[0]
        case 2: return "\(shown[0]) and \(shown[1])"
        default:
            let rest = shown.count - 2
            return "\(shown[0]), \(shown[1]) and \(rest) other"
                + (rest == 1 ? "" : "s")
        }
    }
}
