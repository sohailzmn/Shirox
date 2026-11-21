import Foundation
import AVFoundation

enum PlaybackLanguagePolicy {
    static func code(_ value: String?) -> String? {
        guard let value else { return nil }
        let name = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if ["de", "deu", "ger", "german", "deutsch", "de-de"].contains(name) { return "de" }
        if ["en", "eng", "english", "englisch", "en-us", "en-gb"].contains(name) { return "en" }
        return nil
    }

    /// Unknown audio is never silently advertised as German. Legacy explicit
    /// GER DUB labels are supported; a generic module name is insufficient.
    static func prepare(_ input: StreamResult) -> StreamResult {
        var stream = input
        if stream.audioLanguage == nil,
           stream.title.range(of: #"(?i)\b(?:GER\s*DUB|German\s*Dub|Deutsch)\b"#,
                              options: .regularExpression) != nil,
           !stream.title.lowercased().contains("sub"),
           !stream.title.lowercased().contains("untertitel") { stream.audioLanguage = "de" }
        let tracks = stream.allSubtitles ?? []
        let selected = tracks.first { code($0.language ?? $0.title) == "de" }
            ?? tracks.first { code($0.language ?? $0.title) == "en" }
        if code(stream.audioLanguage) != "de", let selected {
            return StreamResult(title: stream.title, url: stream.url, headers: stream.headers,
                                subtitle: selected.url.absoluteString, subtitleHeaders: selected.headers,
                                allSubtitles: tracks, audioLanguage: stream.audioLanguage,
                                subtitleLanguage: code(selected.language ?? selected.title),
                                isHardsub: false, resolution: stream.resolution, expiresAt: stream.expiresAt)
        }
        return stream
    }

    static func priority(_ stream: StreamResult) -> Int? {
        if code(stream.audioLanguage) == "de" { return 0 }
        guard stream.isHardsub || stream.subtitleURL != nil else { return nil }
        switch code(stream.subtitleLanguage) {
        case "de": return 1
        case "en": return 2
        default: return nil
        }
    }

    static func label(_ stream: StreamResult) -> String {
        switch priority(prepare(stream)) {
        case 0: return "Deutsche Tonspur"
        case 1: return "Originalton · deutsche Untertitel"
        case 2: return "Originalton · englische Untertitel"
        default: return "Sprache nicht bestätigt"
        }
    }
}

enum AutomaticPlaybackError: LocalizedError {
    case noSource, noMatch, noEpisode, noLanguage, noStream, timeout, websiteBlocked
    var errorDescription: String? {
        switch self {
        case .noSource: return "Keine passende Streamingquelle eingerichtet."
        case .noMatch: return "Dieser Titel wurde in den erreichbaren Quellen nicht eindeutig gefunden."
        case .noEpisode: return "Die angeforderte Staffel und Folge wurde in der Quelle nicht bestätigt."
        case .noLanguage: return "Keine deutsche Tonspur oder passende deutsche/englische Untertitel gefunden."
        case .noStream: return "Die geprüften Quellen liefern derzeit kein erreichbares Video."
        case .timeout: return "Die Quellen antworten zu langsam. Bitte später erneut versuchen."
        case .websiteBlocked: return "Die Quelle verlangt eine Website-Prüfung. Keine verfügbare Alternative gefunden."
        }
    }
}

struct AutomaticPlaybackRequest {
    var catalogID: String? = nil
    let title: String
    var aliases: [String] = []
    var kind: CatalogKind = .anime
    var animeID: Int? = nil
    var seasonIsExplicit = false
    var season = 1
    var episode = 1
    var detailHref: String? = nil
    var episodeHref: String? = nil
    var moduleID: String? = nil
}

struct AutomaticPlaybackResult {
    let streams: [StreamResult]
    let module: ModuleDefinition
    let detailHref: String
    let episode: EpisodeLink
    let episodes: [EpisodeLink]
    var selected: StreamResult { streams[0] }
}

/// All remote entry points share this coordinator. Existing local/Jellyfin
/// playback retains its own authentication and local-network routing.
@MainActor
final class AutomaticPlaybackCoordinator {
    static let shared = AutomaticPlaybackCoordinator()

    func resolve(_ request: AutomaticPlaybackRequest,
                 status: ((String) -> Void)? = nil) async throws -> AutomaticPlaybackResult {
        try await PlaybackDeadline.run(seconds: 30) {
            try await self.resolveWithinDeadline(request, status: status)
        }
    }

    private func resolveWithinDeadline(_ request: AutomaticPlaybackRequest,
                                       status: ((String) -> Void)?) async throws -> AutomaticPlaybackResult {
        let started = Date()
        let seasonOffset: Int
        if request.kind == .anime, let id = request.animeID, !request.seasonIsExplicit {
            seasonOffset = (try? await PlaybackDeadline.run(seconds: 3) {
                await SeasonChainMapper.shared.resolveOffset(anchorAniListID: id, anchorMALID: nil) ?? 0
            }) ?? 0
        } else { seasonOffset = 0 }
        var modules = ModuleManager.shared.modules.filter { !$0.isManga && !$0.isLocalPlayback && !$0.isJellyfin }
        if modules.isEmpty {
            await ModuleManager.shared.ensureUnifiedGermanSource()
            modules = ModuleManager.shared.modules.filter { !$0.isManga && !$0.isLocalPlayback && !$0.isJellyfin }
        }
        guard !modules.isEmpty else { throw AutomaticPlaybackError.noSource }
        modules.sort {
            func rank(_ module: ModuleDefinition) -> Int {
                if module.id == request.moduleID { return 0 }
                if module.sourceName.contains("Unified GER") { return 1 }
                let name = module.sourceName.lowercased()
                if request.kind == .anime && name.contains("aniworld") { return 2 }
                if request.kind != .anime && (name.contains("serienstream") || name.contains("s.to")) { return 2 }
                return 3
            }
            return rank($0) < rank($1)
        }
        var lastError: Error = AutomaticPlaybackError.noMatch
        for module in modules.prefix(3) {
            try Task.checkCancellation()
            status?("Passende Quelle wird gesucht …")
            let runner = ModuleJSRunner()
            do {
                try await PlaybackDeadline.run(seconds: 5) { try await runner.load(module: module) }
                var items: [SearchItem] = []
                if module.id == request.moduleID, let href = request.detailHref {
                    items = [SearchItem(title: request.title, image: "", href: href)]
                } else {
                    let queries = Array(ModuleSeasonFallback.queries(for: request.title, alternatives: request.aliases).prefix(2))
                    for query in queries {
                        let found = try await PlaybackDeadline.run(seconds: 5) { try await runner.search(keyword: query) }
                        items += found.filter { item in
                            CatalogModuleTitleMatch.matches(candidateTitle: item.title, requestedTitle: request.title)
                                || request.aliases.contains { alias in
                                    CatalogModuleTitleMatch.matches(candidateTitle: item.title, requestedTitle: alias)
                                }
                        }
                        if !items.isEmpty { break }
                    }
                    if items.count > 1 {
                        items = await JevDecisionEngine.shared.rankCandidates(items, query: request.title, season: request.season)
                    }
                }
                var visited = Set<String>()
                for item in items where visited.insert(item.href).inserted {
                    // Unified search covers both catalogues; never ask an anime
                    // URL to stand in for an unrelated live-action episode.
                    if request.kind != .anime && item.href.contains("aniworld.to") { continue }
                    status?("Staffel und Folge werden geprüft …")
                    let episodes: [EpisodeLink]
                    let episode: EpisodeLink
                    if let href = request.episodeHref, module.id == request.moduleID {
                        // A direct source row already identifies the requested episode.
                        episode = EpisodeLink(number: Double(request.episode), href: href)
                        episodes = []
                    } else {
                        episodes = try await PlaybackDeadline.run(seconds: 8) { try await runner.fetchEpisodes(url: item.href) }
                        if request.kind == .anime, seasonOffset > 0,
                           let exact = EpisodeNavigator.resolve(href: nil, orNumber: seasonOffset + request.episode, in: episodes) {
                            episode = exact
                        } else if request.kind == .anime, seasonOffset > 0 {
                            // An unresolved sequel must never silently play S1 E1.
                            lastError = AutomaticPlaybackError.noEpisode; continue
                        } else if let exact = ModuleSeasonRouting.exactEpisode(episodes, season: request.season, episode: request.episode) {
                            episode = exact
                        } else if request.kind == .movie, episodes.count == 1, let only = episodes.first {
                            episode = only
                        } else if request.kind == .anime, request.season == 1,
                                  let exact = EpisodeNavigator.resolve(href: nil, orNumber: request.episode, in: episodes),
                                  ModuleSeasonRouting.seasonNumber(for: exact.href).map({ $0 == 1 }) ?? true {
                            episode = exact
                        } else { lastError = AutomaticPlaybackError.noEpisode; continue }
                    }
                    status?("Tonspur und Video werden geprüft …")
                    let streams = try await self.streams(runner: runner, episodeHref: episode.href, legacyModule: module)
                    guard !streams.isEmpty else { continue }
                    if let id = request.catalogID {
                        CatalogAvailabilityStore.shared.bind(id: id, sourceHref: episode.href)
                        CatalogAvailabilityStore.shared.set(id: id, state: .reachable)
                    }
                    Logger.shared.log("[AutoPlay] source=\(module.sourceName) stage=resolved ms=\(Int(Date().timeIntervalSince(started)*1000))", type: "Player")
                    return AutomaticPlaybackResult(streams: streams, module: module,
                                                   detailHref: item.href, episode: episode, episodes: episodes)
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                lastError = error
                Logger.shared.log("[AutoPlay] source=\(module.sourceName) stage=unavailable", type: "Player")
            }
        }
        if lastError is ModuleStreamResolutionError { throw AutomaticPlaybackError.websiteBlocked }
        throw lastError
    }

    func streams(runner: ModuleJSRunner, episodeHref: String, legacyModule: ModuleDefinition? = nil) async throws -> [StreamResult] {
        if legacyModule?.scriptContent?.contains("__SHIROX_LANGUAGE_CONTRACT_V2") == true {
            var lastError: Error = AutomaticPlaybackError.noStream
            for language in 0...2 {
                try Task.checkCancellation()
                do {
                    return try await PlaybackDeadline.run(seconds: 10) {
                        let raw = try await runner.fetchStreams(episodeUrl: episodeHref, languagePriority: language, preflight: false)
                        let candidates = raw.map(PlaybackLanguagePolicy.prepare).filter { PlaybackLanguagePolicy.priority($0) == language }
                        return try await self.verified(candidates, legacyModule: legacyModule)
                    }
                } catch is CancellationError { throw CancellationError() }
                catch let error as ModuleStreamResolutionError { throw error }
                catch { lastError = error }
            }
            throw lastError
        }
        let raw = try await PlaybackDeadline.run(seconds: 25) { try await runner.fetchStreams(episodeUrl: episodeHref, preflight: false) }
        return try await verified(raw, legacyModule: legacyModule)
    }

    func verified(_ raw: [StreamResult], legacyModule: ModuleDefinition? = nil) async throws -> [StreamResult] {
        if legacyModule?.isLocalPlayback == true || legacyModule?.isJellyfin == true { return raw }
        var seen = Set<URL>()
        let prepared = raw.map(PlaybackLanguagePolicy.prepare).filter {
            ($0.expiresAt.map { $0 > Date().addingTimeInterval(5) } ?? true) && seen.insert($0.url).inserted
        }
        let candidates = prepared.filter { PlaybackLanguagePolicy.priority($0) != nil }
        guard !candidates.isEmpty else { throw raw.isEmpty ? AutomaticPlaybackError.noStream : AutomaticPlaybackError.noLanguage }
        for language in 0...2 {
            let group = Array(candidates.filter { PlaybackLanguagePolicy.priority($0) == language }.prefix(3))
            if group.isEmpty { continue }
            let verified = await withTaskGroup(of: (StreamResult, Double)?.self, returning: [StreamResult].self) { tasks in
                for candidate in group {
                    tasks.addTask {
                        let start = Date()
                        do {
                            guard try await StreamPreflight.check(candidate) else { return nil }
                            return (candidate, Date().timeIntervalSince(start))
                        } catch { return nil }
                    }
                }
                var results: [(StreamResult, Double)] = []
                for await result in tasks { if let result { results.append(result) } }
                return results.sorted { $0.1 < $1.1 }.map { $0.0 }
            }
            if !verified.isEmpty { return verified }
        }
        throw AutomaticPlaybackError.noStream
    }
}

/// An unstructured race is necessary: a legacy JS promise can ignore task
/// cancellation. The caller must still finish at its deadline, exactly once.
@MainActor
enum PlaybackDeadline {
    private final class Race<T> {
        var continuation: CheckedContinuation<T, Error>?
        var operation: Task<Void, Never>?
        var timer: Task<Void, Never>?
        func finish(_ result: Result<T, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            operation?.cancel(); timer?.cancel()
            continuation.resume(with: result)
        }
    }
    static func run<T>(seconds: Double, operation: @escaping @MainActor () async throws -> T) async throws -> T {
        let race = Race<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.continuation = continuation
                if Task.isCancelled { race.finish(.failure(CancellationError())); return }
                race.operation = Task {
                    do { race.finish(.success(try await operation())) }
                    catch { race.finish(.failure(error)) }
                }
                race.timer = Task {
                    do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
                    catch { return }
                    race.finish(.failure(AutomaticPlaybackError.timeout))
                }
            }
        } onCancel: { Task { @MainActor in race.finish(.failure(CancellationError())) } }
    }
}

enum StreamPreflight {
    static func validRemoteURL(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), host.contains("."), !host.contains(":"),
              host != "localhost", !host.hasSuffix(".local") else { return false }
        let components = host.split(separator: ".").compactMap { Int($0) }
        if components.count == 4 {
            if [0, 10, 127].contains(components[0]) || components[0] >= 224 { return false }
            if components[0] == 192 && components[1] == 168 { return false }
            if components[0] == 169 && components[1] == 254 { return false }
            if components[0] == 172 && (16...31).contains(components[1]) { return false }
        }
        return true
    }

    /// Streaming the response bounds memory/network use even if a CDN ignores Range.
    private static func read(_ url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
        guard validRemoteURL(url) else { throw URLError(.badURL) }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, timeoutInterval: 3)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.setValue("bytes=0-131071", forHTTPHeaderField: "Range")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let final = http.url, validRemoteURL(final) else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            data.append(byte)
            if data.count >= 131072 { break }
        }
        return (data, http)
    }

    static func isPlaylist(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}"))).hasPrefix("#EXTM3U")
    }
    static func mediaBytes(_ data: Data) -> Bool {
        guard data.count >= 16 else { return false }
        let prefix = String(decoding: data.prefix(64), as: UTF8.self).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return !prefix.hasPrefix("<") && !prefix.hasPrefix("{") && !prefix.hasPrefix("#extm3u")
    }

    static func check(_ stream: StreamResult) async throws -> Bool {
        let (data, response) = try await read(stream.url, headers: stream.headers)
        if isPlaylist(data) {
            guard try await checkPlaylist(data, url: stream.url, headers: stream.headers, depth: 0) else { return false }
            return try await checkSubtitle(stream)
        }
        guard response.mimeType?.hasPrefix("video/") == true, mediaBytes(data) else { return false }
        return try await checkSubtitle(stream)
    }

    private static func checkSubtitle(_ stream: StreamResult) async throws -> Bool {
        guard PlaybackLanguagePolicy.code(stream.audioLanguage) != "de", !stream.isHardsub,
              let url = stream.subtitleURL else { return true }
        let (data, _) = try await read(url, headers: stream.subtitleHeaders)
        let text = String(decoding: data, as: UTF8.self)
        return text.contains("-->") && !text.lowercased().contains("<html")
    }

    private static func checkPlaylist(_ data: Data, url: URL, headers: [String: String], depth: Int) async throws -> Bool {
        guard depth < 3, isPlaylist(data) else { return false }
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if text.contains("METHOD=SAMPLE-AES") { return false }
        guard let path = lines.first(where: { !$0.isEmpty && !$0.hasPrefix("#") }),
              let next = URL(string: path, relativeTo: url)?.absoluteURL else { return false }
        let (content, _) = try await read(next, headers: headers)
        if text.contains("#EXT-X-STREAM-INF") {
            guard try await checkPlaylist(content, url: next, headers: headers, depth: depth + 1) else { return false }
            // A separate audio rendition must be reachable too.
            if let audio = lines.first(where: { $0.hasPrefix("#EXT-X-MEDIA:") && $0.contains("TYPE=AUDIO") && $0.contains("URI=") }),
               let range = audio.range(of: #"URI="([^"]+)""#, options: .regularExpression) {
                let value = String(audio[range]).dropFirst(5).dropLast()
                guard let audioURL = URL(string: String(value), relativeTo: url)?.absoluteURL else { return false }
                let (audioData, _) = try await read(audioURL, headers: headers)
                return try await checkPlaylist(audioData, url: audioURL, headers: headers, depth: depth + 1)
            }
            return true
        }
        return text.contains("#EXTINF:") && mediaBytes(content)
    }
}
