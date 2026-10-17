import SwiftUI
import SwiftData

/// FIT-131: a program the coach sent. The client sees who sent it, the note, when it starts and the week it repeats,
/// and starts it or declines (the coach sees which). Starting replaces what's planned from its start day; days already
/// trained stay. Dismissed without an answer, it's asked again next time.
struct ProgramOfferSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Query private var templates: [Template]
    let offer: Cloud.ProgramOffer
    var onAnswered: () -> Void = {}

    @State private var working: Bool?
    @State private var failure: String?

    private static let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    var body: some View {
        let names = Dictionary(templates.map { ($0.slug, $0.name) }, uniquingKeysWith: { first, _ in first })
        let coach = offer.coachName ?? "Your coach"
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(coach) sent you a \(offer.weeks)-week program").font(.title2.bold())
                        if let start = offer.startDate {
                            Text("Starts \(start.formatted(.dateTime.weekday(.wide).month(.wide).day()))").foregroundStyle(.secondary)
                        }
                        if !offer.note.isEmpty {
                            Text("“\(offer.note)”").padding(.top, 4)
                        }
                        if offer.addPerWeek > 0 {
                            Text("Main lifts go up \(Coach.number(offer.addPerWeek)) lb a week.").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section("Each week") {
                    ForEach(offer.week, id: \.weekday) { day in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(Self.weekdays[day.weekday]) · \(day.slot)").font(.headline)
                            ForEach(Array(day.rows.filter { $0.note != TrainingGenerator.warmupNote }.enumerated()), id: \.offset) { _, row in
                                Text("\(names[row.template] ?? row.template)  \(Self.describe(row.targets))")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                Section {
                    Button { answer(true) } label: {
                        HStack { Spacer(); if working == true { ProgressView() } else { Text("Start Program").bold() }; Spacer() }
                    }
                    .disabled(working != nil)
                    Button(role: .destructive) { answer(false) } label: {
                        HStack { Spacer(); if working == false { ProgressView() } else { Text("Decline") }; Spacer() }
                    }
                    .disabled(working != nil)
                } footer: {
                    Text(failure ?? "Starting replaces what's planned from \(offer.startDate?.formatted(.dateTime.month(.wide).day()) ?? "its start"). Sessions you've done stay.")
                        .foregroundStyle(failure == nil ? Color.secondary : Color.red)
                }
            }
            .navigationTitle("From \(coach)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Later") { dismiss() } } }
        }
    }

    /// "3 × 5 @ 185 lb", "3 × 40 s".
    nonisolated static func describe(_ targets: [Measurement]) -> String {
        func v(_ m: String) -> Double? { targets.first { $0.metric == m }?.value }
        let sets = Int(v("sets") ?? 1)
        var text = v("reps").map { "\(sets) × \(Coach.number($0))" } ?? v("duration_s").map { "\(sets) × \(Coach.number($0)) s" } ?? "\(sets) sets"
        if let load = v("load_lb") { text += " @ \(Coach.number(load)) lb" } else if let load = v("load_lb_hand") { text += " @ \(Coach.number(load)) lb/hand" }
        return text
    }

    private func answer(_ start: Bool) {
        working = start
        failure = nil
        Task {
            defer { working = nil }
            do {
                try await Cloud.answerProgram(offer.id, start: start)
                // The program is in the plan on the server now; bring it here.
                if start { SyncEngine.shared.sync() }
                onAnswered()
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
