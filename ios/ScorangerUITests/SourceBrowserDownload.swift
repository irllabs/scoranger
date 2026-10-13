import Network
import XCTest

/// The web view catches a download and the file lands in the library
/// (0.20.0). musescore.com needs a signed-in member and counts downloads, so
/// the page is the test's own: a server on the simulator hands out a
/// MusicXML attachment and an MSCZ one, and `-sourceBrowserURL` points the
/// screen at it. What is proven is the mechanism the real site goes
/// through -- a navigation response the web view cannot show, taken as a
/// WKDownload, written to a file, imported.
final class SourceBrowserDownload: XCTestCase {

    private var app: XCUIApplication!
    private var server: TinyServer!

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    override func tearDown() {
        server?.stop()
        super.tearDown()
    }

    /// The smallest score that imports: one bar of one part.
    private static let musicXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE score-partwise PUBLIC "-//Recordare//DTD MusicXML 4.0 Partwise//EN" "http://www.musicxml.org/dtds/partwise.dtd">
    <score-partwise version="4.0">
      <work><work-title>Downloaded Air</work-title></work>
      <part-list><score-part id="P1"><part-name>Flute</part-name></score-part></part-list>
      <part id="P1"><measure number="1">
        <attributes><divisions>1</divisions><key><fifths>0</fifths></key>
          <time><beats>4</beats><beat-type>4</beat-type></time>
          <clef><sign>G</sign><line>2</line></clef></attributes>
        <note><pitch><step>C</step><octave>5</octave></pitch><duration>4</duration><type>whole</type></note>
      </measure></part>
    </score-partwise>
    """

    private static let page = """
    <!doctype html><html><head><meta name="viewport" content="width=device-width"></head>
    <body style="font: 24px -apple-system; padding: 40px">
    <h1 id="title">A score page</h1>
    <p><a id="xml" href="/download/air.musicxml">Download MusicXML</a></p>
    <p><a id="mscz" href="/download/air.mscz">Download MSCZ</a></p>
    </body></html>
    """

    private func launch() throws {
        server = TinyServer(routes: [
            "/": ("text/html; charset=utf-8", Data(Self.page.utf8), nil),
            "/download/air.musicxml": ("application/vnd.recordare.musicxml+xml",
                                       Data(Self.musicXML.utf8),
                                       "attachment; filename=\"Downloaded Air.musicxml\""),
            "/download/air.mscz": ("application/octet-stream", Data([0x50, 0x4b, 0x03, 0x04]),
                                   "attachment; filename=\"Downloaded Air.mscz\""),
        ])
        let port = try server.start()
        app = XCUIApplication()
        app.launchArguments = ["-resetLibrary", "-seedTestLibrary", "-stubTheSession",
                               "-sourceBrowserURL", "http://127.0.0.1:\(port)/"]
        app.launch()
        let importVerb = element("library-import")
        XCTAssertTrue(importVerb.waitForExistence(timeout: 240))
        importVerb.tap()
        element("library-import-search").tap()
        XCTAssertTrue(element("search-field").waitForExistence(timeout: 20))
        element("search-field").tap()
        element("search-field").typeText("air")
        element("search-go").tap()
        let door = element("search-musescore-open")
        XCTAssertTrue(door.waitForExistence(timeout: 30))
        door.tap()
        XCTAssertTrue(app.staticTexts["A score page"].waitForExistence(timeout: 60),
                      "the browser did not load the test page")
    }

    func testADownloadedMusicXMLLandsInTheLibraryAndOpens() throws {
        try launch()
        snap("browser-page")
        app.links["Download MusicXML"].firstMatch.tap()
        // the import opens the score, as every import does
        XCTAssertTrue(app.buttons["score-title"].waitForExistence(timeout: 180),
                      "the downloaded score did not open")
        XCTAssertTrue(app.staticTexts["Downloaded Air"].firstMatch.waitForExistence(timeout: 60),
                      "the opened score is not the downloaded one")
        snap("browser-downloaded-open")
    }

    func testMuseScoresOwnFormatIsRefusedWithTheFix() throws {
        try launch()
        app.links["Download MSCZ"].firstMatch.tap()
        let line = element("browser-line")
        XCTAssertTrue(line.waitForExistence(timeout: 30), "the refusal was not shown")
        XCTAssertTrue(line.label.contains("choose MusicXML"), line.label)
        XCTAssertTrue(app.staticTexts["A score page"].exists, "the page was left")
        snap("browser-mscz-refused")
    }
}

/// One-connection-at-a-time HTTP/1.0 server on the loopback, enough for a
/// web view to fetch a page and follow a link to an attachment.
final class TinyServer {
    typealias Route = (type: String, body: Data, disposition: String?)
    private let routes: [String: Route]
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "tiny-server")
    private var connections: [NWConnection] = []

    init(routes: [String: Route]) { self.routes = routes }

    func start() throws -> UInt16 {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 10)
        self.listener = listener
        guard let port = listener.port?.rawValue else {
            throw NSError(domain: "TinyServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "no port"])
        }
        return port
    }

    func stop() {
        listener?.cancel()
        connections.forEach { $0.cancel() }
    }

    private func serve(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel(); return
            }
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let response: Data
            if let route = self.routes[path] {
                var head = "HTTP/1.0 200 OK\r\nContent-Type: \(route.type)\r\n"
                    + "Content-Length: \(route.body.count)\r\nConnection: close\r\n"
                if let disposition = route.disposition {
                    head += "Content-Disposition: \(disposition)\r\n"
                }
                response = Data((head + "\r\n").utf8) + route.body
            } else {
                response = Data("HTTP/1.0 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
            }
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}
