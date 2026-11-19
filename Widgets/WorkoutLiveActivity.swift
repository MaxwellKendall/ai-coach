import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct BarbrabellWidgets: WidgetBundle {
    var body: some Widget { WorkoutLiveActivity() }
}

/// FIT-304, TKL-801 (the approved prototype on TKL-800, https://claude.ai/artifact/56LL6q28Kw1gdbeYr2BUpe): the live
/// workout in the Dynamic Island and on the Lock Screen. Expanded and on the Lock Screen: the lift large, "Lift 3 of 6"
/// and the set dots, the set as the hero with Done set; during a rest, the countdown draining in the plate color with
/// −10s, +10s and Skip; then what's next. The buttons work without opening the app (WorkoutIntent). When a rest runs
/// out the island says "Rest over", from the content's stale date even if the app is asleep.
struct WorkoutLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            let phase = Phase(context.state, stale: context.isStale)
            LockScreen(state: context.state, phase: phase, tint: tint(context.attributes.plate))
                .padding(16)
        } dynamicIsland: { context in
            let state = context.state
            let phase = Phase(state, stale: context.isStale)
            let tint = tint(context.attributes.plate)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Heading(state: state, phase: phase, tint: tint, island: true).padding(.leading, 6).padding(.top, 2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Group {
                        if case .resting(let starts, let ends) = phase {
                            RestRing(starts: starts, ends: ends, tint: tint, size: 46)
                        } else if !state.isDone {
                            SetDots(done: state.setsDone, of: state.sets, tint: tint)
                        }
                    }
                    .padding(.trailing, 6).padding(.top, 2)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Hero(state: state, phase: phase, tint: tint, onDark: true)
                        .padding(.horizontal, 6).padding(.bottom, 2)
                }
            } compactLeading: {
                // "Squat 2/3": which lift and which set, always.
                HStack(spacing: 4) {
                    if !state.lift.isEmpty { Text(state.lift).lineLimit(1) }
                    Text(state.step).foregroundStyle(.secondary)
                }
                .font(.subheadline.weight(.semibold)).monospacedDigit().padding(.leading, 4)
            } compactTrailing: {
                switch phase {
                case .resting(_, let ends):
                    Text(timerInterval: Date.now...ends, countsDown: true).monospacedDigit().foregroundStyle(tint)
                        .multilineTextAlignment(.trailing).frame(maxWidth: 44)
                case .restOver:
                    Text("Go").font(.subheadline.weight(.bold)).foregroundStyle(tint)
                case .done:
                    Image(systemName: "checkmark").font(.subheadline.weight(.bold)).foregroundStyle(tint)
                case .lifting:
                    Text(state.set.isEmpty ? (state.load ?? "") : state.set).font(.subheadline.weight(.semibold)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.8).foregroundStyle(tint)
                }
            } minimal: {
                switch phase {
                case .resting(let starts, let ends):
                    RestRing(starts: starts, ends: ends, tint: tint, size: 22, digits: false)
                case .restOver:
                    Image(systemName: "bell.fill").font(.caption2.weight(.bold)).foregroundStyle(tint)
                default:
                    ProgressView(value: state.progress).progressViewStyle(.circular).tint(tint)
                }
            }
            .keylineTint(tint)
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

/// What the Live Activity shows: a set to do, a rest running, a rest that just ran out, or the session done.
enum Phase: Equatable {
    case lifting
    case resting(starts: Date, ends: Date)
    case restOver
    case done

    init(_ state: WorkoutActivityAttributes.ContentState, stale: Bool) {
        if state.isDone {
            self = .done
        } else if let ends = state.restEnds, let starts = state.restStarts {
            // Stale is the rest's end passing with the app asleep.
            self = stale || ends <= .now ? .restOver : .resting(starts: starts, ends: ends)
        } else {
            self = state.restOver ? .restOver : .lifting
        }
    }
}

/// The lift large, then where it sits in the session.
private struct Heading: View {
    let state: WorkoutActivityAttributes.ContentState
    let phase: Phase
    let tint: Color
    /// In the island, where a rest's "up next" moves up here so its buttons fit.
    var island = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(state.title).font(.title3.weight(.bold)).lineLimit(1).minimumScaleFactor(0.8)
            Text(where_).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
        }
    }

    private var where_: String {
        if state.isDone { return "\(state.lifts) lifts · all done" }
        if island, case .resting = phase { return "Rest · up next \(state.set)" }
        if state.warming { return "Warm-up · step \(state.step.replacingOccurrences(of: "/", with: " of "))" }
        let set = "Set " + state.step.replacingOccurrences(of: "/", with: " of ")
        return state.lifts > 0 ? "Lift \(state.liftIndex) of \(state.lifts) · \(set)" : set
    }
}

/// The hero (the set, or the rest's countdown), its buttons, then what's next.
private struct Hero: View {
    let state: WorkoutActivityAttributes.ContentState
    let phase: Phase
    let tint: Color
    /// In the island, which is always black.
    var onDark = false
    /// On the Lock Screen, which has less height than the open island.
    var tight = false

    var body: some View {
        VStack(alignment: .leading, spacing: tight ? 6 : 10) {
            switch phase {
            case .resting(let starts, let ends):
                // In the island the ring counts down and the heading says what's next, so the buttons fit.
                if !onDark {
                    HStack(alignment: .firstTextBaseline) {
                        Text(timerInterval: Date.now...ends, countsDown: true)
                            .font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(tint)
                        Spacer(minLength: 8)
                        Text("Up next \(state.set)").font(.subheadline.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                ProgressView(timerInterval: starts...ends, countsDown: true) { EmptyView() } currentValueLabel: { EmptyView() }
                    .tint(tint)
                HStack(spacing: 8) {
                    action("−10s", "less", label: "10 seconds less")
                    action("+10s", "more", label: "10 seconds more")
                    action("Skip", "skip", label: "Skip rest", primary: true)
                }
            case .done:
                Text("Workout done").font(.system(size: 28, weight: .bold, design: .rounded))
                Text("Open Barbrabell to save it").font(.subheadline).foregroundStyle(.secondary)
            case .lifting, .restOver:
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 0) {
                        if phase == .restOver {
                            Text("Rest over").font(.caption.weight(.bold)).foregroundStyle(tint).textCase(.uppercase)
                        }
                        Text(state.set.isEmpty ? (state.load ?? "") : state.set)
                            .font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.6)
                    }
                    Spacer(minLength: 8)
                    action(state.warming ? "Done" : "Done set", "done", label: state.warming ? "Warm-up step done" : "Done set",
                           primary: true, wide: true)
                }
            }
            // Resting, "Up next" already says it.
            if !state.isDone, !state.next.isEmpty, phase == .lifting || phase == .restOver {
                Text(state.next).font(.subheadline).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
        }
    }

    private func action(_ title: String, _ id: String, label: String, primary: Bool = false, wide: Bool = false) -> some View {
        Button(intent: WorkoutIntent(id)) {
            Text(title).font(.subheadline.weight(.bold)).monospacedDigit()
                .frame(maxWidth: wide ? nil : .infinity).padding(.horizontal, wide ? 18 : 0).frame(height: tight || (onDark && phase != .lifting && phase != .restOver) ? 34 : 40)
                .foregroundStyle(primary ? Color.white : Color.primary)
                .background(primary ? tint : Color.primary.opacity(onDark ? 0.16 : 0.08), in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// The rest as a ring that drains in the plate color, its seconds inside.
private struct RestRing: View {
    let starts: Date
    let ends: Date
    let tint: Color
    let size: CGFloat
    var digits = true

    var body: some View {
        ProgressView(timerInterval: starts...ends, countsDown: true) { EmptyView() } currentValueLabel: {
            if digits {
                Text(timerInterval: Date.now...ends, countsDown: true, showsHours: false)
                    .font(.system(size: 11, weight: .bold)).monospacedDigit()
            }
        }
        .progressViewStyle(.circular).tint(tint).frame(width: size, height: size)
    }
}

/// A dot per set of the lift, filled as they're done.
private struct SetDots: View {
    let done: Int
    let of: Int
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<min(of, 8), id: \.self) { index in
                Circle().fill(index < done ? tint : Color.primary.opacity(0.2)).frame(width: 8, height: 8)
            }
        }
        .frame(height: 28)
        .accessibilityElement().accessibilityLabel("\(done) of \(of) sets done")
    }
}

/// The Lock Screen and StandBy: the expanded island's content, sized for the Lock Screen.
private struct LockScreen: View {
    let state: WorkoutActivityAttributes.ContentState
    let phase: Phase
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "dumbbell.fill").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: 32, height: 32).background(tint, in: .rect(cornerRadius: 8))
                Heading(state: state, phase: phase, tint: tint)
                Spacer(minLength: 0)
                if case .resting(let starts, let ends) = phase {
                    RestRing(starts: starts, ends: ends, tint: tint, size: 34)
                } else if !state.isDone {
                    SetDots(done: state.setsDone, of: state.sets, tint: tint)
                }
            }
            Hero(state: state, phase: phase, tint: tint, tight: true)
        }
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}
