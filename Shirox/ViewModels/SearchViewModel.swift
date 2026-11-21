import Foundation
import Combine

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var moduleResults: [SearchItem] = []
    @Published var aniListResults: [Media] = []
    @Published var liveActionResults: [LiveActionTitle] = []
    @Published var liveActionLoading = false
    @Published var liveActionError: String?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var query = ""
    @Published var hasSearched = false

    private(set) var isUsingModule = false
    private var searchTask: Task<Void, Never>?
    private var liveActionTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init() {
        ProviderManager.shared.$orderedProviders
            .map { $0.first?.providerType }
            .removeDuplicates { $0 == $1 }
            .dropFirst()
            .sink { [weak self] _ in self?.clearResults() }
            .store(in: &cancellables)
    }

    func search(usingModule: Bool) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { clearResults(); return }
        searchTask?.cancel()
        liveActionTask?.cancel()
        isUsingModule = usingModule
        hasSearched = true
        isLoading = true
        errorMessage = nil
        moduleResults = []
        aniListResults = []
        liveActionResults = []
        liveActionError = nil
        liveActionLoading = true
        // An anime/module failure must not hide an independent live-action result.
        liveActionTask = Task { @MainActor in
            do {
                let results = try await LiveActionCatalog.shared.search(q)
                guard !Task.isCancelled, query.trimmingCharacters(in: .whitespaces) == q else { return }
                liveActionResults = results
            } catch {
                if !Task.isCancelled { liveActionError = error.localizedDescription }
            }
            if !Task.isCancelled { liveActionLoading = false }
        }
        searchTask = Task {
            do {
                if usingModule {
                    CloudflareBypassManager.shared.pendingVerificationURL = nil
                    var res: [SearchItem]
                    do {
                        res = try await moduleSearch(q)
                    } catch {
                        // Modules often swallow a CF wall as a JSON parse error and rethrow.
                        // If a Turnstile host was flagged, fall through to verify; else surface it.
                        guard CloudflareBypassManager.shared.pendingVerificationURL != nil else { throw error }
                        res = []
                    }
                    // The user explicitly searched, so a Cloudflare wall here is solved inline
                    // (auto-verify + retry once) rather than deferred to a button. Verify whenever
                    // a wall was flagged — modules often swallow the CF page and return a bogus
                    // result, so we can't rely on the result being empty.
                    if !Task.isCancelled,
                       let cfURL = CloudflareBypassManager.shared.pendingVerificationURL {
                        try? await CloudflareBypassManager.shared.triggerBypass(for: cfURL)
                        if !Task.isCancelled {
                            CloudflareBypassManager.shared.pendingVerificationURL = nil
                            res = try await moduleSearch(q)
                        }
                    }
                    if !Task.isCancelled {
                        var seen = Set<String>()
                        let deduped = res.filter { seen.insert($0.href).inserted }
                        moduleResults = await NSFWContentFilter.shared.filter(deduped, keyword: q)
                        aniListResults = []
                    }
                } else {
                    let res = try await ProviderManager.shared.call { try await $0.search(q) }
                    if !Task.isCancelled {
                        var seen = Set<String>()
                        aniListResults = res.filter { seen.insert($0.uniqueId).inserted }
                        moduleResults = []
                    }
                }
            } catch {
                if !Task.isCancelled {
                    errorMessage = error.localizedDescription
                }
            }
            if !Task.isCancelled {
                isLoading = false
            }
        }
    }

    /// Manga modules use the Luna contract (raw-object returns); everything
    /// else uses the Sora searchResults path. Both produce [SearchItem].
    private func moduleSearch(_ q: String) async throws -> [SearchItem] {
        if ModuleManager.shared.activeModule?.isManga == true {
            return try await JSEngine.shared.mangaSearch(keyword: q)
        }
        return try await JSEngine.shared.search(keyword: q)
    }

    func clearResults() {
        searchTask?.cancel()
        liveActionTask?.cancel()
        searchTask = nil
        liveActionTask = nil
        moduleResults = []
        aniListResults = []
        liveActionResults = []
        liveActionLoading = false
        liveActionError = nil
        isLoading = false
        errorMessage = nil
        hasSearched = false
    }

    var hasResults: Bool { !moduleResults.isEmpty || !aniListResults.isEmpty || !liveActionResults.isEmpty }
    var resultCount: Int { moduleResults.count + aniListResults.count + liveActionResults.count }
}


// MARK: - Independent live-action catalog
// TVmaze provides TV-series metadata; Apple's Search API provides film metadata.
// These are discovery sources, never streaming endpoints or anime list providers.
enum LiveActionKind: String, Sendable { case series = "Series", movie = "Movie" }

struct LiveActionTitle: Identifiable, Hashable, Sendable {
    let id: String
    let remoteID: Int
    let kind: LiveActionKind
    let name: String
    let posterURL: String?
    let synopsis: String?
    let releaseDate: String?
    let sourceURL: String?
    let requestedSeason: Int?
}

struct LiveActionSeason: Identifiable, Decodable {
    let id: Int
    let number: Int
    let episodeCount: Int?
    let premiereDate: String?
}
enum LiveActionReleaseStatus: Equatable {
    case aired
    case upcoming
    case unknown
}

struct LiveActionEpisode: Identifiable, Decodable {
    let id: Int
    let number: Int?
    let name: String
    let airdate: String?

    /// TVmaze's airdate is YYYY-MM-DD. This indicates whether the announced
    /// broadcast date has passed, NOT whether a video is licensed or playable
    /// in any installed streaming module.
    func releaseStatus(asOf date: Date = Date(), calendar: Calendar = .current) -> LiveActionReleaseStatus {
        guard let airdate,
              airdate.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
        else { return .unknown }

        let parts = airdate.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let day = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              calendar.component(.year, from: day) == parts[0],
              calendar.component(.month, from: day) == parts[1],
              calendar.component(.day, from: day) == parts[2]
        else { return .unknown }
        return day <= calendar.startOfDay(for: date) ? .aired : .upcoming
    }
}

@MainActor
final class LiveActionCatalog {
    static let shared = LiveActionCatalog()
    private init() {}

    static func requestedSeason(in query: String) -> Int? {
        let pattern = #"(?i)\b(?:season|staffel|s)\s*(\d{1,2})\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: query, range: NSRange(query.startIndex..., in: query)),
              let range = Range(match.range(at: 1), in: query) else { return nil }
        return Int(query[range])
    }
    static func seriesQuery(_ query: String) -> String {
        query.replacingOccurrences(of: #"(?i)\s*\b(?:season|staffel|s)\s*\d{1,2}\s*$"#,
                                  with: "", options: .regularExpression)
            .replacingOccurrences(of: "resurrected", with: "resurrection",
                                  options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct ShowHit: Decodable { let show: Show }
    private struct Show: Decodable {
        let id: Int
        let name: String
        let summary: String?
        let premiered: String?
        let url: String?
        let image: Poster?
    }
    private struct Poster: Decodable { let medium: String?; let original: String? }
    private struct FilmResponse: Decodable { let results: [Film] }
    private struct Film: Decodable {
        let trackId: Int?
        let trackName: String?
        let artworkUrl100: String?
        let longDescription: String?
        let shortDescription: String?
        let releaseDate: String?
        let trackViewUrl: String?
    }

    private func read<T: Decodable>(_ url: URL, type: T.Type) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("Shirox/1.0 (TV/movie metadata discovery)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 12
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderError.serverError(http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func search(_ query: String) async throws -> [LiveActionTitle] {
        let season = Self.requestedSeason(in: query)
        let clean = Self.seriesQuery(query)
        async let series = searchShows(clean, season: season)
        async let movies = searchFilms(clean)
        let showResult = await series
        let filmResult = await movies
        try Task.checkCancellation()
        if case .failure(let error) = showResult, case .failure = filmResult { throw error }
        return ((try? showResult.get()) ?? []) + (season == nil ? ((try? filmResult.get()) ?? []) : [])
    }

    private func searchShows(_ query: String, season: Int?) async -> Result<[LiveActionTitle], Error> {
        do {
            var url = URLComponents(string: "https://api.tvmaze.com/search/shows")!
            url.queryItems = [URLQueryItem(name: "q", value: query)]
            let hits: [ShowHit] = try await read(url.url!, type: [ShowHit].self)
            return .success(hits.prefix(20).map { entry in
                LiveActionTitle(id: "tvmaze-\(entry.show.id)", remoteID: entry.show.id,
                                kind: .series, name: entry.show.name,
                                posterURL: entry.show.image?.medium ?? entry.show.image?.original,
                                synopsis: entry.show.summary, releaseDate: entry.show.premiered,
                                sourceURL: entry.show.url, requestedSeason: season)
            })
        } catch { return .failure(error) }
    }

    private func searchFilms(_ query: String) async -> Result<[LiveActionTitle], Error> {
        do {
            var url = URLComponents(string: "https://itunes.apple.com/search")!
            url.queryItems = [
                URLQueryItem(name: "term", value: query),
                URLQueryItem(name: "country", value: "DE"),
                URLQueryItem(name: "media", value: "movie"),
                URLQueryItem(name: "entity", value: "movie"),
                URLQueryItem(name: "limit", value: "20")
            ]
            let response: FilmResponse = try await read(url.url!, type: FilmResponse.self)
            return .success(response.results.compactMap { film in
                guard let id = film.trackId, let name = film.trackName else { return nil }
                return LiveActionTitle(
                    id: "itunes-\(id)", remoteID: id, kind: .movie, name: name,
                    posterURL: film.artworkUrl100,
                    synopsis: film.longDescription ?? film.shortDescription,
                    releaseDate: film.releaseDate, sourceURL: film.trackViewUrl,
                    requestedSeason: nil)
            })
        } catch { return .failure(error) }
    }

    func seasons(showID: Int) async throws -> [LiveActionSeason] {
        try await read(URL(string: "https://api.tvmaze.com/shows/\(showID)/seasons")!,
                       type: [LiveActionSeason].self)
    }
    func episodes(seasonID: Int) async throws -> [LiveActionEpisode] {
        try await read(URL(string: "https://api.tvmaze.com/seasons/\(seasonID)/episodes")!,
                       type: [LiveActionEpisode].self)
    }
}
