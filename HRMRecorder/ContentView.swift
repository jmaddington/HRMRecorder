import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var hr: HeartRateManager
    @EnvironmentObject private var model: AppModel

    @State private var now = Date()
    @State private var beat = false
    @State private var showDevicePicker = false
    @State private var deviceExpanded = false
    @State private var confirmForgetAll = false

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
        .alert("Remove all straps?", isPresented: $confirmForgetAll) {
            Button(hr.isRecording ? "End Recording & Remove" : "Remove",
                   role: .destructive) {
                if hr.isRecording { hr.stopRecording() }
                hr.forgetDevice()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(hr.isRecording
                 ? "This stops the current recording and forgets every strap."
                 : "This forgets every strap. You can pick them again next time.")
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
                    // Swipe-to-remove always safe here: secondaries by
                    // definition aren't the primary, so removing one can
                    // never empty the device list (primary still exists).
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            hr.forget(d.id)
                        } label: { Label("Remove", systemImage: "minus.circle") }
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
                        // During recording this is the "remove the last
                        // strap(s)" path — the alert offers to end the
                        // session as part of the action so the user isn't
                        // forced to stop recording first.
                        confirmForgetAll = true
                    } label: {
                        Label("Forget All Straps", systemImage: "minus.circle")
                    }
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
                Toggle("Keep screen on while app is open", isOn: Binding(
                    get: { AppSettings.keepScreenOnWhileAppOpen },
                    set: { on in
                        AppSettings.keepScreenOnWhileAppOpen = on
                        model.hr.refreshIdleTimer()
                    }))
            } header: {
                Text("Display")
            } footer: {
                Text("Keeps the display awake whenever the app is in the foreground; uses more battery.")
            }

            Section {
                NavigationLink {
                    ServerSyncView()
                } label: {
                    Label("Server Sync", systemImage: "arrow.up.circle")
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
/// Currently-connected straps appear in their own "Connected" section so the
/// user can remove any strap (including the primary) mid-session.
struct DevicePickerView: View {
    @EnvironmentObject private var hr: HeartRateManager
    @Environment(\.dismiss) private var dismiss
    let onSelect: (HeartRateManager.Device) -> Void

    /// The strap UUID the user just asked to remove during a recording when
    /// it would be the *last* one — held back until the alert resolves.
    @State private var pendingLastStrapForget: UUID?

    /// Stable ordering for the "Connected" section.
    private var connectedDevices: [HeartRateManager.ConnectedDevice] {
        hr.devices.values.sorted { $0.name < $1.name }
    }

    var body: some View {
        NavigationStack {
            List {
                if !connectedDevices.isEmpty {
                    Section {
                        ForEach(connectedDevices) { d in
                            Button {
                                requestForget(d.id)
                            } label: {
                                HStack {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.green)
                                    Text(d.name)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Circle()
                                        .fill(Self.statusColor(for: d.state))
                                        .frame(width: 7, height: 7)
                                    Text(d.state.label)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    requestForget(d.id)
                                } label: { Label("Remove", systemImage: "minus.circle") }
                            }
                        }
                    } header: {
                        Text("Connected")
                    } footer: {
                        Text("Swipe (or tap) to remove a strap. If you remove the last strap during a recording, you'll be asked whether to end the session.")
                    }
                }

                Section {
                    let available = hr.discoveredDevices
                        .filter { !hr.connectedDeviceIDs.contains($0.id) }
                    if available.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Searching for heart-rate straps…")
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(available) { device in
                        Button {
                            onSelect(device)
                        } label: {
                            HStack {
                                Image(systemName: "sensor.tag.radiowaves.forward")
                                    .foregroundStyle(Color.accentColor)
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
                } header: {
                    Text(connectedDevices.isEmpty ? "Available" : "Add another")
                } footer: {
                    Text("Connect several different straps at once — to compare them, or as a backup if one drops mid-recording. Each strap (e.g. an HRM-Pro+) still allows only one connection to itself, so disconnect it from Garmin Connect / other apps first.")
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
            .alert("Remove the last strap?",
                   isPresented: Binding(
                    get: { pendingLastStrapForget != nil },
                    set: { if !$0 { pendingLastStrapForget = nil } })) {
                Button("End Recording & Remove", role: .destructive) {
                    if let id = pendingLastStrapForget {
                        hr.stopRecording()
                        hr.forget(id)
                    }
                    pendingLastStrapForget = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingLastStrapForget = nil
                }
            } message: {
                Text("This is the only strap connected. Removing it ends the current recording.")
            }
        }
    }

    /// Forget a strap immediately unless doing so would leave the recording
    /// with zero straps — in that case stash the id and let the alert above
    /// confirm the user actually wants to end the session.
    private func requestForget(_ id: UUID) {
        if hr.isRecording && hr.devices.count <= 1 {
            pendingLastStrapForget = id
        } else {
            hr.forget(id)
        }
    }

    private static func statusColor(for state: HeartRateManager.State) -> Color {
        switch state {
        case .connected:              return .green
        case .scanning, .connecting:  return .orange
        default:                      return .red
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
