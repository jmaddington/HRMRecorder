import SwiftUI
import Charts

// AIDEV-NOTE: HR history graphs (HRMRecorder-flq), ported from the jmdash HR chart. Three mark
// layers per contiguous run: AreaMark min-max band, monotone LineMark of avg, PointMark per bucket.
// Data is ALWAYS pre-aggregated buckets from HRDatabase.bucketedSamples — raw samples are never
// materialized (memory-light hard constraint). iOS 17+ Swift Charts scrolling APIs are fine here:
// the app target is 18.6 (only the widget is 16.1).

// MARK: - Shared chart component

/// The chart + legend, shared by the history and per-session screens.
/// The parent owns the viewport/scroll state; this view owns only gestures.
struct HRGraphChart: View {
    let buckets: [HRDatabase.HRBucket]
    /// Bucket width the series was aggregated at (sizes the degenerate domain).
    let bucketSeconds: Double
    @Binding var viewport: HRGraphViewport?
    @Binding var scrollPositionDate: Date

    // AIDEV-NOTE: HRGRAPH-PINCH01 — pinch base is @GestureState (jmdash FIX-B): captured on the
    // gesture's first frame, auto-reset by SwiftUI on end AND cancel, so a cancelled pinch can
    // never leave a stale base that skews the next one.
    @GestureState private var magnifyBase: TimeInterval?

    var body: some View {
        VStack(spacing: 12) {
            chart
            legend
        }
        .padding(.vertical, 4)
    }

    private var chart: some View {
        // One series PER contiguous run: adjacent marks in a single series always connect, so
        // distinct series values are what makes the line/band break at recording gaps (HRGRAPH-GAP01).
        let runs = HRGraphSeries.contiguousRuns(buckets)
        return Chart {
            ForEach(Array(runs.enumerated()), id: \.offset) { runIndex, run in
                ForEach(run) { bucket in
                    AreaMark(
                        x: .value("Time", bucket.startDate),
                        yStart: .value("Min", bucket.minBPM),
                        yEnd: .value("Max", bucket.maxBPM),
                        series: .value("Run", "band-\(runIndex)")
                    )
                    .foregroundStyle(Color.red.opacity(0.15))
                }

                ForEach(run) { bucket in
                    LineMark(
                        x: .value("Time", bucket.startDate),
                        y: .value("Avg HR", bucket.avgBPM),
                        series: .value("Run", "line-\(runIndex)")
                    )
                    .foregroundStyle(.red)
                    .interpolationMethod(.monotone)
                }

                // AIDEV-NOTE: HRGRAPH-GAP02 — a one-bucket run (lone session flanked by gaps) has no
                // line segment; the point glyph guarantees every real reading stays visible.
                ForEach(run) { bucket in
                    PointMark(
                        x: .value("Time", bucket.startDate),
                        y: .value("Avg HR", bucket.avgBPM)
                    )
                    .foregroundStyle(.red)
                    .symbolSize(run.count == 1 ? 40 : 12)
                }
            }
        }
        .chartYAxisLabel("bpm")
        .chartYScale(domain: HRGraphSeries.yDomain(buckets))
        // Scrollable window only when there's something to scroll; the degenerate branch pins a
        // fixed domain around the lone bucket so it can never scroll out of view and render blank.
        .modifier(HRGraphViewportModifier(
            viewport: viewport,
            visibleLength: visibleDomainLength,
            degenerateDomain: degenerateXDomain,
            scrollPosition: $scrollPositionDate,
            magnifyGesture: magnifyGesture))
        .frame(height: 300)
        // The chart writes scrollPositionDate as the user drags; clamp it back into the data
        // bounds and, if clamping moved it, write the clamped value back (converges immediately).
        // AIDEV-NOTE: HRGRAPH-SCROLL01 — epsilon guard skips no-op viewport writes (echoes from
        // apply/magnify/clamp write-backs) so they can't recompute the chart body needlessly.
        .onChange(of: scrollPositionDate) { _, newValue in
            guard var vp = viewport else { return }
            let clamped = vp.clampScroll(newValue)
            if abs(clamped.timeIntervalSince(vp.scrollPosition)) > 0.001 {
                vp.setScrollPosition(clamped)
                viewport = vp
            }
            if clamped != newValue {
                scrollPositionDate = clamped
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 16) {
            HStack(spacing: 4) {
                Rectangle()
                    .fill(Color.red)
                    .frame(width: 12, height: 2)
                Text("Average")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Red line: average heart rate")
            HStack(spacing: 4) {
                Rectangle()
                    .fill(Color.red.opacity(0.15))
                    .frame(width: 12, height: 12)
                Text("Min–max range")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Shaded band: minimum to maximum heart rate range")
            Spacer()
        }
    }

    /// `.chartXVisibleDomain` length; positive sentinel when unscrollable so
    /// Swift Charts never receives a zero/negative domain.
    private var visibleDomainLength: TimeInterval {
        if let vp = viewport, vp.visibleLength > 0 { return vp.visibleLength }
        return 24 * 3600
    }

    /// Fixed domain for the 0/1-bucket case, centered on the lone bucket and
    /// scaled to the bucket width so a short session isn't lost in a huge axis.
    private var degenerateXDomain: ClosedRange<Date> {
        let center = buckets.first?.startDate ?? Date()
        let half = max(bucketSeconds * 10, 60)
        return center.addingTimeInterval(-half)...center.addingTimeInterval(half)
    }

    /// Pinch-to-zoom over the loaded buckets (never re-queries; clamping lives
    /// in HRGraphViewport). First frame may read a nil base — fall back to the
    /// current length, which is exactly what would have been captured.
    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .updating($magnifyBase) { _, state, _ in
                if state == nil { state = viewport?.visibleLength }
            }
            .onChanged { value in
                guard var vp = viewport, !vp.isDegenerate else { return }
                let base = magnifyBase ?? vp.visibleLength
                vp.applyMagnification(value.magnification, base: base)
                viewport = vp
                scrollPositionDate = vp.scrollPosition
            }
    }
}

/// Two mutually exclusive X-axis branches (port of jmdash's modifier): a native scrollable window
/// with the pinch attached as `.simultaneousGesture` (so two-finger zoom and one-finger pan are
/// recognized independently), or a fixed domain when there is nothing to scroll.
private struct HRGraphViewportModifier<G: Gesture>: ViewModifier {
    let viewport: HRGraphViewport?
    let visibleLength: TimeInterval
    let degenerateDomain: ClosedRange<Date>
    @Binding var scrollPosition: Date
    let magnifyGesture: G

    func body(content: Content) -> some View {
        if viewport != nil {
            content
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: visibleLength)
                .chartScrollPosition(x: $scrollPosition)
                .simultaneousGesture(magnifyGesture)
        } else {
            content
                .chartXScale(domain: degenerateDomain)
        }
    }
}

// MARK: - Summary card

/// Min / Avg / Max / Samples row computed from the loaded buckets (no extra query).
struct HRGraphSummaryRow: View {
    let summary: HRGraphSeries.Summary

    var body: some View {
        HStack(spacing: 12) {
            stat("Min", "\(summary.minBPM)")
            stat("Avg", String(format: "%.0f", summary.avgBPM))
            stat("Max", "\(summary.maxBPM)")
            stat("Samples", "\(summary.sampleCount)")
        }
        .padding(.vertical, 4)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 18, weight: .semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - History graph (all sessions, trailing window)

/// Whole-history HR graph behind the "Graphs" link: segmented trailing ranges
/// anchored to now, spanning every session and strap.
struct HRHistoryGraphView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var hr: HeartRateManager
    @Environment(\.scenePhase) private var scenePhase

    @State private var range: HRGraphRange
    @State private var buckets: [HRDatabase.HRBucket] = []
    @State private var loadedBucketSeconds: Double = 1
    @State private var viewport: HRGraphViewport?
    @State private var scrollPositionDate = Date()
    @State private var loadedOnce = false
    /// Most recent sample overall — only fetched when the window is empty, to
    /// hint the user toward a wider range.
    @State private var latestSample: Date?
    @State private var refreshTimer: Timer?
    @State private var loadGeneration = 0
    /// True while the newest-generation load is running; timer ticks skip
    /// instead of piling further reads onto the serial DB queue.
    @State private var loadInFlight = false
    /// Sticky reset intent: survives a reset load being superseded by an
    /// interleaved non-reset (timer) load, so the reset still applies.
    @State private var viewportNeedsReset = false
    /// Whether the screen is on screen (onAppear/onDisappear), so a scenePhase
    /// flip back to .active never resurrects the timer for a covered view.
    @State private var isVisible = false

    /// `initialRange` exists for the DEBUG screenshot flow (deterministic
    /// captures of each range); in-app navigation uses the default.
    init(initialRange: HRGraphRange = .hour24) {
        _range = State(initialValue: initialRange)
    }

    var body: some View {
        List {
            Section {
                Picker("Range", selection: $range) {
                    ForEach(HRGraphRange.allCases) { r in
                        Text(r.label).tag(r)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section {
                if buckets.isEmpty {
                    if loadedOnce { emptyState }
                } else {
                    HRGraphChart(buckets: buckets,
                                 bucketSeconds: loadedBucketSeconds,
                                 viewport: $viewport,
                                 scrollPositionDate: $scrollPositionDate)
                }
            }

            if let summary = HRGraphSeries.summarize(buckets) {
                Section("Summary") {
                    HRGraphSummaryRow(summary: summary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Graphs")
        .onAppear {
            isVisible = true
            reload(resetViewport: !loadedOnce)
            startRefreshTimer()
        }
        .onDisappear {
            isVisible = false
            stopRefreshTimer()
        }
        // AIDEV-NOTE: HRGRAPH-BG01 — onDisappear does NOT fire on backgrounding, and this app stays
        // alive there (bluetooth-central); scenePhase must kill the timer or it polls for hours.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                guard isVisible else { return }
                reload(resetViewport: false)   // catch up on samples missed while backgrounded
                startRefreshTimer()
            } else {
                stopRefreshTimer()
            }
        }
        .onChange(of: range) { _, _ in reload(resetViewport: true) }
        // One extra reload when recording toggles, so the final samples of a
        // just-stopped session (or the first of a new one) appear promptly.
        .onChange(of: hr.isRecording) { _, _ in reload(resetViewport: false) }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.xyaxis.line")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(latestSample == nil ? "No recordings yet" : "No data in this range")
                .font(.subheadline.weight(.medium))
            Text(emptyHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var emptyHint: String {
        if let latest = latestSample {
            return "Most recent sample: \(latest.formatted(.relative(presentation: .named))). Try a wider range."
        }
        return "Heart-rate graphs appear here after your first recording."
    }

    // AIDEV-NOTE: HRGRAPH-LOAD01 — reads run off-main (HRDatabase serializes internally); a
    // generation token drops stale results if the range changes mid-flight. Insert path untouched.
    // AIDEV-NOTE: HRGRAPH-RESET01 — reset intent is sticky (viewportNeedsReset), not per-call: if a
    // timer load supersedes a reset load, the survivor still applies the reset (no stale-VP rebase).
    private func reload(resetViewport: Bool) {
        if resetViewport { viewportNeedsReset = true }
        loadGeneration += 1
        let generation = loadGeneration
        loadInFlight = true
        let db = model.db
        let selected = range
        let to = Date()
        let from = to.addingTimeInterval(-selected.windowSeconds)
        DispatchQueue.global(qos: .userInitiated).async {
            let rows = db.bucketedSamples(sessionID: nil, from: from, to: to,
                                          bucketSeconds: selected.bucketSeconds)
            let extent = rows.isEmpty ? db.sampleExtent() : nil
            DispatchQueue.main.async {
                guard generation == loadGeneration else { return }
                loadInFlight = false
                latestSample = extent?.last
                apply(rows, bucketSeconds: selected.bucketSeconds,
                      resetViewport: viewportNeedsReset)
                viewportNeedsReset = false
                loadedOnce = true
            }
        }
    }

    private func apply(_ rows: [HRDatabase.HRBucket],
                       bucketSeconds: Double,
                       resetViewport: Bool) {
        buckets = rows
        loadedBucketSeconds = bucketSeconds
        let fresh = HRGraphViewport(buckets: rows, bucketSeconds: bucketSeconds)
        if !resetViewport, let current = viewport, let fresh = fresh {
            // Live refresh: preserve the user's zoom/scroll (trailing-pinned
            // windows keep following new data). See HRGRAPH-VP02.
            let rebased = current.withUpdatedBounds(dataStart: fresh.dataStart,
                                                    dataEnd: fresh.dataEnd)
            viewport = rebased
            scrollPositionDate = rebased.scrollPosition
        } else {
            viewport = fresh
            if let vp = fresh { scrollPositionDate = vp.scrollPosition }
        }
    }

    // AIDEV-NOTE: HRGRAPH-TICK01 — gentle 5 s refresh, only while this screen is visible AND the
    // scene is active AND a recording is on; ticks skip while a load is in flight (no queue pile-up).
    private func startRefreshTimer() {
        stopRefreshTimer()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            guard hr.isRecording, !loadInFlight else { return }
            reload(resetViewport: false)
        }
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}

// MARK: - Per-session graph

extension HRDatabase.SessionInfo {
    /// Prefer recorded sensor identity over the advertised BLE name.
    var sensorLabel: String? {
        let identity = [manufacturer, model].compactMap { $0 }.joined(separator: " ")
        if !identity.isEmpty {
            return bodyLocation.map { "\(identity) (\($0))" } ?? identity
        }
        return deviceName
    }
}

/// Detail screen for one recorded session: metadata, the graph over the
/// session's own span, summary stats, and the session CSV export.
struct SessionGraphView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var hr: HeartRateManager
    @Environment(\.scenePhase) private var scenePhase

    /// Starts as the caller's snapshot; re-fetched once when the recording
    /// stops so `endedAt` lands and the duration freezes (HRGRAPH-END01).
    @State private var session: HRDatabase.SessionInfo

    @State private var buckets: [HRDatabase.HRBucket] = []
    @State private var loadedBucketSeconds: Double = 1
    @State private var viewport: HRGraphViewport?
    @State private var scrollPositionDate = Date()
    @State private var loadedOnce = false
    @State private var shareURL: URL?
    @State private var refreshTimer: Timer?
    @State private var loadGeneration = 0
    /// True while the newest-generation load is running; timer ticks skip
    /// instead of piling further reads onto the serial DB queue.
    @State private var loadInFlight = false
    /// Whether the screen is on screen (onAppear/onDisappear), so a scenePhase
    /// flip back to .active never resurrects the timer for a covered view.
    @State private var isVisible = false

    init(session: HRDatabase.SessionInfo) {
        _session = State(initialValue: session)
    }

    /// This screen was opened on the session currently being recorded.
    /// When the recording flag flips false, `.onChange` below runs one final
    /// reload (the last ≤5 s of samples) and re-fetches the session row so
    /// `endedAt` is set and the displayed duration stops counting.
    private var isActive: Bool {
        session.endedAt == nil && hr.isRecording && hr.activeSessionID == session.id
    }

    var body: some View {
        List {
            Section("Session") {
                LabeledContent("Started") {
                    Text(session.startedAt,
                         format: .dateTime.year().month().day().hour().minute())
                }
                LabeledContent(isActive ? "Elapsed" : "Duration", value: durationString)
                if let sensor = session.sensorLabel {
                    LabeledContent("Sensor", value: sensor)
                }
                if isActive {
                    Label("Recording", systemImage: "record.circle")
                        .foregroundStyle(.red)
                }
            }

            Section {
                if buckets.isEmpty {
                    if loadedOnce {
                        Text("No samples in this session")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                } else {
                    HRGraphChart(buckets: buckets,
                                 bucketSeconds: loadedBucketSeconds,
                                 viewport: $viewport,
                                 scrollPositionDate: $scrollPositionDate)
                }
            }

            if let summary = HRGraphSeries.summarize(buckets) {
                Section("Summary") {
                    HRGraphSummaryRow(summary: summary)
                }
            }

            Section {
                Button {
                    shareURL = model.db.exportCSV(sessionID: session.id)
                } label: {
                    Label("Export Session as CSV", systemImage: "square.and.arrow.up")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(session.startedAt.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $shareURL) { url in
            ShareSheet(items: [url])
        }
        .onAppear {
            isVisible = true
            reload(resetViewport: !loadedOnce)
            startRefreshTimer()
        }
        .onDisappear {
            isVisible = false
            stopRefreshTimer()
        }
        // Same scenePhase contract as HRGRAPH-BG01: no polling while backgrounded.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                guard isVisible else { return }
                if session.endedAt == nil { reload(resetViewport: false) }
                startRefreshTimer()
            } else {
                stopRefreshTimer()
            }
        }
        // AIDEV-NOTE: HRGRAPH-END01 — recording stopped: one final reload catches the last ≤5 s of
        // samples, the row re-fetch sets endedAt so durationString stops tracking Date(), and the
        // refresh timer stops (its ticks would be pure no-ops once the session has ended).
        .onChange(of: hr.isRecording) { _, recording in
            guard !recording, session.endedAt == nil else { return }
            reload(resetViewport: false)
            refreshSessionRow()
            stopRefreshTimer()
        }
    }

    /// Re-fetch this session's row off-main (DB reads are `queue.sync`) and
    /// swap the snapshot, freezing `endedAt`/duration once recording stops.
    /// If the row was deleted while this screen is open, freeze the local
    /// copy instead so the Duration row stops advancing from Date().
    private func refreshSessionRow() {
        let db = model.db
        let id = session.id
        DispatchQueue.global(qos: .userInitiated).async {
            let updated = db.session(id: id)
            DispatchQueue.main.async {
                if let updated {
                    session = updated
                } else if session.endedAt == nil {
                    session.endedAt = Date()
                }
            }
        }
    }

    private var durationString: String {
        let end = session.endedAt ?? Date()
        let s = max(0, Int(end.timeIntervalSince(session.startedAt)))
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    private func reload(resetViewport: Bool) {
        loadGeneration += 1
        let generation = loadGeneration
        loadInFlight = true
        // AIDEV-NOTE: HRGRAPH-STATE01 — capture every @State value on main BEFORE dispatching;
        // refreshSessionRow can swap `session` concurrently and @State must never be read off-main.
        let db = model.db
        let sessionID = session.id
        let from = session.startedAt
        // +1 s slop on the exclusive upper bound so a sample stamped exactly
        // at ended_at can't be dropped; active sessions read up to now.
        let to = session.endedAt.map { $0.addingTimeInterval(1) } ?? Date()
        let duration = max(1, to.timeIntervalSince(from))
        // ≤ ~400 buckets; short sessions approach raw 1 Hz (width floor is 1 s).
        let width = max(1.0, duration / 400.0)
        DispatchQueue.global(qos: .userInitiated).async {
            let rows = db.bucketedSamples(sessionID: sessionID, from: from, to: to,
                                          bucketSeconds: width)
            DispatchQueue.main.async {
                guard generation == loadGeneration else { return }
                loadInFlight = false
                apply(rows, bucketSeconds: width, resetViewport: resetViewport)
                loadedOnce = true
            }
        }
    }

    private func apply(_ rows: [HRDatabase.HRBucket],
                       bucketSeconds: Double,
                       resetViewport: Bool) {
        buckets = rows
        loadedBucketSeconds = bucketSeconds
        let fresh = HRGraphViewport(buckets: rows, bucketSeconds: bucketSeconds)
        if !resetViewport, let current = viewport, let fresh = fresh {
            let rebased = current.withUpdatedBounds(dataStart: fresh.dataStart,
                                                    dataEnd: fresh.dataEnd)
            viewport = rebased
            scrollPositionDate = rebased.scrollPosition
        } else {
            viewport = fresh
            if let vp = fresh { scrollPositionDate = vp.scrollPosition }
        }
    }

    // Same cadence contract as HRGRAPH-TICK01; additionally gated on this
    // being the active session, so viewing an old session costs nothing.
    private func startRefreshTimer() {
        stopRefreshTimer()
        guard session.endedAt == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            guard isActive, !loadInFlight else { return }
            reload(resetViewport: false)
        }
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}
