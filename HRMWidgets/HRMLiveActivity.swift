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
            LockScreenHRView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.55))
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
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 64)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 6) {
                        Image(systemName: "sensor.tag.radiowaves.forward")
                        Text(context.state.deviceName).lineLimit(1)
                        Spacer()
                        contactBadge(context.state.sensorContact)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: "heart.fill").foregroundStyle(.red)
            } compactTrailing: {
                Text("\(context.state.bpm)").monospacedDigit()
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

/// Lock-screen / banner presentation.
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
                Text("bpm")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Recording")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.red)
                    Text(context.attributes.sessionStartedAt, style: .timer)
                        .font(.title3.monospacedDigit())
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.trailing)
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "sensor.tag.radiowaves.forward")
                Text(context.state.deviceName).lineLimit(1)
                Spacer()
                if let contact = context.state.sensorContact, !contact {
                    Label("Poor skin contact", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
