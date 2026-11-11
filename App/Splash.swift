import SwiftUI

/// FIT-413: the launch screen's three bars (the app icon's), then the app. The first frame is the launch screen's
/// (LaunchMark on LaunchBackground, project.yml), so the handoff has no seam. The bars fill with the Plate from the
/// baseline, left to right, and the mark lifts away. Cold launch only, and never held for work: by the time it draws,
/// the app under it is ready.
struct Splash: View {
    /// First launch fills the bars one after another, lands the last with a tap and lifts further, toward Welcome's
    /// promise (about 650 ms); a returning launch lifts the mark away at once (about 300 ms).
    var first = false
    /// False holds the first frame, for a splash that another one will play over (the Welcome cover's).
    var plays = true
    let done: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// How many bars have the Plate, left to right.
    @State private var filled = 0
    @State private var landed = false
    /// The bars lift away first, then the page goes: fading together, dark bars would ghost over the app.
    @State private var lifted = false
    @State private var gone = false

    /// The mark's bars in its 96-pt square, as in launch-mark-*.svg: 26 wide, 9 apart, on a baseline 8.5 from the
    /// bottom.
    static let heights: [CGFloat] = [35, 56, 79]

    var body: some View {
        ZStack {
            Color.canvas
            HStack(alignment: .bottom, spacing: 9) {
                ForEach(Self.heights.indices, id: \.self) { index in
                    // ui-score: allow radius-scale: the app icon's bar corners, as drawn by the launch screen
                    RoundedRectangle(cornerRadius: 6).fill(Color.ink)
                        .overlay(alignment: .bottom) {
                            Plate.current.accent.frame(height: index < filled ? Self.heights[index] : 0)
                        }
                        // ui-score: allow radius-scale: the app icon's bar corners, as drawn by the launch screen
                        .clipShape(.rect(cornerRadius: 6))
                        .frame(width: 26, height: Self.heights[index])
                }
            }
            .padding(.bottom, 8.5)
            .frame(width: 96, height: 96, alignment: .bottom)
            .offset(y: lifted && !reduceMotion ? (first ? -48 : -16) : 0)
            .opacity(lifted ? 0 : 1)
        }
        .opacity(gone ? 0 : 1)
        .ignoresSafeArea()
        .allowsHitTesting(!gone)
        .accessibilityHidden(true)
        .sensoryFeedback(.tap, trigger: landed)
        .task {
            guard plays else { return }
            // Each step waits for the last to finish on screen, so a slow first frame of the app under it delays the
            // splash rather than squashing it.
            if reduceMotion {
                // A short crossfade, nothing moving.
                await animate(.tap) { lifted = true; gone = true }
            } else if first {
                for bar in 1...Self.heights.count {
                    if bar < Self.heights.count {
                        withAnimation(.tap) { filled = bar }
                        try? await Task.sleep(for: .milliseconds(40))
                    } else {
                        await animate(.tap) { filled = bar }
                    }
                }
                landed = true
                await animate(.out) { lifted = true }
                await animate(.out) { gone = true }
            } else {
                // Returning: the mark takes the Plate as it lifts away.
                await animate(.out) { filled = Self.heights.count; lifted = true }
                await animate(.out) { gone = true }
            }
            done()
        }
    }

    private func animate(_ animation: Animation, _ change: () -> Void) async {
        await withCheckedContinuation { finished in
            withAnimation(animation, change) { finished.resume() }
        }
    }
}
