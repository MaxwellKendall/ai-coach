import SwiftUI

/// Every swipe in the app (FIT-35): cards in a stack. The top card follows the finger and is thrown off the
/// screen; the next one rises from underneath. Left is next, right brings the previous card back over the top.
/// Up and down mean whatever the screen says they mean for that card, or nothing (the card stays put, so a
/// scroll view on it still scrolls).
struct SwipeDeck<Card: View>: View {
    @Binding var index: Int
    let count: Int
    /// What up or down does to a card; nil when it does nothing.
    var vertical: (Int, VerticalEdge) -> CardThrow? = { _, _ in nil }
    /// A swipe that finished, from the card it started on, before `index` moves. Returns where to go instead
    /// of the next (or previous) card, if somewhere else.
    var swiped: (Int, CardSwipe) -> Int? = { _, _ in nil }
    @ViewBuilder let card: (Int) -> Card

    @State private var drag = CGSize.zero
    @State private var axis: Axis?
    @State private var throwing = false
    /// Where a throw is going, so the card underneath is the one you'll land on.
    @State private var target: Int?

    private let gap: CGFloat = 60
    private let spring = Animation.spring(response: 0.36, dampingFraction: 0.86)

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                ForEach(visible, id: \.self) { position in
                    card(position)
                        .frame(width: size.width, height: size.height)
                        .modifier(Place(role: role(of: position), drag: drag, size: size, gap: gap))
                        .zIndex(role(of: position) == .before ? 2 : position == index ? 1 : 0)
                        .allowsHitTesting(position == index)
                        .accessibilityHidden(position != index)
                        // A jump of more than one card (the list, the week strip) is a plain swap; neighbours animate by role.
                        .transition(.identity)
                }
            }
            .contentShape(.rect)
            .simultaneousGesture(gesture(size))
            .sensoryFeedback(.selection, trigger: index)
            .accessibilityAction(named: "Next") { if index < count - 1 { withAnimation(spring) { advance(.next) } } }
            .accessibilityAction(named: "Previous") { if index > 0 { withAnimation(spring) { advance(.back) } } }
        }
    }

    /// The card behind, the top card, and the one before it (off to the left until pulled back).
    private var visible: [Int] {
        [target ?? index + 1, index, index - 1].filter { (0..<count).contains($0) }
    }

    private func role(of position: Int) -> Place.Role {
        position == index ? .top : position == target || position > index ? .behind : .before
    }

    private func gesture(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { value in
                guard !throwing else { return }
                let t = value.translation
                if axis == nil { axis = abs(t.width) > abs(t.height) ? .horizontal : .vertical }
                drag = axis == .horizontal ? CGSize(width: resist(t.width, allowed: t.width < 0 ? index < count - 1 : index > 0), height: 0)
                    : CGSize(width: 0, height: pull(t.height))
            }
            .onEnded { value in
                defer { axis = nil }
                guard !throwing else { return }
                // A flick counts as much as a long drag.
                let t = value.predictedEndTranslation
                if axis == .horizontal, t.width < -size.width / 3, index < count - 1 {
                    fling(to: CGSize(width: -(size.width + gap) * 1.3, height: 0), .next)
                } else if axis == .horizontal, t.width > size.width / 3, index > 0 {
                    fling(to: CGSize(width: (size.width + gap) * 1.3, height: 0), .back)
                } else if axis == .vertical, abs(t.height) > size.height / 6,
                          let what = vertical(index, t.height < 0 ? .top : .bottom) {
                    let swipe: CardSwipe = t.height < 0 ? .up : .down
                    if what == .off {
                        fling(to: CGSize(width: 0, height: (t.height < 0 ? -1 : 1) * (size.height + gap)), swipe)
                    } else {
                        _ = swiped(index, swipe)
                        withAnimation(spring) { drag = .zero }
                    }
                } else {
                    withAnimation(spring) { drag = .zero }
                }
            }
    }

    /// Up or down: a card that will be thrown follows the finger; one that acts and settles is a heavier pull;
    /// one that does nothing stays put.
    private func pull(_ distance: CGFloat) -> CGFloat {
        switch vertical(index, distance < 0 ? .top : .bottom) {
        case .off?: distance
        case .back?: distance * 0.35
        case nil: 0
        }
    }

    /// Pulling where nothing can go moves a fraction of the finger, like a scroll view's edge.
    private func resist(_ distance: CGFloat, allowed: Bool) -> CGFloat {
        allowed ? distance : distance / (1 + abs(distance) / 40)
    }

    /// Throws the top card (or, going back, brings the previous one in), then moves on without a second animation.
    /// The screen hears about the swipe as the card leaves, so what it does (a rest starting) isn't late.
    private func fling(to end: CGSize, _ swipe: CardSwipe) {
        throwing = true
        let to = destination(swipe)
        if swipe != .back { target = to }
        withAnimation(spring) { drag = end } completion: {
            var quiet = Transaction()
            quiet.disablesAnimations = true
            withTransaction(quiet) {
                index = to
                target = nil
                drag = .zero
            }
            throwing = false
        }
    }

    private func advance(_ swipe: CardSwipe) { index = destination(swipe) }

    private func destination(_ swipe: CardSwipe) -> Int {
        min(max(0, swiped(index, swipe) ?? (swipe == .back ? index - 1 : index + 1)), count - 1)
    }
}

enum CardSwipe: Equatable { case next, back, up, down }

enum CardThrow {
    /// Thrown off that edge, then on to the next card.
    case off
    /// Pulled, acted on, and settles back.
    case back
}

/// Where a card sits for its role, given the drag of the top card.
private struct Place: ViewModifier {
    enum Role { case before, top, behind }
    let role: Role
    let drag: CGSize
    let size: CGSize
    let gap: CGFloat

    func body(content: Content) -> some View {
        // How far the top card has gone on its way off; the card behind rises with it.
        let away = min(1, max(-drag.width, abs(drag.height)) / max(size.width, 1))
        let back = max(0, drag.width)
        switch role {
        case .top:
            content
                .offset(x: min(drag.width, 0), y: drag.height)
                .rotationEffect(.degrees(Double(min(drag.width, 0) / max(size.width, 1)) * 10), anchor: .bottom)
                .scaleEffect(1 - 0.06 * min(1, back / max(size.width, 1)))
                .brightness(-0.04 * min(1, back / max(size.width, 1)))
        case .behind:
            content
                .scaleEffect(0.94 + 0.06 * away)
                .opacity(0.4 + 0.6 * away)
        case .before:
            // Tilted like a thrown card, and far enough out that no corner shows.
            let out = (size.width + gap) * 1.3
            content
                .offset(x: back - out)
                .rotationEffect(.degrees(Double((back - out) / max(size.width, 1)) * 8), anchor: .bottom)
        }
    }
}
