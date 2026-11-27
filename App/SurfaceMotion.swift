import SwiftUI

enum SurfaceMotion {
    /// One band's crossing, in seconds: the usual shimmer, and the calm one for a wait that can last hours (TKL-935).
    static let shimmer: TimeInterval = 1.8
    static let slowShimmer: TimeInterval = 3.6

    static func shimmerPhase(at time: TimeInterval, period: TimeInterval = shimmer) -> Float {
        Float(max(0, time).truncatingRemainder(dividingBy: period) / period)
    }

    static func pulseOpacity(at time: TimeInterval) -> Double {
        0.9 - 0.1 * cos(2 * .pi * time / 3.2)
    }

    static func sheenAngle(_ angle: Angle, reduceMotion: Bool) -> Float {
        Float((reduceMotion ? Angle.degrees(30) : angle).radians)
    }
}

extension View {
    /// `slow`: the calm shimmer, for a wait that can last hours (a coach writing the week).
    func shimmer(slow: Bool = false) -> some View { modifier(Shimmer(period: slow ? SurfaceMotion.slowShimmer : SurfaceMotion.shimmer)) }

    func sheen(angle: Angle) -> some View { modifier(Sheen(angle: angle)) }
}

private struct Shimmer: ViewModifier {
    let period: TimeInterval
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date.now

    func body(content: Content) -> some View {
        if reduceMotion {
            TimelineView(.periodic(from: start, by: 1.0 / 15)) { context in
                content.opacity(SurfaceMotion.pulseOpacity(at: context.date.timeIntervalSince(start)))
            }
        } else {
            TimelineView(.animation) { context in
                content.colorEffect(ShaderLibrary.shimmer(
                    .boundingRect,
                    .float(SurfaceMotion.shimmerPhase(at: context.date.timeIntervalSince(start), period: period))
                ))
            }
        }
    }
}

private struct Sheen: ViewModifier, Animatable {
    nonisolated var angle: Angle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    nonisolated var animatableData: Double {
        get { angle.radians }
        set { angle = .radians(newValue) }
    }

    func body(content: Content) -> some View {
        content.colorEffect(ShaderLibrary.sheen(
            .boundingRect,
            .float(SurfaceMotion.sheenAngle(angle, reduceMotion: reduceMotion))
        ))
    }
}

struct SkeletonLine: View {
    var width: CGFloat? = nil
    var height: CGFloat = 12
    var slow = false

    var body: some View {
        Capsule()
            .fill(Color.ink.opacity(0.16))
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .shimmer(slow: slow)
            .accessibilityHidden(true)
    }
}

/// TKL-935: a day still being planned, as the shape it will take: its time, its title, then a row per block.
struct SkeletonDay: View {
    var blocks = 4
    var slow = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SkeletonLine(width: 72, height: 10, slow: slow)
            SkeletonLine(width: 190, height: 22, slow: slow).padding(.top, 10)
            ForEach(0..<blocks, id: \.self) { index in
                RoundedRectangle(cornerRadius: 12) // ui-score: allow radius-scale: a placeholder for a lift row
                    .fill(Color.ink.opacity(0.08))
                    .frame(height: 44)
                    .shimmer(slow: slow)
                    .padding(.top, index == 0 ? 18 : 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityHidden(true)
    }
}

/// TKL-935: content that arrives top to bottom, line by line, as a mask sweeps down it. With Reduce Motion it fades.
struct LineReveal: Transition {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Where the mask's solid part ends and its clear part starts, for a sweep that's `progress` of the way down.
    static func stops(progress: Double) -> [Double] {
        let p = min(1, max(0, progress))
        let soft = 0.18
        return [min(1, max(0, p * (1 + soft) - soft)), min(1, p * (1 + soft))]
    }

    func body(content: Content, phase: TransitionPhase) -> some View {
        if reduceMotion {
            content.opacity(phase.isIdentity ? 1 : 0)
        } else {
            content.modifier(RevealMask(progress: phase.isIdentity ? 1 : 0))
        }
    }
}

private struct RevealMask: ViewModifier, Animatable {
    nonisolated var progress: Double

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let stops = LineReveal.stops(progress: progress)
        content.mask {
            LinearGradient(stops: [.init(color: .black, location: stops[0]), .init(color: .clear, location: stops[1])],
                           startPoint: .top, endPoint: .bottom)
        }
    }
}

#if DEBUG
struct SurfaceMotionPreview: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date.now

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Thinking…")
                .font(.headline)
                .foregroundStyle(Color.inkMuted)
                .shimmer()

            VStack(alignment: .leading, spacing: 10) {
                SkeletonLine()
                SkeletonLine(width: 144)
            }

            TimelineView(.animation(paused: reduceMotion)) { context in
                let time = context.date.timeIntervalSince(start)
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.inkMuted)
                    .sheen(angle: .degrees(30 + 90 * sin(time * .pi)))
                    .frame(height: 144)
                    .overlay {
                        Text("Share card").font(.headline).foregroundStyle(Color.canvas)
                    }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.canvas.ignoresSafeArea())
    }
}

#Preview("Shimmer and sheen") {
    SurfaceMotionPreview()
}
#endif
