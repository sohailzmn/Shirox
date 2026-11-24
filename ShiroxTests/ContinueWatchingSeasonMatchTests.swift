import XCTest
@testable import Shirox

/// Tests that a Continue Watching item is matched to the correct episode row on a flat,
/// multi-season episode list.
///
/// The reported bug: a module returns one list for a whole franchise, so episode *numbers*
/// repeat across seasons (S1 1…12, then S2 1…12). Starting S1 E5 and closing it mid-way
/// left an in-progress item with episodeNumber 5. The detail view matched that item to
/// *every* row numbered 5 — so S2 E5 showed S1 E5's progress bar and, when tapped, resumed
/// season 1's stream. The unique per-episode `href` disambiguates the two.
final class ContinueWatchingSeasonMatchTests: XCTestCase {
    @MainActor func testEpisodePositionsSurviveSwitchingEpisodesAndBackupRoundTrip() throws {
        let manager = ContinueWatchingManager.shared
        let original = try XCTUnwrap(ProgressBackupSection().export())
        defer { manager.restore(items: original.continueWatching, watchedKeys: original.watchedKeys,
            watchedHrefKeys: original.watchedHrefKeys, episodeProgress: original.episodeProgress ?? [:]) }
        manager.restore(items: [], watchedKeys: [], watchedHrefKeys: [])
        let one = makeItem(episodeNumber: 5, episodeHref: "https://aniworld.to/anime/stream/show/staffel-1/episode-5")
        var two = makeItem(episodeNumber: 5, episodeHref: "https://aniworld.to/anime/stream/show/staffel-2/episode-5")
        two.watchedSeconds = 450
        manager.save(one); manager.save(two)
        XCTAssertEqual(manager.items.count, 1)
        XCTAssertEqual(manager.episodeRecord(aniListID: nil, moduleId: "mod", mediaTitle: "Show", episodeNumber: 5,
            episodeHref: one.episodeHref)?.resumeSeconds, 100)
        XCTAssertEqual(manager.episodeRecord(aniListID: nil, moduleId: "mod", mediaTitle: "Show", episodeNumber: 5,
            episodeHref: two.episodeHref)?.resumeSeconds, 450)
        let payload = try XCTUnwrap(ProgressBackupSection().export())
        let roundTrip = try JSONDecoder().decode(ProgressBackupPayload.self, from: JSONEncoder().encode(payload))
        manager.restore(items: roundTrip.continueWatching, watchedKeys: roundTrip.watchedKeys,
            watchedHrefKeys: roundTrip.watchedHrefKeys, episodeProgress: roundTrip.episodeProgress ?? [:])
        XCTAssertEqual(manager.episodeProgress.count, 2)
        let json = String(decoding: try JSONEncoder().encode(manager.episodeProgress), as: UTF8.self)
        XCTAssertFalse(json.contains("streamUrl")); XCTAssertFalse(json.contains("headers"))
        manager.resetEpisodeProgress(aniListID: nil, moduleId: "mod", mediaTitle: "Show", episodeNumber: 5, episodeHref: one.episodeHref)
        XCTAssertEqual(manager.episodeProgress.count, 1)
        XCTAssertNotNil(manager.episodeRecord(aniListID: nil, moduleId: "mod", mediaTitle: "Show", episodeNumber: 5, episodeHref: two.episodeHref))
        manager.resetProgress(aniListID: nil, moduleId: "mod", mediaTitle: "Show")
        XCTAssertTrue(manager.episodeProgress.isEmpty)
    }

    @MainActor func testCompletedEpisodeKeepsItsPositionWhenNextCardIsQueued() throws {
        let manager = ContinueWatchingManager.shared
        let original = try XCTUnwrap(ProgressBackupSection().export())
        defer { manager.restore(items: original.continueWatching, watchedKeys: original.watchedKeys,
            watchedHrefKeys: original.watchedHrefKeys, episodeProgress: original.episodeProgress ?? [:]) }
        manager.restore(items: [], watchedKeys: [], watchedHrefKeys: [])
        var item = makeItem(episodeNumber: 5, episodeHref: "https://serienstream.to/serie/show/staffel-2/episode-5")
        item.watchedSeconds = 960; item.sourceReferenceOnly = true; item.sourceSeason = 2; item.sourceEpisode = 5
        manager.save(item)
        XCTAssertEqual(manager.items.first?.episodeNumber, 6)
        XCTAssertEqual(manager.items.first?.sourceSeason, 2)
        XCTAssertEqual(manager.items.first?.sourceEpisode, 6)
        let record = try XCTUnwrap(manager.episodeRecord(aniListID: nil, moduleId: "mod", mediaTitle: "Show",
            episodeNumber: 5, episodeHref: item.episodeHref))
        XCTAssertEqual(record.fraction, 0.96, accuracy: 0.001)
        XCTAssertNil(record.resumeSeconds)
        XCTAssertTrue(record.label.contains("16:00"))
    }

    func testHistoryCanonicalizesSourceAliasesWithoutMixingSeasonsOrShows() {
        let old = "https://s.to/serie/stream/dexter/staffel-2/episode-5?lang=1"
        let current = "https://serienstream.cx/serie/dexter/staffel-2/episode-5/"
        XCTAssertEqual(PlaybackHistoryIdentity.canonical(old), PlaybackHistoryIdentity.canonical(current))
        XCTAssertTrue(PlaybackHistoryIdentity.matches(aniListID: nil, moduleID: "old", title: "Old alias", detailHref: old,
            otherID: nil, otherModule: "new", otherTitle: "Dexter", otherHref: current))
        XCTAssertFalse(PlaybackHistoryIdentity.matches(aniListID: nil, moduleID: "mod", title: "Dexter", detailHref: old,
            otherID: nil, otherModule: "mod", otherTitle: "Dexter", otherHref: "https://serienstream.to/serie/dexter-wiedererwachen"))
        XCTAssertFalse(makeItem(episodeNumber: 5, episodeHref: old).matchesEpisode(number: 5,
            href: "https://serienstream.to/serie/dexter/staffel-1/episode-5"))
    }

    func testLegacySourceResumeRefreshesLanguageInsteadOfReplayingOldMediaURL() {
        var item = makeItem(episodeNumber: 5, episodeHref: "https://aniworld.to/anime/stream/show/staffel-1/episode-5")
        XCTAssertNil(item.sourceReferenceOnly)
        XCTAssertTrue(item.usesSourceResume)
        item.localImportName = "picked-video.mp4"
        XCTAssertFalse(item.usesSourceResume)
        XCTAssertEqual(PlaybackLanguagePolicy.resolutionStages(resuming: true), [0, 0, 1, 2])
        XCTAssertEqual(PlaybackLanguagePolicy.resolutionStages(resuming: false), [0, 1, 2])
    }

    func testLegacySavedPositionsDecodeWithoutLanguageMetadata() throws {
        let item = makeItem(episodeNumber: 5, episodeHref: "show/episode-5")
        let restored = try JSONDecoder().decode(ContinueWatchingItem.self, from: JSONEncoder().encode(item))
        XCTAssertNil(restored.audioLanguage); XCTAssertEqual(restored.watchedSeconds, 100)
        XCTAssertEqual(EpisodePlaybackProgress(restored).label, "1:40 von 16:40 · 10 %")
    }

    @MainActor func testNativeResumeBridgeForwardsProviderAndGermanStage() async throws {
        let script = #"async function extractStreamUrl(url, options) { return JSON.stringify({streams:[{streamUrl:'https://media.example/fixture.m3u8',title:options.preferredProvider,audioLanguage:options.languagePriority===0?'de':'en'}]}); }"#
        let json: [String: Any] = ["sourceName": "Resume fixture", "version": "1", "type": "anime",
            "scriptUrl": "https://fixture.example/resume.js", "scriptContent": script]
        let module = try JSONDecoder().decode(ModuleDefinition.self, from: JSONSerialization.data(withJSONObject: json))
        let runner = ModuleJSRunner(); try await runner.load(module: module)
        let streams = try await runner.fetchStreams(episodeUrl: "https://fixture.example/episode-5",
            languagePriority: 0, preflight: false, preferredStreamTitle: "Vidmoly · Auto HLS")
        XCTAssertEqual(streams.first?.title, "Vidmoly · Auto HLS")
        XCTAssertEqual(streams.first?.audioLanguage, "de")
    }

    /// Builds an item carrying only the fields the matcher inspects; the rest are inert.
    private func makeItem(episodeNumber: Int, episodeHref: String?) -> ContinueWatchingItem {
        ContinueWatchingItem(
            id: UUID(), mediaTitle: "Show", episodeNumber: episodeNumber,
            episodeTitle: nil, imageUrl: "", streamUrl: "https://x/s\(episodeNumber)",
            headers: nil, subtitle: nil, streamTitle: nil,
            aniListID: nil, malID: nil, moduleId: "mod", detailHref: nil,
            episodeHref: episodeHref,
            watchedSeconds: 100, totalSeconds: 1000, totalEpisodes: nil,
            availableEpisodes: nil, isAiring: nil, lastWatchedAt: .now, thumbnailUrl: nil
        )
    }

    /// THE BUG: an in-progress item saved for S1 E5 must match S1 E5's row (same href)…
    func testItemMatchesOwnSeasonRowByHref() {
        let item = makeItem(episodeNumber: 5, episodeHref: "s1/ep5")
        XCTAssertTrue(item.matchesEpisode(number: 5, href: "s1/ep5"))
    }

    /// …and must NOT match S2 E5's row, even though the episode number is identical.
    func testItemDoesNotMatchOtherSeasonRowWithSameNumber() {
        let item = makeItem(episodeNumber: 5, episodeHref: "s1/ep5")
        XCTAssertFalse(item.matchesEpisode(number: 5, href: "s2/ep5"),
                       "S1 E5's progress must not bleed onto S2 E5")
    }

    /// Legacy items (saved before episodeHref existed) can only fall back to the number.
    func testLegacyItemWithoutHrefFallsBackToNumber() {
        let item = makeItem(episodeNumber: 5, episodeHref: nil)
        XCTAssertTrue(item.matchesEpisode(number: 5, href: "s2/ep5"))
        XCTAssertFalse(item.matchesEpisode(number: 6, href: "s2/ep6"))
    }

    /// A row without an href (shouldn't happen for module episodes, but be defensive)
    /// falls back to the number rather than silently failing to match.
    func testRowWithoutHrefFallsBackToNumber() {
        let item = makeItem(episodeNumber: 5, episodeHref: "s1/ep5")
        XCTAssertTrue(item.matchesEpisode(number: 5, href: nil))
        XCTAssertTrue(item.matchesEpisode(number: 5, href: ""))
    }

    // MARK: - Identity handoff from Continue Watching to AniSkip

    func testMALOnlyContinueWatchingRestoresSkipIdentity() {
        let item = ContinueWatchingItem(
            id: UUID(), mediaTitle: "Blue Lock", episodeNumber: 6,
            episodeTitle: nil, imageUrl: "", streamUrl: "https://x/video.m3u8",
            headers: nil, subtitle: nil, streamTitle: nil,
            aniListID: nil, malID: 49596, moduleId: "mod", detailHref: "show/blue-lock",
            watchedSeconds: 420, totalSeconds: 1400, lastWatchedAt: .now
        )
        let identity = item.playbackIdentity()
        XCTAssertNil(identity.aniListID)
        XCTAssertEqual(identity.malID, 49596,
                       "MAL-only saved episodes must keep their AniSkip identity")
    }

    func testContinueWatchingRecoversCachedAniListFromMALWithoutErasingMAL() {
        let item = makeItem(episodeNumber: 6, episodeHref: nil)
        let identity = item.playbackIdentity(
            mappedAniListID: 137822, linkedAniListID: nil, mappedMALID: 49596
        )
        XCTAssertEqual(identity.aniListID, 137822)
        XCTAssertEqual(identity.malID, 49596)
    }

    func testContinueWatchingTitleMappingRestoresMissingAnimeID() {
        let item = makeItem(episodeNumber: 6, episodeHref: nil)
        let identity = item.playbackIdentity(linkedAniListID: 137822)
        XCTAssertEqual(identity.aniListID, 137822)
    }

    func testSavedMALAndAniListTakePrecedenceOverFallbacks() {
        let item = ContinueWatchingItem(
            id: UUID(), mediaTitle: "Blue Lock", episodeNumber: 6,
            episodeTitle: nil, imageUrl: "", streamUrl: "https://x/video.m3u8",
            headers: nil, subtitle: nil, streamTitle: nil,
            aniListID: 137822, malID: 49596, moduleId: "mod", detailHref: nil,
            watchedSeconds: 420, totalSeconds: 1400, lastWatchedAt: .now
        )
        let identity = item.playbackIdentity(
            mappedAniListID: 123, linkedAniListID: 456, mappedMALID: 789
        )
        XCTAssertEqual(identity.aniListID, 137822)
        XCTAssertEqual(identity.malID, 49596)
    }

    // MARK: - Completed (watched) display decision

    /// A per-episode href marker is authoritative — the row is watched regardless of the
    /// number key, so completing S1 E5 marks exactly S1 E5.
    func testHrefMarkerAlwaysCountsAsWatched() {
        XCTAssertTrue(ContinueWatchingManager.isEpisodeWatched(
            watchedByHref: true, watchedByNumber: false,
            showUsesHrefTracking: true, numberIsAmbiguous: true))
    }

    /// Shows with no in-app completion keep the legacy behavior: the number key is trusted
    /// (this is how remote-sync and mark-as-watched state shows today). No regression.
    func testNumberKeyTrustedWhenShowHasNoHrefTracking() {
        XCTAssertTrue(ContinueWatchingManager.isEpisodeWatched(
            watchedByHref: false, watchedByNumber: true,
            showUsesHrefTracking: false, numberIsAmbiguous: true))
    }

    /// THE BUG: once the show is href-tracked, a number key on an *ambiguous* number (repeats
    /// across seasons) must NOT count — otherwise S1 E5's completion bleeds onto S2 E5.
    func testAmbiguousNumberSuppressedWhenShowIsHrefTracked() {
        XCTAssertFalse(ContinueWatchingManager.isEpisodeWatched(
            watchedByHref: false, watchedByNumber: true,
            showUsesHrefTracking: true, numberIsAmbiguous: true))
    }

    /// An href-tracked show still honors number keys on *unambiguous* numbers (a uniquely
    /// numbered episode can't belong to another season), preserving sync/single-season display.
    func testUnambiguousNumberStillCountsWhenHrefTracked() {
        XCTAssertTrue(ContinueWatchingManager.isEpisodeWatched(
            watchedByHref: false, watchedByNumber: true,
            showUsesHrefTracking: true, numberIsAmbiguous: false))
    }

    /// Nothing recorded → not watched.
    func testNoMarkersMeansNotWatched() {
        XCTAssertFalse(ContinueWatchingManager.isEpisodeWatched(
            watchedByHref: false, watchedByNumber: false,
            showUsesHrefTracking: false, numberIsAmbiguous: false))
    }
}
