import Foundation

/// One `<video>` as reported by `js/src/video-detect.js` (decisions.md: small, validated schema).
public struct VideoEntry: Equatable, Decodable {
    public let i: Int          // index among the <video> elements of its frame, document order
    public let w: Double       // element size in CSS px
    public let h: Double
    public let vis: Double     // visible area inside the frame's viewport, CSS px²
    public let playing: Bool
    public let ended: Bool
    public let muted: Bool
    public let loop: Bool
    public let dur: Double?    // nil = unknown or live
    public let pos: Double
    public let live: Bool
    public let drm: Bool       // MediaKeys attached (diagnostic; still controllable)
    public let src: Bool       // has a source (currentSrc or MSE blob)
    public let rate: Double?   // playbackRate (optional: older reports lack it)
    public let pip: Bool?      // in picture-in-picture
    public let pj: Bool?       // the page itself called pause() in the last 1.5 s (diagnostic)

    /// Big enough to be the thing the user came to watch (filters out trackers and 1x1 probes).
    public static let minArea = 10_000.0
    public var isCandidate: Bool { drm || w * h >= Self.minArea }
    /// Muted looping clips are page decoration, not what the user watches.
    var isAmbient: Bool { muted && loop }
    /// DRM video is eligible: playback is driven through the element, not its bytes (decisions.md "DRM").
    var isEligible: Bool { isCandidate && src }
}

/// What a frame sends us. Anything that does not fit is dropped.
public enum VideoMessage: Equatable {
    case videos(frame: String, [VideoEntry])
    case gone(frame: String)
    /// The page asked for fullscreen on this video (its own fullscreen button): enter video mode.
    case fullscreen(frame: String, index: Int)
    /// Diagnostic lines about failed, slow or ad-looking page requests (video log only; never acted on).
    case net(frame: String, lines: [String])

    public static let maxVideosPerFrame = 50
    public static let maxNetLines = 40

    private struct Raw: Decodable {
        let type: String
        let frame: String
        let videos: [VideoEntry]?
        let i: Int?
        let lines: [String]?
    }

    public static func parse(_ json: String) -> VideoMessage? {
        guard json.utf8.count < 100_000, let raw = try? JSONDecoder().decode(Raw.self, from: Data(json.utf8)),
              !raw.frame.isEmpty, raw.frame.count <= 64 else { return nil }
        switch raw.type {
        case "gone": return .gone(frame: raw.frame)
        case "fullscreen":
            guard let i = raw.i, i >= 0, i < maxVideosPerFrame else { return nil }
            return .fullscreen(frame: raw.frame, index: i)
        case "net":
            guard let l = raw.lines, l.count <= maxNetLines, l.allSatisfy({ $0.count <= 200 }) else { return nil }
            return .net(frame: raw.frame, lines: l)
        case "videos":
            guard let v = raw.videos, v.count <= maxVideosPerFrame, v.allSatisfy(\.isSane) else { return nil }
            return .videos(frame: raw.frame, v)
        default: return nil
        }
    }
}

extension VideoEntry {
    fileprivate var isSane: Bool {
        i >= 0 && [w, h, vis, pos].allSatisfy { $0.isFinite && $0 >= 0 } && (dur.map { $0.isFinite && $0 >= 0 } ?? true)
    }
}

public struct TrackedVideo: Equatable {
    /// Position among all of the page's videos: main frame first, then subframes in the order
    /// they first reported. This is the "video index" of the video identity.
    public let index: Int
    /// The reporting frame's key, with `entry.i`: where to send commands for this video.
    public let frame: String
    public let isMainFrame: Bool
    public let entry: VideoEntry
}

/// Everything the page's frames have reported. Reset on each main-frame navigation.
public struct VideoTracker: Equatable {
    private struct Frame: Equatable {
        let key: String
        let isMain: Bool
        var videos: [VideoEntry]
    }
    private var frames: [Frame] = []

    public init() {}

    public mutating func apply(_ message: VideoMessage, isMainFrame: Bool) {
        switch message {
        case let .videos(key, videos):
            if let n = frames.firstIndex(where: { $0.key == key }) { frames[n].videos = videos }
            else { frames.append(Frame(key: key, isMain: isMainFrame, videos: videos)) }
        case let .gone(key):
            frames.removeAll { $0.key == key }
        case .fullscreen, .net: break
        }
    }

    public mutating func reset() { frames = [] }

    public var videos: [TrackedVideo] {
        let ordered = frames.filter(\.isMain) + frames.filter { !$0.isMain }
        var out: [TrackedVideo] = []
        for f in ordered {
            for e in f.videos { out.append(TrackedVideo(index: out.count, frame: f.key, isMainFrame: f.isMain, entry: e)) }
        }
        return out
    }

    /// A specific video by its frame and in-frame index (video mode pins its target this way).
    public func video(frame: String, i: Int) -> TrackedVideo? {
        videos.first { $0.frame == frame && $0.entry.i == i }
    }

    /// Worth showing the video button for (it may still be uncontrollable, e.g. DRM).
    public var hasCandidate: Bool { videos.contains { $0.entry.isCandidate } }

    /// The video the user most likely means: not decoration, playing, most visible, biggest, first.
    /// nil = nothing controllable (fail open: the page stays a plain browser).
    public var primary: TrackedVideo? {
        func rank(_ v: TrackedVideo) -> [Double] {
            let e = v.entry
            return [e.isAmbient ? 0 : 1, e.playing ? 1 : 0, e.vis, e.w * e.h, -Double(v.index)]
        }
        return videos.filter { $0.entry.isEligible }
            .max { rank($0).lexicographicallyPrecedes(rank($1)) }
    }
}

/// Video identity (decisions.md): canonical page URL plus the video's index on the page.
public struct VideoID: Hashable, Codable {
    public let page: String
    public let index: Int

    public init(url: URL, index: Int) {
        page = Self.canonical(url)
        self.index = index
    }

    /// From an already canonical page string (read back from storage).
    public init(page: String, index: Int) {
        self.page = page
        self.index = index
    }

    private static let trackingParams: Set<String> = [
        "fbclid", "gclid", "dclid", "msclkid", "igshid", "mc_cid", "mc_eid", "_ga", "yclid", "twclid",
    ]

    /// Lowercase scheme and host, tracking parameters removed, fragment dropped unless it is
    /// a client-side route (`#/watch/1`, `#!/watch/1`).
    public static func canonical(_ url: URL) -> String {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        c.scheme = c.scheme?.lowercased()
        c.host = c.host?.lowercased()
        c.queryItems = c.queryItems?.filter { q in
            let n = q.name.lowercased()
            return !(n.hasPrefix("utm_") || trackingParams.contains(n))
        }
        if c.queryItems?.isEmpty == true { c.queryItems = nil }
        if let f = c.fragment, !(f.hasPrefix("/") || f.hasPrefix("!")) { c.fragment = nil }
        return c.string ?? url.absoluteString
    }
}
