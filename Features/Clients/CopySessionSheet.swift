import SwiftUI

/// FIT-379: a session to copy onto an empty day, with the sets, reps and loads it had: from this client's other days
/// first, then from the coach's other clients.
struct CopySessionSheet: View {
    let client: String
    let day: String
    let names: [String: String]
    let pick: ([SyncUnits.PlanRow]) -> Void

    @Environment(Roster.self) private var roster
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let today = SyncUnits.day(.now)
        // Theirs first, then everyone else A–Z, as the roster is.
        let clients = roster.clients.filter { $0.id == client } + roster.clients.filter { $0.id != client }
        let lists = clients.map { ($0, ClientDay.sessions($0.units, today: today, besides: $0.id == client ? day : "")) }
            .filter { !$0.1.isEmpty }
        NavigationStack {
            List {
                ForEach(lists, id: \.0.id) { other, sessions in
                    Section(other.id == client ? "Their sessions" : other.name) {
                        ForEach(sessions, id: \.day) { session in
                            Button {
                                pick(session.rows)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(session.rows.first { $0.slot != nil }?.slot ?? "Workout").foregroundStyle(Color.ink)
                                    Text(Self.summary(session, names: names)).font(.footnote).foregroundStyle(Color.inkMuted)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .overlay {
                if lists.isEmpty { ContentUnavailableView("No sessions to copy", systemImage: "doc.on.doc", description: Text("Sessions planned in the last four weeks show here.")) }
            }
            .navigationTitle("Copy a Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    /// "Mon, Nov 9 · Back Squat, Bench Press, Row".
    static func summary(_ session: (day: String, rows: [SyncUnits.PlanRow]), names: [String: String]) -> String {
        let date = SyncUnits.date(ofKey: "plan#\(session.day)").map { $0.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) } ?? session.day
        let lifts = session.rows.compactMap(\.template).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return ([date] + [lifts.map { names[$0] ?? $0 }.joined(separator: ", ")]).joined(separator: " · ")
    }
}
