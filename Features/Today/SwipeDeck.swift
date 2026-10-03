import SwiftUI

/// Every swipe in the app (FIT-35): cards in a stack. The top card follows the finger and is thrown off the
/// screen, left to the next card or right to the previous one, which waits underneath. Up and down mean whatever
/// the screen says they mean for that card, or nothing (the card stays put, so a scroll view on it still scrolls).
/// While a card is dragged it says what letting go will do, faint until far enough and solid once it will.
struct SwipeDeck<Card: View>: View {
    @Binding var index: Int
    let count: Int
    var cornerRadius: CGFloat = 30
    /// What up or down does to a card; nil when it does nothing.
    var vertical: (Int, VerticalEdge) -> CardThrow? = { _, _ in nil }
    /// What a swipe will do, shown on the card while it's dragged.
    var hint: (Int, CardSwipe) -> SwipeHint? = { _, swipe in
        swipe == .next ? SwipeHint("Next") : swipe == .back ? SwipeHint("Back") : nil
    }
    /// A swipe that finished, from the card it started on, before `index` moves. Returns where to go instead
    /// of the next (or previous) card, if somewhere else.
    var swiped: (Int, CardSwipe) -> Int? = { _, _ in nil }
    @ViewBuilder let card: (Int) -> Card

    @State private var drag = CGSize.zero
    /// The finger's own travel, before any pull or resistance, for how close a swipe is to counting.
    @State private var travel = CGSize.zero
    @State private var axis: Axis?
    @State private var throwing = false
    /// Where a throw is going, so the card underneath is the one you'll land on.
    @State private var target: Int?

    private let gap: CGFloat = 60
    private let spring = Animation.spring(response: 0.36, dampingFraction: 0.86)

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let swipe = swipe
            let shown = swipe.flatMap { allowed($0) ? hint(index, $0) : nil }
            let progress = progress(size)
            ZStack {
                ForEach(visible, id: \.self) { position in
                    card(position)
                        .frame(width: size.width, height: size.height)
                        .overlay {
                            if position == index, let shown, let swipe {
                                HintOverlay(hint: shown, swipe: swipe, progress: progress, cornerRadius: cornerRadius)
                            }
                        }
                        .modifier(Place(top: position == index, drag: drag, size: size))
                        .zIndex(position == index ? 1 : 0)
                        .allowsHitTesting(position == index)
                        .accessibilityHidden(position != index)
                        // A jump of more than one card (the list, the week strip) is a plain swap.
                        .transition(.identity)
                }
            }
            .contentShape(.rect)
            .simultaneousGesture(gesture(size))
            .sensoryFeedback(.selection, trigger: index)
            .sensoryFeedback(.impact(weight: .light), trigger: shown != nil && progress >= 1) { _, armed in armed && !throwing }
            .accessibilityAction(named: "Next") { if index < count - 1 { withAnimation(spring) { advance(.next) } } }
            .accessibilityAction(named: "Previous") { if index > 0 { withAnimation(spring) { advance(.back) } } }
        }
    }

    /// The top card and the one it will uncover: the previous card while dragged right, else the next.
    private var visible: [Int] {
        let under = target ?? swipe.flatMap { hint(index, $0)?.to } ?? (drag.width > 0 ? index - 1 : index + 1)
        return [under, index].filter { (0..<count).contains($0) }
    }

    /// The swipe the card is being dragged towards.
    private var swipe: CardSwipe? {
        if drag.width < 0 { return .next }
        if drag.width > 0 { return .back }
        if drag.height < 0 { return .up }
        if drag.height > 0 { return .down }
        return nil
    }

    private func allowed(_ swipe: CardSwipe) -> Bool {
        switch swipe {
        case .next: index < count - 1
        case .back: index > 0
        case .up: vertical(index, .top) != nil
        case .down: vertical(index, .bottom) != nil
        }
    }

    /// 1 once letting go will count.
    private func progress(_ size: CGSize) -> CGFloat {
        max(abs(travel.width) / (size.width / 3), abs(travel.height) / (size.height / 6))
    }

    private func gesture(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { value in
                guard !throwing else { return }
                let t = value.translation
                if axis == nil { axis = abs(t.width) > abs(t.height) ? .horizontal : .vertical }
                travel = axis == .horizontal ? CGSize(width: t.width, height: 0) : CGSize(width: 0, height: t.height)
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
                } else if axis == .vertical, abs(t.height) > size.height / 6, let what = vertical(index, t.height < 0 ? .top : .bottom) {
                    let swipe: CardSwipe = t.height < 0 ? .up : .down
                    if what == .off {
                        fling(to: CGSize(width: 0, height: (t.height < 0 ? -1 : 1) * (size.height + gap)), swipe)
                    } else {
                        _ = swiped(index, swipe)
                        settle()
                    }
                } else {
                    settle()
                }
            }
    }

    private func settle() {
        withAnimation(spring) {
            drag = .zero
            travel = .zero
        }
    }

    /// Up or down: a card that will be thrown follows the finger; one that acts and settles is a heavier pull;
    /// one that does nothing stays put.
    private func pull(_ distance: CGFloat) -> CGFloat {
        switch vertical(index, distance < 0 ? .top : .bottom) {
        case .off?: distance
        case .back?: distance * 0.4
        case nil: 0
        }
    }

    /// Pulling where nothing can go moves a fraction of the finger, like a scroll view's edge.
    private func resist(_ distance: CGFloat, allowed: Bool) -> CGFloat {
        allowed ? distance : distance / (1 + abs(distance) / 40)
    }

    /// Throws the top card off, uncovering where it's going, then moves on without a second animation.
    /// The screen hears about the swipe as the card leaves, so what it does (a rest starting) isn't late.
    private func fling(to end: CGSize, _ swipe: CardSwipe) {
        throwing = true
        target = destination(swipe)
        withAnimation(spring) { drag = end } completion: {
            var quiet = Transaction()
            quiet.disablesAnimations = true
            withTransaction(quiet) {
                index = target ?? index
                target = nil
                drag = .zero
                travel = .zero
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

/// What letting go will do: a word and its color. Gray for moving between cards; color when it changes something.
struct SwipeHint {
    let text: String
    var symbol: String?
    var tint: Color = .secondary
    /// The card it lands on, when not the next or previous one, so that's the card underneath.
    var to: Int?

    init(_ text: String, symbol: String? = nil, tint: Color = .secondary, to: Int? = nil) {
        self.text = text
        self.symbol = symbol
        self.tint = tint
        self.to = to
    }
}

/// A tinted edge and a small label on the side the card is leaving from, faint until the swipe will count.
private struct HintOverlay: View {
    let hint: SwipeHint
    let swipe: CardSwipe
    let progress: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        let armed = progress >= 1
        let strength = armed ? 1 : min(progress, 1) * 0.5
        ZStack(alignment: alignment) {
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(hint.tint.opacity(strength), lineWidth: armed ? 3 : 2)
            Label {
                Text(hint.text)
            } icon: {
                if let symbol = hint.symbol { Image(systemName: symbol) }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(armed ? Color.white : hint.tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(in: .capsule)
            .backgroundStyle(armed ? AnyShapeStyle(hint.tint) : AnyShapeStyle(Color(.systemBackground)))
            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
            .opacity(min(1, progress * 1.6))
            .scaleEffect(armed ? 1 : 0.94)
            .padding(18)
        }
        .animation(.snappy(duration: 0.18), value: armed)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Opposite the way the card moves, so the label stays on screen.
    private var alignment: Alignment {
        switch swipe {
        case .next: .topTrailing
        case .back: .topLeading
        case .up: .bottom
        case .down: .top
        }
    }
}

/// Where a card sits, given the drag of the top card.
private struct Place: ViewModifier {
    let top: Bool
    let drag: CGSize
    let size: CGSize

    func body(content: Content) -> some View {
        if top {
            content
                .offset(drag)
                .rotationEffect(.degrees(Double(drag.width / max(size.width, 1)) * 10), anchor: .bottom)
        } else {
            // How far the top card has gone on its way off; the card underneath rises with it.
            let away = min(1, max(abs(drag.width), abs(drag.height)) / max(size.width, 1))
            content
                .scaleEffect(0.94 + 0.06 * away)
                .opacity(0.4 + 0.6 * away)
        }
    }
}
