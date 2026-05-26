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
    @State private var confirmingDelete = false
    @State private var deleteResult = ""

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
    }

    private func refresh() {
        enabled = SyncSettings.isEnabled
        signedIn = model.auth.isSignedIn
        pending = model.db.maxSampleID() - SyncSettings.cursorSampleID
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
