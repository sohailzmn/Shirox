import XCTest
@testable import Shirox

/// Tests for the message shown when every tracker fails.
///
/// The fallback used to be a primary and exactly one spare, so a third provider could be signed
/// in, ordered and displayed while never actually being tried. Generalising it to a chain is a
/// prerequisite for adding Trakt — and the failure message has to name every service attempted,
/// because reporting only the last made it look as though the provider the user chose had never
/// been consulted at all.
final class ProviderFallbackChainTests: XCTestCase {

    private struct Down: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }

    private func message(_ failures: [(provider: ProviderType, error: Error)]) -> String {
        ProviderError.allProvidersFailed(failures).localizedDescription
    }

    func testNamesEveryProviderTried() {
        let text = message([
            (.mal, Down(text: "The service is busy.")),
            (.anilist, Down(text: "The AniList API has been temporarily disabled."))
        ])
        XCTAssertTrue(text.contains("MyAnimeList"), "the chosen provider must be named")
        XCTAssertTrue(text.contains("AniList"))
    }

    func testIncludesEachServicesOwnExplanation() {
        let text = message([
            (.mal, Down(text: "The service is busy.")),
            (.anilist, Down(text: "The AniList API has been temporarily disabled."))
        ])
        XCTAssertTrue(text.contains("The service is busy."))
        XCTAssertTrue(text.contains("The AniList API has been temporarily disabled."))
    }

    /// Three providers is the case this was generalised for.
    func testHandlesMoreThanTwoProviders() {
        let text = message([
            (.mal, Down(text: "busy")),
            (.anilist, Down(text: "disabled")),
            (.local, Down(text: "nothing stored"))
        ])
        for name in [ProviderType.mal, .anilist, .local].map(\.displayName) {
            XCTAssertTrue(text.contains(name), "\(name) was tried and must be named")
        }
    }

    /// One signed-in provider shouldn't read as though several were tried.
    func testSingleProviderReadsAsSingular() {
        let text = message([(.mal, Down(text: "busy"))])
        XCTAssertTrue(text.contains("is unavailable"), "got: \(text)")
        XCTAssertFalse(text.contains("are unavailable"))
    }

    func testTwoProvidersReadAsPlural() {
        let text = message([(.mal, Down(text: "a")), (.anilist, Down(text: "b"))])
        XCTAssertTrue(text.contains("are unavailable"), "got: \(text)")
    }

    /// Defensive: an empty chain must still say something usable rather than a bare fragment.
    func testEmptyChainStillReads() {
        XCTAssertEqual(message([]), "No tracker is available.")
    }
}

/// Tests for which failures are worth asking the next provider about.
///
/// THE BUG: AniList explains an outage in its response body, so "the API has been temporarily
/// disabled" arrives as a 403 carrying text. Adding a case for that message and leaving this
/// switch alone dropped it into `default`, and the app stopped falling back to MyAnimeList for
/// the one failure it matters most for. Reported simply as "it doesn't automatically switch".
@MainActor
final class ProviderFallbackEligibilityTests: XCTestCase {

    private var manager: ProviderManager { ProviderManager.shared }

    // MARK: - AniList outages must fall through to the other tracker

    func testServiceMessageOutageIsEligible() {
        let outage = AniListError.serviceMessage(
            code: 403, message: "The AniList API has been temporarily disabled.")
        XCTAssertTrue(manager.isFallbackEligible(outage))
    }

    func testServiceMessageServerErrorIsEligible() {
        XCTAssertTrue(manager.isFallbackEligible(
            AniListError.serviceMessage(code: 503, message: "Down for maintenance")))
    }

    /// A bare status and one carrying a message must be classified identically — the wording is
    /// for the reader, not for the routing.
    func testMessageAndBareStatusAgree() {
        for code in [403, 500, 503, 400, 404] {
            XCTAssertEqual(
                manager.isFallbackEligible(AniListError.httpError(code)),
                manager.isFallbackEligible(AniListError.serviceMessage(code: code, message: "x")),
                "status \(code) classified differently with and without a message"
            )
        }
    }

    func testHttpOutagesAreEligible() {
        XCTAssertTrue(manager.isFallbackEligible(AniListError.httpError(403)))
        XCTAssertTrue(manager.isFallbackEligible(AniListError.httpError(500)))
        XCTAssertTrue(manager.isFallbackEligible(AniListError.rateLimited))
    }

    // MARK: - Failures another provider can't fix

    /// A bad request stays bad on the next tracker; retrying it only delays the message.
    func testClientErrorsAreNotEligible() {
        XCTAssertFalse(manager.isFallbackEligible(AniListError.httpError(400)))
        XCTAssertFalse(manager.isFallbackEligible(AniListError.serviceMessage(code: 400, message: "Bad query")))
    }

    func testCancellationIsNotEligible() {
        XCTAssertFalse(manager.isFallbackEligible(CancellationError()))
        XCTAssertFalse(manager.isFallbackEligible(URLError(.cancelled)))
    }

    /// Having already exhausted every provider, there is nothing left to try.
    func testExhaustedChainIsNotEligible() {
        XCTAssertFalse(manager.isFallbackEligible(ProviderError.allProvidersFailed([])))
    }

    func testProviderServerErrorsAreEligible() {
        XCTAssertTrue(manager.isFallbackEligible(ProviderError.serverError(504)))
    }
}

/// Tells an announced AniList outage apart from a rate limit.
///
/// AniList switches its whole API off during stability incidents and says so in the body —
/// every request, down to `{ Media(id: 1) { id } }`, comes back 403 with "The AniList API has
/// been temporarily disabled due to severe stability issues." Treating that as a rate limit
/// meant three requests at a service that had just said it was down, and each one widened the
/// shared throttle's gap, so an outage made every other AniList call progressively slower.
final class AniListOutageClassificationTests: XCTestCase {

    func testAniListsOwnOutageWordingIsRecognised() {
        XCTAssertTrue(AniListService.isAnnouncedOutage(
            "The AniList API has been temporarily disabled due to severe stability issues."))
    }

    func testWordingIsMatchedRegardlessOfCase() {
        XCTAssertTrue(AniListService.isAnnouncedOutage(
            "THE ANILIST API HAS BEEN TEMPORARILY DISABLED"))
    }

    func testTemporarilyUnavailableAlsoCounts() {
        XCTAssertTrue(AniListService.isAnnouncedOutage("The API is temporarily unavailable."))
    }

    /// A real rate limit must stay on the retry-and-back-off path.
    func testRateLimitWordingIsNotAnOutage() {
        XCTAssertFalse(AniListService.isAnnouncedOutage("Too Many Requests"))
        XCTAssertFalse(AniListService.isAnnouncedOutage("Rate limit exceeded"))
    }

    /// Ordinary GraphQL complaints are not outages either.
    func testUnrelatedMessagesAreNotOutages() {
        XCTAssertFalse(AniListService.isAnnouncedOutage("Not Found"))
        XCTAssertFalse(AniListService.isAnnouncedOutage("Invalid token"))
        XCTAssertFalse(AniListService.isAnnouncedOutage(""))
    }

    /// "Disabled" on its own isn't enough — a disabled *account* or list entry is not the API
    /// being switched off, and must not skip the retry path.
    func testDisabledWithoutTheAPIIsNotAnOutage() {
        XCTAssertFalse(AniListService.isAnnouncedOutage("This account has been disabled."))
    }
}


// Live-action metadata is intentionally independent of AniList/MAL accounts and
// streaming modules. Search suffixes must resolve to the correct show's season.
@MainActor
final class LiveActionCatalogQueryTests: XCTestCase {
    func testDexterResurrectedSeasonTwoUsesActualSeriesTitle() {
        XCTAssertEqual(LiveActionCatalog.seriesQuery("Dexter: Resurrected Season 2"),
                       "Dexter: resurrection")
        XCTAssertEqual(LiveActionCatalog.requestedSeason(in: "Dexter: Resurrected Season 2"), 2)
    }

    func testGermanSeasonSyntaxAlsoWorks() {
        XCTAssertEqual(LiveActionCatalog.seriesQuery("Dexter Resurrection Staffel 2"),
                       "Dexter Resurrection")
        XCTAssertEqual(LiveActionCatalog.requestedSeason(in: "Dexter Resurrection Staffel 2"), 2)
    }

    func testRegularSeriesAndFilmQueriesDoNotInventSeasons() {
        XCTAssertNil(LiveActionCatalog.requestedSeason(in: "Interstellar"))
        XCTAssertEqual(LiveActionCatalog.seriesQuery("Dexter"), "Dexter")
        XCTAssertEqual(LiveActionCatalog.seriesQuery("The Dark Knight"), "The Dark Knight")
    }

    func testCompactSeasonSyntax() {
        XCTAssertEqual(LiveActionCatalog.requestedSeason(in: "Dexter Resurrection S2"), 2)
        XCTAssertEqual(LiveActionCatalog.seriesQuery("Dexter Resurrection S2"), "Dexter Resurrection")
    }
}


/// TVmaze air dates are catalog metadata, not a promise of streaming access.
/// Regression for Dexter: Resurrection season 2 on 2026-11-02.
final class LiveActionEpisodeReleaseTests: XCTestCase {
    private func utcCalendar() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }

    func testDexterSeasonTwoEpisodeOneAlreadyAired() {
        let c = utcCalendar()
        let now = c.date(from: DateComponents(year: 2026, month: 11, day: 2))!
        let episode = LiveActionEpisode(
            id: 1, number: 1, name: "Risky Business", airdate: "2026-10-30"
        )
        XCTAssertEqual(episode.releaseStatus(asOf: now, calendar: c), .aired)
    }

    func testDexterSeasonTwoEpisodeTwoStillUpcoming() {
        let c = utcCalendar()
        let now = c.date(from: DateComponents(year: 2026, month: 11, day: 2))!
        let episode = LiveActionEpisode(
            id: 2, number: 2, name: "Young Blood", airdate: "2026-11-06"
        )
        XCTAssertEqual(episode.releaseStatus(asOf: now, calendar: c), .upcoming)
    }

    func testEpisodeReleaseOnAirDateIsAired() {
        let c = utcCalendar()
        let date = c.date(from: DateComponents(year: 2026, month: 10, day: 30))!
        let episode = LiveActionEpisode(
            id: 3, number: 1, name: "Risky Business", airdate: "2026-10-30"
        )
        XCTAssertEqual(episode.releaseStatus(asOf: date, calendar: c), .aired)
    }

    func testMissingOrInvalidAirDatesRemainUnknown() {
        let c = utcCalendar()
        let now = c.date(from: DateComponents(year: 2026, month: 11, day: 2))!
        for raw in [nil, "", "2026-02-31", "invalid"] as [String?] {
            let episode = LiveActionEpisode(id: 4, number: nil, name: "Special", airdate: raw)
            XCTAssertEqual(episode.releaseStatus(asOf: now, calendar: c), .unknown)
        }
    }
}
