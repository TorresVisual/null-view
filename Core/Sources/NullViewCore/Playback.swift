import Foundation

/// Playback speed choices for video mode, remembered per site (decisions.md "Video").
public enum PlaybackSpeed {
    public static let steps: [Double] = [0.75, 1, 1.25, 1.5, 1.75, 2]
    /// Anything outside this is ignored when read back from storage.
    public static let allowed = 0.5...3.0

    public static func label(_ rate: Double) -> String {
        let s = String(format: "%g", (rate * 100).rounded() / 100)
        return s + "×"
    }
}

/// Speed per site. Plain value: the app keeps `rates` in UserDefaults. Keyed by host without `www.`,
/// so a speed chosen on one YouTube page is used on the next one. Choosing 1× forgets the site.
public struct SpeedPrefs: Equatable {
    public private(set) var rates: [String: Double]

    public init(rates: [String: Double] = [:]) { self.rates = rates }

    public static func key(_ url: URL) -> String? {
        guard let h = url.host?.lowercased(), !h.isEmpty else { return nil }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    public func rate(for url: URL) -> Double? {
        guard let k = Self.key(url), let r = rates[k], r.isFinite, PlaybackSpeed.allowed.contains(r), r != 1 else { return nil }
        return r
    }

    public mutating func set(_ rate: Double, for url: URL) {
        guard let k = Self.key(url), rate.isFinite, PlaybackSpeed.allowed.contains(rate) else { return }
        rates[k] = rate == 1 ? nil : rate
    }
}

/// Sleep timer for video mode: pause after N minutes, or when the current video ends (the queue then
/// does not advance). Pure value with an injected clock; the app does the pausing.
public struct SleepTimer: Equatable {
    public enum Choice: Hashable { case off, minutes(Int), endOfVideo }

    public static let choices: [Choice] = [.off, .minutes(15), .minutes(30), .minutes(45), .minutes(60), .endOfVideo]

    public let choice: Choice
    public let deadline: Date?

    public init(_ choice: Choice, now: Date = Date()) {
        self.choice = choice
        if case let .minutes(m) = choice, m > 0 { deadline = now.addingTimeInterval(Double(m) * 60) } else { deadline = nil }
    }

    public func isDue(now: Date = Date()) -> Bool { deadline.map { now >= $0 } ?? false }
    public var holdsQueue: Bool { choice == .endOfVideo }

    public static func label(_ c: Choice) -> String {
        switch c {
        case .off: "Off"
        case let .minutes(m): "\(m) minutes"
        case .endOfVideo: "End of this video"
        }
    }
}
