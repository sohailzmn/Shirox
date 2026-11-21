import SwiftUI
import Combine

// MARK: - VM Store

@MainActor
private final class ModuleStreamVMStore: ObservableObject {
    var viewModels: [String: ModuleStreamRowViewModel] = [:]

    func get(for module: ModuleDefinition, mediaId: Int?, animeTitle: String, episodeNumber: Int) -> ModuleStreamRowViewModel {
        if let vm = viewModels[module.id] { return vm }
        let vm = ModuleStreamRowViewModel(module: module, mediaId: mediaId, animeTitle: animeTitle, targetEpisodeNumber: episodeNumber)
        viewModels[module.id] = vm
        return vm
    }
}

// MARK: - Season-aware module matching
//
// AniList often names a second season "Blue Lock Season 2" while AniWorld stores
// every season under "Blue Lock". Keep the requested season when choosing an episode:
// simplifying the search title must never silently play S1E1 for S2E1.
enum ModuleSeasonFallback {
    static func parsedSuffix(in title: String) -> (base: String, season: Int)? {
        let patterns = [
            #"(?i)(?:\s*[\(\[:–—-]\s*|\s+)(?:season|staffel)\s*(\d{1,2})\s*[\)\]]?\s*$"#,
            #"(?i)\s+(\d{1,2})(?:st|nd|rd|th)\s+season\s*$"#,
            #"(?i)\s+s(\d{1,2})\s*$"#
        ]
        let whole = NSRange(title.startIndex..<title.endIndex, in: title)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: title, range: whole),
                  let suffixRange = Range(match.range, in: title),
                  let seasonRange = Range(match.range(at: 1), in: title),
                  let season = Int(title[seasonRange]), season > 0 else { continue }
            let base = String(title[..<suffixRange.lowerBound])
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines
                    .union(CharacterSet(charactersIn: ":-–—([ ")))
            guard base.count > 1 else { continue }
            return (base, season)
        }
        return nil
    }

    /// Separate catalogue identity from release metadata before searching.
    /// A season suffix is never the literal title: "Dexter: Resurrection Season 2"
    /// means series "Dexter: Resurrection" and season 2. The player uses the
    /// returned season to validate the episode URL; a language model may only
    /// rank already-grounded matches, never override this explicit metadata.
    struct MediaIntent: Equatable {
        let seriesTitle: String
        let seasonNumber: Int?
        let episodeNumber: Int?
    }

    /// Some catalogue titles include the currently selected episode, such as
    /// "Dexter: Wiedererwachen S2 · E6". This is S2E6 even if the AniList
    /// card's flat catalogue calls the same episode number 12.
    static func parsedSeasonEpisodeSuffix(in title: String) -> (base: String, season: Int, episode: Int)? {
        let patterns = [
            #"(?i)\s+s\s*0?(\d{1,2})\s*[·•|/–—-]\s*e\s*0?(\d{1,3})\s*$"#,
            #"(?i)\s+(?:season|staffel)\s*(\d{1,2})\s*[·•|/–—-]\s*(?:episode|folge)\s*(\d{1,3})\s*$"#,
            #"(?i)\s+s\s*0?(\d{1,2})\s+e\s*0?(\d{1,3})\s*$"#
        ]
        let range = NSRange(title.startIndex..<title.endIndex, in: title)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: title, range: range),
                  let full = Range(match.range, in: title),
                  let seasonRange = Range(match.range(at: 1), in: title),
                  let episodeRange = Range(match.range(at: 2), in: title),
                  let season = Int(title[seasonRange]), (1...99).contains(season),
                  let episode = Int(title[episodeRange]), (1...500).contains(episode) else { continue }
            let base = String(title[..<full.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard base.count >= 3 else { continue }
            return (base, season, episode)
        }
        return nil
    }

    static func mediaIntent(for title: String) -> MediaIntent {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let explicit = parsedSeasonEpisodeSuffix(in: trimmed) {
            return MediaIntent(seriesTitle: explicit.base, seasonNumber: explicit.season,
                               episodeNumber: explicit.episode)
        }
        if let suffix = parsedSuffix(in: trimmed) {
            return MediaIntent(seriesTitle: suffix.base, seasonNumber: suffix.season,
                               episodeNumber: nil)
        }
        return MediaIntent(seriesTitle: trimmed, seasonNumber: nil, episodeNumber: nil)
    }

    static func sourceEpisodeNumber(for title: String, fallback: Int) -> Int {
        mediaIntent(for: title).episodeNumber ?? fallback
    }

    static func queries(for title: String, alternatives: [String] = []) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for candidate in [title] + alternatives {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count > 1 else { continue }
            // Search the *series*, not the release suffix. Localized title
            // matching must run before a slower literal "Season 2" fallback.
            let parsed = mediaIntent(for: trimmed)
            let variants = parsed.seasonNumber == nil
                ? [trimmed] : [parsed.seriesTitle, trimmed]
            for value in variants {
                let normalized = value.folding(
                    options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                if seen.insert(normalized).inserted { result.append(value) }
                if normalized.lowercased().contains("dexter") &&
                    normalized.lowercased().contains("resurrection") {
                    let german = "Dexter: Wiedererwachen"
                    if seen.insert(german.lowercased()).inserted { result.append(german) }
                }
            }
            if result.count >= 8 { break }
        }
        return Array(result.prefix(8))
    }

    struct DirectEpisodeCandidate: Equatable {
        let episodeHref: String
        let seriesHref: String
        let expectedTitle: String
    }

    /// Generate only canonical paths on the two installed German catalogues.
    /// These are untrusted candidates until the HTTP page has been validated.
    /// The requested season/episode is immutable, even if Jev changes title order.
    static func directEpisodeCandidates(
        for title: String, alternatives: [String], episodeNumber: Int, module: ModuleDefinition
    ) -> [DirectEpisodeCandidate] {
        let intent = mediaIntent(for: title)
        guard let season = intent.seasonNumber, (1...99).contains(season),
              (1...500).contains(episodeNumber) else { return [] }

        let source = module.sourceName.lowercased()
        let isUnified = source.contains("unified ger")
        let supportsAnime = isUnified || source.contains("aniworld")
        let supportsSeries = isUnified || source.contains("serienstream") || source.contains("s.to")
        guard supportsAnime || supportsSeries else { return [] }

        var names = queries(for: title, alternatives: alternatives)
            .map { mediaIntent(for: $0).seriesTitle }
        // On S.to this licensed metadata title is often localized.
        let dexter = intent.seriesTitle.folding(
            options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if dexter.contains("dexter") && dexter.contains("resurrection") {
            names.insert("Dexter: Wiedererwachen", at: 0)
        }

        var seen = Set<String>()
        var slugs: [(String, String)] = []
        for candidate in names {
            let base = mediaIntent(for: candidate).seriesTitle
            let ascii = base.lowercased()
                .replacingOccurrences(of: "ß", with: "ss")
                .folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            let slug = ascii.replacingOccurrences(
                of: "[^a-z0-9]+", with: "-", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            guard slug.count >= 3, slug.count <= 100,
                  seen.insert(slug).inserted else { continue }
            slugs.append((slug, base))
            if slugs.count >= 3 { break }
        }

        let preferSeries = dexter.contains("dexter")
        let origins = (supportsSeries && preferSeries
            ? ["https://serienstream.to/serie/", "https://aniworld.to/anime/stream/"]
            : ["https://aniworld.to/anime/stream/", "https://serienstream.to/serie/"])
            .filter {
                ($0.contains("aniworld") && supportsAnime) ||
                ($0.contains("serienstream") && supportsSeries)
            }

        var output: [DirectEpisodeCandidate] = []
        for origin in origins {
            for (slug, base) in slugs {
                let series = origin + slug
                output.append(DirectEpisodeCandidate(
                    episodeHref: series + "/staffel-\(season)/episode-\(episodeNumber)",
                    seriesHref: series, expectedTitle: base))
                if output.count >= 3 { return output }
            }
        }
        return output
    }

    /// For a grouped AniWorld listing, match the actual season URL. When S2 is
    /// missing, report no match instead of accidentally selecting S1E1.
    static func aniWorldEpisode(
        from episodes: [EpisodeLink], title: String, module: ModuleDefinition, number: Int
    ) -> (handled: Bool, episode: EpisodeLink?) {
        guard (module.sourceName.localizedCaseInsensitiveContains("AniWorld") ||
               module.sourceName.localizedCaseInsensitiveContains("s.to") ||
               module.sourceName.localizedCaseInsensitiveContains("SerienStream")),
              let season = mediaIntent(for: title).seasonNumber else { return (false, nil) }
        let hasSeasonPaths = episodes.contains { $0.href.localizedCaseInsensitiveContains("/staffel-") }
        // Without explicit season URLs we cannot prove that episode 1 is S2E1.
        // Never silently play the first-season episode from an ambiguous list.
        guard hasSeasonPaths else { return (true, nil) }
        let ending = "/staffel-\(season)/episode-\(number)"
        let found = episodes.first { item in
            let path = URL(string: item.href)?.path.lowercased() ?? item.href.lowercased()
            return path.hasSuffix(ending)
        }
        return (true, found)
    }
}

/// Deterministic fast-path decision layer. A remote language model cannot
/// tell whether an HLS playlist is reachable; these states come from actual
/// search / episode / resolver results and remain usable offline.
enum FastSourceDecision {
    static func error(
        foundSeries: Bool, foundEpisodes: Bool, foundStream: Bool,
        timedOut: Bool = false, websiteVerificationRequired: Bool = false
    ) -> String {
        if timedOut {
            return "Die Quellen antworten zu langsam. Erneut versuchen oder Quelle wechseln."
        }
        if websiteVerificationRequired && !foundStream {
            return "Mindestens eine Quelle verlangt eine Website-Verifizierung. Diese lässt sich nicht überspringen. Bitte eine andere zugängliche Quelle wählen."
        }
        if !foundSeries {
            return "Keine passende Serie gefunden. Auch Alternativtitel wurden geprüft."
        }
        if !foundEpisodes {
            return "Serie gefunden, aber die gewünschte Folge ist nicht verfügbar."
        }
        if !foundStream {
            return "Folge gefunden, aber kein abspielbarer Videolink. Anderen Hoster versuchen."
        }
        return "Die Wiedergabe konnte nicht gestartet werden."
    }
}

/// Fast, non-interactive verification of public episode pages. This never
/// attempts to solve CAPTCHAs or reuse another website's authentication.
enum VerifiedDirectEpisode {
    private static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .lowercased()
            .replacingOccurrences(of: "ß", with: "ss")
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isVerified(
        _ candidate: ModuleSeasonFallback.DirectEpisodeCandidate
    ) async -> Bool {
        guard let url = URL(string: candidate.episodeHref),
              url.scheme == "https",
              ["aniworld.to", "serienstream.to"].contains(url.host ?? "") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2.5
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard !Task.isCancelled,
                  let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  http.url?.host == url.host,
                  http.url?.path == url.path,
                  data.count < 2_000_000,
                  let html = String(data: data, encoding: .utf8) else { return false }
            // HTTP 200 alone is never evidence. Challenge and generic landing
            // pages must not be accepted as episode pages.
            let lower = html.lowercased()
            guard !lower.contains("cf-chl-"),
                  !lower.contains("cf-mitigated"),
                  !lower.contains("checking your browser"),
                  lower.contains("episode") || lower.contains("folge") else { return false }
            let pattern = #"<(?:h1|title)\b[^>]*>([\s\S]*?)</(?:h1|title)>"#
            guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
                return false
            }
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            let expected = normalize(candidate.expectedTitle)
            guard expected.count >= 3 else { return false }
            let matchedTitle = re.matches(in: html, range: range).contains { match in
                guard let titleRange = Range(match.range(at: 1), in: html) else { return false }
                return normalize(String(html[titleRange])).contains(expected)
            }
            // Never run a resolver on a title collision, CAPTCHA page or redirect.
            guard matchedTitle,
                  lower.contains("data-play-url") ||
                  lower.contains("episode-links") ||
                  lower.contains("link-box") ||
                  lower.contains("data-lang-key") else { return false }
            return true
        } catch {
            return false
        }
    }

    static func firstVerified(
        _ candidates: [ModuleSeasonFallback.DirectEpisodeCandidate]
    ) async -> ModuleSeasonFallback.DirectEpisodeCandidate? {
        await withTaskGroup(of: ModuleSeasonFallback.DirectEpisodeCandidate?.self) { group in
            for candidate in candidates.prefix(3) {
                group.addTask { await isVerified(candidate) ? candidate : nil }
            }
            for await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }
    }
}

// MARK: - Sheet

struct ModuleStreamPickerView: View {
    let mediaId: Int?
    let animeTitle: String
    let alternateTitles: [String]
    let episodeNumber: Int
    let onDismiss: () -> Void
    let onStreamsLoaded: ([StreamResult], StreamResult?, String?, Int?, String?) -> Void
    let headless: Bool
    let onStatus: ((String) -> Void)?
    let onFailure: ((String) -> Void)?

    init(
        mediaId: Int?, animeTitle: String, episodeNumber: Int,
        alternateTitles: [String] = [],
        onDismiss: @escaping () -> Void,
        headless: Bool = false, onStatus: ((String) -> Void)? = nil,
        onFailure: ((String) -> Void)? = nil,
        onStreamsLoaded: @escaping ([StreamResult], StreamResult?, String?, Int?, String?) -> Void
    ) {
        self.mediaId = mediaId
        self.animeTitle = animeTitle
        self.alternateTitles = alternateTitles
        self.episodeNumber = episodeNumber
        self.onDismiss = onDismiss
        self.onStreamsLoaded = onStreamsLoaded
        self.headless = headless
        self.onStatus = onStatus
        self.onFailure = onFailure
    }

    @EnvironmentObject private var moduleManager: ModuleManager
    @AppStorage("useDefaultExtension") private var useDefaultExtension = false
    @StateObject private var vmStore = ModuleStreamVMStore()
    @State private var autoPlayTask: Task<Void, Never>?
    @State private var autoPlayDeadlineTask: Task<Void, Never>?
    @State private var autoPlayLoading = false
    @State private var autoPlayMessage: String?
    @State private var didAutoStart = false

    private var visibleModules: [ModuleDefinition] {
        if useDefaultExtension, let active = moduleManager.activeModule {
            return [active]
        }
        return moduleManager.modules
    }

    var body: some View {
        Group {
            if headless {
                Color.clear.frame(width: 1, height: 1)
                    .accessibilityHidden(true)
            } else {
                NavigationStack {
                    List {
                Section {
                    Button {
                        if autoPlayLoading {
                            autoPlayTask?.cancel()
                            autoPlayDeadlineTask?.cancel()
                            autoPlayLoading = false
                        } else {
                            startSmartPlay()
                        }
                    } label: {
                        HStack(spacing: 12) {
                            if autoPlayLoading {
                                ProgressView()
                            } else {
                                Image(systemName: "play.fill")
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(autoPlayLoading ? "Finding the fastest stream…" : "Smart Play")
                                    .fontWeight(.semibold)
                                Text(autoPlayLoading ? "Tap to cancel" : "Find a working episode across installed modules")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .disabled(moduleManager.modules.isEmpty)
                    if let autoPlayMessage {
                        Text(autoPlayMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(visibleModules) { module in
                    ModuleStreamRow(
                        module: module,
                        mediaId: mediaId,
                        animeTitle: animeTitle,
                        episodeNumber: episodeNumber,
                        rowVm: vmStore.get(for: module, mediaId: mediaId, animeTitle: animeTitle, episodeNumber: episodeNumber),
                        automaticSearch: false
                    ) { streams, selectedStream, showHref, availableCount, episodeHref in
                        moduleManager.selectModule(module)
                        onDismiss()
                        onStreamsLoaded(streams, selectedStream, showHref, availableCount, episodeHref)
                    }
                }
            }
            .softScrollEdges()
            #if os(iOS)
            .listStyle(.insetGrouped)
            #elseif !os(tvOS)
            .listStyle(.inset)
            #endif

            .navigationTitle("Watch Episode \(episodeNumber)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDismiss() }
                }
            }
                    .tint(.primary)
                }
            }
        }
        .onAppear {
            // A single tap on Watch now starts resolving immediately: no source
            // picker, anime search result picker, or quality picker is required.
            if !didAutoStart {
                didAutoStart = true
                startSmartPlay()
            }
        }
        .onDisappear {
            autoPlayTask?.cancel()
            autoPlayDeadlineTask?.cancel()
        }
        #if os(iOS)
        .adaptivePresentationDetents([.medium, .large])

        #else

        .frame(minWidth: 480, minHeight: 360)

        #endif
    }

    // MARK: - One-tap stream resolution

    private func startSmartPlay() {
        guard !autoPlayLoading else { return }
        autoPlayLoading = true
        autoPlayMessage = nil
        // Avoid running the per-row searches in parallel with this targeted path.
        for row in vmStore.viewModels.values { row.cancelIfSearching() }

        // Independent watchdog: the underlying JS promise bridge can wait 120s,
        // and Smart Play may try multiple titles/providers. Never leave the user
        // staring at "Connecting…" indefinitely when a provider is unresponsive.
        autoPlayDeadlineTask?.cancel()
        autoPlayDeadlineTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 55_000_000_000) }
            catch { return }
            guard !Task.isCancelled, autoPlayLoading else { return }
            Logger.shared.log("[SmartPlay] Timed out after 55s; canceling provider lookups", type: "Error")
            autoPlayTask?.cancel()
            autoPlayLoading = false
            autoPlayMessage = FastSourceDecision.error(
                foundSeries: false, foundEpisodes: false, foundStream: false, timedOut: true)
            if headless { PlaybackPerformance.shared.failed() }
            onFailure?(autoPlayMessage ?? "Verbindung zur Quelle fehlgeschlagen.")
        }
        autoPlayTask = Task { @MainActor in
            defer {
                autoPlayLoading = false
                autoPlayDeadlineTask?.cancel()
                autoPlayDeadlineTask = nil
            }
            // First-launch auto-install is asynchronous. If Watch is tapped
            // immediately, wait for it before taking the Smart Play snapshot.
            // An offline failure still leaves existing modules available.
            await moduleManager.ensureUnifiedGermanSource()
            guard !Task.isCancelled else { return }
            let last = UserDefaults.standard.string(forKey: "lastUsedModuleId")
            let active = moduleManager.activeModule?.id
            let candidates: [ModuleDefinition]
            if useDefaultExtension, let selected = moduleManager.activeModule {
                candidates = [selected]
            } else {
                candidates = moduleManager.modules.filter { !$0.isManga }
            }
            let modules = candidates.sorted { left, right in
                func priority(_ module: ModuleDefinition) -> Int {
                    if module.id == last { return 0 }
                    if module.id == active { return 1 }
                    return 2
                }
                return priority(left) < priority(right)
            }

            // Calculate franchise offset concurrently with source lookup.
            // This otherwise blocked network search before it could even begin.
            let offsetTask = Task<Int, Never> {
                guard let mediaId else { return 0 }
                return await SeasonChainMapper.shared.resolveOffset(
                    anchorAniListID: mediaId, anchorMALID: nil) ?? 0
            }
            defer { offsetTask.cancel() }

            var foundSeries = false
            var foundEpisode = false
            var foundStreams = false
            var verificationRequired = false
            let sourceEpisode = ModuleSeasonFallback.sourceEpisodeNumber(
                for: animeTitle, fallback: episodeNumber)
            for module in modules {
                guard !Task.isCancelled else { return }
                autoPlayMessage = "Checking \(module.sourceName)…"
                onStatus?(module.sourceName)
                if headless {
                    PlaybackPerformance.shared.sourceSearch(provider: module.sourceName)
                }
                let runner = ModuleJSRunner()
                do {
                    try await runner.load(module: module)

                    var hrefs: [String] = []
                    if let previous = ModuleSearchAliasManager.shared.getLastSearchResultHref(
                        mediaId: mediaId, animeTitle: animeTitle, moduleId: module.id) {
                        hrefs.append(previous)
                    }

                    // Fast path: with an explicit season and episode, check a few
                    // trusted public episode URL patterns before expensive
                    // full-catalogue search + all-season enumeration.
                    // A valid page needs a matching actual title and hoster markup.
                    // Blocked pages fail silently here; normal recovery still works.
                    if hrefs.isEmpty {
                        let directCandidates = ModuleSeasonFallback.directEpisodeCandidates(
                            for: animeTitle, alternatives: alternateTitles,
                            episodeNumber: sourceEpisode, module: module)
                        if let direct = await VerifiedDirectEpisode.firstVerified(directCandidates),
                           !Task.isCancelled {
                            foundSeries = true
                            foundEpisode = true
                            if headless {
                                PlaybackPerformance.shared.moduleResolved()
                                PlaybackPerformance.shared.episodeResolved()
                            }
                            var directStreams: [StreamResult] = []
                            do {
                                directStreams = try await runner.fetchStreams(
                                    episodeUrl: direct.episodeHref)
                            } catch {
                                if error is ModuleStreamResolutionError ||
                                   runner.lastTurnstileURL != nil {
                                    verificationRequired = true
                                }
                            }
                            if !directStreams.isEmpty && !Task.isCancelled {
                                foundStreams = true
                                let savedTitle = ModuleSearchAliasManager.shared.getLastStreamTitle(
                                    moduleId: module.id)
                                let winner: StreamResult
                                if let saved = directStreams.first(where: { $0.title == savedTitle }) {
                                    winner = saved
                                } else if headless {
                                    winner = directStreams.first(where: {
                                        $0.title.localizedCaseInsensitiveContains("480p")
                                    }) ?? directStreams[0]
                                } else {
                                    winner = await Self.fastestResponsiveStream(in: directStreams)
                                }
                                guard !Task.isCancelled else { return }
                                ModuleSearchAliasManager.shared.setLastSearchResultHref(
                                    mediaId: mediaId, animeTitle: animeTitle,
                                    moduleId: module.id, href: direct.seriesHref)
                                ModuleSearchAliasManager.shared.setLastStreamTitle(
                                    moduleId: module.id, title: winner.title)
                                UserDefaults.standard.set(module.id, forKey: "lastUsedModuleId")
                                moduleManager.selectModule(module)
                                if headless { PlaybackPerformance.shared.streamResolved() }
                                if !headless { onDismiss() }
                                onStreamsLoaded(directStreams, winner, direct.seriesHref,
                                                nil, direct.episodeHref)
                                return
                            }
                        }
                    }

                    // Pass 0: reuse a known result. Search the AniList title, then
                    // retry a seasonless title (e.g. "Blue Lock" for "Blue Lock Season 2").
                    let alias = ModuleSearchAliasManager.shared.getAlias(
                        mediaId: mediaId, animeTitle: animeTitle, moduleId: module.id)
                    let allQueries = ModuleSeasonFallback.queries(
                        for: alias ?? animeTitle, alternatives: alternateTitles + [animeTitle])
                    // The unified module searches two sites per query. Limit its
                    // title retries and don't revisit identical series URLs.
                    var queries = module.sourceName.contains("Unified GER")
                        ? Array(allQueries.prefix(4)) : allQueries
                    var visitedHrefs = Set<String>()
                    var hasConsultedJev = false
                    for searchPass in 0...queries.count {
                        guard !Task.isCancelled else { return }
                        if searchPass == 0 && hrefs.isEmpty { continue }
                        if searchPass > 0 {
                            let query = queries[searchPass - 1]
                            let results = (try? await runner.search(keyword: query)) ?? []
                            let ranked = SearchResultMatcher.ranked(
                                query: query, items: results, title: { $0.title })
                            // Jev only reranks real results, never returns an unverified URL.
                            let enhanced = await JevDecisionEngine.shared.rankCandidates(
                                ranked, query: animeTitle,
                                season: ModuleSeasonFallback.mediaIntent(for: animeTitle).seasonNumber)
                            hrefs = Array(enhanced.prefix(3).map { $0.href })
                            // No result? One optional Jev decision reprioritizes
                            // the existing retries; the normal search still works offline.
                            if hrefs.isEmpty && searchPass == 1 && !hasConsultedJev {
                                hasConsultedJev = true
                                let first = queries[0]
                                let retry = await JevDecisionEngine.shared.prioritizeRetryQueries(
                                    Array(queries.dropFirst()), originalTitle: animeTitle)
                                queries = [first] + retry
                            }
                        }
                        if !hrefs.isEmpty { foundSeries = true }
                        for href in hrefs where visitedHrefs.insert(href).inserted {
                        guard !Task.isCancelled else { return }
                        if headless { PlaybackPerformance.shared.moduleResolved() }
                        let episodes: [EpisodeLink]
                        do { episodes = try await runner.fetchEpisodes(url: href) }
                        catch {
                            if runner.lastTurnstileURL != nil { verificationRequired = true }
                            continue
                        }
                        if !episodes.isEmpty { foundSeries = true }
                        let seasonMatch = ModuleSeasonFallback.aniWorldEpisode(
                            from: episodes, title: animeTitle, module: module, number: sourceEpisode)
                        let offset = await offsetTask.value
                        let absoluteIndex = offset + sourceEpisode - 1
                        let episode: EpisodeLink?
                        if seasonMatch.handled {
                            episode = seasonMatch.episode
                        } else if offset > 0 && episodes.indices.contains(absoluteIndex),
                                  Int(episodes[absoluteIndex].number) == offset + sourceEpisode {
                            episode = episodes[absoluteIndex]
                        } else {
                            episode = episodes.first { Int($0.number) == sourceEpisode }
                        }
                        guard let episode else { continue }
                        foundEpisode = true
                        if headless { PlaybackPerformance.shared.episodeResolved() }

                        let streams: [StreamResult]
                        do { streams = try await runner.fetchStreams(episodeUrl: episode.href) }
                        catch {
                            if error is ModuleStreamResolutionError ||
                               runner.lastTurnstileURL != nil {
                                verificationRequired = true
                            }
                            continue
                        }
                        guard !streams.isEmpty else { continue }
                        foundStreams = true

                        let savedTitle = ModuleSearchAliasManager.shared.getLastStreamTitle(
                            moduleId: module.id)
                        // A fresh resolver result is already an actual stream.
                        // Reuse the user's last working choice immediately;
                        // network races are only for unfamiliar hosts.
                        let winner: StreamResult
                        if let saved = streams.first(where: { $0.title == savedTitle }) {
                            winner = saved
                        } else if headless {
                            // The module has already extracted working stream URLs.
                            // Don't delay fullscreen playback with a duplicate HTTP
                            // probe. Prefer a lighter rendition if it is offered.
                            winner = streams.first(where: {
                                $0.title.localizedCaseInsensitiveContains("480p")
                            }) ?? streams[0]
                        } else {
                            winner = await Self.fastestResponsiveStream(in: streams)
                        }
                        guard !Task.isCancelled else { return }
                        ModuleSearchAliasManager.shared.setLastSearchResultHref(
                            mediaId: mediaId, animeTitle: animeTitle, moduleId: module.id, href: href)
                        ModuleSearchAliasManager.shared.setLastStreamTitle(
                            moduleId: module.id, title: winner.title)
                        UserDefaults.standard.set(module.id, forKey: "lastUsedModuleId")
                        moduleManager.selectModule(module)
                        if headless { PlaybackPerformance.shared.streamResolved() }
                        if !headless { onDismiss() }
                        onStreamsLoaded(streams, winner, href, episodes.count, episode.href)
                        return
                        }
                    }
                } catch {
                    // A broken provider must not block playback from the next module.
                    if error is ModuleStreamResolutionError ||
                       runner.lastTurnstileURL != nil {
                        verificationRequired = true
                    }
                    Logger.shared.log("[SmartPlay] \(module.sourceName): \(error.localizedDescription)", type: "Error")
                }
                if runner.lastTurnstileURL != nil { verificationRequired = true }
            }
            if !Task.isCancelled {
                autoPlayMessage = FastSourceDecision.error(
                    foundSeries: foundSeries, foundEpisodes: foundEpisode,
                    foundStream: foundStreams, websiteVerificationRequired: verificationRequired)
                if headless { PlaybackPerformance.shared.failed() }
                onFailure?(autoPlayMessage ?? "Keine abspielbare Quelle gefunden.")
            }
        }
    }

    /// Probe the first few candidates concurrently. GET only small HLS playlists,
    /// HEAD for MP4, and never download a whole movie just to measure start time.
    /// Always fall back to the module's first choice if all probes are rejected.
    private static func fastestResponsiveStream(in streams: [StreamResult]) async -> StreamResult {
        guard streams.count > 1 else { return streams[0] }
        let probes = Array(streams.prefix(3)).enumerated().compactMap { index, stream
            -> (index: Int, url: URL, headers: [String: String], isHLS: Bool, isMP4: Bool)? in
            let ext = stream.url.pathExtension.lowercased()
            guard stream.url.scheme?.lowercased() == "https", stream.url.host != nil,
                  ext == "m3u8" || ext == "mp4" else { return nil }
            return (index, stream.url, stream.headers, ext == "m3u8", ext == "mp4")
        }
        guard !probes.isEmpty else { return streams[0] }
        return await withTaskGroup(of: Int?.self) { group in
            for probe in probes {
                group.addTask {
                    guard !Task.isCancelled else { return nil }
                    var request = URLRequest(url: probe.url, timeoutInterval: 2.5)
                    request.httpMethod = probe.isMP4 ? "HEAD" : "GET"
                    if probe.isHLS {
                        request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
                    }
                    probe.headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
                    do {
                        let (data, response) = try await URLSession.shared.data(for: request)
                        guard !Task.isCancelled, let http = response as? HTTPURLResponse,
                              (200..<300).contains(http.statusCode) else { return nil }
                        if probe.isHLS {
                            guard let text = String(data: data, encoding: .utf8),
                                  text.trimmingCharacters(in: .whitespacesAndNewlines)
                                      .hasPrefix("#EXTM3U") else { return nil }
                        }
                        return probe.index
                    } catch { return nil }
                }
            }
            // Return on the first valid playlist instead of waiting for every
            // slower source to finish. The task group cancels in-flight probes.
            for await winner in group {
                if let winner {
                    group.cancelAll()
                    return streams[winner]
                }
            }
            return streams[0]
        }
    }

}

// MARK: - Row ViewModel

@MainActor
private final class ModuleStreamRowViewModel: ObservableObject {
    enum State {
        case idle
        case loading
        case searchResults([SearchItem])
        case loadingEpisodes(SearchItem)
        case selectingEpisode([EpisodeLink])
        case loadingStreams
        case notFound
        case error(String)
    }

    @Published var state: State = .idle
    @Published var searchTitle: String
    @Published var readyStreams: [StreamResult]?
    @Published var selectedEpisodeHref: String?  // Show/search-result href (used to re-fetch the episode list)
    @Published var selectedEpisodeActualHref: String?  // The matched episode's own unique href (anchors Next Episode)
    @Published var availableCount: Int?        // Track total episodes in this module result
    @Published var cloudflareURL: URL?         // Set when *this* module's runner hit a Turnstile wall
    @Published var verificationError: String?   // Keep a failed or cancelled check visible

    /// Captures whether this row's runner hit Cloudflare, then transitions to a settled state.
    private func settle(_ newState: State) {
        cloudflareURL = runner?.lastTurnstileURL
        state = newState
    }

    let module: ModuleDefinition
    let mediaId: Int?
    let originalAnimeTitle: String
    let targetEpisodeNumber: Int

    private var runner: ModuleJSRunner?
    private var currentTask: Task<Void, Never>?
    private var currentSearchResultHref: String?  // Track active search result for manual episode selection

    init(module: ModuleDefinition, mediaId: Int?, animeTitle: String, targetEpisodeNumber: Int) {
        self.module = module
        self.mediaId = mediaId
        self.originalAnimeTitle = animeTitle
        self.targetEpisodeNumber = targetEpisodeNumber
        
        // Load custom alias if available, otherwise fallback to original title
        if let alias = ModuleSearchAliasManager.shared.getAlias(mediaId: mediaId, animeTitle: animeTitle, moduleId: module.id) {
            self.searchTitle = alias
        } else {
            self.searchTitle = animeTitle
        }
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        state = .idle
    }

    func cancelIfSearching() {
        switch state {
        case .loading, .loadingEpisodes, .loadingStreams:
            currentTask?.cancel()
            currentTask = nil
            state = .idle
        default:
            break
        }
    }

    func startFind() {
        guard case .idle = state else { return }
        persistSearchTitle()
        let lastUsed = UserDefaults.standard.string(forKey: "lastUsedModuleId")
        let isPreferred = lastUsed != nil ? lastUsed == module.id : ModuleManager.shared.activeModule?.id == module.id
        if UserDefaults.standard.bool(forKey: "autoPickLastSearchResult"),
           isPreferred,
           let savedHref = ModuleSearchAliasManager.shared.getLastSearchResultHref(
               mediaId: mediaId, animeTitle: originalAnimeTitle, moduleId: module.id) {
            currentTask = Task { await findFast(savedHref: savedHref) }
        } else {
            currentTask = Task { await find() }
        }
    }

    func startSelectResult(_ item: SearchItem, targetEpisodeNumber: Int) {
        persistSearchTitle()
        ModuleSearchAliasManager.shared.setLastSearchResultHref(
            mediaId: mediaId, animeTitle: originalAnimeTitle, moduleId: module.id, href: item.href)
        currentTask = Task { await selectResult(item, targetEpisodeNumber: targetEpisodeNumber) }
    }

    private func persistSearchTitle() {
        ModuleSearchAliasManager.shared.setAlias(
            mediaId: mediaId,
            animeTitle: originalAnimeTitle,
            moduleId: module.id,
            alias: searchTitle
        )
    }

    func startSelectEpisode(_ episode: EpisodeLink) {
        currentTask = Task { await selectEpisode(episode) }
    }

    /// Franchise episodes preceding this AniList season, so a combined-season module list can be
    /// indexed to the right season. 0 for module-only flows (no AniList id) or single-season shows.
    private func seasonOffset() async -> Int {
        guard let mediaId else { return 0 }
        return await SeasonChainMapper.shared.resolveOffset(anchorAniListID: mediaId, anchorMALID: nil) ?? 0
    }

    // Fast path: skip search entirely, go straight to episodes using the saved href.
    // Falls back to full search if the href no longer works.
    func findFast(savedHref: String) async {
        state = .loading
        readyStreams = nil

        let r = ModuleJSRunner()
        runner = r

        do {
            try await r.load(module: module)
            var episodes = try await r.fetchEpisodes(url: savedHref)
            if episodes.isEmpty {
                try await Task.sleep(nanoseconds: 800_000_000)
                if Task.isCancelled { return }
                episodes = try await r.fetchEpisodes(url: savedHref)
            }
            availableCount = episodes.count
            currentSearchResultHref = savedHref

            if let matched = matchEpisode(from: episodes, target: targetEpisodeNumber, seasonOffset: await seasonOffset()) {
                state = .loadingStreams
                selectedEpisodeHref = savedHref
                selectedEpisodeActualHref = matched.href
                let streams = try await r.fetchStreams(episodeUrl: matched.href)
                if streams.isEmpty {
                    settle(.error("No streams found for episode \(targetEpisodeNumber)"))
                } else {
                    readyStreams = streams
                }
            } else {
                // Saved result doesn't contain the target episode (wrong series entry or stale href).
                // Clear the bad saved href and fall back to full search.
                ModuleSearchAliasManager.shared.setLastSearchResultHref(
                    mediaId: mediaId, animeTitle: originalAnimeTitle, moduleId: module.id, href: "")
                await find()
            }
        } catch {
            if (error as? CancellationError) != nil { return }
            // Stale href — fall back to full search
            await find()
        }
    }

    func find() async {
        let keyword = searchTitle.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return }

        state = .loading
        readyStreams = nil

        let r = ModuleJSRunner()
        runner = r

        do {
            try await r.load(module: module)
            let queries = ModuleSeasonFallback.queries(for: keyword)
            var results: [SearchItem] = []
            var matchedQuery = keyword
            for query in queries {
                guard !Task.isCancelled else { return }
                let candidate = (try? await r.search(keyword: query)) ?? []
                if !candidate.isEmpty {
                    results = candidate
                    matchedQuery = query
                    break
                }
            }

            if results.isEmpty {
                // Retry only after trying the shorter title; don't add an 800ms
                // delay before the "Blue Lock" fallback.
                try await Task.sleep(nanoseconds: 800_000_000)
                guard !Task.isCancelled else { return }
                if let last = queries.last {
                    matchedQuery = last
                    results = (try? await r.search(keyword: last)) ?? []
                }
            }

            if results.isEmpty {
                settle(.notFound)
            } else {
                let ordered = SearchResultMatcher.ranked(
                    query: matchedQuery, items: results, title: { $0.title })
                let enhanced = await JevDecisionEngine.shared.rankCandidates(
                    ordered, query: originalAnimeTitle,
                    season: ModuleSeasonFallback.mediaIntent(for: originalAnimeTitle).seasonNumber)
                settle(.searchResults(enhanced))
            }
        } catch {
            if (error as? CancellationError) != nil { return }
            settle(.error(error.localizedDescription))
        }
    }

    func selectResult(_ item: SearchItem, targetEpisodeNumber: Int) async {
        guard let r = runner else { return }
        state = .loadingEpisodes(item)
        currentSearchResultHref = item.href

        do {
            var episodes = try await r.fetchEpisodes(url: item.href)
            if episodes.isEmpty {
                try await Task.sleep(nanoseconds: 800_000_000)
                if Task.isCancelled { return }
                episodes = try await r.fetchEpisodes(url: item.href)
            }
            availableCount = episodes.count

            if let matched = matchEpisode(from: episodes, target: targetEpisodeNumber, seasonOffset: await seasonOffset()) {
                state = .loadingStreams
                selectedEpisodeHref = item.href
                selectedEpisodeActualHref = matched.href
                let streams = try await r.fetchStreams(episodeUrl: matched.href)
                if streams.isEmpty {
                    settle(.error("No streams found for episode \(targetEpisodeNumber)"))
                } else {
                    readyStreams = streams
                }
            } else {
                settle(.selectingEpisode(episodes))
            }
        } catch {
            if (error as? CancellationError) != nil { return }
            settle(.error(error.localizedDescription))
        }
    }

    /// Finds the episode matching `target`, handling modules that use absolute episode
    /// numbering (e.g., Season 2 numbered as episodes 25–48 instead of 1–24).
    ///
    /// `seasonOffset` is the number of franchise episodes preceding this AniList season. When
    /// the module concatenates every season into one list (e.g. AniWorld groups all seasons
    /// under one show, numbering restarts per season), a per-season number like "1" is
    /// ambiguous and the exact match would grab season 1. With a known offset we select by
    /// absolute position instead — but only when the list is actually long enough to contain
    /// that season, so single-season lists fall straight through to the existing logic.
    private func matchEpisode(from episodes: [EpisodeLink], target: Int, seasonOffset: Int = 0) -> EpisodeLink? {
        let seasonMatch = ModuleSeasonFallback.aniWorldEpisode(
            from: episodes, title: originalAnimeTitle, module: module, number: target)
        if seasonMatch.handled { return seasonMatch.episode }

        let targetDouble = Double(target)

        // 0. Combined multi-season list: pick by absolute position.
        if seasonOffset > 0 {
            let absoluteIndex = seasonOffset + target - 1 // 0-based
            if episodes.indices.contains(absoluteIndex) {
                return episodes[absoluteIndex]
            }
        }

        // 1. Exact match
        if let exact = episodes.first(where: { $0.number == targetDouble }) {
            return exact
        }

        // 2. Rounded match — catches modules that label ep 1 as 1.0 but ep 1.5 as a special
        if let rounded = episodes.first(where: { round($0.number) == targetDouble }) {
            return rounded
        }

        // 3. Offset match — module uses absolute numbering (e.g., S2 = eps 25–48).
        //    Only apply when every episode number exceeds the target, meaning the
        //    module doesn't start at 1 for this season.
        if let minEp = episodes.map(\.number).min(), minEp > targetDouble {
            let offsetTarget = minEp + targetDouble - 1
            if let offset = episodes.first(where: { $0.number == offsetTarget }) {
                return offset
            }
        }

        return nil
    }

    func selectEpisode(_ episode: EpisodeLink) async {
        guard let r = runner else { return }
        state = .loadingStreams
        do {
            let streams = try await r.fetchStreams(episodeUrl: episode.href)
            if streams.isEmpty {
                settle(.error("No streams found"))
            } else {
                // Use the current search result href if available (from manual episode selection)
                if let href = currentSearchResultHref {
                    selectedEpisodeHref = href
                }
                selectedEpisodeActualHref = episode.href
                readyStreams = streams
            }
        } catch {
            if (error as? CancellationError) != nil { return }
            settle(.error(error.localizedDescription))
        }
    }

    func reset() {
        currentTask?.cancel()
        currentTask = nil
        state = .idle
        readyStreams = nil
        runner = nil
        currentSearchResultHref = nil
        cloudflareURL = nil
    }


}

// MARK: - Row View

private struct ModuleStreamRow: View {
    let module: ModuleDefinition
    let mediaId: Int?
    let animeTitle: String
    let episodeNumber: Int
    let onStreamsLoaded: ([StreamResult], StreamResult?, String?, Int?, String?) -> Void

    @ObservedObject var rowVm: ModuleStreamRowViewModel
    let automaticSearch: Bool
    @State private var showAllResults = false
    @State private var showStreamPicker = false
    @AppStorage("autoPickLastStream") private var autoPickLastStream = false

    init(
        module: ModuleDefinition,
        mediaId: Int?,
        animeTitle: String,
        episodeNumber: Int,
        rowVm: ModuleStreamRowViewModel,
        automaticSearch: Bool = true,
        onStreamsLoaded: @escaping ([StreamResult], StreamResult?, String?, Int?, String?) -> Void
    ) {
        self.module = module
        self.mediaId = mediaId
        self.animeTitle = animeTitle
        self.episodeNumber = episodeNumber
        self.onStreamsLoaded = onStreamsLoaded
        self._rowVm = ObservedObject(wrappedValue: rowVm)
        self.automaticSearch = automaticSearch
    }

    private var isPreferredModule: Bool {
        let lastUsed = UserDefaults.standard.string(forKey: "lastUsedModuleId")
        return lastUsed != nil ? lastUsed == module.id : ModuleManager.shared.activeModule?.id == module.id
    }

    private func fireStreamsLoaded(_ streams: [StreamResult], selected: StreamResult?, href: String?, count: Int?, episodeHref: String?) {
        UserDefaults.standard.set(module.id, forKey: "lastUsedModuleId")
        onStreamsLoaded(streams, selected, href, count, episodeHref)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow
            stateContent
        }
        .padding(.vertical, 6)
        .onAppear {
            if automaticSearch { rowVm.startFind() }
        }
        .onDisappear {
            rowVm.cancelIfSearching()
        }
        .onChangeOf(rowVm.readyStreams) { streams in
            guard let streams else { return }
            
            if streams.count == 1 {
                fireStreamsLoaded(streams, selected: streams[0], href: rowVm.selectedEpisodeHref, count: rowVm.availableCount, episodeHref: rowVm.selectedEpisodeActualHref)
            } else if autoPickLastStream,
               isPreferredModule,
               let savedTitle = ModuleSearchAliasManager.shared.getLastStreamTitle(moduleId: module.id),
               let match = streams.first(where: { $0.title == savedTitle }) {
                fireStreamsLoaded(streams, selected: match, href: rowVm.selectedEpisodeHref, count: rowVm.availableCount, episodeHref: rowVm.selectedEpisodeActualHref)
            } else {
                showStreamPicker = true
            }
        }
        .adaptiveSheet(isPresented: $showStreamPicker) {
            if let streams = rowVm.readyStreams {
                ModuleStreamSelectionView(
                    streams: streams,
                    onSelect: { stream in
                        ModuleSearchAliasManager.shared.setLastStreamTitle(moduleId: module.id, title: stream.title)
                        showStreamPicker = false
                        let allStreams = rowVm.readyStreams ?? [stream]
                        fireStreamsLoaded(allStreams, selected: stream, href: rowVm.selectedEpisodeHref, count: rowVm.availableCount, episodeHref: rowVm.selectedEpisodeActualHref)
                    },
                    onDismiss: {
                        showStreamPicker = false
                        rowVm.reset()
                    }
                )
            }
        }
        .adaptiveSheet(isPresented: $showAllResults) {
            if case .searchResults(let items) = rowVm.state {
                SearchResultsPickerSheet(items: items, module: module) { item in
                    showAllResults = false
                    rowVm.startSelectResult(item, targetEpisodeNumber: episodeNumber)
                }
            }
        }
    }

    // MARK: Header

    private var headerRow: some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: module.iconUrl ?? "")) { phase in
                if case .success(let img) = phase {
                    img.resizable().scaledToFill()
                } else {
                    Image(systemName: "puzzlepiece.extension")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 2) {
                Text(module.sourceName)
                    .font(.subheadline).fontWeight(.semibold)
                if let lang = module.language {
                    Text(lang.uppercased())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
            actionButton
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch rowVm.state {
        case .idle:
            Button("Find") { rowVm.startFind() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .foregroundStyle(.primary)

        case .loading, .loadingEpisodes, .loadingStreams:
            Button { rowVm.cancel() } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

        case .searchResults, .selectingEpisode, .notFound, .error:
            Button("Retry") { rowVm.reset(); rowVm.startFind() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .foregroundStyle(.primary)
        }
    }

    // MARK: State content

    @ViewBuilder
    private var stateContent: some View {
        switch rowVm.state {
        case .idle:
            titleField

        case .loading:
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.7)
                Text("Searching \"\(rowVm.searchTitle)\"…")
                    .font(.caption).foregroundStyle(.secondary)
            }

        case .loadingEpisodes(let item):
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.7)
                Text("Loading episodes for \"\(item.title)\"…")
                    .font(.caption).foregroundStyle(.secondary)
            }

        case .loadingStreams:
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.7)
                Text("Fetching streams…")
                    .font(.caption).foregroundStyle(.secondary)
            }

        case .searchResults(let items):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    titleField
                    Button("Show All") { showAllResults = true }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                verifyBanner
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 10) {
                        ForEach(items) { item in
                            Button {
                                rowVm.startSelectResult(item, targetEpisodeNumber: episodeNumber)
                            } label: {
                                SearchResultCard(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.bottom, 2)
                }
            }

        case .selectingEpisode(let episodes):
            VStack(alignment: .leading, spacing: 6) {
                titleField
                verifyBanner
                Text("Episode not auto-matched — pick manually:")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(episodes) { ep in
                            Button("Ep \(ep.displayNumber)") {
                                rowVm.startSelectEpisode(ep)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .foregroundStyle(.primary)
                        }
                    }
                }
            }

        case .notFound:
            VStack(alignment: .leading, spacing: 6) {
                titleField
                if rowVm.cloudflareURL != nil {
                    verifyBanner
                } else {
                    Text("No results found")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

        case .error(let msg):
            VStack(alignment: .leading, spacing: 6) {
                titleField
                Text(msg).font(.caption).foregroundStyle(.primary)
                verifyBanner
            }
        }
    }

    /// Show a non-blocking source error instead of opening a website challenge
    /// over the player. Never treat a protected page as a playable stream.
    @ViewBuilder
    private var verifyBanner: some View {
        if rowVm.cloudflareURL != nil {
            Label("Diese Quelle erfordert eine Website-Bestätigung. Bitte eine andere Quelle wählen oder später erneut versuchen.",
                  systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var titleField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Search title…", text: $rowVm.searchTitle)
                .font(.caption)
                .onSubmit { rowVm.reset(); rowVm.startFind() }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Compact search result card

private struct SearchResultCard: View {
    let item: SearchItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Color.clear
                .aspectRatio(2/3, contentMode: .fit)
                .frame(width: 72)
                .overlay(
                    ZStack {
                        CachedAsyncImage(urlString: item.image)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.5),
                                .init(color: .black.opacity(0.8), location: 1)
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)

            Text(item.title)
                .font(.caption2.weight(.medium))
                .lineLimit(2)
                .frame(width: 72, height: 32, alignment: .topLeading)
                .foregroundStyle(.primary)
        }
        .frame(width: 72)
        .contentShape(Rectangle())
    }
}

// MARK: - Full results picker sheet

private struct SearchResultsPickerSheet: View {
    let items: [SearchItem]
    let module: ModuleDefinition
    let onSelect: (SearchItem) -> Void

    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(items) { item in
                        Button { onSelect(item) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Color.clear
                                    .aspectRatio(2/3, contentMode: .fit)
                                    .overlay(
                                        ZStack {
                                            CachedAsyncImage(urlString: item.image)
                                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                                .clipped()
                                            LinearGradient(
                                                stops: [
                                                    .init(color: .clear, location: 0.5),
                                                    .init(color: .black.opacity(0.85), location: 1)
                                                ],
                                                startPoint: .top, endPoint: .bottom
                                            )
                                        }
                                    )
                                    .overlay(alignment: .bottomLeading) {
                                        Text(item.title)
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.white)
                                            .lineLimit(2)
                                            .padding(.horizontal, 8)
                                            .padding(.bottom, 8)
                                    }
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .shadow(color: .black.opacity(0.3), radius: 5, x: 0, y: 3)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .softScrollEdges()
            .navigationTitle(module.sourceName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        #if os(iOS)
        .adaptivePresentationDetents([.medium, .large])

        #else

        .frame(minWidth: 480, minHeight: 360)

        #endif
    }
}

// MARK: - Stream Selection View

private struct ModuleStreamSelectionView: View {
    let streams: [StreamResult]
    let onSelect: (StreamResult) -> Void
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if streams.isEmpty {
                    ContentUnavailableView(
                        "No Streams Found",
                        systemImage: "antenna.radiowaves.left.and.right.slash",
                        description: Text("Could not find any playable streams for this episode.")
                    )
                } else {
                    List(streams, id: \.url) { stream in
                        Button {
                            onSelect(stream)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 32))
                                    .foregroundStyle(.primary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(stream.title)
                                        .font(.subheadline).fontWeight(.semibold)
                                        .foregroundStyle(.primary)
                                    Text(stream.subtitle != nil ? "Soft subtitles available" : "No soft subtitles")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }
                    .softScrollEdges()
                    #if os(iOS)
                    .listStyle(.insetGrouped)
                    #elseif !os(tvOS)
                    .listStyle(.inset)
                    #endif
                }
            }
            .navigationTitle("Select Stream")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onDismiss)
                }
            }
        }
        #if os(iOS)
        .adaptivePresentationDetents([.medium, .large])

        #else

        .frame(minWidth: 480, minHeight: 360)

        #endif
    }
}
