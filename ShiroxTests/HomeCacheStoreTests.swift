import XCTest
@testable import Shirox

/// Tests for `HomeCacheStore`, the disk cache behind Home's cache-then-refresh load.
///
/// Home had no cache at all: every cold start was a blank spinner until the network answered,
/// and a provider switch left the previous provider's rows up — indefinitely, if the new
/// provider's request then failed. Mirrors `LibraryCacheStoreTests`, which covers the same
/// pattern for the Library.
@MainActor
final class HomeCacheStoreTests: XCTestCase {

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeMedia(
        id: Int, title: String, provider: ProviderType, genres: [String]? = nil
    ) -> Media {
        Media(
            id: id, idMal: nil, provider: provider,
            title: MediaTitle(romaji: title, english: title, native: nil),
            coverImage: MediaCoverImage(large: nil, extraLarge: nil),
            bannerImage: nil, description: nil, episodes: 12,
            status: nil, averageScore: nil, genres: genres,
            season: nil, seasonYear: nil, nextAiringEpisode: nil,
            relations: nil, type: nil, format: nil)
    }

    private func makeFeed(provider: ProviderType, prefix: String) -> HomeFeed {
        HomeFeed(
            trending: [makeMedia(id: 1, title: "\(prefix) trending", provider: provider)],
            seasonal: [makeMedia(id: 2, title: "\(prefix) seasonal", provider: provider)],
            lastSeason: [makeMedia(id: 3, title: "\(prefix) last season", provider: provider)],
            popular: [makeMedia(id: 4, title: "\(prefix) popular", provider: provider)],
            topRated: [makeMedia(id: 5, title: "\(prefix) top rated", provider: provider)])
    }

    /// The point of the cache: a later launch reads back what the last successful load wrote.
    func testSaveThenLoadRoundTrips() {
        let dir = tempDir()
        let store = HomeCacheStore(directory: dir)
        store.save(feed: makeFeed(provider: .anilist, prefix: "AniList"), provider: .anilist)

        let reopened = HomeCacheStore(directory: dir)
        let snap = reopened.snapshot(provider: .anilist)
        XCTAssertEqual(snap?.feed.trending.map(\.id), [1])
        XCTAssertEqual(snap?.feed.seasonal.map(\.id), [2])
        XCTAssertEqual(snap?.feed.lastSeason.map(\.id), [3])
        XCTAssertEqual(snap?.feed.popular.map(\.id), [4])
        XCTAssertEqual(snap?.feed.topRated.map(\.id), [5])
        XCTAssertNotNil(snap?.syncedAt)
    }

    /// Each provider gets its own snapshot — switching to AniList must never show MyAnimeList's
    /// cached rows, which is exactly the confusion the cache is meant to remove.
    func testSnapshotsAreIsolatedByProvider() {
        let dir = tempDir()
        let store = HomeCacheStore(directory: dir)
        store.save(feed: makeFeed(provider: .anilist, prefix: "AniList"), provider: .anilist)
        store.save(feed: makeFeed(provider: .mal, prefix: "MAL"), provider: .mal)

        let reopened = HomeCacheStore(directory: dir)
        XCTAssertEqual(reopened.snapshot(provider: .anilist)?.feed.trending.first?.provider, .anilist)
        XCTAssertEqual(reopened.snapshot(provider: .mal)?.feed.trending.first?.provider, .mal)
    }

    func testMissingSnapshotIsNil() {
        let store = HomeCacheStore(directory: tempDir())
        XCTAssertNil(store.snapshot(provider: .anilist))
    }

    /// A later successful load replaces the previous one rather than accumulating.
    func testSaveOverwritesPreviousSnapshot() {
        let dir = tempDir()
        let store = HomeCacheStore(directory: dir)
        store.save(feed: makeFeed(provider: .anilist, prefix: "first"), provider: .anilist)
        let second = HomeFeed(
            trending: [makeMedia(id: 99, title: "second", provider: .anilist)],
            seasonal: [], lastSeason: [], popular: [], topRated: [])
        store.save(feed: second, provider: .anilist)

        let reopened = HomeCacheStore(directory: dir)
        XCTAssertEqual(reopened.snapshot(provider: .anilist)?.feed.trending.map(\.id), [99])
        XCTAssertEqual(reopened.snapshot(provider: .anilist)?.feed.seasonal.count, 0)
    }

    func testClearAllRemovesEverything() {
        let dir = tempDir()
        let store = HomeCacheStore(directory: dir)
        store.save(feed: makeFeed(provider: .anilist, prefix: "AniList"), provider: .anilist)
        store.clearAll()

        XCTAssertNil(store.snapshot(provider: .anilist))
        XCTAssertNil(HomeCacheStore(directory: dir).snapshot(provider: .anilist))
    }

    // MARK: - Home personalization, using only already fetched anime
    private func watchedItem(title: String, aniListID: Int?) -> ContinueWatchingItem {
        ContinueWatchingItem(
            id: UUID(), mediaTitle: title, episodeNumber: 2,
            episodeTitle: nil, imageUrl: "", streamUrl: "https://example.test/master.m3u8",
            headers: nil, subtitle: nil, streamTitle: nil,
            aniListID: aniListID, malID: nil, moduleId: nil, detailHref: nil,
            episodeHref: nil, watchedSeconds: 420, totalSeconds: 1_400,
            totalEpisodes: 12, availableEpisodes: 12, isAiring: false,
            lastWatchedAt: .now, thumbnailUrl: nil
        )
    }

    func testPersonalRecommendationsRankSharedGenresAndExcludeWatchedAnime() {
        let vm = HomeViewModel()
        vm.trending = [makeMedia(id: 10, title: "Blue Lock", provider: .anilist,
                                 genres: ["Sports", "Drama"])]
        vm.seasonal = [makeMedia(id: 11, title: "Haikyuu", provider: .anilist,
                                 genres: ["Sports", "Comedy"]),
                       makeMedia(id: 12, title: "Romance Show", provider: .anilist,
                                 genres: ["Romance"])]
        vm.popular = [makeMedia(id: 13, title: "Another Sports Anime", provider: .anilist,
                                genres: ["Sports", "Drama"])]
        let items = vm.recommendations(for: [watchedItem(title: "Blue Lock", aniListID: 10)])
        XCTAssertEqual(items.map(\.id), [13, 11],
                       "Overlap should rank recommendations and never repeat watched shows")
    }

    func testRecommendationsAreDeduplicatedAcrossFeedRows() {
        let vm = HomeViewModel()
        vm.trending = [makeMedia(id: 10, title: "Blue Lock", provider: .anilist,
                                 genres: ["Sports"])]
        let repeated = makeMedia(id: 11, title: "Haikyuu", provider: .anilist, genres: ["Sports"])
        vm.seasonal = [repeated]
        vm.popular = [repeated]
        XCTAssertEqual(vm.recommendations(for: [
            watchedItem(title: "Blue Lock", aniListID: 10)
        ]).map(\.id), [11])
    }

    func testRecommendationsStayEmptyWithoutViewingHistory() {
        let vm = HomeViewModel()
        vm.trending = [makeMedia(id: 10, title: "Blue Lock", provider: .anilist,
                                 genres: ["Sports"])]
        XCTAssertTrue(vm.recommendations(for: []).isEmpty)
    }
    // Playback Performance must never confuse AVPlayer.readyToPlay with a visible frame.
    func testPlaybackTimingKeepsFiveSeparateMilestones() {
        let diagnostics = PlaybackPerformance.shared
        diagnostics.clear()
        diagnostics.begin(title: "Test Episode", episode: 6)
        diagnostics.sourceSearch(provider: "Test Module")
        diagnostics.moduleResolved()
        diagnostics.episodeResolved()
        diagnostics.streamResolved()
        diagnostics.playerReady()

        guard let pending = diagnostics.samples.first else {
            XCTFail("Missing performance sample")
            return
        }
        XCTAssertNotNil(pending.moduleReadyMs)
        XCTAssertNotNil(pending.episodeReadyMs)
        XCTAssertNotNil(pending.streamReadyMs)
        XCTAssertNotNil(pending.playerReadyMs)
        XCTAssertNil(pending.firstFrameMs)
        XCTAssertEqual(pending.outcome, "Buffering", "readyToPlay must not count as video rendered")

        diagnostics.firstFrameReady()
        guard let rendered = diagnostics.samples.first else {
            XCTFail("Missing completed performance sample")
            return
        }
        XCTAssertNotNil(rendered.firstFrameMs)
        XCTAssertEqual(rendered.outcome, "Playing")
        diagnostics.clear()
    }

}
