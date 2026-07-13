import SwiftUI

// AIDEV-NOTE: first-run disclaimer gate; sheet until acknowledgedV1 set; any -HRM* launch arg skips it (DEBUG)
/// Persistence + launch gating for the one-time disclaimer.
enum Disclaimer {
    private static let acknowledgedKey = "disclaimerAcknowledgedV1"

    static var isAcknowledged: Bool {
        get { UserDefaults.standard.bool(forKey: acknowledgedKey) }
        set { UserDefaults.standard.set(newValue, forKey: acknowledgedKey) }
    }

    /// True only while the user has never acknowledged. Any automation launch
    /// argument (the whole `-HRM` family: screenshots, fixture seeding, fake
    /// sensor, auto-record, CSV export, and future ones) suppresses the sheet
    /// so automated runs land on the intended screen.
    static var shouldPresentOnLaunch: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("-HRM") }) {
            return false
        }
        #endif
        return !isAcknowledged
    }
}

/// The disclaimer text. Two contexts:
/// - First run (`isFirstRun: true`): presented as an undismissable sheet;
///   the prominent "I Understand" button records acknowledgment.
/// - Re-view from Sessions → About & Disclaimer (`isFirstRun: false`):
///   plain sheet with a normal Done dismissal.
struct DisclaimerView: View {
    let isFirstRun: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("**Not a medical device.** HRMRecorder records the heart rate your Bluetooth strap reports — nothing more. It measures rate, not rhythm, and it cannot diagnose, treat, or detect any medical condition.")
                    Text("**Not medical advice.** Your recordings may be useful to share with your doctor, but only a qualified clinician can tell you what they mean. If you think something is wrong, contact your doctor or emergency services — don't wait on an app.")
                    Text("**Accuracy depends on your strap.** The app stores whatever your sensor sends. Readings can be wrong (strap fit, dry electrodes, low battery, interference) or missed entirely if Bluetooth or iOS drops the connection. Don't rely on this app to capture a critical event.")
                    Text("**Built with AI, maintained best-effort.** This is free, open-source software written largely by Claude (Anthropic's AI) with human review, maintained by one person in their spare time. It's provided as-is, with no warranty of any kind (MIT License).")
                    Text("**Your data stays on your phone.** Recordings live only on this device. Nothing is uploaded or shared unless you export it.")

                    Link("View on GitHub",
                         destination: URL(string: "https://github.com/jmaddington/HRMRecorder")!)
                        .font(.footnote)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                }
                .padding()
            }
            .navigationTitle("Before You Begin")
            .toolbar {
                if !isFirstRun {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if isFirstRun {
                    Button {
                        Disclaimer.isAcknowledged = true
                        dismiss()
                    } label: {
                        Text("I Understand")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding()
                    .background(.ultraThinMaterial)
                }
            }
        }
        .interactiveDismissDisabled(isFirstRun)
    }
}
