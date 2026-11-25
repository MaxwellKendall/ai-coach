import SwiftUI

enum CoachMotion {
    static func weeks(for days: [String]) -> [String] {
        Set(days.compactMap { day in
            SyncUnits.date(ofKey: "plan#\(day)").map { SyncUnits.day(Week.start(of: $0)) }
        }).sorted()
    }

    static func newLogs(before: [Bool], after: [Bool]) -> [Int] {
        zip(before, after).enumerated().compactMap { index, pair in
            !pair.0 && pair.1 ? index : nil
        }
    }
}

struct CoachEntrance: ViewModifier {
    var index: Int
    var distance: CGFloat = 10
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .opacity(visible || reduceMotion ? 1 : 0)
            .offset(y: visible || reduceMotion ? 0 : distance)
            .onAppear {
                withAnimation(.settle.staggered(min(index, 12))) { visible = true }
            }
    }
}

struct CoachChartReveal: ViewModifier {
    var enabled: Bool
    var bars = false
    var index = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn = false

    func body(content: Content) -> some View {
        if enabled && !reduceMotion {
            content
                .mask(alignment: bars ? .bottom : .leading) {
                    Rectangle()
                        .scaleEffect(x: drawn || bars ? 1 : 0, y: drawn || !bars ? 1 : 0,
                                     anchor: bars ? .bottom : .leading)
                }
                .onAppear { withAnimation(.reveal.staggered(index)) { drawn = true } }
        } else {
            content
        }
    }
}
