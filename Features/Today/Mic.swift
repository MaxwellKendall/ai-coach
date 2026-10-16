import SwiftUI

/// The one mic (FIT-27, prototype): hold to talk and let go, or tap, speak and tap again (or Done) when finished.
/// FIT-134: the user ends it; silence is only `VoiceCapture`'s backstop. Hidden without Apple Intelligence; the parent
/// keeps its manual paths.
struct MicButton: View {
    let voice: VoiceCapture
    /// FIT-64: a plain toolbar mic (the coach page) instead of the big black one.
    var compact = false
    /// Called with what was said once listening ends; not called on cancel or silence.
    let onHeard: (String) -> Void
    @State private var pressedAt: Date?
    /// This press stopped listening, so its release does nothing.
    @State private var ending = false

    var body: some View {
        Image(systemName: compact ? (voice.listening ? "mic.fill" : "mic") : "mic")
            .font(.system(size: compact ? 17 : 24, weight: .medium))
            .frame(width: compact ? 36 : 68, height: compact ? 36 : 68)
            .foregroundStyle(compact ? Color.primary : Color(.systemBackground))
            .background(compact ? Color.clear : Color.primary, in: .circle)
            .scaleEffect(voice.listening && !compact ? 1.12 : 1)
            .shadow(color: .black.opacity(voice.listening || compact ? 0 : 0.16), radius: 10, y: 6)
            .animation(.snappy, value: voice.listening)
            .contentShape(.circle)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    // While the words are being fixed by hand, Send on the veil sends them.
                    guard pressedAt == nil, !voice.editing else { return }
                    pressedAt = .now
                    if voice.listening { ending = true; voice.finish(how: "tapping the mic") } else { Task { await voice.start(onDone: onHeard) } }
                }
                .onEnded { _ in
                    defer { pressedAt = nil; ending = false }
                    guard !ending, let pressedAt else { return }
                    // A short press is a tap (as is letting go before the mic is ready): keep listening until Done.
                    if Date.now.timeIntervalSince(pressedAt) >= 0.4, voice.listening, !voice.editing { voice.finish(how: "letting go") }
                })
            .sensoryFeedback(.start, trigger: voice.listening) { !$0 && $1 }
            .accessibilityLabel("Talk")
            .accessibilityHint("Hold, or tap, speak and tap Done.")
            .accessibilityAddTraits(.isButton)
    }
}

/// Prototype: the page blurs behind what you're saying, with Cancel. While the model works it shows the words
/// in grey. FIT-134: Done sends, with a ring that shows the pause backstop coming; tapping the words stops the
/// microphone so they can be fixed by hand before sending.
struct ListeningVeil: View {
    let voice: VoiceCapture
    /// Set while what was said is being understood.
    let working: String?
    let prompt: String
    /// FIT-64: the coach starts listening when opened, so offer the keyboard instead.
    var typeInstead: (() -> Void)?
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(.regularMaterial).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button("Cancel") { _ = voice.stop() }
                    Spacer()
                    if let typeInstead, !voice.editing {
                        Button("Type Instead", systemImage: "keyboard") {
                            _ = voice.stop()
                            typeInstead()
                        }
                    }
                }
                .foregroundStyle(.secondary)
                .opacity(working == nil ? 1 : 0)
                Spacer().frame(height: 100)
                Text(working != nil ? "UNDERSTANDING · ON THIS IPHONE" : voice.editing ? "FIX IT, THEN SEND" : "LISTENING · ON THIS IPHONE")
                    .font(.footnote.weight(.semibold)).tracking(0.4).foregroundStyle(.tertiary)
                if voice.editing, working == nil {
                    TextField("", text: $draft, axis: .vertical)
                        .font(.system(size: 30, weight: .semibold)).tracking(-0.3)
                        .lineLimit(1...6)
                        .focused($focused)
                    Button("Send", systemImage: "arrow.up", action: send)
                        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(.primary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    let said = working ?? voice.transcript
                    Text(said.isEmpty ? prompt : said)
                        .font(.system(size: 30, weight: .semibold)).tracking(-0.3)
                        .foregroundStyle(said.isEmpty || working != nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                        .contentTransition(.interpolate)
                        .animation(.snappy, value: said)
                        .onTapGesture {
                            guard working == nil, !voice.transcript.isEmpty else { return }
                            draft = voice.transcript
                            voice.edit()
                            focused = true
                        }
                        .accessibilityHint(said.isEmpty ? "" : "Stops listening so you can edit it.")
                }
                Spacer()
                if working == nil, !voice.editing {
                    VStack(spacing: 22) {
                        Bars()
                        DoneButton(voice: voice, send: send)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 40)
                }
            }
            .padding(.horizontal, 30)
            .padding(.top, 8)
        }
        .transition(.opacity)
    }

    private func send() {
        voice.editing ? voice.finish(draft) : voice.finish()
    }

    /// Done, ringed by the time left before a pause sends it.
    private struct DoneButton: View {
        let voice: VoiceCapture
        let send: () -> Void

        var body: some View {
            VStack(spacing: 10) {
                Button(action: send) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Color(.systemBackground))
                        .frame(width: 68, height: 68)
                        .background(Color.primary, in: .circle)
                        .overlay {
                            TimelineView(.animation(minimumInterval: 0.05)) { context in
                                Circle().trim(from: 0, to: left(at: context.date))
                                    .stroke(Color.primary, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                                    .padding(-8)
                            }
                        }
                }
                .accessibilityLabel("Done")
                Text(voice.transcript.isEmpty ? "Tap when you’re done" : "Done")
                    .font(.footnote).foregroundStyle(.tertiary)
            }
        }

        /// The ring appears after a 1.5 s pause and empties as the backstop nears; full means nothing's coming yet.
        private func left(at now: Date) -> CGFloat {
            guard !voice.transcript.isEmpty else { return 0 }
            let grace = 1.5
            let quiet = now.timeIntervalSince(voice.quietSince)
            guard quiet > grace else { return 0 }
            return max(0, 1 - (quiet - grace) / (VoiceCapture.backstop - grace))
        }
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
