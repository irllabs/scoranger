import SwiftUI

@main
struct ScorangerApp: App {
    @StateObject private var state = AppState()
    /// The account. Constructed at launch and INERT until
    /// somebody presses a sign-in button: constructing it does
    /// not configure Firebase (design/FIREBASE.md §0.2).
    @StateObject private var signIn = SignIn()
    /// The shared set lists. Also inert until somebody signs in: every method
    /// on it returns early while `FirebaseApp` has not been configured, so a
    /// signed-out launch touches no network and starts no listener (§0.2).
    @StateObject private var shared = SharedSetlists()
    /// The account's library on every device it signs in on (0.16.0). Also
    /// inert while signed out: `follow(account:)` is what starts it, and it
    /// returns at once for nil.
    @StateObject private var librarySync = LibrarySync()
    /// Every shared set list in the library, in step with its members
    /// (0.18.0). Inert while signed out, like the two above.
    @StateObject private var setlistSync = SharedSetlistSync()
    @Environment(\.scenePhase) private var scenePhase

    /// The one moment a test's reset can be total.
    ///
    /// `@AppStorage` reads its value as the property wrapper is constructed,
    /// and `AppState` is constructed with this struct, so anything later --
    /// the old reset ran from `RootView.task` -- clears keys whose values have
    /// already been handed out. Here, nothing has read a default yet.
    init() {
        TestReset.wipe()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .environmentObject(signIn)
                .environmentObject(shared)
                .environmentObject(librarySync)
                .environmentObject(setlistSync)
                // This device's own edits go up a moment after they are made;
                // `Manifest` equality ignores the rebuild stamp, so an idle
                // refresh is not an edit.
                .onChange(of: state.manifest) { _, _ in
                    librarySync.libraryChanged()
                    setlistSync.libraryChanged()
                }
                .onChange(of: signIn.account?.uid) { _, uid in
                    librarySync.follow(account: uid)
                    setlistSync.follow(account: uid)
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        librarySync.nudge()
                        setlistSync.syncAll()
                    }
                }
                // Books over cellular are asked about, the way Apple's own
                // apps ask before a large download (Ali, 2026-09-26).
                .alert("Download books over cellular?",
                       isPresented: Binding(get: { librarySync.cellularQuestion != nil },
                                            set: { if !$0 { librarySync.cellularQuestion = nil } })) {
                    Button("Download now") { librarySync.allowCellular() }
                    Button("Wait for Wi-Fi", role: .cancel) { librarySync.waitForWiFi() }
                } message: {
                    Text("\(LibrarySyncModel.megabytes(librarySync.cellularQuestion ?? 0)) of "
                         + "books are waiting to sync. Download them now over cellular, "
                         + "or wait until this device is on Wi-Fi.")
                }
                // Paper & Clay is a single fixed light palette: every surface is
                // a hard hex value with no dark variant. Left to follow the
                // system, dark mode kept the light surfaces but handed every
                // unstyled Text and TextField a white foreground -- which is
                // how the metadata fields in the arrangement sheet ended up
                // with invisible text. One palette, one appearance.
                .preferredColorScheme(.light)
                .onOpenURL { url in
                    // An invitation link comes in the same door as a
                    // `.scorbundle` from AirDrop and a sign-in callback, so it
                    // is recognised positively and everything else falls
                    // through to the file path unchanged.
                    // Both link forms land here: the https universal link
                    // people actually send, and the scoranger:// fallback.
                    // `inviteId(in:)` recognises either and refuses anything
                    // else, so an AirDropped .scorbundle still reaches the
                    // import path unchanged.
                    if let invite = SharedInviteLink.inviteId(in: url) {
                        state.pendingInvite = invite
                    } else {
                        // 0.14.0: asked what it is -- a new piece, an
                        // arrangement of an existing one, or a book -- before
                        // anything is imported (AppState.offerImport).
                        state.offerImport(url)
                    }
                }
                .task {
                    // Installs a CLOSURE and calls nothing. The closure's own
                    // body is what guards on a configured app, so this reaches
                    // no cloud at launch and returns nil for every reader who
                    // never signs in -- which is what lets it be installed
                    // here rather than at first sign-in, where a signed-in
                    // reader who never opens Settings would be missed.
                    OMRIdentity.install(into: state)
                    state.migrateStaleOMRURL()
                    // A device that ever took the old 401 "self-heal" holds the
                    // developer's retired OpenRouter key as if its reader had
                    // saved it; forget it, so chat asks for the reader's own.
                    LocalChat.forgetRetiredKey()
                    state.prepareDocumentsFolders()
                    // The mixer window opens where it was left, and in the
                    // state it was left in (MIXER_WINDOW.md §5, §1.3).
                    // warm up the interpreter so first render doesn't pay import cost
                    let started = await PythonEngine.shared.start()
                    print("SCORANGER-ENGINE start: \(started)")
                    #if DEBUG
                    let r = await PythonEngine.shared.call(op: "selftest")
                    print("SCORANGER-ENGINE selftest: \(r)")
                    // headless testing: adopt an OMR key dropped in Documents
                    // (inbox ingestion is a release feature now — see scanInbox)
                    let keyFile = FileManager.default
                        .urls(for: .documentDirectory, in: .userDomainMask)[0]
                        .appending(path: "omr-key.txt")
                    if let key = try? String(contentsOf: keyFile, encoding: .utf8) {
                        KeychainStore.omrKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
                        try? FileManager.default.removeItem(at: keyFile)
                        print("SCORANGER-ENGINE omr key adopted")
                    }
                    #endif
                    await state.seedLibraryIfEmpty()
                    #if DEBUG
                    await state.bindEmulatorShareIfRequested()
                    #endif
                    // the imported library carries no metadata of its own
                    await state.applyBundledMetadataIfNeeded()
                    await state.refresh()
                    // After the engine is up and the library read: a device
                    // that was signed in last time picks sync back up here.
                    librarySync.attach(state)
                    #if DEBUG
                    // The two-simulator sync test signs in to local emulators.
                    await signIn.signInToEmulatorIfRequested()
                    #endif
                    librarySync.follow(account: signIn.account?.uid)
                    setlistSync.attach(state, shared)
                    setlistSync.follow(account: signIn.account?.uid)
                    // needs a manifest in hand, so it follows the first refresh
                    await state.migrateSeededSetlistName()
                    #if DEBUG
                    // `-shareIn <path>`: a file arriving as a share would, through
                    // the same door onOpenURL uses -- the simulator has no share
                    // sheet to drive, and `simctl openurl` hands a PDF to Files.
                    let args = ProcessInfo.processInfo.arguments
                    if let at = args.firstIndex(of: "-shareIn"), at + 1 < args.count {
                        state.offerImport(URL(fileURLWithPath: args[at + 1]))
                    }
                    // `-shareInSampleBook`: twelve titled pages, shared in, for
                    // the UI test that walks Import as -> New book -> Keep.
                    if args.contains("-shareInSampleBook") {
                        let url = FileManager.default.temporaryDirectory
                            .appending(path: "Sample Tunebook.pdf")
                        if BigBookFixture.write(to: url, pages: 12) {
                            state.offerImport(url)
                        }
                    }
                    if args.contains("-shareInScannedBook") {
                        let url = FileManager.default.temporaryDirectory
                            .appending(path: "Scanned Tunebook.pdf")
                        if BigBookFixture.writeScanned(to: url, pages: 6) {
                            state.offerImport(url)
                        }
                    }
                    await state.seedMultiStepTurnIfRequested()
                    // after the library seed, and after the refresh that gives
                    // it a manifest to check itself against
                    await state.seedScanArrangementIfRequested()
                    // last: it names the arrangements the seeds above made
                    await state.seedOMRQueueIfRequested()
                    #endif
                }
        }
    }
}
