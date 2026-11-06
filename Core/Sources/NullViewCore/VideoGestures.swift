import Foundation

/// The arithmetic behind video-mode gestures (decisions.md "Gestures"), kept free of UIKit so it is tested here.
public enum VideoGestures {
    public enum Axis { case horizontal, vertical }

    /// Seconds a full-width horizontal drag moves. Fine control on short clips, quick on long ones.
    public static func seekSpan(duration: Double) -> Double { min(max(duration / 3, 30), 300) }

    /// Where a horizontal drag of `dx` points (of `width`) lands, clamped to the video.
    public static func seekTarget(start: Double, duration: Double, dx: Double, width: Double) -> Double {
        guard width > 0, duration > 0 else { return start }
        return min(max(start + dx / width * seekSpan(duration: duration), 0), duration)
    }

    /// A vertical drag: dragging up (negative `dy`) raises the level, a full-height drag is the whole range.
    public static func level(start: Double, dy: Double, height: Double) -> Double {
        guard height > 0 else { return start }
        return min(max(start - dy / height, 0), 1)
    }

    /// The axis a drag commits to once it has moved a few points; nil = not decided yet.
    public static func axis(dx: Double, dy: Double, slop: Double = 10) -> Axis? {
        guard max(abs(dx), abs(dy)) >= slop else { return nil }
        return abs(dx) >= abs(dy) ? .horizontal : .vertical
    }

    /// Double-tap seeks back on the left half, forward on the right.
    public static func doubleTapDelta(x: Double, width: Double, step: Double = 10) -> Double { x < width / 2 ? -step : step }

    /// `1:05`, `1:02:03`.
    public static func clock(_ t: Double) -> String {
        let s = Int(t.isFinite ? max(t, 0) : 0)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
