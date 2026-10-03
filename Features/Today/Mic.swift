import SwiftUI

/// The one mic (FIT-27, prototype): hold to talk and let go, or tap, speak and it ends when you stop.
/// Hidden without Apple Intelligence; the parent keeps its manual paths.
struct MicButton: View {
    let voice: VoiceCapture
    /// Called with what was said once listening ends; not called on cancel or silence.
    let onHeard: (String) -> Void
    @State private var pressedAt: Date?
    @State private var tapMode = false
    /// This press stopped listening, so its release does nothing.
    @State private var ending = false

    var body: some View {
        Image(systemName: "mic")
            .font(.system(size: 24, weight: .medium))
            .frame(width: 68, height: 68)
            .foregroundStyle(Color(.systemBackground))
            .background(Color.primary, in: .circle)
            .scaleEffect(voice.listening ? 1.12 : 1)
            .shadow(color: .black.opacity(voice.listening ? 0 : 0.16), radius: 10, y: 6)
            .animation(.snappy, value: voice.listening)
            .contentShape(.circle)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard pressedAt == nil else { return }
                    pressedAt = .now
                    if voice.listening { ending = true; finish() } else { Task { await voice.start() } }
                }
                .onEnded { _ in
                    defer { pressedAt = nil; ending = false }
                    guard !ending, let pressedAt else { return }
                    // A short press is a tap (as is letting go before the mic is ready): keep listening until
                    // a pause in speech.
                    if Date.now.timeIntervalSince(pressedAt) < 0.4 || !voice.listening { tapMode = true } else { finish() }
                })
            .sensoryFeedback(.start, trigger: voice.listening) { !$0 && $1 }
            // Tap mode ends after 1.6 s without new words.
            .task(id: tapMode ? voice.transcript : nil) {
                guard tapMode, voice.listening, !voice.transcript.isEmpty else { return }
                try? await Task.sleep(for: .seconds(1.6))
                if !Task.isCancelled { finish() }
            }
            .onChange(of: voice.listening) { _, listening in if !listening { tapMode = false } }
            .accessibilityLabel("Talk")
            .accessibilityHint("Hold, or tap and speak.")
            .accessibilityAddTraits(.isButton)
    }

    private func finish() {
        tapMode = false
        let said = voice.stop().trimmingCharacters(in: .whitespacesAndNewlines)
        if !said.isEmpty { onHeard(said) }
    }
}

/// Prototype: the page blurs behind what you're saying, with Cancel. While the model works it shows the words
/// in grey.
struct ListeningVeil: View {
    let voice: VoiceCapture
    /// Set while what was said is being understood.
    let working: String?
    let prompt: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(.regularMaterial).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 12) {
                Button("Cancel") { _ = voice.stop() }
                    .foregroundStyle(.secondary)
                    .opacity(working == nil ? 1 : 0)
                Spacer().frame(height: 100)
                Text(working == nil ? "LISTENING · ON THIS IPHONE" : "UNDERSTANDING · ON THIS IPHONE")
                    .font(.footnote.weight(.semibold)).tracking(0.4).foregroundStyle(.tertiary)
                let said = working ?? voice.transcript
                Text(said.isEmpty ? prompt : said)
                    .font(.system(size: 30, weight: .semibold)).tracking(-0.3)
                    .foregroundStyle(said.isEmpty || working != nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                    .contentTransition(.interpolate)
                    .animation(.snappy, value: said)
                Spacer()
                if working == nil { Bars().frame(maxWidth: .infinity).padding(.bottom, 130) }
            }
            .padding(.horizontal, 30)
            .padding(.top, 8)
        }
        .transition(.opacity)
    }

    private struct Bars: View {
        var body: some View {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                HStack(spacing: 5) {
                    ForEach(0..<9, id: \.self) { index in
                        Capsule().fill(.primary)
                            .frame(width: 4, height: 10 + 30 * abs(sin(t * 3.2 + Double(index) * 0.6)))
                    }
                }
                .frame(height: 40)
            }
        }
    }
}

/// FIT-50: in place of the mic while a spoken request is worked on: what was said, the step the agent is on, and
/// Cancel. The screen stays usable underneath.
struct WorkingPill: View {
    let said: String
    let step: String
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ProgressView().tint(Color(.systemBackground))
            VStack(alignment: .leading, spacing: 1) {
                Text("“\(said)”").font(.caption).foregroundStyle(Color(.systemBackground).opacity(0.7))
                Text(step).font(.subheadline.weight(.semibold)).foregroundStyle(Color(.systemBackground))
                    .contentTransition(.opacity)
                    .animation(.snappy, value: step)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: cancel) {
                Image(systemName: "xmark").font(.subheadline.weight(.bold)).foregroundStyle(Color(.systemBackground))
                    .frame(width: 44, height: 44)
                    .background(Color(.systemBackground).opacity(0.16), in: .circle)
            }
            .accessibilityLabel("Cancel")
        }
        .padding(.leading, 20).padding(.trailing, 7)
        .frame(height: 58)
        .background(Color.primary, in: .capsule)
        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
    }
}

/// FIT-50: a slow-turning glow around the screen's edge while the on-device model works (the Siri idiom).
struct EdgeGlow: View {
    var body: some View {
        TimelineView(.animation) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4) / 4
            RoundedRectangle(cornerRadius: 58, style: .continuous)
                .strokeBorder(AngularGradient(colors: [.blue, .purple, .pink, .orange, .yellow, .blue],
                                              center: .center, angle: .degrees(turn * 360)), lineWidth: 10)
                .blur(radius: 14)
                .opacity(0.75)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A short confirmation at the bottom with an optional Undo (prototype toast).
struct Toast: Equatable {
    var text: String
    var undo: (@MainActor () -> Void)?
    let id = UUID()

    static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
}

struct ToastView: View {
    @Binding var toast: Toast?

    var body: some View {
        if let current = toast {
            HStack(spacing: 14) {
                Text(current.text).lineLimit(1)
                if let undo = current.undo {
                    Button("Undo") { undo(); toast = nil }.fontWeight(.semibold)
                }
            }
            .font(.subheadline)
            .padding(.leading, 18).padding(.trailing, current.undo == nil ? 18 : 12)
            .frame(height: 44)
            .foregroundStyle(Color(.systemBackground))
            .background(Color.primary, in: .capsule)
            .shadow(color: .black.opacity(0.18), radius: 10, y: 6)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: current.id) {
                try? await Task.sleep(for: .seconds(current.undo == nil ? 3 : 6))
                if toast?.id == current.id { withAnimation { toast = nil } }
            }
        }
    }
}
