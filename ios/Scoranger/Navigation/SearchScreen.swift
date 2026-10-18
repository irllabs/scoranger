import PDFKit
import SwiftUI

/// Looking a tune up by name (0.20.0, design/SEARCH_0.20.md).
///
/// One field, a tick box per source, and the results under it. thesession.org
/// answers in the screen: a tune opens to its settings, and one or all of
/// them import. MuseScore cannot answer here -- it has no API and refuses
/// anything but a browser -- so its row hands the words to the site's own
/// search in a web view, where a member signs in and downloads.
struct SearchScreen: View {
    @EnvironmentObject var state: AppState
    var onBack: () -> Void
    var onOpen: (String) -> Void
    /// Open a site to finish the search there.
    var onBrowse: (String) -> Void

    @AppStorage("searchSources") private var storedSources = ""
    @State private var query = ""
    @State private var searching = false
    @State private var results: TheSessionSearch?
    @State private var failure: String?
    @State private var searched = ""

    // A tune, opened: its settings ticked, one in focus and previewed
    @State private var openTune: TheSessionTune?
    @State private var opening: Int?
    @State private var ticked: Set<Int> = []
    @State private var focused: Int?
    @State private var previews: [Int: SettingPreview.Phase] = [:]
    @State private var importing = false
    @State private var importedSettings: Set<Int> = []
    @State private var lastImport: (slug: String, said: String)?

    private var sources: Set<SearchSource> { SearchSource.decode(storedSources) }
    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSearch: Bool { !trimmed.isEmpty && !sources.isEmpty && !searching }

    var body: some View {
        Screen(title: "Search", backLabel: openTune == nil ? "Library" : "Results",
               subtitle: openTune.map { $0.name },
               onBack: { if openTune != nil { openTune = nil } else { onBack() } },
               scrolls: false) {
            if let tune = openTune {
                settings(of: tune)
            } else {
                searchPage
            }
        }
    }

    // MARK: - The search

    private var searchPage: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Metric.s8) {
                HStack(spacing: Theme.Metric.s8) {
                    SearchField(placeholder: "Tune or song name", text: $query,
                                identifier: "search-field")
                        .submitLabel(.search)
                        .onSubmit(search)
                    PanelButton(title: "Search", kind: .primary, identifier: "search-go",
                                action: search)
                        .disabled(!canSearch)
                }
                ForEach(SearchSource.allCases) { source in
                    sourceRow(source)
                }
            }
            .padding(.horizontal, Theme.Metric.s16)
            .padding(.vertical, Theme.Metric.s12)
            Theme.Rule()
            resultsPane
        }
        .frame(maxWidth: .infinity)
    }

    private func sourceRow(_ source: SearchSource) -> some View {
        let on = sources.contains(source)
        return Button {
            var now = sources
            if on { now.remove(source) } else { now.insert(source) }
            storedSources = SearchSource.encode(now)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Metric.s8) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .font(.system(size: 17))
                    .foregroundStyle(on ? Theme.Accent.clayStrong : Theme.Ink.ink3)
                    .frame(width: Theme.Metric.s24)
                Text(source.title).typeRole(.row).foregroundStyle(Theme.Ink.ink)
                Text(source.line).typeRole(.meta).foregroundStyle(Theme.Ink.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(minHeight: Theme.Metric.s32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(source.title), \(source.line)")
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : [.isButton])
        .accessibilityIdentifier(source.identifier)
    }

    @ViewBuilder
    private var resultsPane: some View {
        if searching {
            VStack(spacing: Theme.Metric.s8) {
                ProgressView().tint(Theme.Accent.clay)
                Text("Asking thesession.org…").typeRole(.meta).foregroundStyle(Theme.Ink.ink3)
                    .accessibilityIdentifier("search-busy")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if searched.isEmpty {
            StateView(systemImage: "magnifyingglass", title: "Find a tune",
                      message: "Type a name and press Search. thesession.org answers here; "
                             + "MuseScore opens its own site.",
                      identifier: "search-empty")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if sources.contains(.musescore) { musescoreBand }
                    if sources.contains(.thesession) { thesessionBand }
                }
            }
        }
    }

    /// MuseScore's row: not a result, a door. The site searches itself.
    private var musescoreBand: some View {
        VStack(alignment: .leading, spacing: 0) {
            BandHeader(title: "MuseScore") { EmptyView() }
            ScreenRow(title: "Search MuseScore for “\(searched)”",
                      identifier: "search-musescore-open") {
                if let url = TheSessionURL.musescoreSearch(searched) {
                    onBrowse(url.absoluteString)
                }
            }
            Text("Opens musescore.com in Scoranger. Sign in there to download a score as "
                 + "MusicXML; it lands in your library.")
                .typeRole(.meta).foregroundStyle(Theme.Ink.ink3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Theme.Metric.s16 + Theme.Metric.s16)
                .padding(.bottom, Theme.Metric.s8)
        }
    }

    @ViewBuilder
    private var thesessionBand: some View {
        BandHeader(title: "thesession.org") {
            if let results {
                Text(results.countLine).typeRole(.data).foregroundStyle(Theme.Ink.ink3)
                    .accessibilityIdentifier("search-count")
            }
        }
        if let failure {
            Text(failure).typeRole(.body).foregroundStyle(Theme.Status.danger)
                .padding(Theme.Metric.s16)
                .accessibilityIdentifier("search-failed")
        } else if let results {
            if results.hits.isEmpty {
                Text("Nothing on thesession.org is called that. Try another spelling, "
                     + "or a word from the name.")
                    .typeRole(.body).foregroundStyle(Theme.Ink.ink2)
                    .padding(Theme.Metric.s16)
                    .accessibilityIdentifier("search-none")
            }
            ForEach(Array(results.hits.enumerated()), id: \.element.id) { index, hit in
                hitRow(hit, at: index)
            }
            if results.hasMore {
                PanelButton(title: "More", identifier: "search-more") { more() }
                    .padding(Theme.Metric.s16)
            }
        }
    }

    private func hitRow(_ hit: TheSessionHit, at index: Int) -> some View {
        var value = hit.type?.capitalized ?? ""
        if let alias = hit.alias { value = "also “\(alias)”" + (value.isEmpty ? "" : " · \(value)") }
        return ScreenRow(title: hit.name, value: value.isEmpty ? nil : value,
                         identifier: "search-hit-\(index + 1)") {
            open(hit)
        }
        .overlay(alignment: .trailing) {
            if opening == hit.id {
                ProgressView().controlSize(.small).tint(Theme.Accent.clay)
                    .padding(.trailing, Theme.Metric.s32)
            }
        }
    }

    private func search() {
        guard canSearch else { return }
        let words = trimmed
        searched = words
        results = nil
        failure = nil
        guard sources.contains(.thesession) else { return }
        searching = true
        Task {
            do {
                let page = try await state.tuneFinder.search(words, page: 1)
                results = page
            } catch {
                failure = error.localizedDescription
            }
            searching = false
        }
    }

    private func more() {
        guard let have = results, have.hasMore else { return }
        Task {
            do {
                let next = try await state.tuneFinder.search(searched, page: have.page + 1)
                results = TheSessionSearch(query: have.query, hits: have.hits + next.hits,
                                           page: next.page, pages: next.pages, total: next.total)
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private func open(_ hit: TheSessionHit) {
        guard opening == nil else { return }
        opening = hit.id
        Task {
            do {
                let tune = try await state.tuneFinder.tune(hit.id)
                ticked = []
                importedSettings = []
                lastImport = nil
                previews = [:]
                openTune = tune
                if let first = tune.settings.first { focus(first, of: tune) }
            } catch {
                state.notice = "Couldn't open that tune: \(error.localizedDescription)"
            }
            opening = nil
        }
    }

    // MARK: - A tune's settings
    //
    // The settings on the left, each with a tick box; the one in focus drawn
    // on the right, from its own ABC (0.22.0). Ali: "add a preview to the
    // versions; move the list to the left and have a preview window on the
    // right", and "check boxes for each arrangement and an import button to
    // apply to all that is checked". On a phone the preview sits above the
    // list: there is no room beside it.

    private func settings(of tune: TheSessionTune) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(of: tune)
            Theme.Rule()
            GeometryReader { space in
                if space.size.width >= 700 {
                    HStack(spacing: 0) {
                        settingList(of: tune)
                            .frame(width: max(320, space.size.width * 0.38))
                        Rectangle().fill(Theme.Ink.ink3.opacity(0.25)).frame(width: 1)
                        previewPane(of: tune)
                    }
                } else {
                    VStack(spacing: 0) {
                        previewPane(of: tune)
                            .frame(height: space.size.height * 0.45)
                        Theme.Rule()
                        settingList(of: tune)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("search-tune")
    }

    private func header(of tune: TheSessionTune) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metric.s6) {
            HStack(alignment: .firstTextBaseline) {
                Text(tune.name).typeRole(.title).foregroundStyle(Theme.Ink.ink)
                if let type = tune.type {
                    Text(type).typeRole(.meta).foregroundStyle(Theme.Ink.ink3)
                }
                Spacer()
                Link("On thesession.org", destination: TheSessionURL.page(tune.id)!)
                    .typeRole(.meta).foregroundStyle(Theme.Accent.clayStrong)
                    .accessibilityIdentifier("search-tune-link")
            }
            if !tune.aliases.isEmpty {
                Text("Also “" + tune.aliases.joined(separator: "”, “") + "”")
                    .typeRole(.meta).foregroundStyle(Theme.Ink.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("\(tune.settings.count) setting\(tune.settings.count == 1 ? "" : "s") on "
                 + "thesession.org, each one player's way of the tune. Tick the ones to "
                 + "import: each becomes an arrangement of one piece.")
                .typeRole(.body).foregroundStyle(Theme.Ink.ink2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Metric.s8) {
                PanelButton(title: importing ? "Importing…" : importTitle,
                            kind: .primary, identifier: "search-import-ticked") {
                    importTicked(of: tune)
                }
                .disabled(importing || ticked.isEmpty)
                let all = Set(tune.settings.map(\.id))
                PanelButton(title: ticked == all ? "Untick all" : "Tick all",
                            identifier: "search-tick-all") {
                    ticked = ticked == all ? [] : all
                }
                .disabled(importing)
                if let done = lastImport {
                    PanelButton(title: "Open", identifier: "search-open") { onOpen(done.slug) }
                    Text(done.said).typeRole(.meta).foregroundStyle(Theme.Ink.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("search-imported")
                }
            }
        }
        .padding(Theme.Metric.s16)
    }

    private var importTitle: String {
        switch ticked.count {
        case 0: return "Import"
        case 1: return "Import 1 setting"
        default: return "Import \(ticked.count) settings"
        }
    }

    private func settingList(of tune: TheSessionTune) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(tune.settings.enumerated()), id: \.element.id) { index, setting in
                    settingRow(setting, of: tune, at: index)
                    Theme.Rule()
                }
            }
        }
        .accessibilityIdentifier("search-setting-list")
    }

    private func settingRow(_ setting: TheSessionSetting, of tune: TheSessionTune,
                            at index: Int) -> some View {
        let isTicked = ticked.contains(setting.id)
        let isFocused = focused == setting.id
        return HStack(spacing: 0) {
            Button {
                if isTicked { ticked.remove(setting.id) } else { ticked.insert(setting.id) }
            } label: {
                Image(systemName: isTicked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 17))
                    .foregroundStyle(isTicked ? Theme.Accent.clayStrong : Theme.Ink.ink3)
                    .frame(width: Theme.Metric.checkboxGutter, height: Theme.Metric.hitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Import setting \(index + 1)")
            .accessibilityAddTraits(isTicked ? [.isButton, .isSelected] : [.isButton])
            .accessibilityIdentifier("search-tick-\(index + 1)")
            Button {
                focus(setting, of: tune)
            } label: {
                HStack(spacing: Theme.Metric.s8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Setting \(index + 1) · \(setting.keyLine)")
                            .typeRole(.row).foregroundStyle(Theme.Ink.ink)
                        if let member = setting.member {
                            Text("by \(member)").typeRole(.meta).foregroundStyle(Theme.Ink.ink3)
                        }
                    }
                    Spacer()
                    if importedSettings.contains(setting.id) {
                        Text("imported").typeRole(.meta).foregroundStyle(Theme.Ink.ink3)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: Theme.Metric.hitTarget, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Setting \(index + 1), \(setting.keyLine)"
                                + (isFocused ? ", shown" : ""))
            .accessibilityIdentifier("search-setting-\(index + 1)")
        }
        .padding(.trailing, Theme.Metric.s16)
        .padding(.vertical, Theme.Metric.s4)
        // C4: the setting being shown is a flat tint band the width of the list
        .background(isFocused ? Theme.Accent.clayTint : Color.clear)
    }

    @ViewBuilder
    private func previewPane(of tune: TheSessionTune) -> some View {
        Group {
            switch focused.flatMap({ previews[$0] }) {
            case .ready(let document)?:
                SettingPreview(document: document)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("The setting's score")
                    .accessibilityIdentifier("search-preview")
            case .failed(let why)?:
                Text("This setting could not be drawn: \(why)")
                    .typeRole(.body).foregroundStyle(Theme.Ink.ink3)
                    .padding(Theme.Metric.s16)
                    .accessibilityIdentifier("search-preview-failed")
            default:
                ProgressView().accessibilityIdentifier("search-preview-loading")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Surface.band)
    }

    /// Show a setting: draw it from its own ABC the first time it is asked
    /// for. Verovio reads ABC, so nothing is imported to look at one.
    private func focus(_ setting: TheSessionSetting, of tune: TheSessionTune) {
        focused = setting.id
        guard previews[setting.id] == nil else { return }
        previews[setting.id] = .loading
        Task {
            do {
                let whole = try await state.tuneFinder.abc(ofTune: tune.id)
                guard let abc = ABCSettings.select([setting.id], from: whole) else {
                    previews[setting.id] = .failed("thesession.org's ABC does not hold it")
                    return
                }
                let file = FileManager.default.temporaryDirectory
                    .appending(path: "setting-preview-\(setting.id).abc")
                try abc.write(to: file, atomically: true, encoding: .utf8)
                defer { try? FileManager.default.removeItem(at: file) }
                let engraving = try await VerovioRenderer.shared.engrave(musicXMLPath: file.path)
                guard let document = PDFDocument(data: engraving.pdf) else {
                    previews[setting.id] = .failed("the drawing came back empty")
                    return
                }
                previews[setting.id] = .ready(document)
            } catch {
                previews[setting.id] = .failed(OperationReport.reason(error))
            }
        }
    }

    /// Every ticked setting, in the site's order, as ONE file: one import,
    /// one arrangement each, all under one piece (the import files tunes that
    /// share a title under one piece, and every setting shares the tune's).
    private func importTicked(of tune: TheSessionTune) {
        let chosen = tune.settings.filter { ticked.contains($0.id) }
        guard !chosen.isEmpty else { return }
        importing = true
        Task {
            defer { importing = false }
            do {
                let whole = try await state.tuneFinder.abc(ofTune: tune.id)
                guard let abc = ABCSettings.select(Set(chosen.map(\.id)), from: whole) else {
                    state.notice = "thesession.org's ABC for this tune does not hold those settings."
                    return
                }
                let origin = chosen.count == 1
                    ? "\(TheSessionURL.page(tune.id)!.absoluteString)#setting\(chosen[0].id)"
                    : TheSessionURL.page(tune.id)!.absoluteString
                if let slug = await state.importTune(
                    abc: abc, fileName: ABCSettings.fileName(tune: tune.name,
                                                             settingCount: chosen.count),
                    origin: origin) {
                    importedSettings.formUnion(chosen.map(\.id))
                    ticked = []
                    lastImport = (slug, SearchImport.sentence(
                        count: chosen.count, slug: slug, manifest: state.manifest))
                }
            } catch {
                state.notice = "Couldn't fetch that tune: \(error.localizedDescription)"
            }
        }
    }
}

/// A setting's score, its pages one under another from the top of the pane.
///
/// Drawn as pictures rather than in a PDFView: PDFView centres a page shorter
/// than its view, and a setting is usually one short page, so the music sat
/// in the middle of the pane under a band of nothing.
struct SettingPreview: View {
    enum Phase {
        case loading
        case ready(PDFDocument)
        case failed(String)
    }

    let document: PDFDocument

    var body: some View {
        GeometryReader { space in
            ScrollView {
                VStack(spacing: Theme.Metric.s8) {
                    ForEach(0..<document.pageCount, id: \.self) { index in
                        if let page = document.page(at: index) {
                            Image(uiImage: Self.picture(of: page, width: space.size.width))
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: space.size.width)
                        }
                    }
                }
            }
        }
    }

    /// The page at twice the pane's width, so it stays sharp on a Retina
    /// screen and when the pane is the whole phone.
    private static func picture(of page: PDFPage, width: CGFloat) -> UIImage {
        let box = page.bounds(for: .mediaBox)
        let scale = max(width, 1) * 2 / max(box.width, 1)
        return page.thumbnail(of: CGSize(width: box.width * scale, height: box.height * scale),
                              for: .mediaBox)
    }
}
