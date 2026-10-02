import SwiftUI
import SwiftData

struct GoalsScreen: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Goal.createdAt) private var goals: [Goal]
    @Query private var profiles: [Profile]
    @State private var sheet: Sheet?

    enum Sheet: String, Identifiable {
        case profile, suggested, custom
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(goals) { goal in
                    VStack(alignment: .leading) {
                        Text(Goal.label(goal.metric)).font(.headline)
                        Text("\(goal.target.formatted()) \(goal.unit)").foregroundStyle(.secondary)
                        if let deadline = goal.deadline {
                            Text("by \(deadline.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in offsets.forEach { context.delete(goals[$0]) } }
            }
            .overlay {
                if goals.isEmpty {
                    ContentUnavailableView("No goals yet", systemImage: "target")
                }
            }
            .navigationTitle("Goals")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !profiles.isEmpty {
                        Button("Profile", systemImage: "person.crop.circle") { sheet = .profile }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu("Add goal", systemImage: "plus") {
                        if !profiles.isEmpty { Button("Suggested goals", systemImage: "sparkles") { sheet = .suggested } }
                        Button("Custom goal", systemImage: "pencil") { sheet = .custom }
                    }
                }
            }
            .sheet(item: $sheet) { sheet in
                NavigationStack {
                    switch sheet {
                    case .profile: if let profile = profiles.first { ProfileEditor(profile: profile, isNew: false) }
                    case .suggested:
                        if let profile = profiles.first {
                            SuggestedGoalsView(profile: profile, existing: Set(goals.map(\.metric)))
                        }
                    case .custom: GoalEditor()
                    }
                }
            }
        }
    }
}
