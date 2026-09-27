import SwiftUI

/// The account, in Settings, and nowhere else.
///
/// design/FIREBASE.md §0.2. It sits here rather than behind a tab or a launch
/// prompt because signing in is OPTIONAL: no screen in this app requires an
/// account, and a reader who never signs in should never be asked. This
/// section is what they would find if they went looking.
struct AccountSection: View {
    @EnvironmentObject var signIn: SignIn
    /// Only to let go of its listeners on the way out. Signed in or out, this
    /// section shows nothing about shared set lists.
    @EnvironmentObject var shared: SharedSetlists
    /// A pasted invitation is put where a tapped one goes: `pendingInvite`, in
    /// front of the same "You've been invited" band, claimed by the same
    /// button. One entrance, two doors into it.
    @EnvironmentObject var state: AppState
    /// Where the account's library stands on this device (0.16.0).
    @EnvironmentObject var librarySync: LibrarySync

    @State private var pasteNote: String?
    @State private var confirmingDelete = false
    @State private var deleting = false
    /// What became of the deletion, kept OUTSIDE the signed-in branch on
    /// purpose: a successful one ends SIGNED OUT, so a note held inside that
    /// branch would be swept away by the very thing it is reporting on.
    @State private var deletionNote: String?
    var showsHeader = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsHeader { BandHeader("Account") }
            VStack(alignment: .leading, spacing: Theme.Metric.s12) {
                switch signIn.state {
                case .signedOut, .failed:
                    signedOut
                case .working:
                    Text("Signing in…").typeRole(.data).foregroundStyle(Theme.Ink.ink2)
                case .signedIn(let account):
                    signedIn(account)
                }
                if case .failed(let reason) = signIn.state {
                    Text(reason).typeRole(.data).foregroundStyle(Theme.Ink.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("account-error")
                }
                if let deletionNote {
                    Text(deletionNote).typeRole(.data).foregroundStyle(Theme.Ink.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("account-delete-note")
                }
            }
            .padding(.horizontal, Theme.Metric.s16)
            .padding(.vertical, Theme.Metric.s12)

            // Outside the field group, last, the way every other destructive
            // action in this app sits (DESIGN_SYSTEM §7.2).
            if case .signedIn(let account) = signIn.state { careful(account) }
        }
        .task(id: signIn.account?.uid) {
            // So the confirm can NAME the set lists it is about to hand on or
            // destroy. Without this the section knows about no set lists and
            // the question reads "this cannot be undone" and nothing else,
            // which is true and useless. Idempotent -- `watchMemberships`
            // returns immediately when it is already watching this uid.
            guard signIn.account != nil else { return }
            shared.watchMemberships()
        }
    }

    // MARK: - Careful

    /// Deleting the account, which Apple requires to be possible from in here
    /// (App Review guideline 5.1.1(v)) and which this app had no path to at
    /// all. It is the same two-step inline confirm as Delete piece and Delete
    /// arrangement: a `danger` row that becomes a `ConfirmDeleteStrip` in
    /// place. No alert, no sheet, nothing to dismiss.
    @ViewBuilder
    private func careful(_ account: SignIn.Account) -> some View {
        PanelLabel(text: "Careful")

        if deleting {
            Text("Deleting your account…")
                .typeRole(.data).foregroundStyle(Theme.Ink.ink2)
                .padding(.horizontal, Theme.Metric.s16)
                .accessibilityIdentifier("account-delete-working")
        } else if confirmingDelete {
            ConfirmDeleteStrip(what: AccountDeletionPlan.question(),
                               consequence: AccountDeletionPlan.consequence(for: outcome),
                               verb: "Delete my account",
                               identifier: "confirm-delete-account",
                               onDelete: {
                                   confirmingDelete = false
                                   Task { await deleteAccount(account) }
                               },
                               onKeep: { confirmingDelete = false })
        } else {
            ScreenRow(title: "Delete my account", leads: false, isDestructive: true,
                      identifier: "account-delete") {
                confirmingDelete = true
            }
        }

        // What will NOT be deleted, standing whether the question has been
        // asked or not -- the counterpart to `account-signout-keeps`, and the
        // sentence that stops "delete my account" reading as "delete my
        // library".
        Text(AccountDeletionPlan.keepsLocalLibrary)
            .typeRole(.data).foregroundStyle(Theme.Ink.ink3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Theme.Metric.s16)
            .padding(.top, Theme.Metric.s8)
            .padding(.bottom, Theme.Metric.s12)
            .accessibilityIdentifier("account-delete-keeps")
    }

    /// What is about to happen to each shared set list, read off the ones the
    /// app is already watching.
    ///
    /// The CLIENT'S opinion, in the sense `SetlistPermission` is: the
    /// `deleteAccount` Function decides, because membership is
    /// server-authoritative (design/FIREBASE.md §4.4). This is what the reader
    /// is TOLD, and `AccountDeletionPlan` exists so that what the two must
    /// agree on is written down once, where a test can read it.
    private var outcome: AccountDeletionPlan.Outcome {
        AccountDeletionPlan.outcome(for: shared.setlists.map {
            AccountDeletionPlan.Standing(name: $0.name,
                                         isOwner: $0.isOwner,
                                         memberCount: $0.members.count)
        })
    }

    private func deleteAccount(_ account: SignIn.Account) async {
        deleting = true
        deletionNote = nil
        do {
            let report = try await AccountDeletion.deleteAccount(provider: account.provider)
            // In this order, and for the reason Sign out is: the shared set
            // lists have to let go of their listeners before the account they
            // were opened for is gone.
            shared.signedOut()
            signIn.signOut()
            DrawingStore.shared.onSave = nil
            deletionNote = summary(report)
        } catch {
            // NOTHING was deleted on this path, and the reader is told which
            // it was rather than left to guess whether they are half-deleted.
            deletionNote = ((error as? LocalizedError)?.errorDescription
                            ?? error.localizedDescription)
        }
        deleting = false
    }

    /// What the server reported, in the reader's terms.
    private func summary(_ report: AccountDeletion.Report) -> String {
        var said = "Your account is deleted."
        if report.handedOn > 0 {
            said += " \(report.handedOn) set list"
                + (report.handedOn == 1 ? " passed" : "s passed")
                + " to the next person invited."
        }
        if report.destroyed > 0 {
            said += " \(report.destroyed) set list"
                + (report.destroyed == 1 ? " was" : "s were")
                + " deleted, because nobody else was in "
                + (report.destroyed == 1 ? "it." : "them.")
        }
        said += " Your library on this iPad is untouched."
        if !report.incomplete.isEmpty {
            // Reported, not swallowed. The account is gone either way, and
            // "done" about a job that was not finished is a lie.
            said += " Some of it could not be finished: "
                + report.incomplete.joined(separator: "; ") + "."
        }
        return said
    }

    // MARK: - signed out

    @ViewBuilder
    private var signedOut: some View {
        // Said first, and plainly. The reader is not being sold an account:
        // everything they already do keeps working without one.
        Text("Your library works without an account. Sign in only to share "
             + "setlists with other people.")
            .typeRole(.data).foregroundStyle(Theme.Ink.ink2)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("account-explains-optional")

        if signIn.isAvailable {
            // ONE component for both, so they cannot drift apart again.
            ProviderButton(provider: .google) {
                guard let presenter = Self.topViewController() else { return }
                Task { await signIn.signInWithGoogle(presenting: presenter) }
            }

            // Not gated on a self-inspection. Build 185 disabled this
            // button while its capability was fully provisioned, because the
            // check read an embedded.mobileprovision that an App Store-signed
            // app does not carry. The flow reports its own failures now.
            ProviderButton(provider: .apple) {
                Task { await signIn.signInWithApple() }
            }
        } else {
            Text("This build has no Firebase configuration, so signing in is "
                 + "unavailable. Everything else works.")
                .typeRole(.data).foregroundStyle(Theme.Ink.ink3)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("account-unavailable")
        }
    }

    // MARK: - signed in

    @ViewBuilder
    private func signedIn(_ account: SignIn.Account) -> some View {
        ScreenRow(title: account.displayName ?? "Signed in",
                  value: account.email ?? "private address",
                  leads: false,
                  identifier: "account-identity") {}
            .disabled(true)

        // One line, never a spinner (design/FIREBASE.md §5.3): whether what
        // this device shows is the account's library as it stands.
        HStack(alignment: .firstTextBaseline, spacing: Theme.Metric.s12) {
            Text(LibrarySyncModel.sentence(librarySync.status))
                .typeRole(.data).foregroundStyle(Theme.Ink.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("account-library-sync")
            if case .askCellular = librarySync.status {
                PanelButton(title: "Download now", identifier: "account-sync-cellular") {
                    librarySync.allowCellular()
                }
            } else {
                PanelButton(title: "Sync now", identifier: "account-sync-now") {
                    librarySync.nudge()
                }
            }
        }

        if let email = account.email, account.isPrivateRelay {
            // §12.10, and the copy that used to be here pointed at an "invite
            // code" this app has never had. The address itself is the answer:
            // Apple's relay is deliverable and stable for this app, and it is
            // what the token presents as a verified email -- so an invitation
            // sent to it works. It just cannot be GUESSED, so it has to be
            // handed over.
            Text("Apple gave you a private address. Invitations still work — "
                 + "send this to whoever is inviting you:")
                .typeRole(.data).foregroundStyle(Theme.Ink.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("account-relay-explains")

            Text(email)
                .typeRole(.data).foregroundStyle(Theme.Ink.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("account-relay-address")

            ShareLink(item: email) {
                Text("Send my address").typeRole(.control)
            }
            .accessibilityIdentifier("account-relay-share")
        } else if account.email == nil {
            Text("This account has no email address, so people cannot invite "
                 + "you by email yet.")
                .typeRole(.data).foregroundStyle(Theme.Ink.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("account-private-address")
        }

        pasteInvitation

        PanelButton(title: "Sign out", identifier: "sign-out") {
            // Both, and in this order: the shared set lists have to let go of
            // their listeners before the account they were opened for is gone,
            // or they keep publishing the previous person's music.
            shared.signedOut()
            signIn.signOut()
            // Any markup being pushed was going to a set list this iPad can no
            // longer read.
            DrawingStore.shared.onSave = nil
        }

        // The promise, in the place a person would worry about it.
        Text("Signing out keeps your library on this iPad. Nothing is deleted; "
             + "it stops syncing with your other devices until you sign in again.")
            .typeRole(.data).foregroundStyle(Theme.Ink.ink3)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("account-signout-keeps")
    }

    // MARK: - an invitation that did not arrive as a link

    /// The other iPad's way in.
    ///
    /// An invitation travels as `scoranger://invite?id=…` inside a message,
    /// and the app it is sent through decides whether that is tappable.
    /// Messages does not make a custom scheme tappable, so the reader is
    /// holding words they can only copy -- and until this button existed,
    /// copying them led nowhere. The QR code and the offline join that replace
    /// this properly are 0.7.2 (design/FIREBASE.md §11.10); this is the two
    /// lines that stop the flow dead-ending in the meantime.
    @ViewBuilder
    private var pasteInvitation: some View {
        PanelButton(title: "Paste an invitation",
                    identifier: "account-paste-invite") {
            let pasted = UIPasteboard.general.string ?? ""
            if let id = SharedInviteLink.inviteId(inPastedText: pasted) {
                state.pendingInvite = id
                pasteNote = "Invitation found. It's in your library now, "
                    + "under \"You've been invited\"."
            } else if pasted.isEmpty {
                pasteNote = "There's nothing on the clipboard to paste."
            } else {
                // Says which of the two things to copy, because "invalid" here
                // tells a person nothing they can act on.
                pasteNote = "That doesn't look like an invitation. Copy the "
                    + "whole message you were sent, or just the link in it."
            }
        }

        if let pasteNote {
            Text(pasteNote)
                .typeRole(.meta).foregroundStyle(Theme.Ink.ink3)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("account-paste-invite-note")
        }
    }

    /// Google's flow needs a view controller to present from, and SwiftUI has
    /// none to give. This is the one place that reaches for UIKit.
    static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}