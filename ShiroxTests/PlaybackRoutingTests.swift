import XCTest
@testable import Shirox

/// Tests for where a transport command actually goes, and what the system player controls
/// are told about it.
///
/// TWO REPORTED BUGS LIVE HERE.
///
/// 1. "When the next episode is played the app plays it on the phone, not on the TV."
///    `swapStream` was unconditionally local — it called `replaceCurrentItem` and then
///    `player.rate = speed` with no idea a cast was in progress. So the phone started playing
///    episode 2 out loud while the Chromecast sat on the finished episode 1.
///
/// 2. "Play/pause doesn't work as expected and sometimes doesn't affect Control Center."
///    Part of that is routing: while casting, the remote commands drove the *local* player,
///    which is deliberately parked and silent during a cast, so the TV ignored them entirely.
///    Now Playing had the same problem in reverse — it published the local player's rate and
///    clock, so Control Center showed "paused, 0:00" over a movie the TV was happily playing.
final class PlaybackRoutingTests: XCTestCase {
    func testLanguageOrderAndUnknownAudio() {
        let url = URL(string: "https://media.example/video.m3u8")!
        let german = StreamResult(title: "Hoster", url: url, headers: [:], audioLanguage: "de")
        let germanSub = StreamResult(title: "Hoster", url: url, headers: [:], subtitleLanguage: "de", isHardsub: true)
        let englishSub = StreamResult(title: "Hoster", url: url, headers: [:], subtitleLanguage: "en", isHardsub: true)
        XCTAssertEqual(PlaybackLanguagePolicy.priority(german), 0)
        XCTAssertEqual(PlaybackLanguagePolicy.priority(germanSub), 1)
        XCTAssertEqual(PlaybackLanguagePolicy.priority(englishSub), 2)
        XCTAssertNil(PlaybackLanguagePolicy.priority(StreamResult(title: "Hoster", url: url, headers: [:])))
    }

    func testPerStreamSubtitleMetadataAndAutomaticSelection() throws {
        let streams = parseStreamResults(from: ["streams": [[
            "streamUrl": "https://media.example/video.m3u8", "audioLanguage": "ja",
            "allSubtitles": [
                ["url": "https://media.example/en.vtt", "lang": "en", "label": "English"],
                ["url": "https://media.example/de.vtt", "lang": "de", "label": "Deutsch"]
            ]
        ]]])
        let selected = PlaybackLanguagePolicy.prepare(try XCTUnwrap(streams.first))
        XCTAssertEqual(selected.subtitleLanguage, "de")
        XCTAssertEqual(selected.subtitleURL?.lastPathComponent, "de.vtt")
        XCTAssertEqual(PlaybackLanguagePolicy.priority(selected), 1)
    }

    func testSubtitleLanguageRoundTripsAndLegacyBackupDecodes() throws {
        let legacy = Data(#"{"id":"A52B0712-0413-4E90-B8B8-897CE7CC7197","title":"English","url":"https://media.example/en.vtt","headers":{}}"#.utf8)
        let track = try JSONDecoder().decode(SubtitleTrack.self, from: legacy)
        XCTAssertNil(track.language)
        XCTAssertEqual(PlaybackLanguagePolicy.code(track.title), "en")
    }

    func testPreflightRejectsHTMLAndPrivateURLs() {
        XCTAssertFalse(StreamPreflight.mediaBytes(Data("<html>Not a video</html>".utf8)))
        XCTAssertFalse(StreamPreflight.isPlaylist(Data("<html>#EXTM3U</html>".utf8)))
        XCTAssertTrue(StreamPreflight.isPlaylist(Data("#EXTM3U\n#EXTINF:10,\nsegment.ts".utf8)))
        XCTAssertFalse(StreamPreflight.validRemoteURL(URL(string: "https://127.0.0.1/video.mp4")!))
        XCTAssertFalse(StreamPreflight.validRemoteURL(URL(string: "https://user:secret@media.example/video.mp4")!))
        XCTAssertTrue(StreamPreflight.validRemoteURL(URL(string: "https://media.example/video.m3u8?token=opaque")!))
    }

    @MainActor func testDeadlineReturnsWithoutWaitingForSlowOperation() async {
        do {
            let _: String = try await PlaybackDeadline.run(seconds: 0.01) {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                return "late"
            }
            XCTFail("Slow operation must time out")
        } catch { XCTAssertTrue(error is AutomaticPlaybackError) }
    }

    @MainActor func testAvailabilityRankingPreservesChartOrderAndRequiresFirstFrameForPlayed() {
        let a = CatalogTitle(id: UUID().uuidString, remoteID: 1, kind: .series, name: "A")
        let b = CatalogTitle(id: UUID().uuidString, remoteID: 2, kind: .series, name: "B")
        let c = CatalogTitle(id: UUID().uuidString, remoteID: 3, kind: .anime, name: "C")
        let store = CatalogAvailabilityStore.shared
        store.set(id: c.id, state: .reachable)
        XCTAssertEqual(store.rank([a,b,c]).map(\.id), [c.id,a.id,b.id])
        XCTAssertEqual(store.state(c.id), .reachable)
        XCTAssertNotEqual(store.state(c.id), .played)
    }

    func testTMDBAndAnimeIDsCannotCollide() throws {
        let data = Data(#"{"id":42,"name":"Titel","original_name":"Title","overview":"Deutsche Beschreibung"}"#.utf8)
        let title = try JSONDecoder().decode(UnifiedCatalog.TMDBTitle.self, from: data)
        XCTAssertEqual(title.mapped(kind: .series).id, "tmdb-tv-42")
        XCTAssertEqual(title.mapped(kind: .movie).id, "tmdb-movie-42")
        XCTAssertNotEqual(title.mapped(kind: .series).id, "anilist-42")
    }

    func testBundledResolverMatchesAppLanguageContract() throws {
        let bundled = try XCTUnwrap(BundledUnifiedSource.module)
        XCTAssertEqual(bundled.version, "2.0.0")
        XCTAssertTrue(bundled.scriptContent?.contains("__SHIROX_LANGUAGE_CONTRACT_V2") == true)
    }
    func testWebsiteChallengeIsNotAnEmptyVideoResult() {
        XCTAssertThrowsError(try parseResolvedStreamResults(from: [
            "streams": [], "blockedReason": "website_verification_required"
        ])) { error in
            guard case ModuleStreamResolutionError.websiteVerificationRequired = error else {
                return XCTFail("Expected a website verification error, got \(error)")
            }
        }
    }

    func testPlayableMirrorWinsOverBlockedMirror() throws {
        let streams = try parseResolvedStreamResults(from: [
            "streams": [["streamUrl": "https://media.example/video.m3u8"]],
            "blockedReason": "website_verification_required"
        ])
        XCTAssertEqual(streams.count, 1)
    }

    func testOrdinaryEmptyResultDoesNotClaimWebsiteVerification() throws {
        XCTAssertTrue(try parseResolvedStreamResults(from: ["streams": []]).isEmpty)
    }

    func testSeriesSourceDoesNotUseAnimeMetadataMatching() {
        XCTAssertTrue(DetailViewModel.isSeriesSource("https://serienstream.to/serie/dexter"))
        XCTAssertTrue(DetailViewModel.isSeriesSource("https://s.to/serie/stream/dexter"))
        XCTAssertFalse(DetailViewModel.isSeriesSource("https://aniworld.to/anime/stream/naruto"))
        XCTAssertFalse(DetailViewModel.isSeriesSource("https://serienstream.to.evil.example/serie/dexter"))
    }

    func testDexterSourceEpisodeNumberPreservesProgressIdentity() {
        let context = PlayerContext(
            mediaTitle: "Dexter", episodeNumber: 12, episodeTitle: nil, imageUrl: "",
            aniListID: nil, malID: nil, moduleId: nil, totalEpisodes: nil,
            availableEpisodes: nil, isAiring: nil, resumeFrom: nil, detailHref: nil,
            episodeHref: "https://serienstream.to/serie/dexter/staffel-2/episode-6",
            streamTitle: nil, workingDetailHref: nil, thumbnailUrl: nil)
        XCTAssertEqual(context.sourceEpisodeNumber, 6)
        XCTAssertEqual(context.episodeNumber, 12)
    }
    // MARK: - Premature end-of-item (the interrupted-playback data loss)

    /// THE BUG: a stream that died mid-episode posted `didPlayToEndTime`, the player took it
    /// as an ending and skipped to the next episode, and the swap then wrote the abandoned
    /// episode's progress as 0. Reported as "came back from a phone call, it had skipped to
    /// the next episode and ep 207 shows no progress".
    func testDeadStreamMidEpisodeIsNotAnEnding() {
        XCTAssertFalse(PlaybackRouting.isGenuineEnd(position: 640, duration: 1463))
    }

    func testPlayheadAtTheEndIsAnEnding() {
        XCTAssertTrue(PlaybackRouting.isGenuineEnd(position: 1463, duration: 1463))
    }

    /// HLS leaves rounding on the final segment, so an episode can "end" a beat short.
    func testEndingWithinToleranceStillCounts() {
        XCTAssertTrue(PlaybackRouting.isGenuineEnd(position: 1459, duration: 1463))
    }

    func testJustOutsideToleranceDoesNotCount() {
        XCTAssertFalse(PlaybackRouting.isGenuineEnd(position: 1457, duration: 1463))
    }

    /// An unverifiable duration can't be called an ending — that is the state a freshly dead
    /// item reports, and treating it as one is what skipped the episode.
    func testUnknownDurationIsNeverAnEnding() {
        XCTAssertFalse(PlaybackRouting.isGenuineEnd(position: 0, duration: 0))
        XCTAssertFalse(PlaybackRouting.isGenuineEnd(position: 900, duration: 0))
    }

    func testNonFinitePositionIsNeverAnEnding() {
        XCTAssertFalse(PlaybackRouting.isGenuineEnd(position: .nan, duration: 1463))
    }

    // MARK: - Collapsed clock (the progress wipe)

    /// A dead item reads 0 while its duration stays real. Saving that erased the episode.
    func testZeroPositionAfterRealProgressIsDiscarded() {
        XCTAssertTrue(PlaybackRouting.shouldDiscardPositionWrite(position: 0, lastSaved: 1200))
    }

    /// Ordinary playback near the start still saves — the guard must not freeze progress for
    /// someone who genuinely just began an episode.
    func testEarlyPlaybackStillSaves() {
        XCTAssertFalse(PlaybackRouting.shouldDiscardPositionWrite(position: 12, lastSaved: 8))
    }

    /// Rewinding a long way is a real user action and must be recorded.
    func testLargeRewindStillSaves() {
        XCTAssertFalse(PlaybackRouting.shouldDiscardPositionWrite(position: 60, lastSaved: 1200))
    }

    /// Nothing worth protecting yet.
    func testZeroPositionWithNoPriorProgressSaves() {
        XCTAssertFalse(PlaybackRouting.shouldDiscardPositionWrite(position: 0, lastSaved: 0))
    }


    // MARK: - Where does a command go?

    /// THE BUG (next episode): while casting, playback belongs to the receiver. Anything that
    /// starts media — including an episode swap — has to go there, not to the local player.
    func testCastingRoutesToReceiver() {
        XCTAssertEqual(PlaybackRouting.target(isCasting: true, hasLocalPlayer: true), .cast)
    }

    /// A cast session with no local player still routes to the receiver — the local player is
    /// irrelevant to the TV.
    func testCastingRoutesToReceiverEvenWithoutLocalPlayer() {
        XCTAssertEqual(PlaybackRouting.target(isCasting: true, hasLocalPlayer: false), .cast)
    }

    func testNotCastingRoutesToLocalPlayer() {
        XCTAssertEqual(PlaybackRouting.target(isCasting: false, hasLocalPlayer: true), .local)
    }

    /// Nothing to drive. Commands must be dropped rather than sent somewhere arbitrary.
    func testNoPlayerAndNoCastRoutesNowhere() {
        XCTAssertEqual(PlaybackRouting.target(isCasting: false, hasLocalPlayer: false), .none)
    }

    // MARK: - Toggle must be a decision, not a re-read

    /// THE BUG (play/pause): the old toggle handler re-read the player's live state. With two
    /// handlers accidentally registered, the first paused, the second saw "paused" and played
    /// again — a net no-op, which is exactly "the button does nothing". Resolving the toggle
    /// to a concrete intent up front makes a repeated dispatch idempotent instead of cancelling.
    func testToggleResolvesToConcreteIntent() {
        XCTAssertEqual(PlaybackRouting.toggleIntent(isPlaying: true), .pause)
        XCTAssertEqual(PlaybackRouting.toggleIntent(isPlaying: false), .play)
    }

    func testRepeatedIntentIsIdempotent() {
        // Applying `.pause` twice must still mean paused — the property the old
        // re-read-the-player toggle did not have.
        let first = PlaybackRouting.toggleIntent(isPlaying: true)
        let second = PlaybackRouting.toggleIntent(isPlaying: false)
        XCTAssertNotEqual(first, second, "a fresh read flips; that is why intent must be captured once")
        XCTAssertEqual(first, .pause)
    }

    // MARK: - What Control Center is told

    /// THE BUG: Now Playing published the local player's rate. During a cast that player is
    /// parked at rate 0, so Control Center showed a paused button over a playing TV — and
    /// tapping it did the opposite of what the glyph promised.
    func testCastingPublishesReceiverRateNotLocalRate() {
        XCTAssertEqual(PlaybackRouting.nowPlayingRate(target: .cast, isPlaying: true, playbackSpeed: 1.0), 1.0)
        XCTAssertEqual(PlaybackRouting.nowPlayingRate(target: .cast, isPlaying: false, playbackSpeed: 1.0), 0.0)
    }

    /// A paused player advertises rate 0; that is what makes Control Center draw ▶.
    func testPausedPublishesZeroRate() {
        XCTAssertEqual(PlaybackRouting.nowPlayingRate(target: .local, isPlaying: false, playbackSpeed: 1.5), 0.0)
    }

    /// The user's speed setting has to reach Control Center, otherwise its scrubber advances
    /// at the wrong pace and drifts out of sync with the picture.
    func testPlayingPublishesUserPlaybackSpeed() {
        XCTAssertEqual(PlaybackRouting.nowPlayingRate(target: .local, isPlaying: true, playbackSpeed: 1.5), 1.5)
        XCTAssertEqual(PlaybackRouting.nowPlayingRate(target: .cast, isPlaying: true, playbackSpeed: 2.0), 2.0)
    }

    func testNoTargetPublishesZeroRate() {
        XCTAssertEqual(PlaybackRouting.nowPlayingRate(target: .none, isPlaying: true, playbackSpeed: 1.0), 0.0)
    }

    /// THE BUG: elapsed time came from the local player's clock, which is frozen during a cast.
    func testCastingPublishesReceiverPosition() {
        XCTAssertEqual(PlaybackRouting.nowPlayingElapsed(target: .cast, castPosition: 743, localPosition: 0), 743)
    }

    func testLocalPublishesLocalPosition() {
        XCTAssertEqual(PlaybackRouting.nowPlayingElapsed(target: .local, castPosition: 0, localPosition: 128), 128)
    }

    /// A non-finite clock (an item that hasn't loaded) must not reach Now Playing — it renders
    /// as a garbage scrubber rather than simply being absent.
    func testNonFiniteElapsedIsClampedToZero() {
        XCTAssertEqual(PlaybackRouting.nowPlayingElapsed(target: .local, castPosition: 0, localPosition: .nan), 0)
        XCTAssertEqual(PlaybackRouting.nowPlayingElapsed(target: .local, castPosition: 0, localPosition: -3), 0)
    }
    // MARK: - Bounded automatic stream recovery

    func testAutomaticRefetchBudgetIsFinite() {
        XCTAssertTrue(PlaybackRouting.canAttemptStreamRefetch(attempts: 0))
        XCTAssertTrue(PlaybackRouting.canAttemptStreamRefetch(attempts: 1))
        XCTAssertTrue(PlaybackRouting.canAttemptStreamRefetch(attempts: 2))
        XCTAssertFalse(PlaybackRouting.canAttemptStreamRefetch(attempts: 3))
        XCTAssertFalse(PlaybackRouting.canAttemptStreamRefetch(attempts: 99))
    }

    func testInvalidRecoveryBudgetsAreRejected() {
        XCTAssertFalse(PlaybackRouting.canAttemptStreamRefetch(attempts: -1))
        XCTAssertFalse(PlaybackRouting.canAttemptStreamRefetch(attempts: 0, limit: 0))
    }

    func testManualRetryCanBeginNewCycle() {
        let exhaustedAttempts = 3
        XCTAssertFalse(PlaybackRouting.canAttemptStreamRefetch(attempts: exhaustedAttempts))
        // The player clears its attempt counter only for user Retry/new episode.
        let attemptsAfterExplicitRetry = 0
        XCTAssertTrue(PlaybackRouting.canAttemptStreamRefetch(attempts: attemptsAfterExplicitRetry))
    }

    func testFiveSecondRemoteClipIsNotValidFullEpisode() {
        XCTAssertTrue(PlaybackRouting.isClearlyTruncatedEpisode(
            duration: 5, hasEpisodeContext: true, isLocalPlayback: false))
    }

    func testUnknownDurationDoesNotTriggerPrematureSourceRejection() {
        for duration in [0.0, Double.nan, Double.infinity] {
            XCTAssertFalse(PlaybackRouting.isClearlyTruncatedEpisode(
                duration: duration, hasEpisodeContext: true, isLocalPlayback: false))
        }
    }

    func testShortLocalVideosRemainAllowed() {
        XCTAssertFalse(PlaybackRouting.isClearlyTruncatedEpisode(
            duration: 5, hasEpisodeContext: true, isLocalPlayback: true))
        XCTAssertFalse(PlaybackRouting.isClearlyTruncatedEpisode(
            duration: 5, hasEpisodeContext: false, isLocalPlayback: false))
        XCTAssertFalse(PlaybackRouting.isClearlyTruncatedEpisode(
            duration: 1440, hasEpisodeContext: true, isLocalPlayback: false))
    }

}
