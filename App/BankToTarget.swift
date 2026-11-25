import SwiftUI

/// TKL-933 / TKL-934: bank to target. A chip flies from where something was done to where it counts, and the caller shows it
/// counted when the chip lands. Mark the destination with `bankTarget`, report the origin with `bankSource`, and put
/// `banking` on a view that holds both. With Reduce Motion the caller makes no `Bank` and counts at once.
struct Bank: Identifiable {
    let id = UUID()
    let target: AnyHashable
    let from: CGPoint
    /// TKL-934: the default chip's words ("5 × 170"); empty draws the plain capsule.
    var label: String = ""
    /// TKL-934: Undo flies the chip back out of its target to where it came from.
    var reverse: Bool = false

    nonisolated static let space = "bank"

    static func flight(to target: some Hashable, from origin: CGPoint?, reduceMotion: Bool) -> Bank? {
        guard !reduceMotion, let origin else { return nil }
        return Bank(target: target, from: origin)
    }
}

private struct BankTargets: PreferenceKey {
    static var defaultValue: [AnyHashable: Anchor<CGRect>] { [:] }

    static func reduce(value: inout [AnyHashable: Anchor<CGRect>], nextValue: () -> [AnyHashable: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, latest in latest }
    }
}

private struct BankArc: ViewModifier, Animatable {
    let from: CGPoint
    let to: CGPoint
    let reverse: Bool
    nonisolated var progress: CGFloat

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let t = max(0, min(1, progress))
        let start = reverse ? to : from
        let end = reverse ? from : to
        let control = CGPoint(
            x: (start.x + end.x) * 0.5 + (reverse ? 20 : 0),
            y: reverse ? (start.y + 80) : (min(start.y, end.y) - 54)
        )
        let inv = 1 - t
        let x = inv * inv * start.x + 2 * inv * t * control.x + t * t * end.x
        let y = inv * inv * start.y + 2 * inv * t * control.y + t * t * end.y

        let scale: CGFloat = if reverse {
            0.32 + 0.68 * t
        } else {
            t < 0.35 ? (1.0 - 0.1 * (t / 0.35)) : (0.9 - 0.58 * ((t - 0.35) / 0.65))
        }
        let opacity: Double = if reverse {
            t < 0.25 ? Double(t / 0.25) : t > 0.78 ? Double((1 - t) / 0.22) : 1
        } else {
            t > 0.85 ? Double((1 - t) / 0.15) : 1
        }

        content
            .scaleEffect(scale)
            .opacity(opacity)
            .position(x: x, y: y)
    }
}

private struct BankChip<Chip: View>: View {
    let from: CGPoint
    let to: CGPoint
    let reverse: Bool
    let chip: Chip
    let onArrival: () -> Void
    @State private var progress: CGFloat = 0

    var body: some View {
        chip
            .fixedSize()
            .modifier(BankArc(from: from, to: to, reverse: reverse, progress: progress))
            .onAppear {
                withAnimation(.timingCurve(0.3, 0.0, 0.3, 1.0, duration: reverse ? 0.44 : 0.46),
                              completionCriteria: .logicallyComplete) {
                    progress = 1
                } completion: {
                    onArrival()
                }
            }
    }
}

/// TKL-934: the workout's chip, "5 × 170" in ink; the plain capsule when there are no words.
private struct DefaultBankChip: View {
    let label: String

    var body: some View {
        if label.isEmpty {
            Capsule()
                .fill(Plate.current.mark)
                .frame(width: 36, height: 14)
        } else {
            Text(label)
                .font(.display(17, weight: .bold, design: .rounded, relativeTo: .headline))
                .monospacedDigit()
                .foregroundStyle(Color.canvas)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.ink, in: .capsule)
        }
    }
}

extension View {
    func bankTarget(_ id: some Hashable) -> some View {
        anchorPreference(key: BankTargets.self, value: .bounds) { [AnyHashable(id): $0] }
    }

    func bankSource(_ moved: @escaping (CGPoint) -> Void) -> some View {
        onGeometryChange(for: CGPoint.self) { proxy in
            let frame = proxy.frame(in: .named(Bank.space))
            return CGPoint(x: frame.midX, y: frame.midY)
        } action: { moved($0) }
    }

    func banking(_ bank: Bank?, onArrival: @escaping (Bank.ID) -> Void) -> some View {
        banking(bank, onArrival: onArrival) {
            DefaultBankChip(label: bank?.label ?? "")
        }
    }

    func banking<Chip: View>(
        _ bank: Bank?,
        onArrival: @escaping (Bank.ID) -> Void,
        @ViewBuilder chip: @escaping () -> Chip
    ) -> some View {
        coordinateSpace(.named(Bank.space))
            .overlayPreferenceValue(BankTargets.self) { targets in
                GeometryReader { geometry in
                    if let bank, let target = targets[bank.target] {
                        let frame = geometry[target]
                        BankChip(from: bank.from, to: CGPoint(x: frame.midX, y: frame.midY), reverse: bank.reverse, chip: chip()) {
                            onArrival(bank.id)
                        }
                        .id(bank.id)
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
    }
}
