import Foundation

struct StoredStream: Codable, Hashable {
    let title: String
    let url: String
    let headers: [String: String]
    let subtitle: String?
    var subtitleHeaders: [String: String]?

    var asStreamResult: StreamResult? {
        guard let url = URL(string: url) else { return nil }
        return StreamResult(title: title, url: url, headers: headers,
                            subtitle: subtitle, subtitleHeaders: subtitleHeaders ?? [:])
    }
}

struct ContinueWatchingItem: Identifiable, Codable, Hashable {
    let id: UUID
    let mediaTitle: String
    let episodeNumber: Int
    let episodeTitle: String?
    let imageUrl: String
    let streamUrl: String
    let headers: [String: String]?
    let subtitle: String?
    var subtitleHeaders: [String: String]?
    var allSubtitles: [SubtitleTrack]?
    let streamTitle: String?  // the selected stream's title (e.g., "SUB", "DUB", "pahe")
    var allStreams: [StoredStream]?
    let aniListID: Int?
    let malID: Int?
    let moduleId: String?
    let detailHref: String?
    /// The playing episode's own unique href (not the show/detail href). Anchors next-episode
    /// resolution on resume so multi-season flat lists (numbers repeat) advance to the right
    /// season. Optional + decoded if-present, so items saved before this field stay valid.
    var episodeHref: String?
    var watchedSeconds: Double
    var totalSeconds: Double
    var totalEpisodes: Int?
    /// Number of episodes currently aired/available (may be less than totalEpisodes for ongoing shows).
    var availableEpisodes: Int?
    var isAiring: Bool?
    var lastWatchedAt: Date
    var thumbnailUrl: String?
    var aniListUpdatedAt: Int?
    var bookmarkData: Data?   // legacy: security-scoped bookmark for local-file resume; superseded by localImportName
    /// Filename of the picked video copied into the app's persistent imports directory.
    /// Resume reconstructs the file from the current container, so it survives the
    /// transient/sandboxed picker URLs that broke bookmark-based resume. Nil for normal streams.
    var localImportName: String?
    /// Filename of an up-front subtitle copied alongside the video, so resume reloads it.
    var localSubtitleImportName: String?
    var sourceReferenceOnly: Bool? = nil
    var sourceSeason: Int? = nil
    var sourceEpisode: Int? = nil
    var audioLanguage: String? = nil
    var subtitleLanguage: String? = nil
    var isHardsub: Bool? = nil
    var isPlaceholder: Bool { streamUrl.isEmpty && (sourceReferenceOnly != true || totalSeconds == 0) }
}

extension ContinueWatchingItem {
    /// Recover the identity that AniSkip needs when older Continue Watching entries
    /// only saved a MAL ID (or the user linked this module title afterwards).
    /// Stored IDs are authoritative. Never interpret a MAL ID as an AniList ID.
    func playbackIdentity(
        mappedAniListID: Int? = nil, linkedAniListID: Int? = nil,
        mappedMALID: Int? = nil
    ) -> (aniListID: Int?, malID: Int?) {
        let resolvedAniListID = aniListID ?? mappedAniListID ?? linkedAniListID
        return (resolvedAniListID, malID ?? mappedMALID)
    }

    /// Resolve available cached links before mounting AVPlayer so both the
    /// Home card and detail-screen resume use the same chapter metadata keys.
    func resolvedPlaybackIdentity(linkedAniListID: Int? = nil) -> (aniListID: Int?, malID: Int?) {
        let mappedAniListID = malID.flatMap {
            IDMappingService.shared.cachedAnilistId(forMALId: $0)
        }
        let aid = aniListID ?? mappedAniListID ?? linkedAniListID
        let mappedMALID = aid.flatMap {
            IDMappingService.shared.cachedMalId(forAnilistId: $0)
        }
        return playbackIdentity(
            mappedAniListID: mappedAniListID, linkedAniListID: linkedAniListID,
            mappedMALID: mappedMALID
        )
    }

    /// True when this item refers to the episode identified by `number`/`href`.
    ///
    /// On a flat multi-season list episode *numbers* repeat (S1 1…12, S2 1…12), so matching an
    /// item to a row by number alone lets S1 E5's progress bleed onto S2 E5. The saved
    /// `episodeHref` is unique per episode, so when both sides carry one it is authoritative.
    /// Falls back to the number only when either side lacks an href (legacy items, or a row
    /// without one) — there we can't disambiguate and best-effort number matching is unchanged.
    func matchesEpisode(number: Int, href: String?) -> Bool {
        if let itemHref = episodeHref, !itemHref.isEmpty,
           let href, !href.isEmpty {
            return PlaybackHistoryIdentity.canonical(itemHref) == PlaybackHistoryIdentity.canonical(href)
        }
        return episodeNumber == number
    }
}

enum PlaybackHistoryIdentity {
    static func canonical(_ href: String) -> String {
        guard var url = URLComponents(string: href), let host = url.host?.lowercased() else { return href }
        switch host.replacingOccurrences(of: "www.", with: "") {
        case "s.to", "serienstream.to", "serienstream.cx": url.host = "serienstream.to"
        case "aniworld.to", "aniworld.cc": url.host = "aniworld.to"
        default: url.host = host
        }
        url.scheme = "https"; url.query = nil; url.fragment = nil
        url.path = url.path.replacingOccurrences(of: "/serie/stream/", with: "/serie/")
        while url.path.hasSuffix("/") { url.path.removeLast() }
        return url.string ?? href
    }

    static func show(_ href: String) -> String {
        let value = canonical(href)
        return value.components(separatedBy: "/staffel-").first ?? value
    }

    static func matches(aniListID: Int?, moduleID: String?, title: String, detailHref: String?,
                        otherID: Int?, otherModule: String?, otherTitle: String, otherHref: String?) -> Bool {
        if let aniListID, let otherID { return aniListID == otherID }
        if let detailHref, !detailHref.isEmpty, let otherHref, !otherHref.isEmpty {
            return show(detailHref) == show(otherHref)
        }
        if let moduleID, let otherModule, moduleID != otherModule { return false }
        return !title.isEmpty && title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            == otherTitle.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

/// Durable episode position, independent of the single Continue Watching card.
/// Contains source identities only, never expiring media URLs or request headers.
struct EpisodePlaybackProgress: Codable, Equatable {
    let mediaTitle: String
    let aniListID: Int?
    let moduleID: String?
    let detailHref: String?
    let episodeHref: String?
    let episodeNumber: Int
    let sourceSeason: Int?
    let sourceEpisode: Int?
    let watchedSeconds: Double
    let totalSeconds: Double
    let updatedAt: Date

    init(_ item: ContinueWatchingItem) {
        mediaTitle = item.mediaTitle; aniListID = item.aniListID; moduleID = item.moduleId
        detailHref = item.detailHref; episodeHref = item.episodeHref; episodeNumber = item.episodeNumber
        sourceSeason = item.sourceSeason ?? item.episodeHref.flatMap { ModuleSeasonRouting.seasonNumber(for: $0) }
        sourceEpisode = item.sourceEpisode ?? item.episodeHref.flatMap { ModuleSeasonRouting.episodeNumber(for: $0) }
        watchedSeconds = item.watchedSeconds; totalSeconds = item.totalSeconds; updatedAt = item.lastWatchedAt
    }

    var key: String {
        if let episodeHref, !episodeHref.isEmpty { return "href:" + PlaybackHistoryIdentity.canonical(episodeHref) }
        if let aniListID { return "anime:\(aniListID):\(episodeNumber)" }
        return "module:\(moduleID ?? ""):\(mediaTitle):\(sourceSeason ?? 0):\(episodeNumber)"
    }
    var fraction: Double { totalSeconds.isFinite && watchedSeconds.isFinite && totalSeconds > 0 ? min(max(watchedSeconds / totalSeconds, 0), 1) : 0 }
    var resumeSeconds: Double? { watchedSeconds.isFinite && totalSeconds.isFinite && totalSeconds > 0 && watchedSeconds > 0 && fraction < 0.95 ? watchedSeconds : nil }
    var label: String { "\(Self.time(watchedSeconds)) von \(Self.time(totalSeconds)) · \(Int(fraction * 100)) %" }
    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let value = Int(min(seconds, 31_536_000))
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
            : String(format: "%d:%02d", value / 60, value % 60)
    }
}

extension ContinueWatchingItem {
    var usesSourceResume: Bool {
        localImportName == nil && bookmarkData == nil &&
        [episodeHref, detailHref].compactMap { $0 }.contains {
            SourceCatalogRouting.accepts($0, kind: .anime) || SourceCatalogRouting.accepts($0, kind: .series)
        }
    }
}
