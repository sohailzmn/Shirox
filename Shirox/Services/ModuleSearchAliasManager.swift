import Foundation
import Combine

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
    var sourceSearchMs: Int?
    var streamReadyMs: Int?
    var firstFrameMs: Int?
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
