import Foundation
import Combine

extension JSEngine {
    func fetchStreams(episodeUrl: String, timeout: TimeInterval = 120) async throws -> [StreamResult] {
        if let module = ModuleManager.shared.activeModule, !module.isLocalPlayback, !module.isJellyfin {
            return try await PlaybackDeadline.run(seconds: min(timeout, 30)) {
                let runner = ModuleJSRunner()
                try await runner.load(module: module)
                return try await AutomaticPlaybackCoordinator.shared.streams(runner: runner, episodeHref: episodeUrl, legacyModule: module)
            }
        }
        // A time limit applies to the entire JS resolver, including its hoster
        // attempts. The default remains unchanged for existing providers.
        let json = try await callAsyncJS("extractStreamUrl", args: [episodeUrl], timeout: timeout)
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)

        // Some modules return a raw URL string instead of JSON (e.g. animeheaven, animekai)
        if let url = URL(string: trimmed), url.scheme != nil, !trimmed.hasPrefix("{") {
            return [StreamResult(title: "Play", url: url, headers: [:])]
        }

        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JSEngineError.parseError("Could not parse stream result")
        }

        return try parseResolvedStreamResults(from: obj)
    }
}

// MARK: - Shared parsing

func parseResolvedStreamResults(from obj: [String: Any]) throws -> [StreamResult] {
    let streams = parseStreamResults(from: obj)
    if streams.isEmpty, obj["blockedReason"] as? String == "website_verification_required" {
        throw ModuleStreamResolutionError.websiteVerificationRequired
    }
    return streams
}

func parseStreamResults(from obj: [String: Any]) -> [StreamResult] {
    let subtitleUrl = (obj["subtitle"] as? String ?? obj["subtitles"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    let subtitleHeaders = obj["subtitleHeaders"] as? [String: String] ?? [:]
    let allSubtitles = parseSubtitleTracks(from: obj["allSubtitles"] ?? obj["subtitles"])

    var results: [StreamResult] = []

    var seen = Set<String>()

    if let streams = obj["streams"] as? [[String: Any]] {
        for stream in streams {
            guard let urlStr = stream["streamUrl"] as? String ?? stream["url"] as? String,
                  let url = URL(string: urlStr) else { continue }
            guard seen.insert(urlStr).inserted else { continue }
            let title = stream["title"] as? String ?? "Stream"
            let headers = stream["headers"] as? [String: String] ?? [:]
            let tracks = parseSubtitleTracks(from: stream["allSubtitles"] ?? stream["subtitles"]) ?? allSubtitles
            results.append(StreamResult(title: title, url: url, headers: headers,
                                        subtitle: stream["subtitle"] as? String ?? subtitleUrl,
                                        subtitleHeaders: stream["subtitleHeaders"] as? [String: String] ?? subtitleHeaders,
                                        allSubtitles: tracks,
                                        audioLanguage: stream["audioLanguage"] as? String,
                                        subtitleLanguage: stream["subtitleLanguage"] as? String,
                                        isHardsub: stream["isHardsub"] as? Bool ?? false,
                                        resolution: stream["resolution"] as? Int,
                                        expiresAt: (stream["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0) }))
        }
    } else if let streams = obj["streams"] as? [String] {
        for (i, urlStr) in streams.enumerated() {
            guard let url = URL(string: urlStr) else { continue }
            guard seen.insert(urlStr).inserted else { continue }
            results.append(StreamResult(title: "Stream \(i + 1)", url: url, headers: [:],
                                        subtitle: subtitleUrl, subtitleHeaders: subtitleHeaders,
                                        allSubtitles: allSubtitles))
        }
    } else if let stream = obj["stream"] as? String, let url = URL(string: stream) {
        results.append(StreamResult(title: "Stream", url: url, headers: [:],
                                    subtitle: subtitleUrl, subtitleHeaders: subtitleHeaders,
                                    allSubtitles: allSubtitles))
    } else if let stream = obj["stream"] as? [String: Any],
              let urlStr = stream["url"] as? String,
              let url = URL(string: urlStr) {
        let headers = stream["headers"] as? [String: String] ?? [:]
        results.append(StreamResult(title: "Stream", url: url, headers: headers,
                                    subtitle: subtitleUrl, subtitleHeaders: subtitleHeaders,
                                    allSubtitles: allSubtitles))
    }

    return results
}

private func parseSubtitleTracks(from value: Any?) -> [SubtitleTrack]? {
    guard let array = value as? [[String: Any]], !array.isEmpty else { return nil }
    var seen = Set<String>()
    let tracks = array.compactMap { item -> SubtitleTrack? in
        guard let urlStr = item["url"] as? String ?? item["file"] as? String ?? item["src"] as? String,
              let url = URL(string: urlStr) else { return nil }
        guard seen.insert(urlStr).inserted else { return nil }
        let title = item["title"] as? String
            ?? item["label"] as? String
            ?? item["lang"] as? String
            ?? item["language"] as? String
            ?? item["name"] as? String
            ?? "Subtitle"
        let headers = item["headers"] as? [String: String] ?? [:]
        return SubtitleTrack(title: title, url: url, headers: headers,
                             language: item["lang"] as? String ?? item["language"] as? String)
    }
    return tracks.isEmpty ? nil : tracks
}
