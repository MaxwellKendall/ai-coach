import SwiftUI
import SwiftData

/// The app's tabs (FIT-64). The coach sits in the slot iOS 26 keeps for Search.
enum AppTab: Hashable {
    case today, program, progress, groups, coach
}

/// What was said or typed to the coach, waiting for the screen that acts on it. That screen does the work in place
/// (FIT-47 to FIT-50, FIT-41), as if the mic there had heard it.
@MainActor @Observable
final class CoachInbox {
    struct Request: Equatable {
        let id = UUID()
        var said: String
        var target: AppTab
    }

    var request: Request?

    /// Takes the request if it's for `tab`.
    func take(for tab: AppTab) -> String? {
        guard let request, request.target == tab else { return nil }
        self.request = nil
        return request.said
    }
}

/// FIT-64: the coach's page. One field to type into, a mic to talk, and suggestions for where you came from.
/// Sending goes back to that screen, which acts on it there. Program changes go to Program, everything else to Today.
struct CoachScreen: View {
    @Environment(\.modelContext) private var context
    @Query private var templates: [Template]
    @Query(sort: \PlannedActivity.date) private var planned: [PlannedActivity]
    /// The tab the coach was opened from.
    let from: AppTab
    let send: (String, AppTab) -> Void

    @State private var text = ""
    @FocusState private var typing: Bool
    @State private var voice = VoiceCapture()
    @State private var message: String?

    private var target: AppTab { from == .program ? .program : .today }

    var body: some View {
        NavigationStack {
            List {
                ForEach(suggestions, id: \.title) { section in
                    Section(section.title) {
                        ForEach(section.items, id: \.self) { item in
                            Button { pick(item) } label: { Text(item).foregroundStyle(.primary) }
                        }
                    }
                }
            }
            .navigationTitle("Coach")
            .searchable(text: $text, prompt: "Tell your coach…")
            .searchFocused($typing)
            .onSubmit(of: .search) { submit(text) }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    MicButton(voice: voice, compact: true) { submit($0) }
                }
            }
            .overlay {
                if voice.listening { ListeningVeil(voice: voice, working: nil, prompt: prompt) }
            }
            .animation(.snappy, value: voice.listening)
            .alert("Couldn’t do that", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK") {}
            } message: { Text(message ?? "") }
            .onChange(of: voice.problem) { _, problem in if let problem { message = problem } }
        }
    }

    private var prompt: String {
        target == .program ? "“I’m traveling November 9 to 20, hotel gym with dumbbells”" : "Change today, or say what you did"
    }

    /// A finished suggestion is sent; one ending in "…" goes into the field to finish.
    private func pick(_ item: String) {
        if item.hasSuffix("…") {
            text = String(item.dropLast()) + " "
            typing = true
        } else {
            submit(item)
        }
    }

    private func submit(_ said: String) {
        let said = said.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else { return }
        text = ""
        send(said, target)
    }

    private struct Suggestions {
        var title: String
        var items: [String]
    }

    /// Only things the coach can already do: today's workout edits (FIT-46 to FIT-49), logs (FIT-9), trips (FIT-41).
    private var suggestions: [Suggestions] {
        if target == .program {
            return [Suggestions(title: "Your program", items: ["I’m traveling…", "I’m away next week, hotel gym with dumbbells"])]
        }
        var today: [String] = []
        if let first = todaysFirstExercise { today.append("Swap \(first)") }
        today += ["I only have 30 minutes", "Make today a lower-body day"]
        return [
            Suggestions(title: "Today’s workout", items: today),
            Suggestions(title: "Log", items: ["Weighed…", "Had … for breakfast", "Slept … hours"]),
        ]
    }

    private var todaysFirstExercise: String? {
        let names = Dictionary(templates.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return planned
            .filter { $0.kind == .workout && Calendar.current.isDateInToday($0.date) && $0.note != TrainingGenerator.warmupNote }
            .lazy.compactMap { $0.templateRef.flatMap { names[$0] } }.first
    }
}
