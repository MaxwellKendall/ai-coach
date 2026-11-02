import ActivityKit
import SwiftUI
import WidgetKit

@main
struct BarbrabellWidgets: WidgetBundle {
    var body: some Widget { WorkoutLiveActivity() }
}

/// FIT-304: the live workout as one card on the Lock Screen (the lift, then "Set 2 of 3 · 185 lb × 5"; during a rest,
/// the next set with a small countdown on the right) and the same in the Dynamic Island. A tap opens the app, where the
/// workout is still on screen.
struct WorkoutLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            Card(state: context.state, tint: tint(context.attributes.plate)).padding(16)
        } dynamicIsland: { context in
            let state = context.state
            let tint = tint(context.attributes.plate)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) { Card(state: state, tint: tint).padding(.horizontal, 4).padding(.bottom, 4) }
            } compactLeading: {
                Text(state.step).monospacedDigit().padding(.leading, 4)
            } compactTrailing: {
                if let ends = state.restEnds, ends > .now {
                    Text(timerInterval: Date.now...ends, countsDown: true).monospacedDigit().foregroundStyle(tint)
                        .multilineTextAlignment(.trailing).frame(maxWidth: 44)
                } else if let load = state.load {
                    Text(load).monospacedDigit()
                }
            } minimal: {
                ProgressView(value: state.progress).progressViewStyle(.circular).tint(tint)
            }
        }
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
        HStack(spacing: 12) {
            Image(systemName: "dumbbell.fill").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                .frame(width: 32, height: 32).background(tint, in: .rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(state.title).font(.headline).lineLimit(1)
                Text(state.detail).font(.subheadline).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            Spacer(minLength: 0)
            // The rest is a detail of the card, never a card of its own.
            if let ends = state.restEnds, ends > .now {
                Text(timerInterval: Date.now...ends, countsDown: true).font(.title3.weight(.semibold)).monospacedDigit()
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
