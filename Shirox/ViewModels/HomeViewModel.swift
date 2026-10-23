import Foundation
import Combine

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var trending: [Media] = []
    @Published var seasonal: [Media] = []
    @Published var lastSeason: [Media] = []
    @Published var popular: [Media] = []
    @Published var topRated: [Media] = []
    @Published private(set) var personalizedGenres: Set<String> = []
    private var personalizedAnchorID: Int?
    @Published var isLoading = false
    @Published var error: String?

    private var loaded = false
    private var cancellables = Set<AnyCancellable>()

    init(seedCachedFeed: Bool = true) {
        // Production still uses cache-then-refresh. Unit tests opt out so unrelated
        // persisted Home feed rows never leak into isolated recommendation fixtures.
        if seedCachedFeed { seedFromCache() }

        ProviderManager.shared.$orderedProviders
            .map { $0.first?.providerType }
            .removeDuplicates { $0 == $1 }
            .dropFirst() // skip initial value — load() is called by the view's .task
            .sink { [weak self] _ in
                guard let self else { return }
                Task { await self.reload() }
            }
            .store(in: &cancellables)
    }

    func load() async {
        guard !loaded else { return }
        isLoading = true
        error = nil

        do {
            // One call, not five. Each provider decides how few requests that actually takes
            // (AniList: a single aliased GraphQL query; MAL: five, paced). Going through
            // `call` once also means the whole screen comes from one provider — five separate
            // calls could each fall back independently and leave Home showing a mix.
            let feed = try await ProviderManager.shared.call { try await $0.homeFeed() }
            apply(feed)
            if let type = ProviderManager.shared.primary?.providerType {
                HomeCacheStore.shared.save(feed: feed, provider: type)
            }
            loaded = true
        } catch {
            self.error = error.localizedDescription
            // A reload that fails (e.g. right after switching providers) leaves whatever is on
            // screen untouched — nothing above clears it on failure, by design, so a background
            // refresh doesn't flash the screen empty. But with `trending` non-empty, HomeView's
            // own error view never shows either (it only appears when `trending.isEmpty`), so
            // the failure was completely silent: switching to a provider that's down looked
            // exactly like the switch did nothing at all.
            #if os(iOS)
            if !trending.isEmpty {
                let name = ProviderManager.shared.primary?.providerType.displayName ?? "provider"
                ToastManager.shared.show(message: "Couldn't load \(name). Showing previous results.",
                                          type: .error, duration: 4)
            }
            #endif
        }

        isLoading = false
    }

    func reload() async {
        loaded = false
        // Switching providers swaps to that provider's last-known feed straight away, rather
        // than leaving the old provider's rows up while the new request is in flight — which
        // read as the switch having done nothing.
        seedFromCache()
        await load()
    }

    /// Resolve genres for a watched anime even when that anime is not among
    /// today's top/trending entries. Only one existing AniList detail query
    /// is needed, and only when the most recent watched ID changes.
    func refreshPersonalization(from history: [ContinueWatchingItem]) async {
        guard let recent = history.sorted(by: { $0.lastWatchedAt > $1.lastWatchedAt })
                .first(where: { $0.aniListID != nil }),
              let id = recent.aniListID else {
            personalizedAnchorID = nil
            personalizedGenres = []
            return
        }
        guard personalizedAnchorID != id else { return }
        personalizedAnchorID = id
        let available = trending + seasonal + lastSeason + popular + topRated
        if let known = available.first(where: { $0.provider == .anilist && $0.id == id }),
           let genres = known.genres, !genres.isEmpty {
            personalizedGenres = Set(genres)
            return
        }
        // The API also exposes public details without a signed-in AniList
        // account. A failure simply hides this optional row, not Home.
        if let detail = try? await AniListProvider.shared.detail(id: id),
           personalizedAnchorID == id {
            personalizedGenres = Set(detail.genres ?? [])
        }
    }

    /// Local, privacy-preserving recommendations. Ranks the already-loaded
    /// home feed by genres shared with a recently watched title; makes no
    /// additional API calls or invented recommendation claims.
    func recommendations(for history: [ContinueWatchingItem]) -> [Media] {
        let candidates = trending + seasonal + lastSeason + popular + topRated
        guard !history.isEmpty else { return [] }
        let watchedIds = Set(history.compactMap { $0.aniListID })
        let watchedTitles = Set(history.map { $0.mediaTitle.folding(
            options: [.caseInsensitive, .diacriticInsensitive], locale: .current) })
        let anchor = history.sorted { $0.lastWatchedAt > $1.lastWatchedAt }
            .compactMap { watched in
                candidates.first {
                    ($0.provider == .anilist && $0.id == watched.aniListID) ||
                    $0.title.displayTitle.localizedCaseInsensitiveCompare(watched.mediaTitle) == .orderedSame
                }
            }.first
        let localGenres = Set(anchor?.genres ?? [])
        let favorites = localGenres.isEmpty ? personalizedGenres : localGenres
        guard !favorites.isEmpty else { return [] }
        var seen = Set<String>()
        return candidates.filter { media in
            !media.isManga &&
            !(media.provider == .anilist && watchedIds.contains(media.id)) &&
            !watchedTitles.contains(media.title.displayTitle.folding(
                options: [.caseInsensitive, .diacriticInsensitive], locale: .current)) &&
            !Set(media.genres ?? []).isDisjoint(with: favorites) &&
            seen.insert(media.uniqueId).inserted
        }.sorted { a, b in
            let aScore = Set(a.genres ?? []).intersection(favorites).count * 100 + (a.averageScore ?? 0)
            let bScore = Set(b.genres ?? []).intersection(favorites).count * 100 + (b.averageScore ?? 0)
            return aScore > bScore
        }.prefix(12).map { $0 }
    }

    // MARK: - Private

    private func seedFromCache() {
        guard let type = ProviderManager.shared.primary?.providerType,
              let cached = HomeCacheStore.shared.snapshot(provider: type) else { return }
        apply(cached.feed)
    }

    private func apply(_ feed: HomeFeed) {
        trending = feed.trending
        seasonal = feed.seasonal
        lastSeason = feed.lastSeason
        popular = feed.popular
        topRated = feed.topRated
    }
}
