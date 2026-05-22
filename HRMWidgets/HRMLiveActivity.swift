import ActivityKit
import SwiftUI
import WidgetKit

/// The `HRMWidgets` app-extension entry point. ActivityKit renders these views
/// using `ContentState` the app pushes through `LiveActivityController`; the
/// extension never reads heart-rate data itself.
///
/// No availability annotations are needed: the extension target deploys to
/// iOS 16.1, exactly the floor for `ActivityConfiguration` / `DynamicIsland`,
/// so every symbol here is available without a guard.
@main
struct HRMWidgetsBundle: WidgetBundle {
    var body: some Widget {
        HRMLiveActivity()
    }
}

struct HRMLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HRMActivityAttributes.self) { context in
            // Force a dark canvas with explicitly light foregrounds so the
            // lock screen can never end up dark-on-dark (the system's
            // light-mode `.secondary` over a tinted-dark background was the
            // failure mode this guards against). `Color.black` is opaque to
            // give a fully predictable backdrop, and the inner view uses
            // explicit white tones rather than `.primary`/`.secondary`.
            LockScreenHRView(context: context)
                .activityBackgroundTint(Color.black)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("\(context.state.bpm)", systemImage: "heart.fill")
                        .font(.title2.bold().monospacedDigit())
                        .foregroundStyle(.red)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.sessionStartedAt, style: .timer)
                        .font(.title3.monospacedDigit())
                        .foregroundStyle(Color.white.opacity(0.75))
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 64)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 6) {
                        Image(systemName: "sensor.tag.radiowaves.forward")
                        Text(context.state.deviceName).lineLimit(1)
                        if let extra = secondarySummary(context.state.secondaryBPMs) {
                            Text(extra).monospacedDigit()
                        }
                        Spacer()
                        contactBadge(context.state.sensorContact)
                    }
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.75))
                }
            } compactLeading: {
                Image(systemName: "heart.fill").foregroundStyle(.red)
            } compactTrailing: {
                Text("\(context.state.bpm)")
                    .monospacedDigit()
                    .foregroundStyle(.white)
            } minimal: {
                Text("\(context.state.bpm)").monospacedDigit().foregroundStyle(.red)
            }
            .keylineTint(.red)
        }
    }

    @ViewBuilder
    private func contactBadge(_ contact: Bool?) -> some View {
        if let contact {
            Label(contact ? "Contact OK" : "Poor contact",
                   systemImage: contact ? "checkmark.circle" : "exclamationmark.triangle")
                .foregroundStyle(contact ? .green : .orange)
        }
    }
}

/// Lock-screen / banner presentation. Foreground tones are explicit white
/// shades (not `.primary`/`.secondary`) so the always-dark background tint
/// can never resolve to dark-on-dark when the user is in light mode.
struct LockScreenHRView: View {
    let context: ActivityViewContext<HRMActivityAttributes>

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "heart.fill")
                    .foregroundStyle(.red)
                Text("\(context.state.bpm)")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Text("bpm")
                    .font(.headline)
                    .foregroundStyle(Color.white.opacity(0.75))
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Recording")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.red)
                    Text(context.attributes.sessionStartedAt, style: .timer)
                        .font(.title3.monospacedDigit())
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.trailing)
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "sensor.tag.radiowaves.forward")
                Text(context.state.deviceName).lineLimit(1)
                if let extra = secondarySummary(context.state.secondaryBPMs) {
                    Text(extra).monospacedDigit()
                }
                Spacer()
                if let contact = context.state.sensorContact, !contact {
                    Label("Poor skin contact", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(Color.white.opacity(0.75))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// Compact "+ 72 · 75" tag for any additional straps recording into the same
/// session. `nil`/empty (the single-strap case) renders nothing, so the
/// lock screen and Dynamic Island are unchanged for one strap.
private func secondarySummary(_ bpms: [Int]?) -> String? {
    guard let bpms, !bpms.isEmpty else { return nil }
    return "+ " + bpms.map(String.init).joined(separator: " · ")
}
