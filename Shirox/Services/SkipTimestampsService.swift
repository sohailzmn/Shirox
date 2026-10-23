import Foundation

@MainActor
final class SkipTimestampsService {
    static let shared = SkipTimestampsService()

    private struct CacheKey: Hashable {
        let aniListID: Int
        let episodeNumber: Int
        let malID: Int?
        let durationBucket: Int
    }

    private var cache: [CacheKey: SkipSegments] = [:]

    private init() {}

    func fetchSegments(
        aniListID: Int, episodeNumber: Int, malID: Int? = nil,
        playbackDuration: Double = 0
    ) async -> SkipSegments? {
        // The video is often a different cut from the database submission:
        // distinguish versions by runtime, not only the anime and episode ID.
        let duration = playbackDuration.isFinite && playbackDuration > 0 &&
            playbackDuration <= 14_400 ? playbackDuration : 0
        let key = CacheKey(
            aniListID: aniListID, episodeNumber: episodeNumber, malID: malID,
            durationBucket: Int((duration / 5).rounded())
        )
        if let cached = cache[key] { return cached }

        // Try the fast, episode-specific MAL source before expensive cross-ID
        // mapping requests. An AniSkip result may have ONLY the opening or
        // ending: keep it, but let slower providers fill the missing chapter.
        let aniSkip: SkipSegments?
        if let malID, malID > 0 {
            aniSkip = await fetchAniSkip(
                malID: malID, episode: episodeNumber, duration: duration)
        } else {
            aniSkip = nil
        }
        if let aniSkip, aniSkip.intro != nil, aniSkip.credits != nil {
            cache[key] = aniSkip
            return aniSkip
        }

        let tvdbSeason: Int
        let epoffset: Int
        if let mapping = await TVDBMappingService.shared.getTVDBId(for: aniListID) {
            tvdbSeason = mapping.season.flatMap { $0 > 0 ? $0 : nil } ?? 1
            epoffset = TVDBMappingService.shared.cachedEpOffset(for: aniListID) ?? 0
        } else {
            tvdbSeason = 1
            epoffset = 0
        }
        // If episodeNumber > epoffset the module uses absolute/TVDB numbering —
        // convert to AniList-relative for Anira and use the value directly as tvdbEpisode.
        let isAbsolute = epoffset > 0 && episodeNumber > epoffset
        let aniListEpisode = isAbsolute ? episodeNumber - epoffset : episodeNumber
        let tvdbEpisode = isAbsolute ? episodeNumber : episodeNumber + epoffset

        // With sequel seasons, a module may send a global episode index,
        // whereas AniSkip expects the episode number local to that season.
        let preciseAniSkip: SkipSegments?
        if aniListEpisode != episodeNumber, let malID {
            preciseAniSkip = await fetchAniSkip(
                malID: malID, episode: aniListEpisode, duration: duration)
        } else {
            preciseAniSkip = nil
        }
        let verifiedAniSkip = preciseAniSkip ?? aniSkip
        if let verifiedAniSkip,
           verifiedAniSkip.intro != nil && verifiedAniSkip.credits != nil {
            cache[key] = verifiedAniSkip
            return verifiedAniSkip
        }

        // Anira/IntroDB are fallback timestamps. They are only manually skippable
        // when the exact cut cannot be verified (no guessed automatic seeks).
        // 1. Try Anira per-episode endpoint (has intro/outro in seconds)
        let aniraEp = await TVDBMappingService.shared.fetchAniraEpisode(id: aniListID, episodeNumber: aniListEpisode)
        var aniraSegments = SkipSegments()
        if let skips = aniraEp?.skips, !skips.isEmpty {
            for skip in skips {
                let seg = SkipSegments.Segment(startMs: skip.start * 1000, endMs: skip.end * 1000)
                switch skip.type {
                case "op", "mixed-op": aniraSegments.intro = seg
                case "ed", "mixed-ed": aniraSegments.credits = seg
                case "recap": aniraSegments.recap = seg
                default: break
                }
            }
            aniraSegments = validated(aniraSegments, duration: duration)
        }

        // 2. Fall back to introdb / theIntroDB
        let imdbID = await IDMappingService.shared.imdbId(forAnilistId: aniListID)
        let tmdb = await IDMappingService.shared.tmdbId(forAnilistId: aniListID)
        let isMovie = tmdb?.isMovie ?? false

        async let introDBResult = fetchIntroDB(imdbID: imdbID, season: tvdbSeason, episode: tvdbEpisode, isMovie: isMovie)
        async let theIntroDBResult = fetchTheIntroDB(tmdbID: tmdb?.id, season: tvdbSeason, episode: tvdbEpisode, isMovie: isMovie)

        var (introDB, theIntroDB) = await (introDBResult, theIntroDBResult)

        // If tvdbEpisode returned nothing and differs from the raw episode number, retry with the raw number
        if introDB?.hasSegments != true && tvdbEpisode != episodeNumber {
            introDB = await fetchIntroDB(imdbID: imdbID, season: tvdbSeason, episode: episodeNumber, isMovie: isMovie)
        }
        if theIntroDB == nil && tvdbEpisode != episodeNumber {
            theIntroDB = await fetchTheIntroDB(tmdbID: tmdb?.id, season: tvdbSeason, episode: episodeNumber, isMovie: isMovie)
        }
        var segments = validated(merge(introdb: introDB, theintrodb: theIntroDB), duration: duration)
        // AniSkip markers that match this video's runtime take precedence.
        // Otherwise show independently provided chapters as manual buttons.
        segments.intro = verifiedAniSkip?.intro ?? segments.intro ?? aniraSegments.intro
        segments.recap = verifiedAniSkip?.recap ?? segments.recap ?? aniraSegments.recap
        segments.credits = verifiedAniSkip?.credits ?? segments.credits ?? aniraSegments.credits
        segments.autoSkipIntro = verifiedAniSkip?.autoSkipIntro ?? false
        segments.autoSkipRecap = verifiedAniSkip?.autoSkipRecap ?? false
        segments.autoNextCredits = verifiedAniSkip?.autoNextCredits ?? false

        // A source without runtime metadata cannot authorize automatic jumps
        // alone. However, two independent providers marking essentially the
        // same scene within the actual runtime is a strong second signal.
        // This is intentionally strict to avoid skipping dialogue.
        let anira = aniraSegments
        let database = validated(merge(introdb: introDB, theintrodb: theIntroDB), duration: duration)
        let introAgrees = Self.agrees(anira.intro, database.intro)
        let endingAgrees = Self.agrees(anira.credits, database.credits)
        let recapAgrees = Self.agrees(anira.recap, database.recap)
        if duration >= 60 {
            segments.autoSkipIntro = segments.autoSkipIntro || introAgrees
            segments.autoSkipRecap = segments.autoSkipRecap || recapAgrees
            segments.autoNextCredits = segments.autoNextCredits || endingAgrees
        }
        segments.isDurationVerified = segments.autoSkipIntro ||
            segments.autoSkipRecap || segments.autoNextCredits
        cache[key] = segments
        return segments
    }

    func clearCache() {
        cache.removeAll()
    }

    // MARK: - Exact-cut timestamps

    private func fetchAniSkip(malID: Int, episode: Int, duration: Double) async -> SkipSegments? {
        guard malID > 0, episode > 0, duration >= 60, duration <= 14_400 else { return nil }
        var url = URLComponents(string: "https://api.aniskip.com/v2/skip-times/\(malID)/\(episode)")
        url?.queryItems = [
            URLQueryItem(name: "episodeLength", value: String(format: "%.3f", duration))
        ] + ["op", "ed", "recap", "mixed-op", "mixed-ed"].map {
            URLQueryItem(name: "types", value: $0)
        }
        guard let endpoint = url?.url else { return nil }
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 6
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let payload = try? JSONDecoder().decode(AniSkipResponse.self, from: data),
              payload.found else { return nil }
        var result = SkipSegments()
        for entry in payload.results {
            guard let cutLength = entry.episodeLength, cutLength > 0,
                  abs(cutLength - duration) <= max(4, duration * 0.005),
                  let segment = validSegment(
                    .init(startMs: entry.interval.startTime * 1000,
                          endMs: entry.interval.endTime * 1000),
                    duration: duration
                  ) else { continue }
            switch entry.skipType {
            case "op", "mixed-op":
                if result.intro == nil { result.intro = segment }
            case "ed", "mixed-ed":
                if result.credits == nil { result.credits = segment }
            case "recap":
                if result.recap == nil { result.recap = segment }
            default: break
            }
        }
        guard result.intro != nil || result.credits != nil || result.recap != nil else { return nil }
        result.autoSkipIntro = result.intro != nil
        result.autoSkipRecap = result.recap != nil
        result.autoNextCredits = result.credits != nil
        result.isDurationVerified = true
        return result
    }

    private static func agrees(
        _ lhs: SkipSegments.Segment?, _ rhs: SkipSegments.Segment?
    ) -> Bool {
        guard let lhs, let rhs, let lStart = lhs.startMs, let rStart = rhs.startMs,
              lStart.isFinite, rStart.isFinite, lhs.endMs.isFinite, rhs.endMs.isFinite else { return false }
        return abs(lStart - rStart) <= 3_000 && abs(lhs.endMs - rhs.endMs) <= 3_000
    }

    private func validSegment(_ segment: SkipSegments.Segment?, duration: Double) -> SkipSegments.Segment? {
        guard let segment, segment.endMs.isFinite else { return nil }
        let start = segment.startMs ?? 0
        guard start.isFinite, start >= 0, segment.endMs > start + 3_000 else { return nil }
        if duration > 0 && segment.endMs > duration * 1_000 + 1_500 { return nil }
        return segment
    }

    private func validated(_ segments: SkipSegments, duration: Double) -> SkipSegments {
        var result = segments
        result.intro = validSegment(segments.intro, duration: duration)
        result.recap = validSegment(segments.recap, duration: duration)
        result.credits = validSegment(segments.credits, duration: duration)
        result.preview = validSegment(segments.preview, duration: duration)
        // Lack of verified source-duration matching means show the manual
        // Skip button but NEVER seek automatically.
        result.isDurationVerified = false
        return result
    }

    // MARK: - Private fetches

    private func fetchIntroDB(imdbID: String?, season: Int, episode: Int, isMovie: Bool) async -> IntroDBResponse? {
        guard let imdbID else { return nil }
        var urlString = "https://api.introdb.app/segments?imdb_id=\(imdbID)"
        if !isMovie { urlString += "&season=\(season)&episode=\(episode)" }
        guard let url = URL(string: urlString),
              let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return try? JSONDecoder().decode(IntroDBResponse.self, from: data)
    }

    private func fetchTheIntroDB(tmdbID: Int?, season: Int, episode: Int, isMovie: Bool) async -> TheIntroDBResponse? {
        guard let tmdbID else { return nil }
        var urlString = "https://api.theintrodb.org/v2/media?tmdb_id=\(tmdbID)"
        if !isMovie { urlString += "&season=\(season)&episode=\(episode)" }
        guard let url = URL(string: urlString),
              let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return try? JSONDecoder().decode(TheIntroDBResponse.self, from: data)
    }

    // MARK: - Merge

    private func merge(introdb: IntroDBResponse?, theintrodb: TheIntroDBResponse?) -> SkipSegments {
        var result = SkipSegments()

        if let seg = introdb?.intro {
            result.intro = SkipSegments.Segment(startMs: seg.start_ms, endMs: seg.end_ms)
        } else if let seg = theintrodb?.intro?.first, let endMs = seg.end_ms {
            result.intro = SkipSegments.Segment(startMs: seg.start_ms, endMs: endMs)
        }

        if let seg = introdb?.recap {
            result.recap = SkipSegments.Segment(startMs: seg.start_ms, endMs: seg.end_ms)
        } else if let seg = theintrodb?.recap?.first, let endMs = seg.end_ms {
            result.recap = SkipSegments.Segment(startMs: seg.start_ms, endMs: endMs)
        }

        if let seg = introdb?.outro {
            result.credits = SkipSegments.Segment(startMs: seg.start_ms, endMs: seg.end_ms)
        } else if let seg = theintrodb?.credits?.first, let endMs = seg.end_ms {
            result.credits = SkipSegments.Segment(startMs: seg.start_ms, endMs: endMs)
        }

        if let seg = theintrodb?.preview?.first, let endMs = seg.end_ms {
            result.preview = SkipSegments.Segment(startMs: seg.start_ms, endMs: endMs)
        }

        return result
    }
}

// MARK: - Response decodables (private to this file)

private struct IntroDBResponse: Decodable {
    struct Segment: Decodable {
        let start_ms: Double?
        let end_ms: Double
    }
    let intro: Segment?
    let recap: Segment?
    let outro: Segment?
    var hasSegments: Bool { intro != nil || recap != nil || outro != nil }
}

private struct TheIntroDBResponse: Decodable {
    struct Segment: Decodable {
        let start_ms: Double?
        let end_ms: Double?
    }
    let intro: [Segment]?
    let recap: [Segment]?
    let credits: [Segment]?
    let preview: [Segment]?
}

private struct AniSkipResponse: Decodable {
    struct Interval: Decodable {
        let startTime: Double
        let endTime: Double
    }
    struct Item: Decodable {
        let interval: Interval
        let skipType: String
        let episodeLength: Double?
    }
    let found: Bool
    let results: [Item]
}
