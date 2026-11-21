import SwiftUI

struct CatalogAccessSettings: View {
    @ObservedObject private var config = CatalogConfiguration.shared
    @State private var token = ""
    var body: some View {
        Section("Serien- und Filmkatalog") {
            Image("TMDBLogo").resizable().scaledToFit().frame(width: 70, height: 50).accessibilityLabel("TMDB")
            SecureField("Kostenloser TMDB-Lesezugang", text: $token)
                .autocorrectionDisabled()
            Button("Katalogzugang speichern") { config.save(token); token = "" }
                .disabled(token.isEmpty)
            if config.hasToken {
                Button("Katalogzugang entfernen", role: .destructive) { config.remove() }
            }
            if let message = config.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            Link("Kostenlosen TMDB-Zugang einrichten", destination: URL(string: "https://www.themoviedb.org/settings/api")!)
            Text("Einmalige Einrichtung für deutsche Beschreibungen und Toplisten. Keine kostenpflichtigen Dienste und kein eigener Server. Streamingquellen funktionieren unabhängig davon.")
                .font(.caption).foregroundStyle(.secondary)
            Link("Metadaten und Bilder: TMDB", destination: URL(string: "https://www.themoviedb.org")!)
            Text("This product uses the TMDB API but is not endorsed or certified by TMDB.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct UnifiedHomeSections: View {
    @ObservedObject var animeVM: HomeViewModel
    @ObservedObject private var catalog = UnifiedCatalog.shared
    @ObservedObject private var sources = SourceCatalog.shared
    @ObservedObject private var availability = CatalogAvailabilityStore.shared
    @ObservedObject private var configuration = CatalogConfiguration.shared
    @ObservedObject private var history = ContinueWatchingManager.shared
    @ObservedObject private var watchlist = CatalogWatchlist.shared
    @State private var filter = "Alle"
    private var rows: [CatalogRow] {
        // Browse the catalogues that actually supply this app's episodes.
        var rows = sources.rows
        if filter == "Filme" { rows = catalog.rows.filter { $0.titles.first?.kind == .movie } }
        let visible = rows.map { row in
            CatalogRow(id: row.id, name: row.name, titles: availability.rank(row.titles.filter { filter == "Alle" || $0.kind.label == filter }))
        }.filter { !$0.titles.isEmpty }
        let all = visible.flatMap { $0.titles }
        var seen = Set<String>()
        let confirmed = availability.rank(all).filter { availability.state($0.id) == .played && seen.insert($0.id).inserted }
        let genres = Set(history.items.flatMap { item in all.first(where: { $0.name.caseInsensitiveCompare(item.mediaTitle) == .orderedSame })?.genres ?? [] })
        seen = []
        let suggestions = all.filter { !genres.isEmpty && !Set($0.genres).isDisjoint(with: genres) && seen.insert($0.id).inserted }
        var result = visible
        let saved = watchlist.titles.filter { filter == "Alle" || $0.kind.label == filter }
        if !saved.isEmpty { result.insert(CatalogRow(id: "watchlist", name: "Meine Merkliste", titles: availability.rank(saved)), at: 0) }
        if !suggestions.isEmpty { result.insert(CatalogRow(id: "for-you", name: "Für dich", titles: availability.rank(suggestions)), at: 0) }
        if !confirmed.isEmpty { result.insert(CatalogRow(id: "confirmed", name: "Zuletzt erfolgreich abgespielt", titles: confirmed), at: 0) }
        return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Picker("Inhalte", selection: $filter) {
                ForEach(["Alle", "Serien", "Anime", "Filme"], id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.segmented).padding(.horizontal)
            if let featured = rows.first?.titles.first {
                NavigationLink { CatalogDetailScreen(title: featured) } label: { CatalogHero(title: featured) }
                    .buttonStyle(.plain)
            }
            if sources.loading { ProgressView("Quellenkatalog wird geladen …").padding(.horizontal) }
            ForEach(rows) { row in CatalogShelf(row: row) }
            ForEach(sources.errors, id: \.self) { message in
                Text(message).font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
            }
            if let error = catalog.error, filter == "Filme" {
                Label(error, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
            }
            if rows.isEmpty, !sources.loading {
                Text("Noch keine Katalogdaten verfügbar. Die Suche in deinen Streamingquellen bleibt nutzbar.")
                    .foregroundStyle(.secondary).padding()
            }
            Link("Metadaten und Bilder: TMDB", destination: URL(string: "https://www.themoviedb.org")!)
                .font(.caption2).foregroundStyle(.secondary).padding(.horizontal)
        }
        .task { async let metadata: () = catalog.load(); async let source: () = sources.load(); _ = await (metadata, source) }
        .onChange(of: configuration.hasToken) { _ in Task { await catalog.load() } }
    }
}

struct CatalogShelf: View {
    let row: CatalogRow
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(row.name).font(.title3.bold()).padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(row.titles) { title in
                        NavigationLink { CatalogDetailScreen(title: title) } label: {
                            CatalogPoster(title: title).frame(width: 145)
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal)
            }
        }
    }
}

struct CatalogPoster: View {
    let title: CatalogTitle
    @ObservedObject private var availability = CatalogAvailabilityStore.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                AsyncImage(url: title.poster.flatMap(URL.init(string:))) { image in image.resizable().scaledToFill() }
                placeholder: { ZStack { Color.gray.opacity(0.2); Image(systemName: "play.rectangle").font(.largeTitle) } }
                    .frame(width: geometry.size.width, height: geometry.size.height).clipped()
            }.aspectRatio(2.0 / 3.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            Text(title.name).font(.subheadline.weight(.semibold)).lineLimit(2)
            Text(availability.state(title.id).label).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }.foregroundStyle(.primary)
    }
}

private struct CatalogHero: View {
    let title: CatalogTitle
    var showsAction = true
    @Environment(\.horizontalSizeClass) private var sizeClass
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomLeading) {
                AsyncImage(url: (title.backdrop ?? title.poster).flatMap(URL.init(string:))) { image in image.resizable().scaledToFill() }
                placeholder: { Color.gray.opacity(0.2) }
                    .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.95)], startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 10) {
                    Text(title.kind.label.uppercased()).font(.caption.bold()).tracking(2)
                    Text(title.name).font(sizeClass == .compact ? .title2.bold() : .largeTitle.bold()).lineLimit(2)
                    if let synopsis = title.synopsis, !synopsis.isEmpty { Text(synopsis).font(.subheadline).lineLimit(2) }
                    if showsAction {
                        Label("Details und Wiedergabe", systemImage: "play.fill")
                            .font(.subheadline.bold()).padding(.horizontal, 16).padding(.vertical, 10)
                            .background(.white, in: Capsule()).foregroundStyle(.black)
                    }
                }.foregroundStyle(.white).padding(sizeClass == .compact ? 16 : 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }.frame(height: sizeClass == .compact ? 260 : 330)
            .clipShape(RoundedRectangle(cornerRadius: 18)).padding(.horizontal)
    }
}

struct CatalogDetailScreen: View {
    let title: CatalogTitle
    @State private var seasons: [CatalogSeason] = []
    @State private var episodes: [CatalogEpisode] = []
    @State private var season = 1
    @State private var loading = false
    @State private var error: String?
    @State private var playTask: Task<Void, Never>?
    @State private var sourceSynopsis: String?
    @State private var sourceEpisodes: [EpisodeLink] = []
    @ObservedObject private var availability = CatalogAvailabilityStore.shared
    @ObservedObject private var watchlist = CatalogWatchlist.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                CatalogHero(title: title, showsAction: false)
                VStack(alignment: .leading, spacing: 16) {
                    Text(title.name).font(.title.bold())
                    Text([title.kind.label, title.year].compactMap { $0 }.joined(separator: " · ")).foregroundStyle(.secondary)
                    Text(availability.state(title.id).label).font(.caption)
                    Button { watchlist.toggle(title) } label: {
                        Label(watchlist.contains(title) ? "Aus Merkliste entfernen" : "Zur Merkliste hinzufügen",
                              systemImage: watchlist.contains(title) ? "checkmark" : "plus")
                    }.buttonStyle(.bordered)
                    if let synopsis = title.synopsis ?? sourceSynopsis, !synopsis.isEmpty { Text(synopsis) }
                    else { Text("Deutsche Beschreibung nicht verfügbar.").foregroundStyle(.secondary) }
                    if let media = title.anime {
                        NavigationLink("Anime-Details und Merkliste") { AniListDetailView(mediaId: media.id, preloadedMedia: media) }
                    }
                    Button { play(episode: 1) } label: {
                        Label(title.kind == .movie ? "Abspielen" : "Folge 1 abspielen", systemImage: "play.fill")
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                    }.buttonStyle(.borderedProminent).disabled(loading || (title.sourceHref != nil && episodes.isEmpty))
                    Text("Deutsch bevorzugt · danach deutsche, zuletzt englische Untertitel")
                        .font(.caption).foregroundStyle(.secondary)
                    if !seasons.isEmpty {
                        Picker("Staffel", selection: $season) {
                            ForEach(seasons) { Text($0.name).tag($0.number) }
                        }.pickerStyle(.menu)
                    }
                    ForEach(episodes) { episode in
                        Button { play(episode: episode.number) } label: {
                            HStack {
                                Text("\(episode.number)").font(.title3.monospacedDigit()).frame(width: 35)
                                VStack(alignment: .leading) {
                                    Text(episode.name).font(.subheadline.weight(.semibold))
                                    if !episode.released { Text("Noch nicht veröffentlicht").font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer(); Image(systemName: "play.circle.fill")
                            }.padding(12).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain).disabled(!episode.released || loading)
                    }
                    if loading { ProgressView("Quelle und Folge werden geprüft …") }
                    if let error { Text(error).font(.footnote).foregroundStyle(.secondary) }
                    if title.isTMDB {
                        Link("Metadaten: TMDB", destination: URL(string: "https://www.themoviedb.org/\(title.tmdbType)/\(title.remoteID)")!)
                            .font(.caption)
                    }
                }.padding(.horizontal, 20)
            }.padding(.bottom, 28).frame(maxWidth: 1100).frame(maxWidth: .infinity)
        }
        .navigationTitle(title.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            if let href = title.sourceHref, let module = BundledUnifiedSource.module {
                do {
                    let runner = ModuleJSRunner(); runner.allowsVerificationPrompt = false; try await runner.load(module: module)
                    sourceEpisodes = try await PlaybackDeadline.run(seconds: 25) { try await runner.fetchEpisodes(url: href) }
                    let groups = Dictionary(grouping: sourceEpisodes) { ModuleSeasonRouting.seasonNumber(for: $0.href) ?? 1 }
                    seasons = groups.keys.sorted().map { CatalogSeason(number: $0, name: "Staffel \($0)", episodeCount: groups[$0]?.count ?? 0) }
                    season = seasons.first?.number ?? 1
                    await loadEpisodes()
                    sourceSynopsis = try? await runner.sourceDescription(url: href)
                    if sourceEpisodes.isEmpty { error = "Die Quelle hat keine Folgen geliefert. Bitte später erneut versuchen." }
                } catch { self.error = error.localizedDescription }
                return
            }
            do { seasons = try await UnifiedCatalog.shared.seasons(title); await loadEpisodes() }
            catch { self.error = error.localizedDescription }
            if let anime = title.anime {
                let count = anime.nextAiringEpisode.map { max(0, $0.episode - 1) }
                    ?? (["FINISHED", "finished_airing"].contains(anime.status ?? "") ? anime.episodes ?? 0 : 0)
                if count > 0 {
                    episodes = (1...min(count, 3000)).map { CatalogEpisode(number: $0, name: "Folge \($0)", airDate: nil, knownReleased: true) }
                }
                sourceSynopsis = await UnifiedCatalog.shared.germanDescription(title)
            }
        }
        .onChange(of: season) { _ in Task { await loadEpisodes() } }
    }

    private func loadEpisodes() async {
        if title.sourceHref != nil {
            episodes = sourceEpisodes.filter { (ModuleSeasonRouting.seasonNumber(for: $0.href) ?? 1) == season }.map { link in
                let number = Int((link.href.range(of: #"/episode-(\d+)"#, options: .regularExpression)).map { String(link.href[$0]).replacingOccurrences(of: "/episode-", with: "") } ?? "") ?? Int(link.number)
                return CatalogEpisode(number: number, name: "Folge \(number)", airDate: nil, knownReleased: true)
            }
            return
        }
        guard title.isTMDB, title.kind != .movie else { return }
        let selected = season
        do {
            let fetched = try await UnifiedCatalog.shared.episodes(title, season: selected)
            guard season == selected else { return }
            episodes = fetched
        } catch { self.error = error.localizedDescription }
    }
    private func play(episode: Int) {
        guard !loading else { return }
        error = nil; loading = true
        let request = AutomaticPlaybackRequest(catalogID: title.id, title: title.name,
                                               aliases: [title.originalName].compactMap { $0 }, kind: title.kind,
                                               animeID: title.anime?.provider == .anilist ? title.anime?.id : nil,
                                               seasonIsExplicit: title.sourceHref != nil || title.kind != .anime,
                                               season: season, episode: episode, detailHref: title.sourceHref, moduleID: title.moduleID)
        #if os(iOS)
        PlayerPresenter.shared.presentResolvingEpisode(title: title.name, episode: episode, artwork: title.poster ?? "", onResolve: {
            defer { loading = false }
            do { try await launch(request) }
            catch { self.error = error.localizedDescription; throw error }
        }, onChooseSource: { self.error = "Keine passende Quelle verfügbar. Die Quellen können in den Einstellungen geprüft werden." })
        #else
        playTask = Task {
            defer { loading = false }
            do { try await launch(request) } catch { self.error = error.localizedDescription }
        }
        #endif
    }
    @MainActor private func launch(_ request: AutomaticPlaybackRequest) async throws {
        let result = try await AutomaticPlaybackCoordinator.shared.resolve(request)
        ModuleManager.shared.selectModule(result.module)
        let available = title.anime?.airedOrAnnouncedEpisodes ?? result.episodes.count
        let total = title.anime?.episodes ?? seasons.first(where: { $0.number == season })?.episodeCount ?? result.episodes.count
        let context = PlayerContext(mediaTitle: title.name, episodeNumber: title.anime != nil ? request.episode : Int(result.episode.number), episodeTitle: nil,
                                    imageUrl: title.poster ?? "", aniListID: title.anime?.provider == .anilist ? title.anime?.id : nil,
                                    malID: title.anime?.idMal, moduleId: result.module.id, totalEpisodes: total,
                                    availableEpisodes: available, isAiring: total > available, resumeFrom: nil,
                                    detailHref: result.detailHref, episodeHref: result.episode.href, streamTitle: result.selected.title,
                                    workingDetailHref: result.detailHref, thumbnailUrl: nil)
        let refresh: StreamRefetchLoader = { number, href in
            guard let exact = EpisodeNavigator.resolve(href: href, orNumber: number, in: result.episodes + [result.episode]) else { return [] }
            let runner = ModuleJSRunner(); try await runner.load(module: result.module)
            return try await AutomaticPlaybackCoordinator.shared.streams(runner: runner, episodeHref: exact.href, legacyModule: result.module)
        }
        var anchor = result.episode.href
        let sourceOffset = (ModuleSeasonRouting.episodeNumber(for: anchor) ?? Int(result.episode.number)) - context.episodeNumber
        let sourceSeason = ModuleSeasonRouting.seasonNumber(for: anchor)
        let next: WatchNextLoader = { number in
            guard let step = EpisodeNavigator.next(afterHref: anchor, orNumber: number, in: result.episodes) else { return nil }
            if title.anime != nil, ModuleSeasonRouting.seasonNumber(for: step.href) != sourceSeason { return nil }
            let runner = ModuleJSRunner(); try await runner.load(module: result.module)
            let streams = try await AutomaticPlaybackCoordinator.shared.streams(runner: runner, episodeHref: step.href, legacyModule: result.module)
            anchor = step.href
            let progressNumber = title.anime != nil ? (ModuleSeasonRouting.episodeNumber(for: step.href) ?? Int(step.number)) - sourceOffset : Int(step.number)
            return (streams: streams, episodeNumber: progressNumber, episodeHref: step.href)
        }
        #if os(iOS)
        PlayerPresenter.shared.presentPlayer(stream: result.selected, streams: result.streams, context: context,
                                             onWatchNext: next, onStreamExpired: refresh)
        #elseif os(macOS)
        MacPlayerWindowManager.shared.open(stream: result.selected, streams: result.streams, context: context,
                                          onWatchNext: next, onStreamExpired: refresh)
        #endif
    }
}

struct CatalogWatchlistScreen: View {
    @ObservedObject private var watchlist = CatalogWatchlist.shared
    var body: some View {
        ScrollView {
            if watchlist.titles.isEmpty {
                Text("Deine Serien- und Filmmerkliste ist noch leer.").foregroundStyle(.secondary).padding(30)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 16) {
                    ForEach(watchlist.titles) { title in
                        NavigationLink { CatalogDetailScreen(title: title) } label: { CatalogPoster(title: title) }
                            .buttonStyle(.plain)
                    }
                }.padding()
            }
        }.navigationTitle("Meine Merkliste")
    }
}
