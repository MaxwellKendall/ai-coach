import SwiftUI

/// TKL-933: bank to target. A chip flies from where something was done to where it counts, and the caller shows it
/// counted when the chip lands. Mark the destination with `bankTarget`, report the origin with `bankSource`, and put
/// `banking` on a view that holds both. With Reduce Motion the caller makes no `Bank` and counts at once.
struct Bank: Identifiable {
    let id = UUID()
    let target: AnyHashable
    let from: CGPoint

    nonisolated static let space = "bank"
}

private struct BankTargets: PreferenceKey {
    static var defaultValue: [AnyHashable: Anchor<CGRect>] { [:] }

    static func reduce(value: inout [AnyHashable: Anchor<CGRect>], nextValue: () -> [AnyHashable: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, latest in latest }
    }
}

private struct BankChip: View {
    let from: CGPoint
    let to: CGPoint
    let onArrival: () -> Void
    @State private var arrived = false

    var body: some View {
        Capsule()
            .fill(Plate.current.mark)
            .frame(width: 36, height: 14)
            .scaleEffect(arrived ? 0.35 : 1)
            .position(arrived ? to : from)
            .onAppear {
                withAnimation(.throw, completionCriteria: .logicallyComplete) {
                    arrived = true
                } completion: {
                    onArrival()
                }
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
        coordinateSpace(.named(Bank.space))
            .overlayPreferenceValue(BankTargets.self) { targets in
                GeometryReader { geometry in
                    if let bank, let target = targets[bank.target] {
                        let frame = geometry[target]
                        BankChip(from: bank.from, to: CGPoint(x: frame.midX, y: frame.midY)) { onArrival(bank.id) }
                            .id(bank.id)
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
    }
}
