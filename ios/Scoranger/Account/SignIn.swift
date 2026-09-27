import AuthenticationServices
import CryptoKit
import FirebaseAuth
import FirebaseCore
#if DEBUG
import FirebaseFirestore
import FirebaseStorage
#endif
import Foundation
import GoogleSignIn

/// The account, and the only place in the app that brings Firebase up.
///
/// design/FIREBASE.md §0.2 and §9.1. Principle 1: *"LOCAL-FIRST; cloud
/// OPTIONAL; no login should ever gate using the app."*
///
/// **`FirebaseApp.configure()` is called here, at first sign-in, and nowhere
/// else.** Not at launch, not in `ScorangerApp`, not lazily from the first
/// Firestore read. A signed-out install makes no Firebase contact of any kind:
/// no anonymous auth, no App Check handshake, no configuration call. That is
/// the difference between a promise and an intention, and
/// `check_signed_out.py` asserts that no other file calls it.
///
/// Anonymous auth is deliberately not used as the signed-out state (§9.1). It
/// would create a server-side identity for somebody who declined to have one,
/// put a round trip in first launch, and leave an orphan account behind for
/// everyone who tried the app once.
@MainActor
final class SignIn: ObservableObject {

    /// What the reader is, as far as the account goes.
    enum State: Equatable {
        /// The default, and a complete way to use this app forever.
        case signedOut
        case working
        case signedIn(Account)
        /// Sign-in was attempted and did not finish. The library is untouched.
        case failed(String)
    }

    struct Account: Equatable {
        let uid: String
        /// The address invitations must be sent to. Present for a relay
        /// address too -- see `isPrivateRelay`.
        let email: String?
        /// Apple's Hide My Email gave a relay address
        /// (`…@privaterelay.appleid.com`).
        ///
        /// **The address is still kept, and that is a correction.** It used to
        /// be discarded as "not an address anybody can invite", which confused
        /// GUESSABLE with USABLE: a bandmate cannot guess a relay address, but
        /// they can be told one, and it is precisely what the Firebase token
        /// carries as a verified email -- so `claimInvite` matches an
        /// invitation sent to it exactly as it would any other. Throwing it
        /// away was what actually made a Hide My Email account un-invitable,
        /// and the screen told those readers to ask for an "invite code" that
        /// does not exist (§12.10).
        ///
        /// So the flag is for EXPLAINING the address, not for hiding it: the
        /// reader is shown it and asked to send it to whoever is inviting them.
        let isPrivateRelay: Bool
        let displayName: String?
        /// Which button they pressed. Kept because the two providers behave
        /// differently at invitation time, not for display.
        let provider: Provider
    }

    enum Provider: String, Equatable {
        case google = "google.com"
        case apple = "apple.com"
    }

    @Published private(set) var state: State = .signedOut

    /// Whether this device has signed in before -- the one bit that decides
    /// whether launch brings Firebase up. See `SignInMemory`.
    private let memory = SignInMemory()

    init() {
        if Self.pretendedAccount != nil { state = .signedIn(Self.pretendedAccount!); return }
        restoreIfSignedInBefore()
    }

    /// A signed-in state with no Firebase behind it, for tests and for
    /// photographs.
    ///
    /// The Account section's destructive half -- "Delete my account" and its
    /// confirm -- only exists when somebody is signed in, and a simulator has
    /// no Apple ID and no Google account to sign in WITH. Without this the
    /// flow could be built and never looked at.
    ///
    /// It fakes the LOCAL STATE and nothing else. `FirebaseApp` is still not
    /// configured, so every path that would touch the network still refuses,
    /// and `AccountDeletion` reports `notConfigured` rather than pretending to
    /// delete something. That refusal is itself worth photographing: it is
    /// what a reader sees if the build has no configuration.
    ///
    /// Same shape as `-failAppleSignIn` and `-appleSignInPatience`: a launch
    /// argument, read once, false in every shipped run.
    nonisolated static var pretendedAccount: Account? {
        guard ProcessInfo.processInfo.arguments.contains("-pretendSignedIn") else {
            return nil
        }
        return Account(uid: "u-pretend", email: "you@example.com",
                       isPrivateRelay: false, displayName: "Test Account",
                       provider: .google)
    }

    /// Pick the persisted session back up, on a device that has one.
    ///
    /// Firebase Auth keeps the signed-in user in the keychain across launches;
    /// this app never read it, because it never configured Firebase at launch
    /// (§0.2), so every launch began signed out and asked Ali to sign in again.
    ///
    /// Gated on `memory`, which is what keeps principle 1 true: a device that
    /// has never signed in has the bit clear and this returns before touching
    /// anything. `startFirebaseIfNeeded()` comes before `Auth.auth()` in the
    /// same function, which `check_signed_out.py` requires of every path that
    /// asks Firebase a question -- `Auth.auth()` traps when nothing has
    /// configured it.
    ///
    /// A set bit with no user behind it -- the keychain was cleared, the token
    /// was revoked -- is corrected rather than trusted: the bit is dropped and
    /// the state is honestly signed out.
    private func restoreIfSignedInBefore() {
        guard memory.hasSignedInBefore else { return }
        do { try startFirebaseIfNeeded() } catch { return }
        guard let user = Auth.auth().currentUser else {
            memory.forget()
            return
        }
        // Which button they pressed last time, read back off the account.
        let provider = user.providerData
            .compactMap { Provider(rawValue: $0.providerID) }
            .first ?? .google
        state = .signedIn(account(from: user, provider: provider))
    }

    /// The account, if there is one. Nil is the ordinary case and not a fault.
    var account: Account? {
        if case .signedIn(let account) = state { return account }
        return nil
    }

    /// Whether this build can sign in at all.
    ///
    /// False when `GoogleService-Info.plist` was not baked in -- a checkout
    /// without one still builds and runs, because the signed-out app is the
    /// whole app minus sharing. The account screen says so rather than
    /// offering a button that cannot work.
    var isAvailable: Bool {
        Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist") != nil
    }

    /// Brought up once, on demand. `FirebaseApp.configure()` traps if called
    /// twice, and the second sign-in in a session would do exactly that.
    private func startFirebaseIfNeeded() throws {
        guard FirebaseApp.app() == nil else { return }
        guard isAvailable else { throw SignInError.notConfigured }
        FirebaseApp.configure()
    }

    enum SignInError: LocalizedError {
        case notConfigured
        case noIdentityToken
        case cancelled

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "This build has no Firebase configuration, so signing in "
                     + "is unavailable. Everything else works."
            case .noIdentityToken:
                return "That sign-in did not return an identity."
            case .cancelled:
                return "Sign-in cancelled."
            }
        }
    }

    // MARK: - Google

    func signInWithGoogle(presenting: UIViewController) async {
        state = .working
        do {
            try startFirebaseIfNeeded()
            try configureGoogleIfNeeded()
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenting)
            guard let idToken = result.user.idToken?.tokenString else {
                throw SignInError.noIdentityToken
            }
            let credential = GoogleAuthProvider.credential(
                withIDToken: idToken, accessToken: result.user.accessToken.tokenString)
            try await finish(with: credential, provider: .google)
        } catch {
            state = .failed(readable(error))
        }
    }

    /// Give GoogleSignIn its client id before asking it to do anything.
    ///
    /// **This is what crashed 0.7.0 build 183 on the first tap.**
    /// `GIDSignIn.sharedInstance.signIn(withPresenting:)` requires a
    /// configuration, and with none it raises an OBJECTIVE-C NSException --
    /// "No active configuration" -- which SIGABRTs the process.
    ///
    /// The part worth remembering: the `do/catch` around that call could never
    /// have helped. An NSException is not a Swift `Error`, so `catch` does not
    /// see it and there is no way to contain it after the fact. The only fix is
    /// to satisfy the precondition, which is why this is a separate function
    /// with a name that says so rather than a line inside the flow.
    ///
    /// Firebase has already parsed `GoogleService-Info.plist` by this point and
    /// exposes its `CLIENT_ID` as `options.clientID`, so the id comes from the
    /// one file that is the source of truth for which project this build talks
    /// to -- not from a second copy in `Info.plist` that could disagree with it.
    private func configureGoogleIfNeeded() throws {
        if GIDSignIn.sharedInstance.configuration != nil { return }
        guard let clientID = FirebaseApp.app()?.options.clientID else {
            throw SignInError.notConfigured
        }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
    }

    // MARK: - Apple

    /// Apple's flow needs a nonce, and it needs it hashed on the way out and
    /// raw on the way back: Apple signs the SHA256 of what we send, and
    /// Firebase verifies the signature against the raw value. Sending the same
    /// string to both is the mistake that makes this fail with an unhelpful
    /// credential error.
    private var appleNonce: String?

    /// The value to put on Apple's request: the HASH. The raw one is kept
    /// here for Firebase to verify against, and the two must not be swapped.
    func prepareAppleNonce() -> String {
        let nonce = Self.randomNonce()
        appleNonce = nonce
        return Self.sha256(nonce)
    }

    /// Whether this build can do Apple sign-in at all.
    ///
    /// Read from the running app's OWN ENTITLEMENTS, not from a constant.
    /// Ali's report was "Sign in with Apple does nothing", and the cause was
    /// that `com.apple.developer.applesignin` is absent -- the capability was
    /// never enabled on the App ID (verified: it carries only GAME_CENTER and
    /// IN_APP_PURCHASE), so the entitlement cannot be in the profile, so
    /// `ASAuthorizationController` fails immediately.
    ///
    /// Asking the binary rather than hardcoding `false` means this button
    /// starts working the moment the capability is enabled and a profile is
    /// regenerated, with no code change and nothing to remember. A constant
    /// would be a second fact to keep in step with the App ID, and it would be
    /// wrong in whichever direction nobody updated.
    /// Whether this build can do Apple sign-in.
    ///
    /// **Always true when Firebase is configured, and that is the fix.** It
    /// used to read the app's own `embedded.mobileprovision` and look for
    /// `com.apple.developer.applesignin`, and in 0.7.2 build 185 that check
    /// disabled a button whose capability was fully provisioned. Everything
    /// was right except the check:
    ///
    ///   - the App ID carries APPLE_ID_AUTH;
    ///   - the distribution profile grants
    ///     `com.apple.developer.applesignin = [Default]`;
    ///   - that profile is embedded in the archived .app;
    ///   - the codesigned entitlements carry it;
    ///   - and the parse itself returns TRUE when run against that exact
    ///     profile file, which was measured rather than assumed.
    ///
    /// The one thing left is that an App Store-signed app does not carry an
    /// `embedded.mobileprovision` on the device -- Apple re-signs during
    /// processing -- so `Bundle.main.url(forResource:)` finds nothing and the
    /// check answered "no capability" for a build that had it. It could only
    /// ever have worked in the configurations nobody ships from.
    ///
    /// So the self-inspection is GONE rather than corrected. There is no
    /// supported way for an app to read its own entitlements on iOS, an
    /// availability check that can be wrong about a working feature is worse
    /// than no check at all, and the honest test of whether Apple sign-in
    /// works is to run it: `ASAuthorizationController` reports its own
    /// failures, and `signInWithApple` now shows them instead of a guess.
    var appleIsAvailable: Bool { isAvailable }

    /// Apple's flow, driven by this app's own button.
    ///
    /// `SignInWithAppleButton` used to own this, and it brought two problems.
    /// Its geometry could not be made to match the Google button (Ali's second
    /// report), and its `onCompletion` failure branch was written to swallow
    /// cancellation -- which meant it swallowed EVERY error, including the one
    /// that was actually happening. A tap did nothing and said nothing.
    ///
    /// Here, cancellation is the only thing that stays quiet, and it is
    /// identified by its code rather than by being the default.
    func signInWithApple() async {
        guard isAvailable else {
            state = .failed(readable(SignInError.notConfigured))
            return
        }
        state = .working
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        // Apple signs the SHA256 of what we send and Firebase verifies the RAW
        // value, so the pair is prepared in one place and only the hash goes out.
        request.nonce = prepareAppleNonce()

        do {
            let authorization = try await AppleRequest.run(request)
            await completeApple(authorization)
        } catch let error as ASAuthorizationError where error.code == .canceled {
            // The one silence that is correct: they changed their mind.
            state = .signedOut
        } catch {
            state = .failed(readable(error))
        }
    }

    func completeApple(_ authorization: ASAuthorization) async {
        state = .working
        do {
            try startFirebaseIfNeeded()
            guard let credential = authorization.credential
                    as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8),
                  let nonce = appleNonce else {
                throw SignInError.noIdentityToken
            }
            let firebaseCredential = OAuthProvider.appleCredential(
                withIDToken: idToken, rawNonce: nonce,
                fullName: credential.fullName)
            try await finish(with: firebaseCredential, provider: .apple)
        } catch {
            state = .failed(readable(error))
        }
        appleNonce = nil
    }

    // MARK: - both

    /// One account for one person, whichever button they pressed.
    ///
    /// If somebody signs in with Google and later with Apple, Firebase would
    /// hand them two uids and therefore two libraries. Where it can tell the
    /// two are the same person -- a verified address that matches -- the second
    /// credential is LINKED to the first account instead. Where it cannot,
    /// because Hide My Email gave a relay address, they really are two
    /// accounts and nothing here can honestly merge them (§0.4).
    private func finish(with credential: AuthCredential, provider: Provider) async throws {
        do {
            let result = try await Auth.auth().signIn(with: credential)
            state = .signedIn(account(from: result.user, provider: provider))
            memory.remember()
        } catch let error as NSError
                    where error.code == AuthErrorCode.accountExistsWithDifferentCredential.rawValue {
            // The address is already an account under the other provider. Sign
            // in as that account and attach this credential to it, so the
            // library the person already has is the one they get back.
            guard let current = Auth.auth().currentUser else { throw error }
            let linked = try await current.link(with: credential)
            state = .signedIn(account(from: linked.user, provider: provider))
            memory.remember()
        }
    }

    private func account(from user: User, provider: Provider) -> Account {
        let relay = user.email?.hasSuffix("privaterelay.appleid.com") ?? false
        return Account(uid: user.uid,
                       // Kept whether it is a relay or not: it is the address
                       // an invitation has to be addressed to either way.
                       email: user.email,
                       isPrivateRelay: relay,
                       displayName: user.displayName,
                       provider: provider)
    }

    #if DEBUG
    /// `-emulatorAccount <email>`: sign in to the LOCAL Firebase emulators on
    /// 127.0.0.1, for the two-simulator library sync test (0.16.0). Debug
    /// builds only, and only when asked for by launch argument.
    ///
    /// Nothing about it reaches the real project: the emulators are pointed
    /// at before the first Auth, Firestore or Storage call, the password is a
    /// fixed test value that exists only in the emulator, and the session is
    /// NOT remembered, so the next ordinary launch does not try to restore an
    /// emulator user against production.
    func signInToEmulatorIfRequested() async {
        let args = ProcessInfo.processInfo.arguments
        guard let at = args.firstIndex(of: "-emulatorAccount"), at + 1 < args.count else { return }
        let email = args[at + 1]
        let password = "emulator-only-test-password"
        state = .working
        do {
            try startFirebaseIfNeeded()
            Auth.auth().useEmulator(withHost: "127.0.0.1", port: 9099)
            let settings = Firestore.firestore().settings
            settings.host = "127.0.0.1:8181"
            settings.isSSLEnabled = false
            settings.cacheSettings = MemoryCacheSettings()
            Firestore.firestore().settings = settings
            Storage.storage().useEmulator(withHost: "127.0.0.1", port: 9199)
            _ = try? await Auth.auth().createUser(withEmail: email, password: password)
            let result = try await Auth.auth().signIn(withEmail: email, password: password)
            state = .signedIn(account(from: result.user, provider: .google))
            print("SCORANGER-EMULATOR signed in \(result.user.uid)")
        } catch {
            state = .failed(readable(error))
            print("SCORANGER-EMULATOR sign-in failed: \(error)")
        }
    }
    #endif

    /// Signing out keeps everything. The library is local and stays local
    /// (§9.2), and the confirmation says so in those words.
    func signOut() {
        if FirebaseApp.app() != nil { try? Auth.auth().signOut() }
        GIDSignIn.sharedInstance.signOut()
        // So the next launch does not bring them straight back.
        memory.forget()
        state = .signedOut
    }

    private func readable(_ error: Error) -> String {
        if let signInError = error as? SignInError {
            return signInError.errorDescription ?? "Sign-in failed."
        }
        let nsError = error as NSError
        // The reader pressed cancel. Not a failure to report as one.
        if nsError.domain == ASAuthorizationError.errorDomain
            && nsError.code == ASAuthorizationError.canceled.rawValue {
            return SignInError.cancelled.errorDescription ?? ""
        }
        if nsError.domain == kGIDSignInErrorDomain
            && nsError.code == GIDSignInError.canceled.rawValue {
            return SignInError.cancelled.errorDescription ?? ""
        }
        return nsError.localizedDescription
    }

    // MARK: - the nonce

    static func randomNonce(length: Int = 32) -> String {
        // Apple requires a nonce; a predictable one would let a captured token
        // be replayed against this app.
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }

    static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
