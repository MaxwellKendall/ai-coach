import ActivityKit
import SwiftUI
import WidgetKit

@main
struct BarbrabellWidgets: WidgetBundle {
    var body: some Widget {
        WorkoutLiveActivity()
        TodayWidget()
    }
}

/// FIT-304 + TKL-934: the live workout on the Lock Screen and in the Dynamic Island.
/// Keeps the existing layout (TKL-801 owns layout changes) and adds motion: countdown rings via
/// `ProgressView(timerInterval:)` + `Text(timerInterval:)`, `numericText` transitions on logged sets,
/// and "Next: Back Squat · 170 × 5" in the expanded view.
struct WorkoutLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            Card(state: context.state, tint: tint(context.attributes.plate)).padding(16)
        } dynamicIsland: { context in
            let state = context.state
            let tint = tint(context.attributes.plate)
            let restRange = Self.restInterval(for: state)
            return DynamicIsland {
                // Long-pressed: the lift and the set large, the rest's countdown or the load on the right, then progress.
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.title).font(.headline).lineLimit(1)
                        Text(state.step.contains("/") ? "Set \(state.step.replacingOccurrences(of: "/", with: " of "))" : state.step)
                            .font(.subheadline).foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                    .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Group {
                        if let range = restRange {
                            Text(timerInterval: range, countsDown: true).foregroundStyle(tint)
                        } else {
                            Text(state.set.isEmpty ? (state.load ?? "") : state.set)
                                .contentTransition(.numericText())
                        }
                    }
                    .font(.title2.weight(.semibold)).monospacedDigit().multilineTextAlignment(.trailing).padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(state.nextUp ?? state.detail)
                            .font(.subheadline).monospacedDigit().lineLimit(1)
                            .contentTransition(.numericText())
                        ProgressView(value: state.progress).tint(tint)
                    }
                    .padding(.horizontal, 6).padding(.bottom, 4)
                }
            } compactLeading: {
                // "Squat 2/3": which lift and which set, always.
                HStack(spacing: 4) {
                    if !state.lift.isEmpty { Text(state.lift).lineLimit(1) }
                    Text(state.step).foregroundStyle(.secondary).contentTransition(.numericText())
                }
                .font(.subheadline.weight(.semibold)).monospacedDigit().padding(.leading, 4)
            } compactTrailing: {
                // "185×5", or a countdown ring + timer while resting (animates without updates).
                if let range = restRange {
                    HStack(spacing: 4) {
                        ProgressView(timerInterval: range, countsDown: true) {
                            EmptyView()
                        } currentValueLabel: {
                            EmptyView()
                        }
                        .progressViewStyle(.circular)
                        .tint(tint)
                        .frame(width: 18, height: 18)
                        Text(timerInterval: range, countsDown: true)
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(tint)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 38)
                    }
                } else {
                    Text(state.set.isEmpty ? (state.load ?? "") : state.set)
                        .font(.subheadline.weight(.semibold)).monospacedDigit()
                        .contentTransition(.numericText())
                        .lineLimit(1).minimumScaleFactor(0.8).foregroundStyle(tint)
                }
            } minimal: {
                if let range = restRange {
                    ProgressView(timerInterval: range, countsDown: true) {
                        EmptyView()
                    } currentValueLabel: {
                        EmptyView()
                    }
                    .progressViewStyle(.circular)
                    .tint(tint)
                } else {
                    ProgressView(value: state.progress).progressViewStyle(.circular).tint(tint)
                }
            }
        }
    }

    static func restInterval(for state: WorkoutActivityAttributes.ContentState) -> ClosedRange<Date>? {
        guard let ends = state.restEnds, ends > .now else { return nil }
        let start = min(state.restStarted ?? .now, ends)
        return start...ends
    }

    /// The app's plate colors (Plate.mark in App/Theme.swift), each light and dark.
    private func tint(_ plate: String) -> Color {
        let (light, dark): (UInt32, UInt32) = switch plate {
        case "red": (0xd21f2f, 0xff5a62)
        case "yellow": (0x7a5f00, 0xffd21f)
        case "green": (0x0f7d43, 0x2fc774)
        default: (0x1747d6, 0x5f86ff)
        }
        return Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
}

private struct Card: View {
    let state: WorkoutActivityAttributes.ContentState
    let tint: Color

    var body: some View {
        let restRange = WorkoutLiveActivity.restInterval(for: state)
        HStack(spacing: 12) {
            if let range = restRange {
                ZStack {
                    ProgressView(timerInterval: range, countsDown: true) {
                        EmptyView()
                    } currentValueLabel: {
                        EmptyView()
                    }
                    .progressViewStyle(.circular)
                    .tint(tint)
                    .frame(width: 32, height: 32)
                }
                .frame(width: 32, height: 32)
            } else {
                Image(systemName: "dumbbell.fill").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: 32, height: 32).background(tint, in: .rect(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(state.title).font(.headline).lineLimit(1)
                Text(state.detail)
                    .font(.subheadline).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 0)
            if let range = restRange {
                Text(timerInterval: range, countsDown: true).font(.title3.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(tint).multilineTextAlignment(.trailing).frame(width: 56, alignment: .trailing)
            }
        }
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}
