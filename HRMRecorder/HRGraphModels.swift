import Foundation
import CoreGraphics

// AIDEV-NOTE: Pure, Foundation-only graph math ported from the jmdash HR chart (HRMRecorder-flq).
// No SwiftUI here — gap-splitting, summary math, and zoom/scroll clamping stay UI-independent.

/// Preset trailing windows for the history graph, anchored to "now" at query time.
enum HRGraphRange: String, CaseIterable, Identifiable {
    case hour1, hour6, hour24, day7, day30

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hour1:  return "1H"
        case .hour6:  return "6H"
        case .hour24: return "24H"
        case .day7:   return "7D"
        case .day30:  return "30D"
        }
    }

    var windowSeconds: TimeInterval {
        switch self {
        case .hour1:  return 3600
        case .hour6:  return 6 * 3600
        case .hour24: return 24 * 3600
        case .day7:   return 7 * 24 * 3600
        case .day30:  return 30 * 24 * 3600
        }
    }

    /// Bucket width scaled for ~300 buckets per window — comfortably under
    /// `HRDatabase`'s defensive row cap and cheap for Swift Charts to render.
    var bucketSeconds: Double { windowSeconds / 300 }
}

/// Pure helpers over `HRDatabase.HRBucket` series.
enum HRGraphSeries {

    // AIDEV-NOTE: HRGRAPH-GAP01 — split the series into contiguous runs so the chart's line/band
    // BREAK at recording gaps instead of drawing a segment across them (which would invent HR data
    // that never happened — recording is session-based, so gaps are common). The DB only returns
    // buckets that contain data, so a gap is simply a jump in bucketIndex of more than 1.
    static func contiguousRuns(_ buckets: [HRDatabase.HRBucket]) -> [[HRDatabase.HRBucket]] {
        var runs: [[HRDatabase.HRBucket]] = []
        var current: [HRDatabase.HRBucket] = []
        for bucket in buckets {
            if let last = current.last, bucket.bucketIndex != last.bucketIndex + 1 {
                runs.append(current)
                current = []
            }
            current.append(bucket)
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    struct Summary: Equatable {
        let sampleCount: Int
        let minBPM: Int
        let avgBPM: Double
        let maxBPM: Int
    }

    /// Whole-window stats from the buckets alone (no extra query). The
    /// count-weighted average is exact because each bucket's avg is exact.
    static func summarize(_ buckets: [HRDatabase.HRBucket]) -> Summary? {
        var count = 0
        var weighted = 0.0
        var lo = Int.max
        var hi = Int.min
        for b in buckets {
            count += b.count
            weighted += b.avgBPM * Double(b.count)
            lo = min(lo, b.minBPM)
            hi = max(hi, b.maxBPM)
        }
        guard count > 0 else { return nil }
        return Summary(sampleCount: count, minBPM: lo,
                       avgBPM: weighted / Double(count), maxBPM: hi)
    }

    /// Y-axis domain padded a little beyond the observed min/max so the line
    /// isn't flush against the plot edges. Falls back to a typical HR band
    /// when empty; a flat series (min == max) gets a fixed ±10 bpm window.
    static func yDomain(_ buckets: [HRDatabase.HRBucket]) -> ClosedRange<Double> {
        guard let low = buckets.map({ Double($0.minBPM) }).min(),
              let high = buckets.map({ Double($0.maxBPM) }).max() else {
            return 40...180
        }
        if high > low {
            let padding = Swift.max((high - low) * 0.1, 5)
            return (low - padding)...(high + padding)
        }
        return (low - 10)...(high + 10)
    }
}

// AIDEV-NOTE: HRGRAPH-VP01 — slimmed port of jmdash's HRChartViewport: pure value type owning ONLY
// the visible X-window (a rendering concern over already-loaded buckets). Pinch changes
// `visibleLength`, scroll moves `scrollPosition` (leading edge). It never re-queries the DB — zoom
// shows the loaded buckets at their loaded resolution. jmdash's reducer/identity machinery is NOT
// ported: HRMRecorder loads synchronously from local SQLite, so there is no stale-while-revalidate
// ordering problem — the caller simply resets on a range change and rebases on a live refresh.
struct HRGraphViewport: Equatable {
    /// Leading (earliest) edge of the loaded data.
    let dataStart: Date
    /// Trailing (latest) edge of the loaded data.
    let dataEnd: Date
    /// Zoom-in floor. Scales with bucket width so a pinch can never land on
    /// fewer than a handful of buckets (there is no finer data to show).
    let minVisibleLength: TimeInterval
    /// Width of the visible window in seconds.
    private(set) var visibleLength: TimeInterval
    /// Leading edge (Date) of the visible window.
    private(set) var scrollPosition: Date

    /// Tolerance for deciding the window's right edge is "at" the trailing
    /// edge — such a window keeps following new data after a live refresh.
    static let trailingEpsilon: TimeInterval = 1

    var fullLength: TimeInterval { max(0, dataEnd.timeIntervalSince(dataStart)) }
    var effectiveMinLength: TimeInterval { min(minVisibleLength, fullLength) }
    var isDegenerate: Bool { fullLength <= 0 }

    init(dataStart: Date, dataEnd: Date, minVisibleLength: TimeInterval) {
        let lo = min(dataStart, dataEnd)
        let hi = max(dataStart, dataEnd)
        self.dataStart = lo
        self.dataEnd = hi
        self.minVisibleLength = max(1, minVisibleLength)
        // Open showing the whole loaded span; scroll sits at the leading edge.
        self.visibleLength = max(0, hi.timeIntervalSince(lo))
        self.scrollPosition = lo
    }

    /// Build from an ascending bucket series. Returns nil when there is
    /// nothing to scroll/zoom (fewer than 2 buckets, or zero span) so the
    /// caller can fall back to a fixed degenerate domain instead.
    init?(buckets: [HRDatabase.HRBucket], bucketSeconds: Double) {
        guard let lo = buckets.first?.startDate,
              let hi = buckets.last?.startDate, hi > lo else { return nil }
        self.init(dataStart: lo, dataEnd: hi,
                  minVisibleLength: max(60, bucketSeconds * 8))
    }

    /// Pinch magnification: fingers apart (factor > 1) zoom IN => smaller
    /// window. `base` is the visible length captured at gesture start so a
    /// continuous pinch is relative, not compounding. Garbage factors/bases
    /// are ignored so a bad gesture can never poison `.chartXVisibleDomain`.
    mutating func applyMagnification(_ factor: CGFloat, base: TimeInterval) {
        guard fullLength > 0 else { return }
        guard factor.isFinite, factor > 0 else { return }
        guard base.isFinite, base > 0 else { return }
        setVisibleLengthAnchored(base / TimeInterval(factor))
    }

    /// Clamp-only length change (no anchoring). Used by `withUpdatedBounds`.
    mutating func setVisibleLength(_ length: TimeInterval) {
        guard fullLength > 0, length.isFinite, length > 0 else { return }
        visibleLength = length.clamped(to: effectiveMinLength...fullLength)
        scrollPosition = clampScroll(scrollPosition)
    }

    /// Length change with a natural zoom anchor: if the old window sat at the
    /// trailing (most-recent) edge, keep its right edge pinned to `dataEnd`;
    /// otherwise preserve the window center (the user's point of interest).
    mutating func setVisibleLengthAnchored(_ length: TimeInterval) {
        guard fullLength > 0, length.isFinite, length > 0 else { return }
        let oldRightEdge = scrollPosition.addingTimeInterval(visibleLength)
        let wasTrailing = oldRightEdge >= dataEnd.addingTimeInterval(-Self.trailingEpsilon)
        let oldCenter = scrollPosition.addingTimeInterval(visibleLength / 2)
        let clamped = length.clamped(to: effectiveMinLength...fullLength)
        visibleLength = clamped
        if wasTrailing {
            scrollPosition = clampScroll(dataEnd.addingTimeInterval(-clamped))
        } else {
            scrollPosition = clampScroll(oldCenter.addingTimeInterval(-clamped / 2))
        }
    }

    /// Clamp a proposed leading edge so the window never leaves the data:
    /// `[dataStart, dataEnd - visibleLength]`.
    func clampScroll(_ proposed: Date) -> Date {
        let maxStart = dataEnd.addingTimeInterval(-visibleLength)
        let upperBound = max(dataStart, maxStart)
        if proposed < dataStart { return dataStart }
        if proposed > upperBound { return upperBound }
        return proposed
    }

    mutating func setScrollPosition(_ proposed: Date) {
        scrollPosition = clampScroll(proposed)
    }

    // AIDEV-NOTE: HRGRAPH-VP02 — live-refresh rebase (port of jmdash withUpdatedBounds): re-home the
    // user's current zoom/scroll onto new data bounds. A trailing-pinned window keeps following the
    // newest samples; a window scrolled into history stays put. Prevents a 5 s refresh from yanking
    // a zoomed-in user back to full range.
    func withUpdatedBounds(dataStart newStart: Date, dataEnd newEnd: Date) -> HRGraphViewport {
        let oldRightEdge = scrollPosition.addingTimeInterval(visibleLength)
        let wasTrailing = oldRightEdge >= dataEnd.addingTimeInterval(-Self.trailingEpsilon)

        var rebased = HRGraphViewport(dataStart: newStart, dataEnd: newEnd,
                                      minVisibleLength: minVisibleLength)
        guard rebased.fullLength > 0 else { return rebased }

        rebased.setVisibleLength(visibleLength)
        if wasTrailing {
            rebased.setScrollPosition(rebased.dataEnd.addingTimeInterval(-rebased.visibleLength))
        } else {
            rebased.setScrollPosition(scrollPosition)
        }
        return rebased
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        if self < range.lowerBound { return range.lowerBound }
        if self > range.upperBound { return range.upperBound }
        return self
    }
}
