import XCTest
@testable import Shirox

/// Tests for the pure "should we start prefetching the next episode now?" decision.
///
/// The prefetch fires once per episode at the `watchedPercentage` threshold, but only when a
/// next-episode loader actually exists, and never twice. This pins down exactly that.
final class PlayerNextEpisodePrefetchTests: XCTestCase {

    // MARK: Fires once, at/after the threshold

    func testStartsAtThreshold() {
        XCTAssertTrue(PlayerNextEpisodePrefetch.shouldStart(
            progress: 0.90, threshold: 0.90, hasLoader: true, alreadyStarted: false))
    }

    func testStartsAboveThreshold() {
        XCTAssertTrue(PlayerNextEpisodePrefetch.shouldStart(
            progress: 0.95, threshold: 0.90, hasLoader: true, alreadyStarted: false))
    }

    // MARK: Does not fire

    func testDoesNotStartBelowThreshold() {
        XCTAssertFalse(PlayerNextEpisodePrefetch.shouldStart(
            progress: 0.50, threshold: 0.90, hasLoader: true, alreadyStarted: false))
    }

    /// No next-episode loader (last episode, or sequel-only) → nothing to prefetch.
    func testDoesNotStartWithoutLoader() {
        XCTAssertFalse(PlayerNextEpisodePrefetch.shouldStart(
            progress: 0.99, threshold: 0.90, hasLoader: false, alreadyStarted: false))
    }

    /// Already kicked off this episode → never start a second prefetch (the loader's cursor
    /// is stateful; a second call would advance it).
    func testDoesNotStartWhenAlreadyStarted() {
        XCTAssertFalse(PlayerNextEpisodePrefetch.shouldStart(
            progress: 0.99, threshold: 0.90, hasLoader: true, alreadyStarted: true))
    }

    /// A custom (lower) watchedPercentage still gates correctly.
    func testRespectsCustomThreshold() {
        XCTAssertFalse(PlayerNextEpisodePrefetch.shouldStart(
            progress: 0.79, threshold: 0.80, hasLoader: true, alreadyStarted: false))
        XCTAssertTrue(PlayerNextEpisodePrefetch.shouldStart(
            progress: 0.80, threshold: 0.80, hasLoader: true, alreadyStarted: false))
    }

    // MARK: - Chapter timing

    private func credits(
        verified: Bool = true, end: Double = 1_424, preview: Bool = false
    ) -> SkipSegments {
        var result = SkipSegments()
        result.isDurationVerified = verified
        result.autoSkipIntro = verified
        result.autoNextCredits = verified
        result.intro = .init(startMs: 80_000, endMs: 170_000)
        result.credits = .init(startMs: 1_340_000, endMs: end * 1_000)
        if preview { result.preview = .init(startMs: 1_420_000, endMs: 1_435_000) }
        return result
    }

    func testSkipAppearsOnlyWithinExactSegment() {
        let segments = credits()
        XCTAssertNil(PlayerChapterTiming.activeSegment(at: 79.9, segments: segments))
        XCTAssertEqual(PlayerChapterTiming.activeSegment(at: 80, segments: segments), .intro)
        XCTAssertEqual(PlayerChapterTiming.activeSegment(at: 169.9, segments: segments), .intro)
        XCTAssertNil(PlayerChapterTiming.activeSegment(at: 170, segments: segments))
    }

    func testOnlyDurationMatchedIntroMayAutoSkip() {
        XCTAssertTrue(PlayerChapterTiming.shouldAutoSkip(.intro, segments: credits()))
        XCTAssertFalse(PlayerChapterTiming.shouldAutoSkip(.intro, segments: credits(verified: false)))
        XCTAssertFalse(PlayerChapterTiming.shouldAutoSkip(.credits, segments: credits()))
        XCTAssertFalse(PlayerChapterTiming.shouldAutoSkip(.preview, segments: credits()))
    }

    func testNextPromptFollowsVerifiedCreditsNotGuessedCredits() {
        let valid = credits()
        XCTAssertFalse(PlayerChapterTiming.shouldOfferNext(
            at: 1_339, duration: 1_425, segments: valid, hasNext: true))
        XCTAssertTrue(PlayerChapterTiming.shouldOfferNext(
            at: 1_340, duration: 1_425, segments: valid, hasNext: true))
        XCTAssertFalse(PlayerChapterTiming.shouldOfferNext(
            at: 1_340, duration: 1_425, segments: credits(verified: false), hasNext: true))
        XCTAssertTrue(PlayerChapterTiming.shouldOfferNext(
            at: 1_407, duration: 1_425, segments: nil, hasNext: true))
        XCTAssertFalse(PlayerChapterTiming.shouldOfferNext(
            at: 1_410, duration: 1_425, segments: nil, hasNext: false))
    }

    func testAutoNextStartsAsSoonAsVerifiedCreditsBegin() {
        let markers = credits()
        XCTAssertFalse(PlayerChapterTiming.shouldAdvanceAtCreditsStart(
            at: 1_339.9, duration: 1_425, segments: markers))
        XCTAssertTrue(PlayerChapterTiming.shouldAdvanceAtCreditsStart(
            at: 1_340, duration: 1_425, segments: markers))
        XCTAssertTrue(PlayerChapterTiming.shouldAdvanceAtCreditsStart(
            at: 1_390, duration: 1_425, segments: markers))
        XCTAssertFalse(PlayerChapterTiming.shouldAdvanceAtCreditsStart(
            at: 1_340, duration: 1_425, segments: credits(verified: false)))
    }

    func testAutoNextIgnoresPostCreditScenesAndPreviews() {
        // Long remaining footage does not delay Auto Next when the credits
        // start time is verified: that is the requested behavior.
        XCTAssertTrue(PlayerChapterTiming.shouldAdvanceAtCreditsStart(
            at: 1_340, duration: 1_500, segments: credits(preview: true)))
        XCTAssertFalse(PlayerChapterTiming.shouldAdvanceAtCreditsStart(
            at: 1_340, duration: 1_500, segments: credits(verified: false)))
        XCTAssertFalse(PlayerChapterTiming.shouldAdvanceAtCreditsStart(
            at: 1_500, duration: 1_500, segments: credits()))
        XCTAssertFalse(PlayerChapterTiming.shouldAdvanceAtCreditsStart(
            at: .nan, duration: 1_425, segments: credits()))
        XCTAssertFalse(PlayerChapterTiming.shouldAdvanceAtCreditsStart(
            at: 1_340, duration: 0, segments: credits()))
    }

    func testIntroVerificationNeverAuthorizesAnUnverifiedOutro() {
        var chapters = credits()
        chapters.autoNextCredits = false
        XCTAssertTrue(PlayerChapterTiming.shouldAutoSkip(.intro, segments: chapters))
        XCTAssertFalse(PlayerChapterTiming.shouldAdvanceAtCreditsStart(
            at: 1_340, duration: 1_425, segments: chapters))
        XCTAssertFalse(PlayerChapterTiming.shouldOfferNext(
            at: 1_340, duration: 1_425, segments: chapters, hasNext: true))
    }

    func testOutroVerificationNeverAuthorizesUnverifiedIntro() {
        var chapters = credits()
        chapters.autoSkipIntro = false
        XCTAssertFalse(PlayerChapterTiming.shouldAutoSkip(.intro, segments: chapters))
        XCTAssertTrue(PlayerChapterTiming.shouldAdvanceAtCreditsStart(
            at: 1_340, duration: 1_425, segments: chapters))
    }

    func testInaccurateMarkersAreOnlyManual() {
        var chapters = credits()
        chapters.isDurationVerified = false
        XCTAssertEqual(PlayerChapterTiming.activeSegment(at: 100, segments: chapters), .intro)
        XCTAssertFalse(PlayerChapterTiming.shouldAutoSkip(.intro, segments: chapters))
        XCTAssertFalse(PlayerChapterTiming.shouldAdvanceAtCreditsStart(
            at: 1_340, duration: 1_425, segments: chapters))
    }

    func testPrefetchBeforeCreditsOrLastNinetySeconds() {
        XCTAssertTrue(PlayerNextEpisodePrefetch.shouldStart(
            progress: 0.7, threshold: 0.9, hasLoader: true,
            alreadyStarted: false, remainingSeconds: 85))
        XCTAssertTrue(PlayerNextEpisodePrefetch.shouldStart(
            progress: 0.7, threshold: 0.9, hasLoader: true,
            alreadyStarted: false, remainingSeconds: 300,
            creditsStart: 1_340, currentTime: 1_315))
        XCTAssertFalse(PlayerNextEpisodePrefetch.shouldStart(
            progress: 0.7, threshold: 0.9, hasLoader: true,
            alreadyStarted: true, remainingSeconds: 10))
        XCTAssertFalse(PlayerNextEpisodePrefetch.shouldStart(
            progress: 0.7, threshold: 0.9, hasLoader: false,
            alreadyStarted: false, remainingSeconds: 10))
    }
}


@MainActor
final class InstantPlayUXTests: XCTestCase {
    func testMultilingualQueriesKeepExactTitleFirstAndDeduplicate() {
        let queries = ModuleSeasonFallback.queries(
            for: "Blue Lock Season 2",
            alternatives: ["Blue Lock", "BLUE LOCK", "ブルーロック", "Blue Lock 2nd Season"]
        )
        XCTAssertEqual(queries.first, "Blue Lock Season 2")
        XCTAssertTrue(queries.contains("Blue Lock"))
        XCTAssertTrue(queries.contains("ブルーロック"))
        XCTAssertEqual(queries.filter { $0.caseInsensitiveCompare("Blue Lock") == .orderedSame }.count, 1)
    }

    func testSeasonSuffixIsNotStrippedFromNormalTitles() {
        XCTAssertEqual(ModuleSeasonFallback.queries(for: "Death Note"), ["Death Note"])
        XCTAssertEqual(ModuleSeasonFallback.queries(for: "Blue Lock Staffel 2"),
                       ["Blue Lock Staffel 2", "Blue Lock"])
        XCTAssertEqual(ModuleSeasonFallback.queries(for: "Blue Lock S2"),
                       ["Blue Lock S2", "Blue Lock"])
    }

    func testMetricsDoNotCountResolvedURLAsVideoFrame() {
        let performance = PlaybackPerformance.shared
        performance.clear()
        performance.begin(title: "Blue Lock", episode: 14)
        performance.sourceSearch(provider: "AniWorld")
        performance.streamResolved()
        XCTAssertNotNil(performance.samples.first?.streamReadyMs)
        XCTAssertNil(performance.samples.first?.firstFrameMs,
                     "A URL response is not the first displayed frame.")
        performance.firstFrameReady()
        let sample = performance.samples.first
        XCTAssertNotNil(sample?.firstFrameMs)
        XCTAssertGreaterThanOrEqual(sample?.firstFrameMs ?? -1, sample?.streamReadyMs ?? 0)
        XCTAssertEqual(sample?.outcome, "Playing")
    }

    func testFailureIsNotReportedAsFastPlayback() {
        let performance = PlaybackPerformance.shared
        performance.clear()
        performance.begin(title: "Dexter", episode: 1)
        performance.failed()
        XCTAssertEqual(performance.samples.first?.outcome, "Failed")
        XCTAssertNil(performance.samples.first?.firstFrameMs)
        performance.clear()
    }

    func testCacheCountersKeepIndependentHitCounts() {
        let performance = PlaybackPerformance.shared
        performance.clear()
        performance.cacheHit(script: true)
        performance.cacheHit(script: false)
        performance.cacheHit(script: false)
        XCTAssertEqual(performance.scriptCacheHits, 1)
        XCTAssertEqual(performance.metadataCacheHits, 2)
        performance.clear()
    }
}
