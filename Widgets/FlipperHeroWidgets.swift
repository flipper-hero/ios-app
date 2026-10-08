import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct FlipperHeroWidgets: WidgetBundle {
    var body: some Widget {
        FlipperLiveActivity()
    }
}

private let orange = Color(red: 1.0, green: 0.51, blue: 0.0)

struct FlipperLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FlipperActivityAttributes.self) { context in
            LockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(orange)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Logo(size: 40).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Trailing(context: context).font(.title3.monospacedDigit().weight(.semibold))
                        .foregroundStyle(orange).padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.title).font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(context.state.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        if let progress = context.state.progress, !context.state.isFinished {
                            ProgressView(value: progress).tint(orange)
                        }
                        ActionButton(context: context)
                    }
                }
            } compactLeading: {
                Logo(size: 22)
            } compactTrailing: {
                Trailing(context: context).font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(orange).frame(maxWidth: 52)
            } minimal: {
                Logo(size: 22)
            }
            .keylineTint(orange)
        }
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<FlipperActivityAttributes>

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Logo(size: 46)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(context.state.title).font(.headline).foregroundStyle(.white).lineLimit(1)
                    Spacer()
                    Trailing(context: context).font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(orange)
                }
                Text(context.state.detail).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(2)
                if let progress = context.state.progress, !context.state.isFinished {
                    ProgressView(value: progress).tint(orange)
                }
                ActionButton(context: context)
            }
        }
        .padding(16)
    }
}

/// Elapsed time for an emulation, percent for an update.
private struct Trailing: View {
    let context: ActivityViewContext<FlipperActivityAttributes>

    var body: some View {
        if context.state.isFinished {
            Image(systemName: "checkmark")
        } else if let progress = context.state.progress {
            Text("\(Int(progress * 100))%")
        } else {
            Text(context.attributes.startedAt, style: .timer).multilineTextAlignment(.trailing)
        }
    }
}

private struct ActionButton: View {
    let context: ActivityViewContext<FlipperActivityAttributes>

    var body: some View {
        if !context.state.isFinished {
            switch context.attributes.kind {
            case .emulation:
                Button(intent: StopFlipperAppIntent()) {
                    Label("Stop", systemImage: "stop.fill").font(.caption.weight(.semibold))
                }
                .tint(orange)
            case .firmwareUpdate where (context.state.progress ?? 0) < 1:
                Button(intent: CancelFirmwareUpdateIntent()) {
                    Label("Cancel", systemImage: "xmark").font(.caption.weight(.semibold))
                }
                .tint(.gray)
            case .firmwareUpdate:
                EmptyView()
            case .engagement:
                Button(intent: DisarmEngagementIntent()) {
                    Label("Disarm", systemImage: "lock.open").font(.caption.weight(.semibold))
                }
                .tint(.red)
            }
        }
    }
}

private struct Logo: View {
    let size: CGFloat
    var body: some View {
        Image("Logo").resizable().scaledToFit().frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}
