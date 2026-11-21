import Foundation
import Combine
import Security

final class ModuleSearchAliasManager: ObservableObject {
    nonisolated(unsafe) static let shared = ModuleSearchAliasManager()
    
    private let userDefaults = UserDefaults.standard
    private let keyPrefix = "moduleSearchAlias_"
    
    private init() {}
    
    private func key(mediaId: Int?, animeTitle: String, moduleId: String) -> String {
        // Use a stable base64 encoding for the URL so it's a valid key
        let moduleKey = moduleId.data(using: .utf8)?.base64EncodedString() ?? moduleId
        
        if let mediaId = mediaId {
            return "\(keyPrefix)\(mediaId)_\(moduleKey)"
        } else {
            // Use a stable, sanitized version of the title
            let safeTitle = animeTitle.lowercased()
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: " ", with: "_")
                .filter { $0.isLetter || $0.isNumber || $0 == "_" }
            
            return "\(keyPrefix)title_\(safeTitle)_\(moduleKey)"
        }
    }
    
    func getAlias(mediaId: Int?, animeTitle: String, moduleId: String) -> String? {
        let k = key(mediaId: mediaId, animeTitle: animeTitle, moduleId: moduleId)
        return userDefaults.string(forKey: k)
    }
    
    func setAlias(mediaId: Int?, animeTitle: String, moduleId: String, alias: String) {
        let k = key(mediaId: mediaId, animeTitle: animeTitle, moduleId: moduleId)
        let trimmed = alias.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            userDefaults.removeObject(forKey: k)
        } else {
            userDefaults.set(trimmed, forKey: k)
        }
        objectWillChange.send()
    }

    // MARK: - Last picked search result href

    private func searchResultKey(mediaId: Int?, animeTitle: String, moduleId: String) -> String {
        "moduleLastSearchResult_" + key(mediaId: mediaId, animeTitle: animeTitle, moduleId: moduleId)
    }

    func getLastSearchResultHref(mediaId: Int?, animeTitle: String, moduleId: String) -> String? {
        userDefaults.string(forKey: searchResultKey(mediaId: mediaId, animeTitle: animeTitle, moduleId: moduleId))
    }

    func setLastSearchResultHref(mediaId: Int?, animeTitle: String, moduleId: String, href: String) {
        let key = searchResultKey(mediaId: mediaId, animeTitle: animeTitle, moduleId: moduleId)
        if href.isEmpty {
            userDefaults.removeObject(forKey: key)
        } else {
            userDefaults.set(href, forKey: key)
        }
    }

    // MARK: - Last picked stream title per module

    private func streamTitleKey(moduleId: String) -> String {
        let moduleKey = moduleId.data(using: .utf8)?.base64EncodedString() ?? moduleId
        return "moduleLastStreamTitle_\(moduleKey)"
    }

    func getLastStreamTitle(moduleId: String) -> String? {
        userDefaults.string(forKey: streamTitleKey(moduleId: moduleId))
    }

    func setLastStreamTitle(moduleId: String, title: String) {
        userDefaults.set(title, forKey: streamTitleKey(moduleId: moduleId))
    }

    func clearAll() {
        let prefixes = [keyPrefix, "moduleLastSearchResult_", "moduleLastStreamTitle_"]
        let allKeys = userDefaults.dictionaryRepresentation().keys
        for key in allKeys where prefixes.contains(where: { key.hasPrefix($0) }) {
            userDefaults.removeObject(forKey: key)
        }
        objectWillChange.send()
    }
}


/// In-memory session diagnostics. Tracks the moment an episode is tapped, source
/// lookup, resolved stream and the video layer becoming ready for display.
/// Unlike "AVPlayer is playing", isReadyForDisplay means visual frames exist.
/// No CDN URLs, cookies or viewing history are persisted.
struct PlaybackStartupSample: Identifiable {
    let id: UUID
    let title: String
    let episode: Int
    let startedAt: TimeInterval
    var provider: String = "—"
    var sourceSearchMs: Int? // when provider lookup began
    var moduleReadyMs: Int?   // module show URL chosen
    var episodeReadyMs: Int?  // exact episode href chosen
    var streamReadyMs: Int?   // video URL extracted
    var playerReadyMs: Int?   // AVPlayerItem.readyToPlay (not a visible frame)
    var firstFrameMs: Int?    // AVPlayerLayer.isReadyForDisplay
    var outcome: String = "Loading"
}

@MainActor
final class PlaybackPerformance: ObservableObject {
    static let shared = PlaybackPerformance()
    @Published private(set) var samples: [PlaybackStartupSample] = []
    @Published private(set) var metadataCacheHits = 0
    @Published private(set) var scriptCacheHits = 0
    private var activeID: UUID?

    private init() {}

    func begin(title: String, episode: Int) {
        let sample = PlaybackStartupSample(
            id: UUID(), title: title, episode: episode,
            startedAt: ProcessInfo.processInfo.systemUptime
        )
        activeID = sample.id
        samples.insert(sample, at: 0)
        if samples.count > 30 { samples.removeLast(samples.count - 30) }
    }

    private func update(_ mutate: (inout PlaybackStartupSample, Int) -> Void) {
        guard let activeID, let index = samples.firstIndex(where: { $0.id == activeID }) else { return }
        let elapsed = max(0, Int((ProcessInfo.processInfo.systemUptime -
                                  samples[index].startedAt) * 1_000))
        mutate(&samples[index], elapsed)
    }

    func sourceSearch(provider: String) {
        update { s, time in
            if s.sourceSearchMs == nil { s.sourceSearchMs = time }
            s.provider = provider
        }
    }

    func moduleResolved() {
        update { s, time in
            if s.moduleReadyMs == nil { s.moduleReadyMs = time }
        }
    }

    func episodeResolved() {
        update { s, time in
            if s.episodeReadyMs == nil { s.episodeReadyMs = time }
        }
    }

    func playerReady() {
        update { s, time in
            if s.playerReadyMs == nil { s.playerReadyMs = time }
        }
    }

    func streamResolved() {
        update { s, time in
            if s.streamReadyMs == nil { s.streamReadyMs = time }
            s.outcome = "Buffering"
        }
    }

    func firstFrameReady() {
        update { s, time in
            guard s.firstFrameMs == nil else { return }
            s.firstFrameMs = time
            s.outcome = "Playing"
            Logger.shared.log(
                "[Startup] first visual frame ready in \(time) ms; source=\(s.provider)",
                type: "Player"
            )
        }
    }

    /// A decoded frame can belong to an invalid ad/preview, not the requested episode.
    /// Remove any premature first-frame success if the actual asset is clearly too short.
    func rejectedInvalidEpisode() {
        update { s, _ in
            s.firstFrameMs = nil
            s.outcome = "Invalid episode source"
        }
    }

    func failed() {
        update { s, _ in if s.firstFrameMs == nil { s.outcome = "Failed" } }
    }

    func cancelled() {
        update { s, _ in if s.firstFrameMs == nil { s.outcome = "Cancelled" } }
    }

    func cacheHit(script: Bool) {
        if script { scriptCacheHits += 1 } else { metadataCacheHits += 1 }
    }

    func clear() {
        samples = []
        metadataCacheHits = 0
        scriptCacheHits = 0
        activeID = nil
    }
}


// MARK: - Optional Jev 1.13 decision engine (bring-your-own APInex key)
//
// Jev is a private, non-chat, non-UI enhancement for ambiguous source searches.
// Real URLs/episodes come ONLY from existing modules; a model is never allowed
// to invent an episode, stream or domain. Sending no key means zero API calls.
// The user's own key lives in the platform Keychain, never UserDefaults/logs.
@MainActor
final class JevDecisionEngine: ObservableObject {
    static let shared = JevDecisionEngine()

    static let modelID = "free/jev-1.13"
    static let endpoint = URL(string: "https://api.apinex.bond/v1/decisions")!
    private static let service = "com.shirox.apinex.jev"
    static let credentialAccount = "apinex_jev_api_key"

    @Published private(set) var hasKey: Bool
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "jevIntelligenceEnabled") }
    }
    @Published private(set) var checking = false
    @Published private(set) var status: String?

    // Avoid consuming the free model's shared rate limit on every search row.
    private var requestTimes: [Date] = []
    private var backoffUntil: Date = .distantPast

    private init() {
        hasKey = Self.readKey() != nil
        enabled = UserDefaults.standard.object(forKey: "jevIntelligenceEnabled") as? Bool ?? true
    }

    private static func readKey() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: credentialAccount,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let bytes = result as? Data,
              let key = String(data: bytes, encoding: .utf8),
              !key.isEmpty else { return nil }
        return key
    }

    @discardableResult
    func saveKey(_ raw: String) -> Bool {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.count >= 12, !key.contains(where: { $0.isWhitespace }) else {
            status = "Bitte einen gültigen APInex-API-Schlüssel eingeben."
            return false
        }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: Self.credentialAccount
        ]
        let data = Data(key.utf8)
        var result = SecItemAdd((query.merging([
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]) { _, new in new }) as CFDictionary, nil)
        if result == errSecDuplicateItem {
            result = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        }
        hasKey = result == errSecSuccess
        status = hasKey ? "API-Schlüssel sicher gespeichert." : "Schlüssel konnte nicht gespeichert werden."
        return hasKey
    }

    func removeKey() {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: Self.credentialAccount
        ]
        SecItemDelete(query as CFDictionary)
        hasKey = false
        status = "API-Schlüssel entfernt. Die lokale Suche bleibt verfügbar."
    }

    private enum DecisionError: Error {
        case invalidResponse, unavailable
    }

    private func select(state: String, criteria: [String: String], question: String) async throws -> (String, Double) {
        guard enabled, hasKey, let key = Self.readKey(), Date() >= backoffUntil,
              criteria.count >= 2 else { throw DecisionError.unavailable }
        let now = Date()
        requestTimes = requestTimes.filter { now.timeIntervalSince($0) < 60 }
        // Stay conservatively below the free tier's documented rate limit.
        guard requestTimes.count < 4 else { throw DecisionError.unavailable }
        requestTimes.append(now)

        let payload: [String: Any] = [
            "model": Self.modelID,
            "state": String(state.prefix(1300)),
            "questions": [
                question: [
                    "type": "choice",
                    "instructions": "Choose the best matching REAL option. Never assume a stream or season exists. Reply only with a criteria key.",
                    "criteria": criteria
                ]
            ]
        ]
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 3.0
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        // Only search metadata (titles/season/candidate names) is sent to APInex.
        // No watched history, media URLs, cookies or tokens are sent.
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DecisionError.invalidResponse }
        if http.statusCode == 429 || http.statusCode >= 500 {
            backoffUntil = Date().addingTimeInterval(60)
            throw DecisionError.unavailable
        }
        guard http.statusCode == 200 else { throw DecisionError.unavailable }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["object"] as? String == "decision",
              let returnedModel = root["model"] as? String,
              returnedModel == Self.modelID || returnedModel == "jev-1.13",
              let answers = root["answers"] as? [String: Any],
              let answer = answers[question] as? [String: Any],
              answer["type"] as? String == "choice",
              let chosen = answer["choice"] as? String,
              criteria[chosen] != nil,
              let confidence = answer["confidence"] as? Double,
              confidence.isFinite, (0...1).contains(confidence) else {
            throw DecisionError.invalidResponse
        }
        return (chosen, confidence)
    }

    /// Reorder an actual list, never add synthetic results. Low confidence,
    /// a blocked API or an expired allowance retains the local ordering.
    func rankCandidates(_ items: [SearchItem], query: String, season: Int?) async -> [SearchItem] {
        guard enabled, hasKey, items.count > 1 else { return items }
        let subset = Array(items.prefix(5))
        var criteria: [String: String] = ["none": "None of these titles is the requested series"]
        for (index, item) in subset.enumerated() {
            criteria["c\(index)"] = "Existing catalogue result: \(String(item.title.prefix(120)))"
        }
        let context = "User searches for series '\(query)' with requested season \(season.map(String.init) ?? "unspecified"). Choose matching series title, ignoring a trailing Season/Staffel suffix."
        do {
            let (choice, confidence) = try await select(state: context, criteria: criteria, question: "best_title")
            guard confidence >= 0.75, choice.hasPrefix("c"),
                  let index = Int(choice.dropFirst()), subset.indices.contains(index) else { return items }
            if index == 0 { return items }
            var output = items
            let winner = output.remove(at: index)
            output.insert(winner, at: 0)
            return output
        } catch {
            return items
        }
    }

    /// Called only after the first title search fails, so Jev cannot slow down
    /// already-working exact matches. It may change the order, never the input
    /// set or the requested season.
    func prioritizeRetryQueries(_ queries: [String], originalTitle: String) async -> [String] {
        guard enabled, hasKey, queries.count > 1 else { return queries }
        let subset = Array(queries.prefix(5))
        var criteria: [String: String] = [:]
        for (index, title) in subset.enumerated() {
            criteria["q\(index)"] = "Search this exact existing title: \(String(title.prefix(120)))"
        }
        let context = "Search for '\(originalTitle)' failed. Which existing alternative title is likeliest to match the same series on a German catalogue? Season metadata is not part of the series name."
        do {
            let (choice, confidence) = try await select(state: context, criteria: criteria, question: "retry_title")
            guard confidence >= 0.65, choice.hasPrefix("q"),
                  let index = Int(choice.dropFirst()), subset.indices.contains(index) else { return queries }
            var output = queries
            let winner = output.remove(at: index)
            output.insert(winner, at: 0)
            return output
        } catch {
            return queries
        }
    }

    func testConnection() async {
        guard hasKey else { status = "Bitte zuerst einen API-Schlüssel speichern."; return }
        checking = true
        defer { checking = false }
        // An unambiguous, nonpersonal test of the provider's real decision API.
        do {
            let (choice, confidence) = try await select(
                state: "A TV series release marked Season 2 is the second season, not part of the series title.",
                criteria: [
                    "metadata": "Season 2 is a season number separate from the title",
                    "literal": "Season 2 is inseparable from the series title"
                ],
                question: "season_parse"
            )
            status = choice == "metadata" && confidence >= 0.5
                ? "Jev ist verbunden und einsatzbereit."
                : "API antwortet, aber die Testentscheidung war unsicher."
        } catch {
            status = "Keine Verbindung zur kostenlosen Jev-API. Schlüssel, Kontingent oder Netzwerk prüfen."
        }
    }
}
