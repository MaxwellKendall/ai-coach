import SwiftUI

enum SurfaceMotion {
    static func shimmerPhase(at time: TimeInterval) -> Float {
        Float(max(0, time).truncatingRemainder(dividingBy: 1.8) / 1.8)
    }

    static func pulseOpacity(at time: TimeInterval) -> Double {
        0.9 - 0.1 * cos(2 * .pi * time / 3.2)
    }

    static func sheenAngle(_ angle: Angle, reduceMotion: Bool) -> Float {
        Float((reduceMotion ? Angle.degrees(30) : angle).radians)
    }
}

extension View {
    func shimmer() -> some View { modifier(Shimmer()) }

    func sheen(angle: Angle) -> some View { modifier(Sheen(angle: angle)) }
}

private struct Shimmer: ViewModifier {
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
                    .float(SurfaceMotion.shimmerPhase(at: context.date.timeIntervalSince(start)))
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

    var body: some View {
        Capsule()
            .fill(Color.ink.opacity(0.16))
            .frame(width: width, height: height)
            .shimmer()
            .accessibilityHidden(true)
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
