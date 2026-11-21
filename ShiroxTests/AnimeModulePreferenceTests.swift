import XCTest
@testable import Shirox

final class AnimeModulePreferenceTests: XCTestCase {
    // `ModuleDefinition` is Codable with a custom `init(from:)` (ModuleDefinition.swift:41).
    // Required decode keys: sourceName, version, scriptUrl, type. `id` is computed as
    // `scriptUrl`, so set scriptUrl to the id. `isManga` is `type == "mangas" || "manga"`.
    private func mod(_ id: String, manga: Bool) -> ModuleDefinition {
        let type = manga ? "mangas" : "anime"
        let json = #"{"sourceName":"\#(id)","version":"1","scriptUrl":"\#(id)","type":"\#(type)"}"#
        return try! JSONDecoder().decode(ModuleDefinition.self, from: Data(json.utf8))
    }

    func testKeepsActiveWhenActiveIsAnime() {
        let active = mod("a", manga: false)
        let picked = AnimeModulePreference.pick(active: active, modules: [active, mod("m", manga: true)])
        XCTAssertEqual(picked?.id, "a")
    }

    func testSwitchesToFirstAnimeWhenActiveIsManga() {
        let active = mod("m", manga: true)
        let anime = mod("a", manga: false)
        let picked = AnimeModulePreference.pick(active: active, modules: [active, anime])
        XCTAssertEqual(picked?.id, "a")
    }

    func testNilWhenNoAnimeModule() {
        let active = mod("m", manga: true)
        XCTAssertNil(AnimeModulePreference.pick(active: active, modules: [active]))
    }
    func testUnifiedGermanMatchesRequestedSeasonOnly() {
        let combined = mod("Shirox Unified GER (AniWorld + S.to)", manga: false)
        let episodes = [
            EpisodeLink(number: 1, href: "https://aniworld.to/anime/stream/apothecary/staffel-1/episode-1"),
            EpisodeLink(number: 25, href: "https://aniworld.to/anime/stream/apothecary/staffel-2/episode-1"),
            EpisodeLink(number: 49, href: "https://aniworld.to/anime/stream/apothecary/staffel-3/episode-1")
        ]
        let result = ModuleSeasonFallback.aniWorldEpisode(
            from: episodes, title: "The Apothecary Diaries Season 3",
            module: combined, number: 1
        )
        XCTAssertTrue(result.handled)
        XCTAssertTrue(result.episode?.href.contains("/staffel-3/episode-1") == true)
    }

    func testDexterSearchAddsGermanTitle() {
        let queries = ModuleSeasonFallback.queries(for: "Dexter: Resurrection")
        XCTAssertTrue(queries.contains("Dexter: Wiedererwachen"))
        XCTAssertEqual(queries.first, "Dexter: Resurrection")
    }

    func testSourceFailureReasonRemainsSpecific() {
        XCTAssertTrue(FastSourceDecision.error(foundSeries: false, foundEpisodes: false, foundStream: false)
            .contains("Serie"))
        XCTAssertTrue(FastSourceDecision.error(foundSeries: true, foundEpisodes: false, foundStream: false)
            .contains("Folge"))
        XCTAssertTrue(FastSourceDecision.error(foundSeries: true, foundEpisodes: true, foundStream: false)
            .contains("Videolink"))
        XCTAssertTrue(FastSourceDecision.error(foundSeries: false, foundEpisodes: false,
                                               foundStream: false, timedOut: true).contains("langsam"))
    }

    func testSTOSeriesExplicitSeasonDoesNotChooseWrongEpisode() {
        let module = mod("s.to German Dub", manga: false)
        let episodes = [
            EpisodeLink(number: 1, href: "https://serienstream.to/serie/dexter-wiedererwachen/staffel-1/episode-1"),
            EpisodeLink(number: 4, href: "https://serienstream.to/serie/dexter-wiedererwachen/staffel-2/episode-4")
        ]
        let matched = ModuleSeasonFallback.aniWorldEpisode(from: episodes, title: "Dexter: Wiedererwachen Season 2", module: module, number: 4)
        XCTAssertTrue(matched.handled)
        XCTAssertTrue(matched.episode?.href.hasSuffix("/staffel-2/episode-4") == true)
    }
}
