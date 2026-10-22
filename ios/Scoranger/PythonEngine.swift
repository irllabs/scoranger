import Foundation

/// The on-device engine: embedded CPython + music21 behind a JSON bridge.
/// All calls are serialized through this actor; the first call initializes the
/// interpreter and configures the workspace in the app's Documents directory.
actor PythonEngine {
    static let shared = PythonEngine()

    enum EngineState: Equatable {
        case idle
        case ready(python: String, music21: String)
        case failed(String)
    }

    private(set) var state: EngineState = .idle

    static var workspaceURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "workspace")
    }

    /// Initialize interpreter + engine; safe to call repeatedly.
    func start() -> EngineState {
        guard case .idle = state else { return state }
        let resources = Bundle.main.resourcePath!
        let rc = LaunchTiming.shared.measure("engine: interpreter") {
            scoranger_python_init(resources)
        }
        guard rc == 0 else {
            state = .failed("interpreter init failed (code \(rc))")
            return state
        }
        // Test fixture only: UI tests need each launch to start from the same
        // library, or edits made by one test leak into the next one's
        // assertions. Never reachable in a shipped run -- it is an argument the
        // test runner passes, not a setting.
        if ProcessInfo.processInfo.arguments.contains("-resetLibrary") {
            try? FileManager.default.removeItem(at: Self.workspaceURL)
        }
        try? FileManager.default.createDirectory(at: Self.workspaceURL,
                                                 withIntermediateDirectories: true)
        let response = LaunchTiming.shared.measure("engine: configure") {
            rawCall(op: "configure", args: ["workspace": Self.workspaceURL.path])
        }
        if let ok = response["ok"] as? Bool, ok,
           let py = response["python"] as? String,
           let m21 = response["music21"] as? String {
            state = .ready(python: py, music21: m21)
        } else {
            state = .failed(response["error"] as? String ?? "configure failed")
        }
        return state
    }

    /// Dispatch one op. Returns the parsed JSON envelope from bridge.py.
    func call(op: String, args: [String: Any] = [:]) -> [String: Any] {
        if case .idle = state { _ = start() }
        guard case .ready = state else {
            return ["ok": false, "error": "engine not ready: \(state)"]
        }
        // The time Python spends on the op, apart from any wait for the
        // actor, which `LocalEngine` counts in its own span.
        return LaunchTiming.shared.measure("py.\(op)") { rawCall(op: op, args: args) }
    }

    private func rawCall(op: String, args: [String: Any]) -> [String: Any] {
        let request: [String: Any] = ["op": op, "args": args]
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let json = String(data: data, encoding: .utf8),
              let cResult = scoranger_python_call(json) else {
            return ["ok": false, "error": "bridge call failed"]
        }
        defer { free(cResult) }
        let text = String(cString: cResult)
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            return ["ok": false, "error": "unparseable bridge response: \(text.prefix(200))"]
        }
        return parsed
    }
}
