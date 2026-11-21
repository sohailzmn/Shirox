import Foundation
import Combine
import Security

enum CatalogKind: String, Codable, CaseIterable, Sendable {
    case series, anime, movie
    var label: String { switch self { case .series: return "Serien"; case .anime: return "Anime"; case .movie: return "Filme" } }
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
                     backdrop: media.bannerImage, synopsis: media.plainDescription,
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
    var released: Bool {
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
    private init() { hasToken = token != nil }
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
        guard let entry = entries[id], Date().timeIntervalSince(entry.date) < 86400 else { return .unknown }
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
        if let href = context.episodeHref, let id = bindings[href] { set(id: id, state: .played) }
        if let id = context.aniListID { set(id: "anilist-\(id)", state: .played) }
    }
    func rank(_ titles: [CatalogTitle]) -> [CatalogTitle] {
        // Preserve the published chart's order within each availability group.
        titles.enumerated().sorted {
            func weight(_ title: CatalogTitle) -> Int {
                switch state(title.id) { case .played: return 0; case .reachable: return 1; case .unknown: return 2; case .unavailable: return 3 }
            }
            let a = weight($0.element), b = weight($1.element)
            return a == b ? $0.offset < $1.offset : a < b
        }.map { $0.element }
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
    private init() {
        if let data = UserDefaults.standard.data(forKey: "catalogMetadataV2"), let saved = try? JSONDecoder().decode([String: Cached].self, from: data) { cache = saved }
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
        let (data, response) = try await URLSession.shared.data(for: request)
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
                output.append(CatalogRow(id: path, name: label, titles: page.results.map { $0.mapped(kind: kind) }))
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
                output += page.results.map { $0.mapped(kind: kind) }
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
