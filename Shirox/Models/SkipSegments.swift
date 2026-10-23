import Foundation

enum SkipSegmentType: String, CaseIterable, Hashable {
    case intro, recap, credits, preview

    var label: String {
        switch self {
        case .intro:   return "Skip Intro"
        case .recap:   return "Skip Recap"
        case .credits: return "Skip Credits"
        case .preview: return "Skip Preview"
        }
    }
}

struct SkipSegments {
    /// True only for segments confirmed against the current file runtime.
    /// Unverified segments remain available as manual Skip buttons.
    var isDurationVerified: Bool = false
    /// Trust is tracked per chapter, not per episode. A trustworthy intro
    /// must not implicitly authorize an unrelated, incorrect credits marker.
    var autoSkipIntro: Bool = false
    var autoSkipRecap: Bool = false
    var autoNextCredits: Bool = false

    struct Segment {
        let startMs: Double?  // nil = from start of episode
        let endMs: Double
    }

    var intro: Segment?
    var recap: Segment?
    var credits: Segment?
    var preview: Segment?

    func segment(for type: SkipSegmentType) -> Segment? {
        switch type {
        case .intro:   return intro
        case .recap:   return recap
        case .credits: return credits
        case .preview: return preview
        }
    }
}

 
/// Conservative, per-video timing decisions independent of SwiftUI/AVPlayer.
/// A duration-matched marker permits automatic actions; other metadata only
/// controls a manually tappable button.
enum PlayerChapterTiming {
    static func activeSegment(at seconds: Double, segments: SkipSegments) -> SkipSegmentType? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        let ms = seconds * 1_000
        for type in SkipSegmentType.allCases {
            guard let s = segments.segment(for: type) else { continue }
            if ms >= (s.startMs ?? 0), ms < s.endMs { return type }
        }
        return nil
    }

    static func shouldAutoSkip(_ type: SkipSegmentType, segments: SkipSegments) -> Bool {
        guard segments.isDurationVerified else { return false }
        switch type {
        case .intro: return segments.autoSkipIntro
        case .recap: return segments.autoSkipRecap
        case .credits, .preview: return false
        }
    }

    static func shouldOfferNext(
        at position: Double, duration: Double, segments: SkipSegments?,
        hasNext: Bool
    ) -> Bool {
        guard hasNext, position.isFinite, duration.isFinite,
              duration > 0, position >= 0 else { return false }
        if segments?.isDurationVerified == true,
           segments?.autoNextCredits == true,
           let credits = segments?.credits, let start = credits.startMs {
            let creditsStart = start / 1_000
            // Don't show the prompt long before credits on a mismatched cut.
            if creditsStart >= 0, creditsStart <= duration,
               position >= creditsStart, position <= duration - 1 {
                return true
            }
        }
        return duration - position <= 35 && duration - position > 1
    }

    static func shouldAdvanceAtCreditsStart(
        at position: Double, duration: Double, segments: SkipSegments?
    ) -> Bool {
        // Auto Next begins when VERIFIED end credits begin. Post-credit scenes
        // and previews are deliberately not protected: the viewer opted into
        // Auto Next and prefers to jump to the following episode immediately.
        // Unknown / unverified timing never causes an early jump.
        guard let segments, segments.isDurationVerified, segments.autoNextCredits,
              let credits = segments.credits, let start = credits.startMs,
              duration.isFinite, duration > 0, position.isFinite,
              start.isFinite, credits.endMs.isFinite else { return false }
        let creditsStart = start / 1_000
        let creditsEnd = credits.endMs / 1_000
        return creditsStart >= 0 && creditsStart < creditsEnd &&
            creditsEnd <= duration + 1.5 &&
            position >= creditsStart && position < duration
    }
}
