import Foundation

struct SubtitleTrack: Identifiable, Equatable, Hashable, Codable {
    let id: UUID
    let title: String
    let url: URL
    let headers: [String: String]
    var language: String? = nil

    init(title: String, url: URL, headers: [String: String], language: String? = nil) {
        self.id = UUID()
        self.title = title
        self.url = url
        self.headers = headers
        self.language = language
    }
}

struct StreamResult: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let url: URL
    let headers: [String: String]
    let subtitle: String?
    let subtitleHeaders: [String: String]
    let allSubtitles: [SubtitleTrack]?
    var audioLanguage: String? = nil
    var subtitleLanguage: String? = nil
    var isHardsub = false
    var resolution: Int? = nil
    var expiresAt: Date? = nil

    var subtitleURL: URL? { subtitle.flatMap { URL(string: $0) } }

    init(title: String, url: URL, headers: [String: String], subtitle: String? = nil,
         subtitleHeaders: [String: String] = [:], allSubtitles: [SubtitleTrack]? = nil,
         audioLanguage: String? = nil, subtitleLanguage: String? = nil,
         isHardsub: Bool = false, resolution: Int? = nil, expiresAt: Date? = nil) {
        self.title = title
        self.url = url
        self.headers = headers
        self.subtitle = subtitle
        self.subtitleHeaders = subtitleHeaders
        self.allSubtitles = allSubtitles
        self.audioLanguage = audioLanguage
        self.subtitleLanguage = subtitleLanguage
        self.isHardsub = isHardsub
        self.resolution = resolution
        self.expiresAt = expiresAt
    }
}
