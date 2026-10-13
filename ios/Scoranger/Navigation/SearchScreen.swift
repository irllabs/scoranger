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

    // A tune, opened
    @State private var openTune: TheSessionTune?
    @State private var opening: Int?
    @State private var importing: Set<Int> = []
    @State private var importingAll = false
    @State private var imported: [Int: String] = [:]
    @State private var importedAll: (count: Int, slug: String)?

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
        .frame(maxWidth: Theme.Metric.readingColumn)
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
                imported = [:]
                importedAll = nil
                openTune = tune
            } catch {
                state.notice = "Couldn't open that tune: \(error.localizedDescription)"
            }
            opening = nil
        }
    }

    // MARK: - A tune's settings

    private func settings(of tune: TheSessionTune) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: Theme.Metric.s6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(tune.name).typeRole(.title).foregroundStyle(Theme.Ink.ink)
                        if let type = tune.type {
                            Text(type).typeRole(.meta).foregroundStyle(Theme.Ink.ink3)
                        }
                    }
                    if !tune.aliases.isEmpty {
                        Text("Also “" + tune.aliases.joined(separator: "”, “") + "”")
                            .typeRole(.meta).foregroundStyle(Theme.Ink.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("\(tune.settings.count) setting\(tune.settings.count == 1 ? "" : "s") on "
                         + "thesession.org. Each is one player's way of the tune; every one "
                         + "you import becomes an arrangement of one piece.")
                        .typeRole(.body).foregroundStyle(Theme.Ink.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: Theme.Metric.s8) {
                        if let all = importedAll {
                            PanelButton(title: "Open", kind: .primary,
                                        identifier: "search-open-all") { onOpen(all.slug) }
                            Text("Imported \(all.count) settings.")
                                .typeRole(.meta).foregroundStyle(Theme.Ink.ink2)
                                .accessibilityIdentifier("search-imported-all")
                        } else {
                            PanelButton(title: importingAll ? "Importing…"
                                            : "Import all \(tune.settings.count)",
                                        identifier: "search-import-all") { importAll(tune) }
                                .disabled(importingAll || tune.settings.count < 2)
                        }
                        Spacer()
                        Link("On thesession.org", destination: TheSessionURL.page(tune.id)!)
                            .typeRole(.meta).foregroundStyle(Theme.Accent.clayStrong)
                            .accessibilityIdentifier("search-tune-link")
                    }
                }
                .padding(Theme.Metric.s16)
                Theme.Rule()
                ForEach(Array(tune.settings.enumerated()), id: \.element.id) { index, setting in
                    settingRow(setting, of: tune, at: index)
                    Theme.Rule()
                }
            }
        }
        .frame(maxWidth: Theme.Metric.readingColumn)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("search-tune")
    }

    private func settingRow(_ setting: TheSessionSetting, of tune: TheSessionTune,
                            at index: Int) -> some View {
        HStack(spacing: Theme.Metric.s12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Setting \(index + 1) · \(setting.keyLine)")
                    .typeRole(.row).foregroundStyle(Theme.Ink.ink)
                if let member = setting.member {
                    Text("by \(member)").typeRole(.meta).foregroundStyle(Theme.Ink.ink3)
                }
            }
            Spacer()
            if let slug = imported[setting.id] {
                PanelButton(title: "Open", kind: .primary,
                            identifier: "search-open-\(index + 1)") { onOpen(slug) }
            } else {
                PanelButton(title: importing.contains(setting.id) ? "Importing…" : "Import",
                            identifier: "search-import-\(index + 1)") {
                    importOne(setting, of: tune)
                }
                .disabled(importing.contains(setting.id) || importingAll)
            }
        }
        .padding(.horizontal, Theme.Metric.s16)
        .padding(.vertical, Theme.Metric.s8)
        .frame(minHeight: Theme.Metric.hitTarget)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("search-setting-\(index + 1)")
    }

    private func importOne(_ setting: TheSessionSetting, of tune: TheSessionTune) {
        importing.insert(setting.id)
        Task {
            defer { importing.remove(setting.id) }
            do {
                let whole = try await state.tuneFinder.abc(ofTune: tune.id)
                guard let abc = ABCSettings.select([setting.id], from: whole) else {
                    state.notice = "thesession.org's ABC for this tune does not hold that setting."
                    return
                }
                if let slug = await state.importTune(
                    abc: abc, fileName: ABCSettings.fileName(tune: tune.name, settingCount: 1),
                    origin: "\(TheSessionURL.page(tune.id)!.absoluteString)#setting\(setting.id)") {
                    imported[setting.id] = slug
                }
            } catch {
                state.notice = "Couldn't fetch that tune: \(error.localizedDescription)"
            }
        }
    }

    private func importAll(_ tune: TheSessionTune) {
        importingAll = true
        Task {
            defer { importingAll = false }
            do {
                let whole = try await state.tuneFinder.abc(ofTune: tune.id)
                let abc = ABCSettings.whole(whole)
                if let slug = await state.importTune(
                    abc: abc, fileName: ABCSettings.fileName(tune: tune.name,
                                                             settingCount: tune.settings.count),
                    origin: TheSessionURL.page(tune.id)!.absoluteString) {
                    importedAll = (tune.settings.count, slug)
                }
            } catch {
                state.notice = "Couldn't fetch that tune: \(error.localizedDescription)"
            }
        }
    }
}
