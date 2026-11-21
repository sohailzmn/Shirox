import Foundation
import Combine
import Security

enum CatalogKind: String, Codable, CaseIterable, Sendable {
    case series, anime, movie
    var label: String { switch self { case .series: return "Serien"; case .anime: return "Anime"; case .movie: return "Filme" } }
}

enum SourceCatalogRouting {
    static func kind(for href: String) -> CatalogKind? {
        guard let url = URL(string: href), let host = url.host?.lowercased() else { return nil }
        let name = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if ["aniworld.to", "aniworld.cc"].contains(name), url.path.hasPrefix("/anime/stream/") { return .anime }
        if ["s.to", "serienstream.to", "serienstream.cx"].contains(name), url.path.hasPrefix("/serie/") { return .series }
        return nil
    }
    static func accepts(_ href: String, kind: CatalogKind) -> Bool { self.kind(for: href) == kind }
    static func acceptsModule(_ module: ModuleDefinition, kind: CatalogKind) -> Bool {
        let name = module.sourceName.lowercased()
        if name.contains("unified") { return kind != .movie }
        if name.contains("aniworld") { return kind == .anime }
        if name.contains("serienstream") || name.contains("s.to") { return kind == .series }
        return true
    }
}

/// Source-backed shelves need no metadata API key. A listed title is not a
/// playback guarantee; the exact episode and media are still checked on Play.
@MainActor
final class SourceCatalog: ObservableObject {
    static let shared = SourceCatalog()
    @Published var rows: [CatalogRow] = []
    @Published var errors: [String] = []
    @Published var loading = false
    private var loadedAt: Date?
    func load() async {
        guard !loading else { return }
        if let loadedAt, Date().timeIntervalSince(loadedAt) < 300 { return }
        guard let module = BundledUnifiedSource.module else { return }
        loading = true
        defer { loading = false }
        errors = []
        async let anime = fetchTitles(kind: .anime, module: module)
        async let series = fetchTitles(kind: .series, module: module)
        let animeTitles = await anime
        publish(animeTitles, kind: .anime)
        let seriesTitles = await series
        publish(seriesTitles, kind: .series)
        rows.sort { $0.id < $1.id }
        loadedAt = Date()
    }
    private func fetchTitles(kind: CatalogKind, module: ModuleDefinition) async -> [CatalogTitle] {
        do {
            let items: [SearchItem] = try await PlaybackDeadline.run(seconds: 15) {
                let runner = ModuleJSRunner()
                try await runner.load(module: module)
                return try await runner.sourceCatalog(kind: kind)
            }
            return items.filter { SourceCatalogRouting.accepts($0.href, kind: kind) }.map { item in
                CatalogTitle(id: "source-" + item.href, remoteID: 0, kind: kind, name: item.title,
                             poster: item.image, sourceHref: item.href, moduleID: module.id)
            }
        } catch { return [] }
    }
    private func publish(_ titles: [CatalogTitle], kind: CatalogKind) {
        let rowID = "source-" + kind.rawValue
        rows.removeAll { $0.id == rowID }
        if titles.isEmpty {
            errors.append(kind == .anime ? "AniWorld ist derzeit nicht erreichbar oder liefert keine Titel." : "SerienStream ist derzeit nicht erreichbar oder liefert keine Titel.")
        } else {
            rows.append(CatalogRow(id: rowID, name: kind == .anime ? "Auf AniWorld" : "Auf SerienStream", titles: titles))
        }
    }

}

struct CatalogTitle: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let remoteID: Int
    let kind: CatalogKind
    let name: String
    var originalName: String? = nil
    var poster: String? = nil
    var backdrop: String? = nil
    var synopsis: String? = nil
    var year: String? = nil
    var score: Double? = nil
    var genres: [String] = []
    var anime: Media? = nil
    var sourceHref: String? = nil
    var moduleID: String? = nil

    static func anime(_ media: Media) -> CatalogTitle {
        CatalogTitle(id: media.uniqueId, remoteID: media.id, kind: .anime, name: media.title.displayTitle,
                     originalName: media.title.romaji, poster: media.coverImage.large,
                     backdrop: media.bannerImage, synopsis: nil,
                     year: media.seasonYear.map(String.init), score: media.averageScore.map { Double($0) / 10 },
                     genres: media.genres ?? [], anime: media)
    }
    var isTMDB: Bool { id.hasPrefix("tmdb-") }
    var tmdbType: String { kind == .movie ? "movie" : "tv" }
}

struct CatalogSeason: Identifiable, Codable, Sendable {
    var id: Int { number }
    let number: Int
    let name: String
    let episodeCount: Int
}
struct CatalogEpisode: Identifiable, Codable, Sendable {
    var id: Int { number }
    let number: Int
    let name: String
    let airDate: String?
    var knownReleased: Bool? = nil
    var released: Bool {
        if let knownReleased { return knownReleased }
        guard let airDate, airDate.count == 10 else { return false }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: airDate) else { return false }
        return date <= Date()
    }
}
struct CatalogRow: Identifiable {
    let id: String
    let name: String
    let titles: [CatalogTitle]
}

/// Dedicated device-only credentials; neither credentials nor signed source
/// URLs are stored in the catalogue cache or checked into a build.
@MainActor
final class CatalogConfiguration: ObservableObject {
    static let shared = CatalogConfiguration()
    @Published private(set) var hasToken = false
    @Published var message: String?
    private let service = "com.shirox.catalog.tmdb"
    private init() { FreshInstallKeychainPurge.runIfNeeded(); hasToken = token != nil }
    var token: String? {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                     kSecAttrAccount: "read-token", kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }
    func save(_ raw: String) {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 20, !value.contains(where: { $0.isWhitespace }) else {
            message = "Bitte einen gültigen TMDB-Lesezugang eingeben."; return
        }
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: "read-token"]
        let data = Data(value.utf8)
        var status = SecItemAdd(query.merging([kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]) { _, new in new } as CFDictionary, nil)
        if status == errSecDuplicateItem { status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary) }
        hasToken = status == errSecSuccess
        message = hasToken ? "Katalogzugang auf diesem Gerät gespeichert." : "Katalogzugang konnte nicht gespeichert werden."
    }
    func remove() {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: "read-token"] as CFDictionary)
        hasToken = false; message = "Katalogzugang entfernt. Streamingmodule bleiben verfügbar."
    }
}

enum CatalogAvailability: String, Codable {
    case unknown, reachable, played, unavailable
    var label: String {
        switch self {
        case .unknown: return "Noch nicht geprüft"
        case .reachable: return "Quelle geprüft"
        case .played: return "Zuletzt abgespielt"
        case .unavailable: return "Derzeit keine Quelle bestätigt"
        }
    }
}

@MainActor
final class CatalogAvailabilityStore: ObservableObject {
    static let shared = CatalogAvailabilityStore()
    private struct Entry: Codable { let state: CatalogAvailability; let date: Date }
    @Published private var entries: [String: Entry] = [:]
    private var bindings: [String: String] = [:]
    private let key = "catalogAvailabilityV2"
    private init() {
        if let data = UserDefaults.standard.data(forKey: key), let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) { entries = decoded }
    }
    func state(_ id: String) -> CatalogAvailability {
        guard let entry = entries[id], Date().timeIntervalSince(entry.date) < (entry.state == .unavailable ? 900 : 86400) else { return .unknown }
        return entry.state
    }
    func set(id: String, state: CatalogAvailability) {
        entries[id] = Entry(state: state, date: Date())
        entries = entries.filter { Date().timeIntervalSince($0.value.date) < 86400 }
        if let data = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(data, forKey: key) }
    }
    func bind(id: String, sourceHref: String) { bindings[sourceHref] = id }
    func recordPlayback(context: PlayerContext?) {
        guard let context else { return }
        if let href = context.episodeHref, let id = bindings[href], state(id) != .played { set(id: id, state: .played) }
        if let id = context.aniListID, state("anilist-\(id)") != .played { set(id: "anilist-\(id)", state: .played) }
    }
    func rank(_ titles: [CatalogTitle]) -> [CatalogTitle] {
        // Preserve the published chart's order within each availability group.
        var weights: [String: Int] = [:]
        for title in titles {
            switch state(title.id) {
            case .played: weights[title.id] = 0
            case .reachable: weights[title.id] = 1
            case .unknown: weights[title.id] = 2
            case .unavailable: weights[title.id] = 3
            }
        }
        return titles.enumerated().sorted {
            let a = weights[$0.element.id] ?? 2, b = weights[$1.element.id] ?? 2
            return a == b ? $0.offset < $1.offset : a < b
        }.map { $0.element }
    }
}

@MainActor
final class CatalogWatchlist: ObservableObject {
    static let shared = CatalogWatchlist()
    @Published private(set) var titles: [CatalogTitle] = []
    private let key = "catalogWatchlistV2"
    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([CatalogTitle].self, from: data) { titles = saved }
    }
    func contains(_ title: CatalogTitle) -> Bool { titles.contains { $0.id == title.id } }
    func toggle(_ title: CatalogTitle) {
        if contains(title) { titles.removeAll { $0.id == title.id } }
        else { titles.insert(title, at: 0) }
        if let data = try? JSONEncoder().encode(titles) { UserDefaults.standard.set(data, forKey: key) }
    }
}

enum CatalogError: LocalizedError {
    case configuration, response
    var errorDescription: String? {
        switch self {
        case .configuration: return "Für deutsche Serien- und Film-Toplisten fehlt der kostenlose TMDB-Katalogzugang. Er lässt sich einmalig in den Einstellungen einrichten. Die Quellensuche bleibt verfügbar."
        case .response: return "Der Katalog ist momentan nicht erreichbar. Gespeicherte Titel und Quellen bleiben verfügbar."
        }
    }
}

@MainActor
final class UnifiedCatalog: ObservableObject {
    static let shared = UnifiedCatalog()
    @Published var rows: [CatalogRow] = []
    @Published var loading = false
    @Published var error: String?
    private struct Cached: Codable { let date: Date; let data: Data }
    private var cache: [String: Cached] = [:]
    private var germanDescriptions: [String: String] = [:]
    private init() {
        germanDescriptions = UserDefaults.standard.dictionary(forKey: "catalogGermanDescriptionsV2") as? [String: String] ?? [:]
        if let data = UserDefaults.standard.data(forKey: "catalogMetadataV2"), let saved = try? JSONDecoder().decode([String: Cached].self, from: data) { cache = saved }
    }

    func germanDescription(_ title: CatalogTitle) async -> String? {
        if let cached = germanDescriptions[title.id] { return cached }
        guard title.kind == .anime,
              let module = ModuleManager.shared.modules.first(where: { $0.sourceName.contains("Unified GER") }) else { return nil }
        let result: String? = try? await PlaybackDeadline.run(seconds: 5) {
            let runner = ModuleJSRunner(); try await runner.load(module: module)
            let matches = try await runner.search(keyword: title.name, kind: .anime)
            guard let match = matches.first(where: { CatalogModuleTitleMatch.matches(candidateTitle: $0.title, requestedTitle: title.name) }) else { return nil }
            return try await runner.sourceDescription(url: match.href)
        }
        if let result {
            if germanDescriptions.count >= 200 { germanDescriptions.removeAll() }
            germanDescriptions[title.id] = result
            UserDefaults.standard.set(germanDescriptions, forKey: "catalogGermanDescriptionsV2")
        }
        return result
    }

    struct TMDBPage: Decodable { let results: [TMDBTitle] }
    struct TMDBTitle: Decodable {
        let id: Int
        let name: String?
        let title: String?
        let original_name: String?
        let original_title: String?
        let poster_path: String?
        let backdrop_path: String?
        let overview: String?
        let first_air_date: String?
        let release_date: String?
        let vote_average: Double?
        let genre_ids: [Int]?
        func mapped(kind: CatalogKind) -> CatalogTitle {
            CatalogTitle(id: "tmdb-\(kind == .movie ? "movie" : "tv")-\(id)", remoteID: id, kind: kind,
                         name: name ?? title ?? original_name ?? original_title ?? "Unbekannter Titel",
                         originalName: original_name ?? original_title,
                         poster: poster_path.map { "https://image.tmdb.org/t/p/w342" + $0 },
                         backdrop: backdrop_path.map { "https://image.tmdb.org/t/p/w780" + $0 },
                         synopsis: overview, year: (first_air_date ?? release_date).map { String($0.prefix(4)) }, score: vote_average)
        }
    }
    private struct TMDBDetail: Decodable {
        let seasons: [Season]?
        struct Season: Decodable { let season_number: Int; let name: String; let episode_count: Int }
    }
    private struct GenreList: Decodable {
        let genres: [Genre]
        struct Genre: Decodable { let id: Int; let name: String }
    }
    private func titles(_ page: TMDBPage, kind: CatalogKind) async -> [CatalogTitle] {
        let genres = try? await read("genre/\(kind == .movie ? "movie" : "tv")/list", as: GenreList.self)
        let names = Dictionary(uniqueKeysWithValues: (genres?.genres ?? []).map { ($0.id, $0.name) })
        return page.results.map { item in
            var title = item.mapped(kind: kind)
            title.genres = (item.genre_ids ?? []).compactMap { names[$0] }
            return title
        }
    }
    private struct TMDBEpisodes: Decodable {
        let episodes: [Episode]
        struct Episode: Decodable { let episode_number: Int; let name: String; let air_date: String? }
    }

    private func read<T: Decodable>(_ path: String, query: [URLQueryItem] = [], as type: T.Type) async throws -> T {
        var components = URLComponents(string: "https://api.themoviedb.org/3/" + path)!
        components.queryItems = [URLQueryItem(name: "language", value: "de-DE"), URLQueryItem(name: "include_adult", value: "false")] + query
        let key = components.url!.absoluteString
        if let saved = cache[key], Date().timeIntervalSince(saved.date) < 86400,
           let result = try? JSONDecoder().decode(type, from: saved.data) { return result }
        guard let token = CatalogConfiguration.shared.token else { throw CatalogError.configuration }
        var request = URLRequest(url: components.url!, timeoutInterval: 8)
        if token.contains(".") { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        else {
            components.queryItems?.append(URLQueryItem(name: "api_key", value: token))
            request.url = components.url
        }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) }
        catch {
            if let saved = cache[key], let result = try? JSONDecoder().decode(type, from: saved.data) { return result }
            throw CatalogError.response
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            if let saved = cache[key], let result = try? JSONDecoder().decode(type, from: saved.data) { return result }
            throw CatalogError.response
        }
        let result = try JSONDecoder().decode(type, from: data)
        cache[key] = Cached(date: Date(), data: data)
        if cache.count > 120 { cache = cache.filter { Date().timeIntervalSince($0.value.date) < 86400 } }
        if let saved = try? JSONEncoder().encode(cache) { UserDefaults.standard.set(saved, forKey: "catalogMetadataV2") }
        return result
    }

    func load() async {
        guard !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        var output: [CatalogRow] = []
        for (path, label, kind) in [("tv/popular", "Beliebte Serien", CatalogKind.series),
                                    ("tv/top_rated", "Top bewertete Serien", .series),
                                    ("movie/popular", "Beliebte Filme", .movie)] {
            do {
                let page = try await read(path, as: TMDBPage.self)
                output.append(CatalogRow(id: path, name: label, titles: await titles(page, kind: kind)))
            } catch { self.error = error.localizedDescription }
        }
        rows = output
    }

    func search(_ query: String) async throws -> [CatalogTitle] {
        var output: [CatalogTitle] = []
        var lastError: Error?
        for kind in [CatalogKind.series, .movie] {
            do {
                let page = try await read("search/\(kind == .movie ? "movie" : "tv")",
                                          query: [URLQueryItem(name: "query", value: LiveActionCatalog.seriesQuery(query))], as: TMDBPage.self)
                output += await titles(page, kind: kind)
            } catch { lastError = error }
        }
        if output.isEmpty, let lastError { throw lastError }
        return output
    }
    func seasons(_ title: CatalogTitle) async throws -> [CatalogSeason] {
        guard title.isTMDB, title.kind != .movie else { return [] }
        let detail = try await read("tv/\(title.remoteID)", as: TMDBDetail.self)
        return (detail.seasons ?? []).filter { $0.season_number > 0 }.map {
            CatalogSeason(number: $0.season_number, name: "Staffel \($0.season_number)", episodeCount: $0.episode_count)
        }
    }
    func episodes(_ title: CatalogTitle, season: Int) async throws -> [CatalogEpisode] {
        let detail = try await read("tv/\(title.remoteID)/season/\(season)", as: TMDBEpisodes.self)
        return detail.episodes.map { CatalogEpisode(number: $0.episode_number, name: $0.name, airDate: $0.air_date) }
    }
}
