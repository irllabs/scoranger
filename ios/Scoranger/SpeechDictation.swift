import AVFoundation
import Speech
import SwiftUI

/// Live speech-to-text for the chat input: press the mic to start, speak,
/// press again to stop. Streams the microphone through SFSpeechRecognizer and
/// publishes the running transcript so the view can mirror it into the draft.
///
/// ON DEVICE OR NOT AT ALL. `SFSpeechAudioBufferRecognitionRequest` defaults
/// `requiresOnDeviceRecognition` to false, which sends the microphone to
/// Apple's servers even on hardware that could transcribe locally. This app
/// sets it true and REFUSES to dictate where on-device recognition is
/// unavailable, rather than falling back to the network.
///
/// Refusing rather than falling back, deliberately:
///   - a fallback is invisible. The user cannot tell which of the two runs,
///     so any honest UI would have to warn on every session about a case that
///     almost never happens, or say nothing and be untrue some of the time;
///   - dictation is a convenience on a text field. The keyboard is always
///     there, so refusing costs a user one alternative way to type, not a
///     feature;
///   - it makes one sentence true without qualification: no voice recorded by
///     this app leaves the device. That is what lets the App Privacy
///     questionnaire answer Audio Data "No" instead of "Yes, App
///     Functionality" (design/APP_STORE_PRIVACY.md 3.2), and it keeps the app
///     out of COPPA 312.2(8) and 312.2(10) -- a child's voice file and a
///     voiceprint -- which a known under-13 user makes a live question
///     (design/CHILDRENS_PRIVACY_BRIEF.md 7.1).
///
/// `supportsOnDeviceRecognition` is per recogniser and per locale, and is
/// false while the locale's model is still downloading, so the refusal can be
/// temporary. The message says so.
@MainActor
final class SpeechDictation: ObservableObject {
    @Published var isRecording = false
    /// Everything said this dictation session, refined live. Kept across the
    /// recogniser's pauses by `words`; it used to be the latest utterance only.
    @Published var transcript = ""
    private var words = DictationTranscript()
    /// Permission or engine failure, phrased for the input placeholder.
    @Published var errorText: String?

    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func toggle() {
        if isRecording { stop() } else { start() }
    }

    func start() {
        guard !isRecording else { return }
        errorText = nil
        transcript = ""
        words = DictationTranscript()
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                guard status == .authorized else {
                    self.errorText = "Dictation is off — allow Speech Recognition in Settings"
                    return
                }
                let granted = await AVAudioApplication.requestRecordPermission()
                guard granted else {
                    self.errorText = "Dictation is off — allow the microphone in Settings"
                    return
                }
                self.beginSession()
            }
        }
    }

    func stop() {
        request?.endAudio()
        finishSession()
    }

    private func beginSession() {
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            errorText = "Speech recognition isn't available right now"
            return
        }
        // Checked BEFORE the audio session opens, so a device that cannot do
        // this never gets as far as recording. Asking for on-device
        // recognition where it is unsupported fails inside the recognition
        // task instead -- after the microphone is live, which is the one
        // ordering that would record audio it then had nowhere to send.
        guard recognizer.supportsOnDeviceRecognition else {
            // SHORT ON PURPOSE. errorText is the chat field's PLACEHOLDER, and
            // that field is about thirty characters wide at the panel's width
            // -- a sentence there is truncated to a fragment with an ellipsis,
            // which was what the first draft of this string did. Photographed
            // and shortened.
            errorText = "On-device speech isn't ready"
            return
        }
        self.recognizer = recognizer
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            // The line this whole type is arranged around. Without it the
            // default is false and every syllable goes to Apple's servers.
            request.requiresOnDeviceRecognition = true
            self.request = request

            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            // capture the request directly: the tap fires on an audio thread
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let result {
                        self.words.receive(result.bestTranscription.formattedString,
                                           utteranceEnded: result.speechRecognitionMetadata != nil)
                        self.transcript = self.words.text
                    }
                    // A failure that produced no words looked like a dead
                    // mic: the button un-lit and the field said nothing. It
                    // is also the shape the on-device refusal takes if the
                    // guard above is ever removed, so it must be visible.
                    if error != nil, self.transcript.isEmpty {
                        self.errorText = "Dictation heard nothing"
                    }
                    if error != nil || result?.isFinal == true {
                        if self.isRecording { self.finishSession() }
                    }
                }
            }
        } catch {
            errorText = "Couldn't start dictation: \(error.localizedDescription)"
            finishSession()
        }
    }

    private func finishSession() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        task?.cancel()
        task = nil
        request = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
