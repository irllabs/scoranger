import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// A site opened inside Scoranger to finish a search there (0.20.0,
/// design/SEARCH_0.20.md §3).
///
/// MuseScore has no API -- the one it had was shut down for abuse -- and its
/// terms forbid "automated systems ... for accessing or downloading Content".
/// What they allow is a member using the site, so that is what this is: the
/// site's own pages in a web view, the reader signed in there, pressing the
/// site's own Download button. The web view keeps the sign-in between visits
/// (WKWebsiteDataStore.default), and Scoranger never sees the password.
///
/// The one thing added is where the download LANDS. A browser would put it
/// in Files; here `WKDownload` writes it to a temporary file and it goes
/// through `receiveFile`, the path every imported score takes, with the page
/// it came from as origin. A file the engine cannot read -- MSCZ, MuseScore's
/// own format -- is refused by name with the fix: choose MusicXML.
struct SourceBrowserScreen: View {
    @EnvironmentObject var state: AppState
    let start: String
    var onBack: () -> Void
    @StateObject private var page = WebPageModel()

    var body: some View {
        Screen(title: "MuseScore", backLabel: "Search", subtitle: page.host,
               onBack: onBack, trailing: {
            HStack(spacing: Theme.Metric.s8) {
                PanelIconButton(systemName: "chevron.left", label: "Back a page",
                                action: { page.goBack() })
                    .disabled(!page.canGoBack)
                    .accessibilityIdentifier("browser-back")
                PanelIconButton(systemName: "arrow.clockwise", label: "Reload",
                                action: { page.reload() })
                    .accessibilityIdentifier("browser-reload")
            }
        }, content: {
            VStack(spacing: 0) {
                if page.loading {
                    ProgressView(value: page.progress).tint(Theme.Accent.clay)
                        .frame(height: 2)
                }
                WebPage(model: page)
                    .accessibilityIdentifier("browser-web")
                if let line = page.line {
                    Text(line).typeRole(.meta).foregroundStyle(Theme.Ink.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Theme.Metric.s16)
                        .padding(.vertical, Theme.Metric.s8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.Surface.band)
                        .accessibilityIdentifier("browser-line")
                }
            }
        }, scrolls: false)
        .onAppear {
            page.state = state
            page.start(Self.startURL(or: start))
        }
    }

    /// `-sourceBrowserURL <url>` points the screen at a page of the test's
    /// own, served on the simulator, so the download path is driven end to
    /// end without musescore.com, a sign-in or a daily download limit.
    static func startURL(or start: String) -> URL {
        let args = ProcessInfo.processInfo.arguments
        if let at = args.firstIndex(of: "-sourceBrowserURL"), at + 1 < args.count,
           let url = URL(string: args[at + 1]) {
            return url
        }
        return URL(string: start) ?? URL(string: "https://musescore.com/sheetmusic")!
    }
}

/// What a download is allowed to be, decided before a byte is kept.
enum DownloadPolicy {
    /// The suffixes the engine imports as notation or a scan.
    static let notation: Set<String> = ["musicxml", "mxl", "xml", "mid", "midi", "abc", "pdf"]
    /// MuseScore's own format, which the engine cannot read: refused with
    /// the fix rather than failing inside the importer.
    static let museScoreOwn: Set<String> = ["mscz", "mscx"]

    enum Verdict: Equatable {
        case take(fileName: String)
        case refuse(String)
        case show
    }

    /// From what the server said about the response. A page the web view can
    /// show is shown; an attachment is taken when the engine can read it.
    static func judge(mimeType: String?, canShow: Bool, suggestedFileName: String?,
                      url: URL?) -> Verdict {
        let name = suggestedFileName ?? url?.lastPathComponent ?? ""
        let ext = (name as NSString).pathExtension.lowercased()
        let attachment = !canShow
            || notation.contains(ext) || museScoreOwn.contains(ext)
        guard attachment else { return .show }
        if museScoreOwn.contains(ext) {
            return .refuse("That is MuseScore's own format, which Scoranger cannot read. "
                         + "Press Download again and choose MusicXML.")
        }
        if notation.contains(ext) { return .take(fileName: name) }
        // no useful name: trust the type
        switch mimeType?.lowercased() {
        case "application/vnd.recordare.musicxml+xml", "application/vnd.recordare.musicxml",
             "text/xml", "application/xml":
            return .take(fileName: name.isEmpty ? "score.musicxml" : name + ".musicxml")
        case "audio/midi", "audio/x-midi":
            return .take(fileName: name.isEmpty ? "score.mid" : name + ".mid")
        case "application/pdf":
            return .take(fileName: name.isEmpty ? "score.pdf" : name + ".pdf")
        default:
            return .refuse("That file is not a score Scoranger can read (\(name.isEmpty ? (mimeType ?? "unknown type") : name)). "
                         + "Choose MusicXML, MIDI or PDF.")
        }
    }
}

/// The web view's state, and the download it catches.
@MainActor
final class WebPageModel: NSObject, ObservableObject {
    @Published var loading = false
    @Published var progress: Double = 0
    @Published var canGoBack = false
    @Published var host: String?
    /// What the screen says under the page: a refusal, or what is happening.
    @Published var line: String?

    weak var state: AppState?
    lazy var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        // the default store: the reader's sign-in on the site survives
        // leaving the screen and relaunching the app
        config.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self
        view.allowsBackForwardNavigationGestures = true
        return view
    }()
    private var observers: [NSKeyValueObservation] = []
    private var downloads: [ObjectIdentifier: URL] = [:]
    private var origin: String?

    func start(_ url: URL) {
        guard observers.isEmpty else { return }
        observers = [
            webView.observe(\.isLoading) { [weak self] v, _ in
                Task { @MainActor in self?.loading = v.isLoading } },
            webView.observe(\.estimatedProgress) { [weak self] v, _ in
                Task { @MainActor in self?.progress = v.estimatedProgress } },
            webView.observe(\.canGoBack) { [weak self] v, _ in
                Task { @MainActor in self?.canGoBack = v.canGoBack } },
            webView.observe(\.url) { [weak self] v, _ in
                Task { @MainActor in self?.host = v.url?.host() } },
        ]
        webView.load(URLRequest(url: url))
    }

    func goBack() { webView.goBack() }
    func reload() { webView.reload() }
}

extension WebPageModel: WKNavigationDelegate, WKDownloadDelegate {
    nonisolated func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                             decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let http = response.response as? HTTPURLResponse
        let verdict = DownloadPolicy.judge(mimeType: response.response.mimeType,
                                           canShow: response.canShowMIMEType,
                                           suggestedFileName: response.response.suggestedFilename,
                                           url: response.response.url)
        // WebKit calls its navigation delegate on the main thread; answered
        // there and then, because the download that follows a `.download`
        // asks its delegate for a destination straight away -- a delegate
        // set a turn later is a download with none, dropped without a word
        // (the first run of SourceBrowserDownload).
        MainActor.assumeIsolated {
            switch verdict {
            case .show:
                decisionHandler(.allow)
            case .refuse(let why):
                self.line = why
                decisionHandler(.cancel)
            case .take:
                self.line = "Downloading…"
                self.origin = http?.url?.absoluteString
                decisionHandler(.download)
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse,
                             didBecome download: WKDownload) {
        MainActor.assumeIsolated { download.delegate = self }
    }

    nonisolated func webView(_ webView: WKWebView, navigationAction: WKNavigationAction,
                             didBecome download: WKDownload) {
        MainActor.assumeIsolated { download.delegate = self }
    }

    nonisolated func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                              suggestedFilename: String,
                              completionHandler: @escaping (URL?) -> Void) {
        let verdict = DownloadPolicy.judge(mimeType: response.mimeType, canShow: false,
                                           suggestedFileName: suggestedFilename, url: response.url)
        guard case .take(let name) = verdict else {
            MainActor.assumeIsolated {
                if case .refuse(let why) = verdict { self.line = why }
            }
            completionHandler(nil)
            return
        }
        let dir = FileManager.default.temporaryDirectory.appending(path: "downloads-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: name)
        MainActor.assumeIsolated { self.downloads[ObjectIdentifier(download)] = file }
        completionHandler(file)
    }

    nonisolated func downloadDidFinish(_ download: WKDownload) {
        Task { @MainActor in
            guard let file = self.downloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
            self.line = nil
            // the page the Download button was on, not the file's own URL,
            // which is a signed one-off address
            let page = self.webView.url?.absoluteString ?? self.origin
            // and then it opens, as every import does (RootView.openAfterImport)
            self.state?.receiveFile(at: file, origin: page)
        }
    }

    nonisolated func download(_ download: WKDownload, didFailWithError error: Error,
                              resumeData: Data?) {
        Task { @MainActor in
            self.downloads.removeValue(forKey: ObjectIdentifier(download))
            self.line = "The download failed: \(error.localizedDescription)"
        }
    }
}

struct WebPage: UIViewRepresentable {
    @ObservedObject var model: WebPageModel

    func makeUIView(context: Context) -> WKWebView { model.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
