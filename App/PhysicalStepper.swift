import SwiftUI

/// TKL-934 (W3): hold-to-repeat acceleration curve for physical steppers.
enum StepperRepeat {
    /// Time until the next repeated step while a button is held: starts deliberate, then accelerates.
    nonisolated static func interval(after stepCount: Int) -> Duration {
        if stepCount < 3 { return .milliseconds(380) }
        if stepCount < 7 { return .milliseconds(180) }
        return .milliseconds(90)
    }
}

/// TKL-934 (W3): reusable physical stepper for the workout card and pass 3's quiz.
/// Digits roll in the step's direction (`numericText(countsDown:)`), scale 1.04 on each change,
/// holding − or + repeats and accelerates with a tick per step, and a placeholder ("–") pulses gently until set.
struct PhysicalStepper: View {
    let value: String
    let unit: String
    let lessLabel: String
    let moreLabel: String
    var fontSize: CGFloat? = nil
    var isPlaceholder: Bool = false
    var reduceMotion: Bool = false
    let onStep: (Double) -> Void

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var countsDown = false
    @State private var bump = 0
    @State private var pulsing = false

    private var reduced: Bool { reduceMotion || systemReduceMotion }

    var body: some View {
        let size = fontSize ?? (value.count > 4 ? 52 : 76)
        VStack(spacing: 10) {
            Text(value)
                .font(.display(size, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .foregroundStyle(isPlaceholder ? Color.inkFaint : Color.ink)
                .contentTransition(reduced ? .identity : .numericText(countsDown: countsDown))
                .keyframeAnimator(initialValue: 1.0, trigger: bump) { content, scale in
                    content.scaleEffect(reduced ? 1.0 : scale)
                } keyframes: { _ in
                    KeyframeTrack {
                        SpringKeyframe(1.04, duration: 0.1)
                        SpringKeyframe(1.0, duration: 0.18)
                    }
                }
                .opacity(isPlaceholder && pulsing && !reduced ? 0.35 : 1)
                .onAppear { updatePulse() }
                .onChange(of: isPlaceholder) { updatePulse() }
                .onChange(of: reduced) { updatePulse() }
            Text(unit).font(.subheadline).foregroundStyle(Color.inkMuted)
            HStack(spacing: 10) {
                RepeatRoundButton(symbol: "minus", label: lessLabel, reduceMotion: reduced) { step(-1) }
                RepeatRoundButton(symbol: "plus", label: moreLabel, reduceMotion: reduced) { step(1) }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .sensoryFeedback(.tick, trigger: bump)
    }

    private func step(_ direction: Double) {
        countsDown = direction < 0
        bump += 1
        withAnimation(reduced ? nil : .tap) { onStep(direction) }
    }

    private func updatePulse() {
        guard isPlaceholder, !reduced else {
            withAnimation(.out) { pulsing = false }
            return
        }
        pulsing = false
        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
            pulsing = true
        }
    }
}

/// A 52 pt round button that steps once on tap and repeats with acceleration when held.
private struct RepeatRoundButton: View {
    let symbol: String
    let label: String
    let reduceMotion: Bool
    let step: () -> Void

    @State private var repeater: Task<Void, Never>?
    @State private var didRepeat = false

    var body: some View {
        Button {
            if didRepeat {
                didRepeat = false
            } else {
                step()
            }
        } label: {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.ink)
                .frame(width: 52, height: 52)
                .background(Color.fill, in: .circle)
        }
        .buttonStyle(HoldRepeatButtonStyle(reduceMotion: reduceMotion) { pressed in
            if pressed {
                didRepeat = false
                repeater?.cancel()
                repeater = Task { @MainActor in
                    var count = 0
                    while !Task.isCancelled {
                        try? await Task.sleep(for: StepperRepeat.interval(after: count))
                        guard !Task.isCancelled else { break }
                        didRepeat = true
                        step()
                        count += 1
                    }
                }
            } else {
                repeater?.cancel()
                repeater = nil
            }
        })
        .accessibilityLabel(label)
        .onDisappear {
            repeater?.cancel()
            repeater = nil
        }
    }
}

private struct HoldRepeatButtonStyle: ButtonStyle {
    let reduceMotion: Bool
    let onPressChanged: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .animation(configuration.isPressed ? .tap : .release, value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in onPressChanged(pressed) }
    }
}
