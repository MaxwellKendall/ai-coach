import SwiftUI
import UIKit

/// FIT-389: the app's motion and haptics by name (FIT-388's principles: physics, not curves; one haptic grammar).
/// Views use these rather than an inline spring or duration, so the feel is tuned in one place.
extension Animation {
    /// A control answering a touch: a chip picked, a cell selected, a section opened, a number stepped.
    static let tap = Animation.snappy(duration: 0.25)
    /// Content settling into its new state: a page, a card, a toast, an edit to the session.
    static let settle = Animation.snappy
    /// A thrown card's flight (SwipeDeck, FIT-35).
    static let `throw` = Animation.spring(response: 0.36, dampingFraction: 0.86)
    /// Something arriving or leaving slowly enough to be noticed: a fresh highlight fading, a review being written.
    static let reveal = Animation.smooth(duration: 0.6)
    /// Something getting out of the way, quickly, of what's under it: the splash's mark.
    static let out = Animation.easeOut(duration: 0.15)
    /// A pressed button coming back up, a little past where it rests.
    static let release = Animation.spring(duration: 0.3, bounce: 0.5)

    /// The nth of several things arriving one after another.
    func staggered(_ index: Int) -> Animation { delay(Double(index) * 0.04) }
}

/// The haptic grammar: tick for a choice moving, tap for something logged, thud for a threshold crossed. A win's
/// crescendo comes with Core Haptics (FIT-393).
extension SensoryFeedback {
    static let tick = SensoryFeedback.selection
    static let tap = SensoryFeedback.impact(weight: .light)
    static let thud = SensoryFeedback.impact(flexibility: .rigid)
}

/// Movement the eye follows (a card thrown, a page slid) happens at once with Reduce Motion on; use it for those, and
/// plain withAnimation for fades and colour.
@MainActor func withMotion<Result>(_ animation: Animation, _ body: () throws -> Result) rethrows -> Result {
    try withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : animation, body)
}

/// TKL-933: a cover or sheet going up or down. With Reduce Motion on it is there, or gone, at once.
@MainActor func withPresentation(reduceMotion: Bool, _ body: () -> Void) {
    var transaction = Transaction()
    transaction.disablesAnimations = reduceMotion
    withTransaction(transaction, body)
}

/// Spatial motion becomes a fade with Reduce Motion on (the Appllama design skill's motion laws).
private struct MotionTransition: ViewModifier {
    let transition: AnyTransition
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View { content.transition(reduceMotion ? .opacity : transition) }
}

extension View {
    func motionTransition(_ transition: AnyTransition) -> some View { modifier(MotionTransition(transition: transition)) }
}

/// A button pressed in: it gives a little under the finger and springs back. Still with Reduce Motion on.
struct Pressed: ViewModifier {
    let pressed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(pressed && !reduceMotion ? 0.97 : 1)
            .animation(pressed ? .tap : .release, value: pressed)
    }
}

/// A field shaking its head at what was typed (an invite code that isn't one). Still with Reduce Motion on, where the
/// message and the error haptic say it.
struct Shake: ViewModifier {
    let trigger: Int
    var reduceMotion = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    func body(content: Content) -> some View {
        let reduced = reduceMotion || systemReduceMotion
        content.keyframeAnimator(initialValue: 0.0, trigger: trigger) { content, x in
            content.offset(x: reduced ? 0 : x)
        } keyframes: { _ in
            KeyframeTrack {
                for x in [-10.0, 9, -6, 4, 0] { SpringKeyframe(x, duration: 0.07) }
            }
        }
    }
}

/// TKL-934: an integer or rounded number that counts smoothly from one value to another on arrival.
struct CountingNumber: View, Animatable {
    nonisolated var value: Double
    var format: (Double) -> String = { Int($0.rounded()).formatted(.number) }

    nonisolated var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text(format(value)).monospacedDigit()
    }
}

/// TKL-934: a checkmark path that draws itself on with `.trim(from: 0, to:)`.
struct CheckmarkStroke: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.23, y: rect.minY + rect.height * 0.52))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.41, y: rect.minY + rect.height * 0.70))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.77, y: rect.minY + rect.height * 0.30))
        return path
    }
}

/// TKL-934: a superset's vertical pairing bracket, open on the right, drawn on with `.trim(from: 0, to:)`.
struct SupersetBracket: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = min(4, rect.width * 0.4)
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + r), control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.maxY), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return path
    }
}
