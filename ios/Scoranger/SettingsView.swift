import SwiftUI

struct SettingsView: View {
    @AppStorage("touchDiagnostics") private var showTouchDiagnostics = false
    /// OFF by default and off in every build that has not been compared page
    /// by page against the bitmap path. See `VectorRendering`.
    @AppStorage(VectorRendering.defaultsKey) private var drawVectors = false
    @EnvironmentObject var state: AppState
    @State private var urlDraft = ""
    @State private var selfTestResult = ""
    @State private var selfTestRunning = false
    @State private var apiKeyDraft = ""
    @State private var omrURLDraft = ""
    @State private var omrKeyDraft = ""
    @State private var omrTestResult = ""
    @State private var omrTestRunning = false
    /// What is actually in the keychain, so the field can say "saved" without
    /// the draft being the thing the network layer reads.
    @State private var savedChatKey = ""
    @State private var savedOMRKey = ""
    @State private var repairRunning = false
    @State private var repairResult = ""

    /// Send a tiny non-PDF body: 415 back = URL and key both good
    /// (the request passed auth and reached content validation).
    ///
    /// `key` must be the key the app would actually send — the saved one, or
    /// the built-in default when nothing is saved. Testing the *field* instead
    /// is what reported "the key is wrong" on a perfectly working install: the
    /// field is empty whenever the built-in key is in use.
    static func testOMR(urlString: String, key: String) async -> String {
        guard let url = URL(string: urlString), !urlString.isEmpty else {
            return "✗ enter the service URL first"
        }
        guard !key.isEmpty else {
            return "✗ no key: this build has no built-in key, so paste one above"
        }
        var req = URLRequest(url: url.appending(path: "omr"))
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue(key, forHTTPHeaderField: "X-API-Key")
        do {
            let (_, resp) = try await URLSession(configuration: .ephemeral)
                .upload(for: req, from: Data("ping".utf8))
            switch (resp as? HTTPURLResponse)?.statusCode ?? 0 {
            case 415: return "✓ service reachable, key accepted"
            case 401: return "✗ service reachable but the key is wrong"
            case let code: return "✗ unexpected response (HTTP \(code))"
            }
        } catch {
            return "✗ can't reach the service: \(error.localizedDescription)"
        }
    }

    /// One section, or nil for the whole list in order (the score's own
    /// narrow panel shows the list; the Settings page shows the split).
    var section: SettingsSection? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let section {
                block(section)
            } else {
                ForEach(SettingsSection.allCases) { block($0) }
            }
        }
        .onAppear {
            urlDraft = state.engineURLString
            omrURLDraft = state.omrURLString
            // Key fields start empty and say what is in use underneath them.
            // Seeding them with the stored secret and writing back on every
            // keystroke is what let a stray edit clear a working key.
            savedChatKey = KeychainStore.openRouterKey
            savedOMRKey = KeychainStore.omrKey
            apiKeyDraft = ""
            omrKeyDraft = ""
        }
        .onDisappear { Task { await state.refresh() } }
    }

    /// A secret field: never pre-filled, saved on demand, and honest about
    /// which key the app is using right now.

    @ViewBuilder
    private func block(_ which: SettingsSection) -> some View {
        switch which {
        case .account:
            AccountSection(showsHeader: section == nil)
        case .reading:
            if section == nil { BandHeader("Reading") }
            VStack(alignment: .leading, spacing: Theme.Metric.s12) {
                // One property, every surface. A toggle cannot say
                // "continuous", and the top bar and this screen disagreeing
                // about how the score is laid out is exactly the confusion the
                // single `ScoreLayout` was introduced to end.
                ForEach(ScoreLayout.allCases, id: \.self) { option in
                    PanelToggle(title: option.label,
                                isOn: Binding(get: { state.layout == option },
                                              set: { on in
                                                  guard on else { return }
                                                  state.layout = option
                                                  state.pageIndex = 0
                                                  Task { await state.renderIfNeeded() }
                                              }))
                }
                PanelNote(text: "One page is largest. Two pages sit the way a score does "
                          + "on a stand. Continuous runs every system in one line, "
                          + "left to right, for arranging.")
            }
            .padding(Theme.Metric.panelPadding)

            // Only while there is something to repair. Derived from the
            // library, so it appears on every device that holds the damage and
            // disappears from all of them once it is fixed -- no flag, and no
            // large edit made on anyone's behalf at launch.
        case .titles:
            if let offer = TitleRepair.offer(count: state.titleRepairsNeeded.count) {
                if section == nil { BandHeader("Titles") }
                VStack(alignment: .leading, spacing: Theme.Metric.s12) {
                    PanelNote(text: offer)
                    HStack {
                        PanelButton(title: repairRunning ? "Fixing…" : TitleRepair.buttonTitle(count: state.titleRepairsNeeded.count),
                                    kind: .primary) {
                            repairRunning = true
                            repairResult = ""
                            Task {
                                let done = await state.repairTitles()
                                repairResult = TitleRepair.outcome(repaired: done.repaired,
                                                                   failed: done.failed)
                                repairRunning = false
                            }
                        }
                        .disabled(repairRunning)
                        .accessibilityIdentifier("repair-titles")
                        Spacer()
                    }
                }
                .padding(Theme.Metric.panelPadding)
            }
            if !repairResult.isEmpty {
                WellBlock(text: repairResult, tint: Theme.Status.ok)
                    .padding(Theme.Metric.panelPadding)
                    .accessibilityIdentifier("repair-titles-result")
            }

            // Optional, and placed where somebody would go looking for it
            // rather than where it would interrupt them.
        case .engine:
            if section == nil { BandHeader("Engine") }
            VStack(alignment: .leading, spacing: Theme.Metric.s12) {
                HStack(spacing: Theme.Metric.s12) {
                    PanelToggle(title: "Use on-device engine", isOn: $state.useLocalEngine)
                }
                // the caller owns the mode word: the dot says whether the
                // engine answers, not which engine it is
                HStack(spacing: Theme.Metric.s6) {
                    LED(isOn: state.engineOK)
                    Text(state.useLocalEngine ? "on-device" : "remote")
                        .typeRole(.data).foregroundStyle(Theme.Ink.ink2)
                    Text(state.engineOK ? "reachable" : "unreachable")
                        .typeRole(.meta).foregroundStyle(Theme.Ink.ink3)
                }
                .accessibilityIdentifier("settings-engine-state")
                keyField(label: "OpenRouter API key",
                         draft: $apiKeyDraft, saved: $savedChatKey,
                         identifier: "openrouter-key",
                         baked: !LocalChat.bakedKey.isEmpty) { value in
                    KeychainStore.openRouterKey = value
                }
                PanelNote(text: "On: scores live on this iPad; no laptop needed. Off: connect to scor serve on your Mac.")
                HStack {
                    PanelButton(title: selfTestRunning ? "Running…" : "Self-test") {
                        runSelfTest()
                    }
                    .disabled(selfTestRunning)
                    Spacer()
                }
                if !selfTestResult.isEmpty {
                    WellBlock(text: selfTestResult,
                              tint: selfTestResult.contains("failed") ? Theme.Status.danger
                                                                     : Theme.Status.ok)
                }
            }
            .padding(Theme.Metric.panelPadding)

        case .server:
            if !state.useLocalEngine {
                if section == nil { BandHeader("Server") }
                VStack(alignment: .leading, spacing: Theme.Metric.s12) {
                    LabeledField("Engine URL", text: $urlDraft, isMono: true,
                                 identifier: "engine-url")
                        .onChange(of: urlDraft) { _, value in
                            state.engineURLString = value.trimmingCharacters(in: .whitespaces)
                        }
                    PanelNote(text: "Run engine/.venv/bin/scor serve on your Mac, and use its hostname so the iPad can reach it over the local network.")
                }
                .padding(Theme.Metric.panelPadding)
            }

        case .scanning:
            if section == nil { BandHeader("Scanning") }
            VStack(alignment: .leading, spacing: Theme.Metric.s12) {
                LabeledField("OMR service URL", text: $omrURLDraft, isMono: true,
                             identifier: "omr-url")
                    .onChange(of: omrURLDraft) { _, value in
                        state.omrURLString = value.trimmingCharacters(in: .whitespaces)
                    }
                keyField(label: "OMR service API key",
                         draft: $omrKeyDraft, saved: $savedOMRKey,
                         identifier: "omr-key",
                         baked: !AppState.bakedOMRKey.isEmpty) { value in
                    KeychainStore.omrKey = value
                }
                HStack {
                    PanelButton(title: omrTestRunning ? "Testing…" : "Test") {
                        omrTestRunning = true
                        omrTestResult = ""
                        Task {
                            omrTestResult = await Self.testOMR(
                                urlString: omrURLDraft.trimmingCharacters(in: .whitespaces),
                                key: AppState.effectiveOMRKey)
                            omrTestRunning = false
                        }
                    }
                    .disabled(omrTestRunning)
                    Spacer()
                }
                if !omrTestResult.isEmpty {
                    WellBlock(text: omrTestResult,
                              tint: omrTestResult.hasPrefix("✓") ? Theme.Status.ok
                                                                 : Theme.Status.danger)
                }
                PanelNote(text: "Share a PDF into Scoranger and Audiveris converts it in the cloud. Leave empty to collect PDFs in Files → Scoranger → intake.")
            }
            .padding(Theme.Metric.panelPadding)

        case .model:
            if section == nil { BandHeader("Model") }
            VStack(alignment: .leading, spacing: Theme.Metric.s8) {
                if let catalog = state.modelCatalog {
                    ForEach(catalog.models.keys.sorted(), id: \.self) { alias in
                        Button {
                            state.chatModel = alias
                        } label: {
                            HStack(spacing: Theme.Metric.s8) {
                                Image(systemName: state.chatModel == alias
                                      ? "circle.fill" : "circle")
                                    .font(.system(size: 9))
                                    .foregroundStyle(state.chatModel == alias
                                                     ? Theme.Accent.clay : Theme.Ink.ink3)
                                Text(alias).typeRole(.row).foregroundStyle(Theme.Ink.ink)
                                Text(catalog.models[alias] ?? "").typeRole(.data)
                                    .foregroundStyle(Theme.Ink.ink3).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .frame(minHeight: 30)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    PanelNote(text: "The model list loads once the engine is reachable.")
                }
            }
            .padding(Theme.Metric.panelPadding)
        
        case .diagnostics:
            if section == nil { BandHeader("Diagnostics") }
            VStack(alignment: .leading, spacing: Theme.Metric.s12) {
                PanelToggle(title: "Show what the canvas is receiving",
                            isOn: $showTouchDiagnostics)
                PanelNote(text: "Prints every touch on the score — pencil or finger, how many "
                          + "are down, how long they were held, and whether a selection "
                          + "started. For reporting a gesture that is not working.")
                PanelToggle(title: "Draw the score as vectors",
                            isOn: $drawVectors)
                PanelNote(text: "Unfinished, and it changes nothing yet — the canvas "
                          + "still draws the page it always has. When it is wired, this "
                          + "draws from Verovio's own outlines instead of a picture of "
                          + "them, and some marks will be missing until it is finished.")
                PerfPanel()
            }
            .padding(Theme.Metric.panelPadding)

        case .about:
            if section == nil { BandHeader("About") }
            VStack(alignment: .leading, spacing: Theme.Metric.s8) {
                // The build stamp had no home once Home went, and a tester who
                // cannot say which build they are on cannot report anything
                // useful about it -- every device report in this project has
                // turned on knowing that.
                Text(BuildStamp.short)
                    .typeRole(.data)
                    .foregroundStyle(Theme.Ink.ink2)
                    .accessibilityIdentifier("build-stamp")
                PanelNote(text: "Quote this when reporting anything.")
            }
            .padding(Theme.Metric.panelPadding)

        }
    }

    @ViewBuilder
    private func keyField(label: String, draft: Binding<String>, saved: Binding<String>,
                          identifier: String, baked: Bool,
                          store: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledField(label: label, text: draft, isMono: true,
                         identifier: identifier) {
                let typed = draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !typed.isEmpty {
                    PanelButton(title: "Save", kind: .primary) {
                        store(typed)
                        saved.wrappedValue = typed
                        draft.wrappedValue = ""
                    }
                    .accessibilityIdentifier("save-\(identifier)")
                } else if !saved.wrappedValue.isEmpty {
                    PanelButton(title: "Clear") {
                        store("")
                        saved.wrappedValue = ""
                    }
                    .accessibilityIdentifier("clear-\(identifier)")
                }
            }
            PanelNote(text: keyStatus(saved: saved.wrappedValue, baked: baked))
        }
    }

    private func keyStatus(saved: String, baked: Bool) -> String {
        if !saved.isEmpty {
            return "Using your saved key (\(String(saved.suffix(4))) …last four). "
                + "Type a new one to replace it, or Clear to fall back to the built-in key."
        }
        return baked ? "Using the key built into this build. Type one above to override it."
                     : "No key: this build has none built in, so paste one above."
    }

    private func runSelfTest() {
        selfTestRunning = true
        selfTestResult = ""
        Task {
            let started = await PythonEngine.shared.start()
            var lines: [String] = []
            if case .ready(let py, let m21) = started {
                lines.append("Python \(py) · music21 \(m21)")
                let r = await PythonEngine.shared.call(op: "selftest")
                if let ok = r["ok"] as? Bool, ok,
                   let result = r["result"] as? [String: Any] {
                    let pitches = (result["transposed"] as? [String]) ?? []
                    lines.append("C D E F → \(pitches.joined(separator: " ")) (up M2)")
                    lines.append("versions \((result["versions"] as? [String])?.joined(separator: ", ") ?? "?") ✓")
                } else {
                    lines.append("selftest failed: \(r["error"] as? String ?? "\(r)")")
                }
            } else {
                lines.append("engine failed: \(started)")
            }
            selfTestResult = lines.joined(separator: "\n")
            selfTestRunning = false
        }
    }
}


/// Where the app's time actually goes.
///
/// Off by default and free when off (`PerfMetrics`). Switched on, it records
/// the durations that decide whether the app feels quick: an engine round trip,
/// a render pass, a thumbnail, a manifest refresh, and the two title-bar
/// dropdowns from tap to the frame that answers.
///
/// It does NOT observe the recorder. The readings are pulled when this view is
/// on screen, because publishing on every sample would invalidate views at the
/// rate the samples arrive -- which is the problem, not the instrument.
struct PerfPanel: View {
    @State private var isOn = PerfMetrics.shared.isOn
    @State private var ledger = PerfLedger()
    @State private var copied = false

    /// Slow enough to cost nothing, quick enough that a reader who just tapped
    /// something sees it appear.
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metric.s12) {
            PanelToggle(title: "Measure what the app spends time on", isOn: $isOn)
                .onChange(of: isOn) { _, on in
                    PerfMetrics.shared.setOn(on)
                    ledger = PerfMetrics.shared.snapshot()
                }
            PanelNote(text: "Times the engine, the engraver, the page thumbnails and the "
                      + "title-bar dropdowns. Switching it on clears what was there, so a "
                      + "reading is of what you do next. Off costs nothing.")

            if isOn {
                // Monospaced and scrolling sideways, like the touch readout
                // above it: the columns ARE the reading, and a proportional
                // face turns the table into a paragraph.
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(PerfReport.text(ledger, buildStamp: BuildStamp.short))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.Ink.ink2)
                        .fixedSize(horizontal: true, vertical: true)
                }
                .padding(Theme.Metric.s8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Surface.well)
                .accessibilityIdentifier("perf-readings")
                HStack(spacing: Theme.Metric.s12) {
                    PanelButton(title: copied ? "Copied" : "Copy") {
                        UIPasteboard.general.string =
                            PerfReport.text(ledger, buildStamp: BuildStamp.short)
                        copied = true
                    }
                    PanelButton(title: "Clear") {
                        PerfMetrics.shared.clear()
                        ledger = PerfMetrics.shared.snapshot()
                        copied = false
                    }
                    Spacer()
                }
            }
        }
        .onReceive(tick) { _ in
            guard isOn else { return }
            ledger = PerfMetrics.shared.snapshot()
        }
        .onAppear { ledger = PerfMetrics.shared.snapshot() }
    }
}
