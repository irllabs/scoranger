import Foundation

/// On-device arrangement agent: an OpenAI-style tool loop over OpenRouter,
/// dispatching tool calls into the embedded Python engine. Mirrors
/// engine/scoranger_engine/chat.py (same instructions, same tools).
struct LocalChat {

    /// Friendly alias -> OpenRouter model slug (mirror of chat.py MODELS,
    /// OpenRouter routes only — the iPad always goes through the gateway).
    static let models: [String: String] = [
        "gemini-flash": "google/gemini-3.7-flash",
        "kimi": "moonshotai/kimi-k3",
        "qwen": "qwen/qwen3.8-max",
        "claude": "anthropic/claude-sonnet-5",
        "claude-opus": "anthropic/claude-opus-5",
        "deepseek": "deepseek/deepseek-v4-flash",
    ]
    static let defaultModel = "gemini-flash"

    /// Chat uses the READER's own OpenRouter key, and the app ships none
    /// (0.15.0; Ali, 2026-09-23). Through 0.14.0 a developer key was baked in
    /// and used whenever the reader had not saved one -- readable by anyone who
    /// unzipped the .ipa. `ChatKey.choose` is the whole rule, in ScoreModel so
    /// it can be tested.
    ///
    /// Forget the developer key a device may still hold: the old 401
    /// "self-heal" wrote it into the reader's Keychain. Called once at launch.
    static func forgetRetiredKey() {
        if RetiredKeys.isRetiredOpenRouterKey(KeychainStore.openRouterKey) {
            KeychainStore.openRouterKey = ""
        }
    }

    static let instructions = """
    You are Scoranger's arrangement agent. You manipulate a musical score ONLY \
    through the provided tools — deterministic operations that each create a new \
    immutable version. Never describe notation edits you cannot perform with a tool.

    Working rules:
    1. Orient first: call get_score_info before planning changes.
    2. State your plan briefly, then execute it with tool calls.
    3. Verify after: read each tool result; after change_instrument, relay the \
    octave-shift and out-of-range report to the user.
    4. If a tool returns an error, read it — bad part names include the real part \
    list. Correct and retry.
    5. Musical judgment is yours: sensible clefs, octaves, keys. Flag questionable \
    requests instead of silently producing garbage.
    6. A PIECE is the composition; an ARRANGEMENT is one scoring of it; a VERSION \
    is one immutable step in an arrangement's history. You always operate on ONE \
    arrangement. When the user writes '#N' they mean arrangement number N of the \
    same piece, listed with its 'arr:<slug>' ref in the context: "take the violin \
    part from #3" means pull_part from that ref. '#N' never means a version or a \
    measure. If no numbered list is in context, say the arrangement isn't filed \
    under a piece yet rather than guessing.
    7. A HARMONY LINE stays in the key. "A third above", "a sixth below", \
    "harmonise it" are diatonic: use transpose_diatonic, which moves by scale \
    degrees and leaves the key signature alone. Plain `transpose` is chromatic \
    and changes key -- right for "put this in D", wrong for a harmony. Never \
    answer that scale-degree transposition within a key is unsupported; it is \
    transpose_diatonic.
    8. "I can't play this fast", "reduce the 16ths to eighths", "simplify the \
    rhythm" is simplify_rhythm, and it has TWO answers that are different \
    pieces of music: augment (every value doubles, the meter's denominator \
    halves, nothing is lost, the passage lasts twice as long) and thin (notes \
    between the beats are dropped, the passage keeps its place and length). \
    Never say rhythmic augmentation or quantization is unsupported, and never \
    choose between the two silently -- say which you used and what it cost, \
    and relay notes_removed when you thinned. A solo can have augment for \
    free; a part playing with others can only be thinned. The third answer \
    needs no tool: play it slower, which is what augmenting writes down.
    10. The app can take ABC now -- the text notation thesession.org publishes
    Irish traditional music in. If a reader asks whether they can bring a tune
    in from there, the answer is yes: `.abc` imports like MusicXML or MIDI,
    modal keys included (Edor, Amix). You do not import files yourself -- the
    reader does, from Import -- so say it can be done rather than offering to
    do it. Two things to say if it comes up: a file holding several tunes
    imports as several ARRANGEMENTS, and ABC's `~` rolls and `!...!`
    decorations are not carried into the notation. Scoranger cannot WRITE ABC;
    export is MusicXML, MIDI or PDF.
    Answer concisely; the user sees the score update live.
    """

    enum ChatError: Error, LocalizedError {
        case missingKey
        /// OpenRouter answered 401 to the reader's own key. Said, not healed:
        /// the old recovery swapped in the developer's key without a word.
        case rejectedKey
        /// The provider refused, in its own words -- read out of whatever
        /// envelope it arrived in, and never handed over as JSON. This replaced
        /// `http(Int, String)` and `badResponse(String)`, both of which printed
        /// the response body at the reader: what Ali saw was
        /// `Unexpected OpenRouter response: {"error":{"message":"Corrupted
        /// thought signature.","code":400}}`.
        case provider(ChatWire.Fault)
        case network(URLError)
        var errorDescription: String? {
            switch self {
            case .missingKey: return ChatKey.missingSentence
            case .rejectedKey: return ChatKey.rejectedSentence
            case .provider(let fault): return fault.readable
            case .network(let error):
                return "Couldn't reach OpenRouter: \(error.localizedDescription) "
                    + "(tried 4 times on fresh connections). Check Wi-Fi, and any "
                    + "VPN or proxy that might be closing the connection."
            }
        }
    }

    let engine = LocalEngine()

    /// The tool table lives in `ChatTools`, in ScoreModel, so the dispatch
    /// below can be tested without this file's engine, Keychain and network.
    static var toolsJSON: [[String: Any]] { ChatTools.json }

    // MARK: the loop

    struct Turn {
        var reply: String
        var historyJSON: String
    }

    /// Live progress events for the UI checklist.
    enum Event {
        case toolStarted(title: String)
        case toolFinished(detail: String?)   // e.g. "→ v005"
    }

    /// One chat turn against the on-device engine. `historyJSON` is the JSON
    /// message array from the previous Turn (OpenAI wire format).
    /// `context` is extra situational info (e.g. the score's piece and sibling
    /// arrangements) appended to the system message. `onEvent` streams
    /// checklist progress to the UI as tools run.
    func run(slug: String, message: String, modelAlias: String?,
             historyJSON: String?, context: String? = nil,
             onEvent: (@MainActor (Event) -> Void)? = nil) async throws -> Turn {
        let model = Self.models[modelAlias ?? Self.defaultModel]
            ?? modelAlias ?? Self.models[Self.defaultModel]!

        // Stamp every version this turn creates with a shared turn id so the
        // UI can group them under the prompt. Best-effort; closed on all exits.
        _ = try? await engine.call(op: "begin-turn", args: ["score": slug, "prompt": message])
        do {
            let turn = try await runLoop(slug: slug, message: message, model: model,
                                         historyJSON: historyJSON, context: context,
                                         onEvent: onEvent)
            _ = try? await engine.call(op: "end-turn", args: [:])
            return turn
        } catch {
            _ = try? await engine.call(op: "end-turn", args: [:])
            throw error
        }
    }

    /// The tool loop itself (wrapped by run() in begin-turn/end-turn stamping).
    private func runLoop(slug: String, message: String, model: String,
                         historyJSON: String?, context: String? = nil,
                         onEvent: (@MainActor (Event) -> Void)? = nil) async throws -> Turn {
        let system = Self.instructions + (context.map { "\n\n" + $0 } ?? "")
        var messages: [[String: Any]]
        if let historyJSON, let data = historyJSON.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            // A reasoning signature is worth keeping only inside the turn that
            // minted it, where the model is continuing its own chain of
            // thought. Carried into the NEXT turn it can only fail -- and when
            // it does the provider answers "Corrupted thought signature." and
            // the whole turn dies with the arrangement half-applied.
            messages = ChatWire.withoutReasoning(parsed)
            // keep the system context current (siblings may have changed)
            if messages.first?["role"] as? String == "system" {
                messages[0]["content"] = system
            }
        } else {
            messages = [["role": "system", "content": system]]
        }
        messages.append(["role": "user", "content": message])

        var finalReply = ""
        var rounds = 0
        for _ in 0..<20 {
            rounds += 1
            let assistant = try await complete(model: model, messages: messages)
            messages.append(assistant)
            let calls = ChatTools.toolCalls(in: assistant)
            guard !calls.isEmpty else {
                finalReply = (assistant["content"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
            print("SCORANGER-CHAT-LOOP round \(rounds): \(calls.count) tool call(s)")
            for (id, name, argsRaw) in calls {
                if let onEvent {
                    let title = ChatSteps.stepTitle(name: name, argsJSON: argsRaw)
                    await MainActor.run { onEvent(.toolStarted(title: title)) }
                }
                let resultText = await dispatch(slug: slug, name: name, argsJSON: argsRaw)
                if let onEvent {
                    // surface the created version (or an error) on the step
                    let parsed = (try? JSONSerialization.jsonObject(
                        with: Data(resultText.utf8)) as? [String: Any]) ?? [:]
                    let detail: String?
                    if let result = parsed["result"] as? [String: Any],
                       let v = (result["new_version_label"] as? String)
                            ?? (result["new_version"] as? String) {
                        detail = "→ \(v)"
                    } else if parsed["ok"] as? Bool == false {
                        // The reader's half of the refusal: the engine's own
                        // words without the Python class name in front of
                        // them (ChatSteps.readableError). The FULL text still
                        // goes back to the model below, untouched.
                        detail = "⚠︎ " + ChatSteps.readableError(
                            parsed["error"] as? String ?? "")
                    } else {
                        detail = nil
                    }
                    await MainActor.run { onEvent(.toolFinished(detail: detail)) }
                }
                messages.append(["role": "tool", "tool_call_id": id, "content": resultText])
            }
        }

        // A turn must never end silent: if the model finished on a tool round
        // (empty content) or hit the round cap, force a text-only summary.
        if finalReply.isEmpty {
            print("SCORANGER-CHAT-LOOP empty reply after \(rounds) rounds; forcing summary")
            messages.append(["role": "user", "content":
                "Summarize for the user what you just did to the score (or explain what you need from them). Text only."])
            let summary = try await complete(model: model, messages: messages, allowTools: false)
            messages.append(summary)
            finalReply = (summary["content"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let historyData = try JSONSerialization.data(withJSONObject: messages)
        return Turn(reply: finalReply.isEmpty
                        ? "Something went wrong: the model returned no text (after \(rounds) rounds). Check the score's version list — operations may still have been applied."
                        : finalReply,
                    historyJSON: String(data: historyData, encoding: .utf8) ?? "")
    }

    private func dispatch(slug: String, name: String, argsJSON: String) async -> String {
        guard let call = ChatTools.call(named: name, argsJSON: argsJSON, slug: slug) else {
            return #"{"ok": false, "error": "unknown tool \#(name)"}"#
        }
        do {
            let result = try await engine.call(op: call.op, args: call.args)
            let data = try JSONSerialization.data(withJSONObject: ["ok": true, "result": result])
            return String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            // errors go back to the model as data so it can self-correct
            let data = (try? JSONSerialization.data(
                withJSONObject: ["ok": false, "error": "\(error.localizedDescription)"])) ?? Data("{}".utf8)
            return String(data: data, encoding: .utf8) ?? "{}"
        }
    }

    /// Worth another go on a fresh connection: a dropped or timed-out
    /// connection, not "there is no network" or a cancelled request.
    static func isTransient(_ error: URLError) -> Bool {
        [.networkConnectionLost, .timedOut, .cannotConnectToHost,
         .cannotFindHost, .dnsLookupFailed].contains(error.code)
    }

    /// One request, with the key handling and the transient-network retry.
    /// Returns whatever came back; judging it is `complete`'s business.
    private func send(model: String, messages: [[String: Any]],
                      allowTools: Bool) async throws -> (Data, Int) {
        // the reader's own key, or nothing: there is no other key to fall back to
        guard case .use(let key) = ChatKey.choose(saved: KeychainStore.openRouterKey) else {
            throw ChatError.missingKey
        }

        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://github.com/irllabs/scoranger", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Scoranger", forHTTPHeaderField: "X-Title")
        var payload: [String: Any] = ["model": model, "messages": messages]
        if allowTools {
            payload["tools"] = Self.toolsJSON
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        var data: Data
        var code: Int
        var networkAttempt = 0
        while true {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            do {
                // A fresh ephemeral session per attempt, like the OMR upload
                // path: URLSession.shared pools HTTP/2 connections, and a
                // pooled one that the far end has dropped fails every retry
                // with "The network connection was lost" until it is discarded.
                let session = URLSession(configuration: .ephemeral)
                defer { session.finishTasksAndInvalidate() }
                let (d, response) = try await session.data(for: request)
                data = d
                code = (response as? HTTPURLResponse)?.statusCode ?? 0
            } catch let error as URLError where Self.isTransient(error) && networkAttempt < 3 {
                networkAttempt += 1
                try await Task.sleep(for: .seconds(networkAttempt))
                continue
            } catch let error as URLError {
                throw ChatError.network(error)
            }
            // a refused key is the reader's to replace, and the reply says so
            if code == 401 { throw ChatError.rejectedKey }
            break
        }
        return (data, code)
    }

    /// One assistant message, with the provider's refusals handled.
    ///
    /// The two recoveries are in ChatWire's own notes. Briefly: a rejected
    /// reasoning signature is retried ONCE with every signature stripped, which
    /// is the recovery `runLoop` already applies to history a turn later; and a
    /// busy provider is waited out twice. Everything else is the reader's to
    /// know about, in a sentence.
    private func complete(model: String, messages initialMessages: [[String: Any]],
                          allowTools: Bool = true) async throws -> [String: Any] {
        var messages = initialMessages
        var strippedReasoning = false
        var busyAttempt = 0
        while true {
            let (data, code) = try await send(model: model, messages: messages,
                                              allowTools: allowTools)
            if let fault = ChatWire.fault(in: data, status: code) {
                // the body belongs in the log, which is where it always
                // belonged, and nowhere near the transcript
                print("SCORANGER-CHAT-FAULT \(fault.kind) HTTP \(code): "
                      + (String(data: data, encoding: .utf8)?.prefix(400) ?? "<unreadable>"))
                switch fault.kind {
                case .staleReasoning where !strippedReasoning
                        && ChatWire.carriesReasoning(messages):
                    strippedReasoning = true
                    messages = ChatWire.withoutReasoning(messages)
                    print("SCORANGER-CHAT-FAULT retrying without reasoning state")
                    continue
                case .busy where busyAttempt < 2:
                    busyAttempt += 1
                    try await Task.sleep(for: .seconds(busyAttempt * 2))
                    continue
                default:
                    throw ChatError.provider(fault)
                }
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  var assistant = choices.first?["message"] as? [String: Any] else {
                print("SCORANGER-CHAT-UNPARSEABLE HTTP \(code): "
                      + (String(data: data, encoding: .utf8)?.prefix(400) ?? "<unreadable>"))
                throw ChatError.provider(
                    ChatWire.Fault(kind: .other, providerMessage: "", status: code))
            }
            // normalize: some providers send content: null with tool_calls
            if assistant["content"] is NSNull { assistant["content"] = "" }
            return assistant
        }
    }
}

/// Minimal Keychain wrapper for API keys.
enum KeychainStore {
    private static let service = "com.irllabs.scoranger"

    static var openRouterKey: String {
        get { read("openrouter-api-key") }
        set { write("openrouter-api-key", newValue) }
    }

    static var omrKey: String {
        get { read("omr-api-key") }
        set { write("omr-api-key", newValue) }
    }

    private static func read(_ account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func write(_ account: String, _ rawValue: String) {
        // API keys never legitimately contain whitespace; pasted keys often do
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
