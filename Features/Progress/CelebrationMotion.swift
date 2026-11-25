import SwiftUI

/// TKL-934 (C1–C3): pure rules and particle generation for workout celebrations.
enum CelebrationMotion {
    /// A goal hit is a 100% milestone and gets the bigger chart → lit target → 3D flip celebration.
    nonisolated static func isGoalHit(_ win: WinItem) -> Bool {
        win.kind == .milestone && win.percent == 100
    }

    /// The count-up range for a personal best (old → new), or 0 → value otherwise.
    nonisolated static func countRange(for win: WinItem) -> (from: Double, to: Double) {
        if win.kind == .pr, let previous = win.previous {
            return (previous, win.value)
        }
        return (0, win.value)
    }
}

/// TKL-934 (C2): depth-of-field flecks rendered with Canvas + TimelineView in ink and the user's Plate accent.
/// Hidden when Reduce Motion is enabled.
struct CelebrationFlecks: View {
    struct Fleck: Equatable, Sendable {
        var xFrac: Double
        var yFrac: Double
        var vx: Double
        var vy: Double
        var depth: Double
        var accent: Bool
        var rotation: Double
        var isRect: Bool

        var radius: CGFloat { CGFloat(1.5 + depth * 4.0) }
        var blur: CGFloat { CGFloat((1.0 - depth) * 3.0) }
        var baseOpacity: Double { 0.5 + depth * 0.5 }
    }

    let trigger: Int
    var duration: TimeInterval = 2.2
    var reduceMotion = false

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var startedAt: Date?
    @State private var particles: [Fleck] = []

    private var reduced: Bool { reduceMotion || systemReduceMotion }

    var body: some View {
        Group {
            if !reduced, let startedAt {
                TimelineView(.animation(paused: Date.now.timeIntervalSince(startedAt) > duration)) { context in
                    let elapsed = context.date.timeIntervalSince(startedAt)
                    if elapsed >= 0 && elapsed <= duration {
                        Canvas { ctx, size in
                            let fade = max(0, 1 - elapsed / duration)
                            let accentColor = Plate.current.accent
                            let inkColor = Color.ink
                            for p in particles {
                                let x = size.width * p.xFrac + p.vx * elapsed
                                let y = size.height * p.yFrac + p.vy * elapsed + 0.5 * 160 * elapsed * elapsed
                                let angle = Angle.radians(p.rotation + elapsed * 3.0)
                                let color = (p.accent ? accentColor : inkColor).opacity(p.baseOpacity * fade)
                                ctx.drawLayer { layer in
                                    if p.blur > 0.25 {
                                        layer.addFilter(.blur(radius: p.blur))
                                    }
                                    layer.translateBy(x: x, y: y)
                                    layer.rotate(by: angle)
                                    let r = p.radius
                                    if p.isRect {
                                        layer.fill(Path(CGRect(x: -r, y: -r / 2, width: r * 2, height: r)), with: .color(color))
                                    } else {
                                        layer.fill(Path(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2)), with: .color(color))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: trigger) { _, count in
            guard count > 0, !reduced else { return }
            particles = Self.makeParticles(count: 46, seed: UInt64(count &* 7919 &+ 42))
            startedAt = .now
        }
    }

    nonisolated static func makeParticles(count: Int, seed: UInt64) -> [Fleck] {
        var state = seed == 0 ? 1 : seed
        func nextUnit() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double((state >> 33) & 0x7FFF_FFFF) / Double(0x7FFF_FFFF)
        }
        return (0..<count).map { _ in
            let z = nextUnit()
            return Fleck(
                xFrac: 0.15 + nextUnit() * 0.70,
                yFrac: 0.52 + nextUnit() * 0.30,
                vx: (nextUnit() - 0.5) * 70,
                vy: -(120 + nextUnit() * 220) * (0.6 + z * 0.6),
                depth: z,
                accent: nextUnit() < 0.65,
                rotation: nextUnit() * 6.283,
                isRect: nextUnit() < 0.5
            )
        }
    }
}

/// TKL-934 (C1–C3): the complete celebration presentation (single PR, goal hit, or fanned multi-win deck).
/// Used both by `CelebrationSheet` (Today's Save bar / `-celebrate YES`) and inline inside `WorkoutModeView`
/// when Save condenses the finish card directly into the best win's card.
struct CelebrationView: View {
    let wins: [WinItem]
    var reduceMotion = false
    var cardNamespace: Namespace.ID? = nil
    var onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var currentIndex = 0
    @State private var indexCountsDown = false
    @State private var style = CardStyle.dark
    @State private var showNumbers = true
    @State private var image: UIImage?
    @State private var haptics = HapticPlayer()
    @State private var flecksTrigger = 0
    @State private var flecksDuration: TimeInterval = 2.2
    @State private var fanned = false
    @State private var dragX: CGFloat = 0
    @State private var throwing = false
    @State private var throwTick = 0
    @State private var landedOnce = false

    private var reduced: Bool { reduceMotion || systemReduceMotion }
    private var activeWin: WinItem { wins[min(currentIndex, max(0, wins.count - 1))] }

    var body: some View {
        let win = activeWin
        let words = WinWords(win, showNumbers: showNumbers)
        ZStack {
            VStack(spacing: 0) {
                header
                cardStage
                    .padding(.top, 8)
                controls(for: win)
                    .padding(.horizontal, 24).padding(.top, 20)
                Spacer(minLength: 12)
                ShareActions(image: image, item: ShareActions.Item(
                    kind: "win", key: win.key, look: "\(style.rawValue)\(showNumbers)", title: words.title,
                    payload: { SharedWin.payload(win, style: style, showNumbers: showNumbers) },
                    render: { ShareCard.image(win, style: style, showNumbers: showNumbers, link: $0) }))
                .padding(.horizontal, 24).padding(.bottom, 16)
            }
            CelebrationFlecks(trigger: flecksTrigger, duration: flecksDuration, reduceMotion: reduced)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .hapticFallback(for: haptics)
        .sensoryFeedback(.tick, trigger: throwTick)
        .task(id: "\(win.key)\(style.rawValue)\(showNumbers)") {
            image = ShareCard.image(win, style: style, showNumbers: showNumbers)
        }
        .onAppear {
            if wins.count > 1, !landedOnce {
                landedOnce = true
                if !reduced {
                    withAnimation(.release) { fanned = true }
                } else {
                    fanned = true
                }
                haptics.play(.crescendo)
                if !reduced {
                    flecksDuration = 2.2
                    flecksTrigger += 1
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Color.clear.frame(width: 44, height: 44)
            Spacer()
            if wins.count == 1 {
                Text("Nice work").font(.headline)
            } else {
                HStack(spacing: 0) {
                    Text("Nice work · ")
                    Text("\(currentIndex + 1)")
                        .monospacedDigit()
                        .contentTransition(reduced ? .identity : .numericText(countsDown: indexCountsDown))
                    Text(" of \(wins.count)")
                }
                .font(.headline)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Nice work · \(currentIndex + 1) of \(wins.count)")
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.ink)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 12).padding(.top, 8)
    }

    @ViewBuilder private var cardStage: some View {
        if wins.count == 1 {
            AnimatedWinCard(win: wins[0], style: style, showNumbers: showNumbers, reduceMotion: reduced) { isGoal in
                guard !landedOnce else { return }
                landedOnce = true
                haptics.play(.crescendo)
                if !reduced {
                    flecksDuration = isGoal ? 2.8 : 2.2
                    flecksTrigger += 1
                }
            }
            .modifier(OptionalMatchedCard(namespace: cardNamespace, reduceMotion: reduced))
            .shadow(color: .black.opacity(0.14), radius: 15, y: 8)
        } else {
            fannedDeck
                .modifier(OptionalMatchedCard(namespace: cardNamespace, reduceMotion: reduced))
        }
    }

    /// C2/C3: several wins arrive fanned and throw aside one by one, with "1 of 3" rolling.
    private var fannedDeck: some View {
        let remaining = Array(wins.enumerated().dropFirst(currentIndex))
        return ZStack {
            ForEach(Array(remaining.reversed()), id: \.element.id) { item in
                let depth = item.offset - currentIndex
                let isTop = depth == 0
                ShareCard(win: item.element, style: style, showNumbers: showNumbers)
                    .shadow(color: .black.opacity(0.14), radius: 15, y: 8)
                    .rotationEffect(.degrees(reduced ? 0 : (isTop ? Double(dragX) / 18.0 : (fanned ? Double(depth) * 5.0 : 0))),
                                    anchor: UnitPoint(x: 0.5, y: 0.9))
                    .offset(x: isTop ? (reduced ? 0 : dragX) : (reduced ? 0 : (fanned ? CGFloat(depth) * 10.0 : 0)))
                    .scaleEffect(isTop ? 1 : (reduced ? 1 : (fanned ? max(0.88, 1 - CGFloat(depth) * 0.03) : 1)))
                    .zIndex(Double(wins.count - depth))
                    .animation(reduced ? nil : .release.delay(fanned ? 0 : Double(depth) * 0.06), value: fanned)
                    .animation(reduced ? nil : .settle, value: currentIndex)
                    .allowsHitTesting(isTop)
                    .accessibilityHidden(!isTop)
            }
        }
        .frame(width: ShareCard.size.width + 36, height: ShareCard.size.height + 12)
        .contentShape(.rect)
        .gesture(
            DragGesture(minimumDistance: 12)
                .onChanged { value in
                    guard !throwing else { return }
                    if !reduced { dragX = value.translation.width }
                }
                .onEnded { value in
                    guard !throwing else { return }
                    let dx = value.translation.width
                    let vx = value.velocity.width
                    let shouldThrow = abs(dx) > 80 || abs(vx) > 500
                    if shouldThrow, currentIndex + 1 < wins.count {
                        throwing = true
                        let sign: CGFloat = (dx != 0 ? dx : vx) >= 0 ? 1 : -1
                        let speed = max(abs(vx), 600)
                        let duration = max(0.16, min(0.36, Double(420 / speed)))
                        throwTick += 1
                        if reduced {
                            indexCountsDown = false
                            currentIndex += 1
                            dragX = 0
                            throwing = false
                        } else {
                            withAnimation(.timingCurve(0.2, 0.6, 0.4, 1.0, duration: duration),
                                          completionCriteria: .logicallyComplete) {
                                dragX = sign * 440
                            } completion: {
                                var quiet = Transaction()
                                quiet.disablesAnimations = true
                                withTransaction(quiet) { dragX = 0 }
                                withAnimation(.tap) {
                                    indexCountsDown = false
                                    currentIndex += 1
                                }
                                throwing = false
                            }
                        }
                    } else {
                        withAnimation(reduced ? nil : .release) { dragX = 0 }
                    }
                }
        )
        .accessibilityAction(named: "Next win") {
            if currentIndex + 1 < wins.count {
                throwTick += 1
                withAnimation(reduced ? nil : .tap) {
                    indexCountsDown = false
                    currentIndex += 1
                }
            }
        }
        .accessibilityAction(named: "Previous win") {
            if currentIndex > 0 {
                throwTick += 1
                withAnimation(reduced ? nil : .tap) {
                    indexCountsDown = true
                    currentIndex -= 1
                }
            }
        }
    }

    private func controls(for win: WinItem) -> some View {
        VStack(spacing: 12) {
            Picker("Style", selection: $style.animation(reduced ? nil : .tap)) {
                ForEach(CardStyle.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            if win.kind != .streak {
                Toggle(isOn: $showNumbers.animation(reduced ? nil : .tap)) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Show weights")
                        Text(showNumbers ? "Lifts and weights appear on the card" : "Only changes and percents appear")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .tint(.primary)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 18))
            }
        }
    }
}

private struct OptionalMatchedCard: ViewModifier {
    let namespace: Namespace.ID?
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        if let namespace, !reduceMotion {
            content.matchedGeometryEffect(id: "workout.finishCard", in: namespace)
        } else {
            content
        }
    }
}

/// TKL-934 (C2 & C3): animates either a Personal Best (count-up + drawing Sparkline + peak pop)
/// or a Goal Hit (chart draws to target, target line lights end-to-end, 3D Y-flip to achieved face).
struct AnimatedWinCard: View {
    let win: WinItem
    let style: CardStyle
    let showNumbers: Bool
    let reduceMotion: Bool
    let onLand: (Bool) -> Void

    @State private var played = false
    @State private var shownValue: Double = 0
    @State private var sparkProgress: CGFloat = 0
    @State private var peakVisible = false
    @State private var numberBounce = false
    // Goal hit choreography
    @State private var goalLineProgress: CGFloat = 0
    @State private var targetLitProgress: CGFloat = 0
    @State private var flipped = false
    @State private var thudTrigger = 0

    var body: some View {
        Group {
            if CelebrationMotion.isGoalHit(win) {
                goalHitCard
            } else if win.kind == .pr {
                prCard
            } else {
                ShareCard(win: win, style: style, showNumbers: showNumbers)
                    .onAppear {
                        guard !played else { return }
                        played = true
                        onLand(false)
                    }
            }
        }
        .sensoryFeedback(.thud, trigger: thudTrigger)
    }

    private var prCard: some View {
        let range = CelebrationMotion.countRange(for: win)
        let words = WinWords(win, showNumbers: showNumbers)
        return PRAnimatedCardBody(
            win: win,
            style: style,
            showNumbers: showNumbers,
            displayedValue: played ? shownValue : range.from,
            fallbackBig: words.big,
            sparklineProgress: reduceMotion ? 1 : sparkProgress,
            peakVisible: reduceMotion ? true : peakVisible,
            bigScale: numberBounce && !reduceMotion ? 1.08 : 1.0
        )
        .onAppear {
            guard !played else { return }
            played = true
            if reduceMotion {
                shownValue = range.to
                sparkProgress = 1
                peakVisible = true
                onLand(false)
                return
            }
            shownValue = range.from
            sparkProgress = 0
            peakVisible = false
            withAnimation(.timingCurve(0.22, 1.0, 0.36, 1.0, duration: 0.95)) {
                shownValue = range.to
                sparkProgress = 1
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(920))
                onLand(false)
                withAnimation(.release) {
                    peakVisible = true
                    numberBounce = true
                }
                try? await Task.sleep(for: .milliseconds(220))
                withAnimation(.tap) { numberBounce = false }
            }
        }
    }

    private var goalHitCard: some View {
        let angle: Double = flipped ? 180 : 0
        return ZStack {
            // Front face: chart draws to target line, target lights end to end.
            GoalHitFrontCard(win: win, style: style, showNumbers: showNumbers,
                             lineProgress: reduceMotion ? 1 : goalLineProgress,
                             targetLitProgress: reduceMotion ? 1 : targetLitProgress)
                .opacity(angle < 90 ? 1 : 0)
            // Achieved back face: flipped 180° so it reads forward once the container flips.
            ShareCard(win: win, style: style, showNumbers: showNumbers,
                      overrideTag: "GOAL HIT", tagAccent: true)
                .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
                .opacity(angle >= 90 ? 1 : 0)
        }
        .rotation3DEffect(.degrees(reduceMotion ? (flipped ? 180 : 0) : angle), axis: (x: 0, y: 1, z: 0), perspective: 0.45)
        .onAppear {
            guard !played else { return }
            played = true
            if reduceMotion {
                goalLineProgress = 1
                targetLitProgress = 1
                flipped = true
                onLand(true)
                return
            }
            Task { @MainActor in
                withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 1.05)) {
                    goalLineProgress = 1
                }
                try? await Task.sleep(for: .milliseconds(1050))
                thudTrigger += 1
                withAnimation(.easeOut(duration: 0.45)) {
                    targetLitProgress = 1
                }
                try? await Task.sleep(for: .milliseconds(650))
                onLand(true)
                withAnimation(.settle) {
                    flipped = true
                }
            }
        }
    }
}

private struct PRAnimatedCardBody: View, Animatable {
    let win: WinItem
    let style: CardStyle
    let showNumbers: Bool
    nonisolated var displayedValue: Double
    let fallbackBig: String
    var sparklineProgress: CGFloat
    var peakVisible: Bool
    var bigScale: CGFloat

    nonisolated var animatableData: Double {
        get { displayedValue }
        set { displayedValue = newValue }
    }

    var body: some View {
        let option = GoalOption.all.first { $0.metric == win.metric }
        let formatted: String = if showNumbers {
            option?.format(displayedValue) ?? Coach.number(displayedValue.rounded())
        } else {
            fallbackBig
        }
        ShareCard(
            win: win,
            style: style,
            showNumbers: showNumbers,
            overrideBig: formatted,
            bigScale: bigScale,
            sparklineProgress: sparklineProgress,
            peakVisible: peakVisible,
            peakAccent: true
        )
    }
}

/// Front face of the Goal Hit flip: dashed target line, rising trend line, and Plate-colored lit target line.
private struct GoalHitFrontCard: View {
    let win: WinItem
    let style: CardStyle
    let showNumbers: Bool
    let lineProgress: CGFloat
    let targetLitProgress: CGFloat

    var body: some View {
        let words = WinWords(win, showNumbers: showNumbers)
        let values = win.trend.count > 1 ? win.trend : [win.start ?? 0, win.value]
        let target = win.target ?? win.value
        VStack(alignment: .leading, spacing: 0) {
            Text("GOAL")
                .font(.caption2.weight(.semibold)).tracking(1.2)
                .foregroundStyle(style.muted)
            Text(words.heading)
                .font(.headline)
                .padding(.top, 4)
            Spacer(minLength: 12)
            GeometryReader { proxy in
                let w = proxy.size.width
                let h = proxy.size.height
                let targetY: CGFloat = 14
                let low = min(values.min() ?? 0, target * 0.7)
                let high = max(values.max() ?? target, target)
                let span = max(high - low, 1)
                let pts = values.enumerated().map { idx, v -> CGPoint in
                    let x = w * CGFloat(idx) / CGFloat(max(1, values.count - 1))
                    let norm = CGFloat((v - low) / span)
                    let y = (h - 10) - (h - 10 - targetY) * min(1, max(0, norm))
                    return CGPoint(x: x, y: y)
                }
                ZStack {
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: targetY))
                        p.addLine(to: CGPoint(x: w, y: targetY))
                    }
                    .stroke(style.muted.opacity(0.45), style: StrokeStyle(lineWidth: 2, dash: [4, 5]))
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: targetY))
                        p.addLine(to: CGPoint(x: w, y: targetY))
                    }
                    .trim(from: 0, to: targetLitProgress)
                    .stroke(Plate.current.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    Path { $0.addLines(pts) }
                        .trim(from: 0, to: lineProgress)
                        .stroke(style.text, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                }
            }
            .frame(height: 112)
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text(words.big)
                    .font(.display(64, weight: .bold, design: .rounded)).tracking(-1.5)
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                Text(words.unit)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(style.muted)
            }
            .padding(.top, 12)
            Text(words.sub)
                .font(.subheadline)
                .foregroundStyle(style.soft)
                .padding(.top, 4)
            HStack {
                Text(win.date.formatted(.dateTime.month(.abbreviated).day().year()))
                    .font(.caption)
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "circle.circle.fill").font(.caption)
                    Text(ShareCard.appName).font(.caption.weight(.semibold))
                }
            }
            .foregroundStyle(style.muted)
            .padding(.top, 14)
        }
        .foregroundStyle(style.text)
        .padding(EdgeInsets(top: 24, leading: 24, bottom: 20, trailing: 24))
        .frame(width: ShareCard.size.width, height: ShareCard.size.height, alignment: .topLeading)
        .background(style.background)
        .clipShape(.rect(cornerRadius: 24))
        .overlay { if style == .paper { RoundedRectangle(cornerRadius: 24).strokeBorder(style.track) } }
        .environment(\.colorScheme, style == .dark ? .dark : .light)
    }
}
