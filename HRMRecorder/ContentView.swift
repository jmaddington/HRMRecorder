import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var hr: HeartRateManager
    @EnvironmentObject private var model: AppModel

    @State private var now = Date()
    @State private var beat = false
    @State private var showDevicePicker = false
    @State private var deviceExpanded = false

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            List {
                liveSection
                otherStrapsSection
                recordSection
                deviceSection
                Section {
                    NavigationLink {
                        SessionsView()
                    } label: {
                        Label("Sessions", systemImage: "list.bullet.rectangle")
                    }
                } footer: {
                    Text(Self.versionString)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .navigationTitle("HRM Recorder")
            .listStyle(.insetGrouped)
        }
        .onAppear { maybePresentPicker() }
        .onReceive(tick) { now = $0 }
        .onChange(of: hr.state) { _ in maybePresentPicker() }
        .sheet(isPresented: $showDevicePicker) {
            DevicePickerView { device in
                hr.select(device)          // additive — pick several; tap Done
            }
            .environmentObject(hr)
        }
    }

    // MARK: - Live heart rate

    private var liveSection: some View {
        Section {
            VStack(spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(.red)
                        .scaleEffect(beat ? 1.18 : 1.0)
                        .animation(hr.heartRate > 0
                                   ? .easeInOut(duration: 0.45).repeatForever(autoreverses: true)
                                   : .default,
                                   value: beat)
                        .onAppear { beat = true }
                    Text(hr.heartRate > 0 ? "\(hr.heartRate)" : "—")
                        .font(.system(size: 72, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("bpm").font(.title3).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 9, height: 9)
                    Text(hr.state.label)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text(hr.deviceName)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                if let c = hr.sensorContact {
                    Label(c ? "Skin contact OK" : "Poor skin contact",
                          systemImage: c ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(c ? .green : .orange)
                }
                if !hr.rrIntervals.isEmpty {
                    Text("RR: " + hr.rrIntervals.map { "\($0)" }.joined(separator: " ") + " ms")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Other straps

    /// One compact line per non-primary strap — a connection-status list, not
    /// a dashboard (per-strap analysis is done later in the CSV). Absent with
    /// a single strap, so the screen is unchanged for the common case.
    @ViewBuilder
    private var otherStrapsSection: some View {
        let others = hr.secondaryDevices
        if !others.isEmpty {
            Section("Other straps") {
                ForEach(others) { d in
                    HStack(spacing: 8) {
                        Image(systemName: "heart.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                        Text(d.heartRate > 0 ? "\(d.heartRate)" : "—")
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                        Text("bpm").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Text(d.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Circle()
                            .fill(Self.color(for: d.state))
                            .frame(width: 7, height: 7)
                    }
                }
            }
        }
    }

    private static func color(for state: HeartRateManager.State) -> Color {
        switch state {
        case .connected:              return .green
        case .scanning, .connecting:  return .orange
        default:                      return .red
        }
    }

    /// Collapsed-row summary: nothing / the strap name / "N straps".
    private var strapSummary: String {
        switch hr.devices.count {
        case 0:  return "Not selected"
        case 1:  return hr.deviceName
        default: return "\(hr.devices.count) straps"
        }
    }

    // MARK: - Device selection

    private var deviceSection: some View {
        Section("Device") {
            DisclosureGroup(isExpanded: $deviceExpanded) {
                if let summary = hr.sensorSummary {
                    LabeledContent("Sensor", value: summary)
                }
                if let fw = hr.firmware {
                    LabeledContent("Firmware", value: fw)
                }
                Button {
                    hr.startDeviceScan()
                    showDevicePicker = true
                } label: {
                    Label(hr.hasDevice ? "Add / Change Strap" : "Choose Device",
                          systemImage: "sensor.tag.radiowaves.forward")
                }
                if hr.hasDevice {
                    Button(role: .destructive) {
                        hr.forgetDevice()
                    } label: {
                        Label("Forget All Straps", systemImage: "minus.circle")
                    }
                    .disabled(hr.isRecording)
                }
            } label: {
                LabeledContent(hr.devices.count > 1 ? "Straps" : "Strap") {
                    Text(strapSummary)
                        .foregroundStyle(hr.hasDevice ? .primary : .secondary)
                }
            }
        }
    }

    // MARK: - Record toggle

    private var recordSection: some View {
        Section("Recording") {
            Button {
                hr.isRecording ? hr.stopRecording() : hr.startRecording()
            } label: {
                HStack {
                    Image(systemName: hr.isRecording ? "stop.circle.fill" : "record.circle")
                    Text(hr.isRecording ? "Stop Recording" : "Start Recording")
                    Spacer()
                }
                .font(.headline)
                .foregroundStyle(hr.isRecording ? .red : .accentColor)
            }

            if hr.isRecording {
                LabeledContent("Elapsed", value: elapsedString)
                LabeledContent("Samples saved", value: "\(hr.sessionSampleCount)")
            }
        }
    }

    // MARK: - Helpers

    /// Marketing version + build, read from the bundle so it always reflects
    /// the shipped `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`.
    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(v) (\(b))"
    }

    private var statusColor: Color {
        switch hr.state {
        case .connected:   return .green
        case .scanning,
             .connecting:  return .orange
        default:           return .red
        }
    }

    private var elapsedString: String {
        guard let start = hr.sessionStartedAt else { return "0:00" }
        let s = Int(now.timeIntervalSince(start))
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    /// Surface the strap picker automatically when the app is scanning and the
    /// user genuinely has to choose: nothing connected, no remembered strap to
    /// reconnect to silently, and not mid-recording. Without this the scan runs
    /// invisibly and found monitors never appear unless the user knows to tap
    /// "Choose Device".
    private func maybePresentPicker() {
        guard !showDevicePicker,
              hr.state == .scanning,
              !hr.isRecording,
              !hr.hasRememberedStrap
        else { return }
        showDevicePicker = true
    }
}

/// Recorded sessions, behind a button off the main screen so the live-BPM
/// view stays uncluttered. Owns its own data load + the session-scoped and
/// whole-database export/delete actions.
struct SessionsView: View {
    @EnvironmentObject private var model: AppModel

    @State private var sessions: [HRDatabase.SessionInfo] = []
    @State private var shareURL: URL?
    @State private var confirmClear = false
    @State private var limitRange = false
    @State private var rangeStart = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var rangeEnd = Date()

    var body: some View {
        List {
            Section {
                if sessions.isEmpty {
                    Text("No sessions yet").foregroundStyle(.secondary)
                }
                ForEach(sessions) { s in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(s.startedAt, format: .dateTime.year().month().day()
                            .hour().minute().second())
                            .font(.subheadline.weight(.medium))
                        HStack(spacing: 10) {
                            Label("\(s.sampleCount)", systemImage: "waveform.path.ecg")
                            if let sensor = sessionSensorLabel(s) {
                                Label(sensor, systemImage: "sensor.tag.radiowaves.forward")
                            }
                            if s.endedAt == nil {
                                Text("active").foregroundStyle(.red)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            model.db.deleteSession(s.id)
                            reload()
                        } label: { Label("Delete", systemImage: "trash") }
                        Button {
                            shareURL = model.db.exportCSV(sessionID: s.id)
                        } label: { Label("CSV", systemImage: "square.and.arrow.up") }
                        .tint(.blue)
                    }
                }
            }

            Section {
                Toggle("Limit to date range", isOn: $limitRange.animation())
                if limitRange {
                    DatePicker("From", selection: $rangeStart,
                               displayedComponents: .date)
                    DatePicker("To", selection: $rangeEnd,
                               displayedComponents: .date)
                    if !rangeValid {
                        Label("End date must be on or after the start date.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Button {
                    shareURL = model.db.exportCSV(
                        sessionID: nil,
                        from: limitRange ? rangeBounds?.from : nil,
                        to: limitRange ? rangeBounds?.to : nil)
                } label: {
                    Label(limitRange ? "Export Range as CSV" : "Export All as CSV",
                          systemImage: "square.and.arrow.up")
                }
                .disabled(limitRange && !rangeValid)
            } header: {
                Text("Export")
            } footer: {
                if limitRange {
                    Text("Exports whole calendar days, inclusive of both dates. If no samples fall in the range, no file is produced.")
                }
            }

            Section {
                Button(role: .destructive) {
                    confirmClear = true
                } label: {
                    Label("Delete All Data", systemImage: "trash")
                }
            } footer: {
                Text("Database: \(model.db.fileURL.path)")
                    .font(.caption2)
            }
        }
        .navigationTitle("Sessions")
        .listStyle(.insetGrouped)
        .onAppear { reload() }
        .sheet(item: $shareURL) { url in
            ShareSheet(items: [url])
        }
        .alert("Delete all recorded data?", isPresented: $confirmClear) {
            Button("Delete Everything", role: .destructive) {
                model.db.deleteAll()
                reload()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes every session and sample from the database.")
        }
    }

    private var rangeValid: Bool {
        let cal = Calendar.current
        return cal.startOfDay(for: rangeStart) <= cal.startOfDay(for: rangeEnd)
    }

    /// Whole-calendar-day bounds: `from` = start of the start day,
    /// `to` = start of the day *after* the end day (exclusive upper bound,
    /// matching `s.ts < ?` in `exportCSV` so the end day is fully included).
    private var rangeBounds: (from: Date, to: Date)? {
        guard rangeValid else { return nil }
        let cal = Calendar.current
        let from = cal.startOfDay(for: rangeStart)
        guard let to = cal.date(byAdding: .day, value: 1,
                                 to: cal.startOfDay(for: rangeEnd)) else { return nil }
        return (from, to)
    }

    /// Prefer recorded sensor model over the advertised BLE name.
    private func sessionSensorLabel(_ s: HRDatabase.SessionInfo) -> String? {
        let identity = [s.manufacturer, s.model].compactMap { $0 }.joined(separator: " ")
        if !identity.isEmpty {
            return s.bodyLocation.map { "\(identity) (\($0))" } ?? identity
        }
        return s.deviceName
    }

    private func reload() {
        sessions = model.db.sessions()
    }
}

/// Bridges `UIActivityViewController` so CSV files can be shared/saved anywhere.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Live list of nearby heart-rate straps; tap one to connect and remember it.
struct DevicePickerView: View {
    @EnvironmentObject private var hr: HeartRateManager
    @Environment(\.dismiss) private var dismiss
    let onSelect: (HeartRateManager.Device) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if hr.discoveredDevices.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Searching for heart-rate straps…")
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(hr.discoveredDevices) { device in
                        let isOn = hr.connectedDeviceIDs.contains(device.id)
                        Button {
                            if isOn { hr.forget(device.id) } else { onSelect(device) }
                        } label: {
                            HStack {
                                Image(systemName: isOn
                                      ? "checkmark.circle.fill"
                                      : "sensor.tag.radiowaves.forward")
                                    .foregroundStyle(isOn ? Color.green : Color.accentColor)
                                Text(device.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: signalIcon(device.rssi))
                                    .foregroundStyle(.secondary)
                                Text("\(device.rssi) dBm")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                } footer: {
                    Text("Tap a strap to connect it; tap a connected (✓) strap to disconnect it. Connect several different straps at once — to compare them, or as a backup if one drops mid-recording. Each strap (e.g. an HRM-Pro+) still allows only one connection to itself, so disconnect it from Garmin Connect / other apps first.")
                }
            }
            .navigationTitle(hr.hasDevice ? "Straps" : "Choose Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { hr.startDeviceScan() } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
    }

    private func signalIcon(_ rssi: Int) -> String {
        switch rssi {
        case ..<(-85):  return "wifi.slash"
        case ..<(-70):  return "wifi.exclamationmark"
        default:        return "wifi"
        }
    }
}

extension URL: Identifiable {
    public var id: String { absoluteString }
}
