import SwiftUI
import SwiftData

struct GoalsScreen: View {
    @Query(sort: \Goal.createdAt) private var goals: [Goal]

    var body: some View {
        NavigationStack {
            List(goals) { goal in
                VStack(alignment: .leading) {
                    Text(Goal.label(goal.metric)).font(.headline)
                    Text("\(goal.target.formatted()) \(goal.unit)").foregroundStyle(.secondary)
                    if let deadline = goal.deadline {
                        Text("by \(deadline.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .overlay {
                if goals.isEmpty {
                    ContentUnavailableView("No goals yet", systemImage: "target")
                }
            }
            .navigationTitle("Goals")
        }
    }
}
