import SwiftUI

/// The one in-app sync screen, reached by a single row on the secondary
/// Sessions page — the live-BPM screen stays untouched (uncluttered-UI
/// constraint). Server URL + enable are edited in iOS Settings.app; this
/// screen adds what Settings.app can't: OAuth sign-in (needs an in-app web
/// auth session), a reachability test, and read-only status.
struct ServerSyncView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var uploader: SyncUploader

    @State private var enabled = SyncSettings.isEnabled
    @State private var signedIn = false
    @State private var testing = false
    @State private var testResult = ""
    @State private var signingIn = false
    @State private var pending = 0
    @State private var cursorOverrun = 0
    @State private var confirmingDelete = false
    @State private var deleteResult = ""
    @State private var confirmingResync = false

    private var serverURL: String { SyncSettings.serverURLString }
    private var urlIsValidHTTPS: Bool { SyncSettings.validatedBaseURL != nil }

    var body: some View {
        List {
            Section {
                if serverURL.isEmpty {
                    Text("No server configured")
                        .foregroundStyle(.secondary)
                } else {
                    Text(serverURL)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                    if !urlIsValidHTTPS {
                        Label("Must be a valid https:// URL — sync is disabled until fixed.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Toggle("Enable Sync", isOn: Binding(
                    get: { enabled },
                    set: { on in
                        enabled = on
                        SyncSettings.isEnabled = on
                        if on { uploader.trigger("enabled") }
                    }))
                .disabled(!urlIsValidHTTPS && !enabled)
            } header: {
                Text("Server")
            } footer: {
                Text("Edit the server URL and the static-token fallback in the iOS Settings app under HRM Recorder.")
            }

            Section("Authentication") {
                HStack {
                    Text("Status")
                    Spacer()
                    Text(signedIn ? "Signed in" : "Not signed in")
                        .foregroundStyle(signedIn ? .green : .secondary)
                }
                Button {
                    signIn()
                } label: {
                    HStack {
                        Label("Sign in", systemImage: "person.crop.circle.badge.checkmark")
                        if signingIn { Spacer(); ProgressView() }
                    }
                }
                .disabled(signingIn || !urlIsValidHTTPS)
                if signedIn {
                    Button(role: .destructive) {
                        model.auth.signOut()
                        refresh()
                    } label: {
                        Label("Sign out", systemImage: "person.crop.circle.badge.xmark")
                    }
                }
            }

            Section("Connection") {
                Button {
                    testConnection()
                } label: {
                    HStack {
                        Label("Test connection", systemImage: "antenna.radiowaves.left.and.right")
                        if testing { Spacer(); ProgressView() }
                    }
                }
                .disabled(testing || !urlIsValidHTTPS)
                if !testResult.isEmpty {
                    Text(testResult)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent("Last result",
                               value: uploader.status.isEmpty ? "—" : uploader.status)
                LabeledContent("Synced cursor", value: "\(SyncSettings.cursorSampleID)")
                LabeledContent("Pending samples", value: "\(max(0, pending))")
                // AIDEV-NOTE: HRMRecorder-59s — a cursor past the highest id
                // this install ever ALLOCATED means sync silently uploads
                // nothing while still reporting "Synced". Measured against the
                // allocation high-water mark, not MAX(id): the latter drops
                // when "Delete synced sessions" prunes rows, which would make
                // an ordinary prune look like a wedged cursor.
                if cursorOverrun > 0 {
                    Label("Sync position is \(cursorOverrun) samples past anything recorded on this device — nothing will upload. Tap “Force full resync” below to repair.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Button {
                    uploader.trigger("manual")
                    refresh()
                } label: {
                    Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!enabled || !urlIsValidHTTPS)
            } header: {
                Text("Status")
            } footer: {
                Text("Sync is best-effort and runs automatically. A failed sync never affects recording. Local data is only deleted when you tap “Delete synced sessions” below.")
            }

            Section {
                Button {
                    confirmingResync = true
                } label: {
                    Label("Force full resync", systemImage: "arrow.clockwise.circle")
                }
                .disabled(!enabled || !urlIsValidHTTPS)
            } header: {
                Text("Repair")
            } footer: {
                Text("Re-uploads every heart-rate sample stored on this device, ignoring the saved sync position. Use this if the dashboard is missing data or the sync position looks wrong. The server ignores samples it already has, so this is safe — it only costs time and battery, never duplicates. May take several minutes for a large history.")
            }

            Section {
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Label("Delete synced sessions", systemImage: "trash")
                }
                if !deleteResult.isEmpty {
                    Text(deleteResult)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Local storage")
            } footer: {
                Text("Removes ended sessions whose samples are all confirmed on the server. The current recording is never touched, and the server keeps its copy. Once deleted, those sessions can no longer be exported to CSV from this device.")
            }
        }
        .navigationTitle("Server Sync")
        .listStyle(.insetGrouped)
        .onAppear { refresh() }
        .confirmationDialog("Delete synced sessions from this device?",
                            isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete synced sessions", role: .destructive) {
                deleteSyncedSessions()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Only sessions whose samples are all confirmed on the server will be removed. The current recording and any not-yet-synced sessions are kept.")
        }
        .confirmationDialog("Force a full resync?",
                            isPresented: $confirmingResync,
                            titleVisibility: .visible) {
            Button("Re-upload everything") {
                uploader.forceResync()
                refresh()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Every sample on this device is sent to the server again. Already-synced samples are ignored by the server, so nothing is duplicated — this only refills missing data. It may take a while and use battery.")
        }
    }

    private func refresh() {
        enabled = SyncSettings.isEnabled
        signedIn = model.auth.isSignedIn
        pending = model.db.maxSampleID() - SyncSettings.cursorSampleID
        cursorOverrun = SyncSettings.cursorSampleID - model.db.highestAllocatedSampleID()
    }

    private func signIn() {
        signingIn = true
        testResult = ""
        Task {
            do {
                try await model.auth.signIn()
                testResult = "Signed in."
            } catch {
                testResult = error.localizedDescription
            }
            signingIn = false
            refresh()
            if enabled { uploader.trigger("after-signin") }
        }
    }

    private func deleteSyncedSessions() {
        let cursor = SyncSettings.cursorSampleID
        let active = model.hr.activeSessionID
        let n = model.db.deleteFullySyncedSessions(uploadedThroughID: cursor,
                                                   excluding: active)
        deleteResult = n == 0
            ? "Nothing to delete — no sessions are fully synced."
            : "Deleted \(n) session\(n == 1 ? "" : "s")."
        refresh()
    }

    private func testConnection() {
        testing = true
        testResult = ""
        Task {
            if let d = await model.auth.discover() {
                let mode = d.mode == .oauth ? "OAuth" : "static token"
                testResult = "OK — protocol reachable, auth: \(mode), "
                    + "cap \(d.maxSamplesPerRequest)."
            } else {
                testResult = "Unreachable — check the server URL (HTTPS) and network."
            }
            testing = false
        }
    }
}
