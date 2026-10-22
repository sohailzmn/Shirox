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

        // For anime, AniSkip uses the actual MyAnimeList ID and a media-length
        // constraint. These intervals are suitable for precise/automatic skips.
        // Never substitute the AniList ID: they are different ID namespaces.
        if let malID, let accurate = await fetchAniSkip(
            malID: malID, episode: aniListEpisode, duration: duration
        ) {
            cache[key] = accurate
            return accurate
        }

        // Anira/IntroDB are fallback timestamps. They are only manually skippable
        // when the exact cut cannot be verified (no guessed automatic seeks).
        // 1. Try Anira per-episode endpoint (has intro/outro in seconds)
        let aniraEp = await TVDBMappingService.shared.fetchAniraEpisode(id: aniListID, episodeNumber: aniListEpisode)
        if let skips = aniraEp?.skips, !skips.isEmpty {
            var result = SkipSegments()
            for skip in skips {
                let seg = SkipSegments.Segment(startMs: skip.start * 1000, endMs: skip.end * 1000)
                switch skip.type {
                case "op", "mixed-op": result.intro = seg
                case "ed", "mixed-ed": result.credits = seg
                case "recap": result.recap = seg
                default: break
                }
            }
            result = validated(result, duration: duration)
            cache[key] = result
            return result
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
        let segments = validated(merge(introdb: introDB, theintrodb: theIntroDB), duration: duration)
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
        result.isDurationVerified = true
        return result
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
