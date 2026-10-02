import SwiftUI
import SwiftData

struct ProgressScreen: View {
    @Query(sort: \Win.date, order: .reverse) private var wins: [Win]

    var body: some View {
        NavigationStack {
            List {
                if !wins.isEmpty {
                    Section("Wins") {
                        ForEach(wins) { win in
                            LabeledContent(win.kind.rawValue, value: win.date.formatted(date: .abbreviated, time: .omitted))
                        }
                    }
                }
            }
            .overlay {
                if wins.isEmpty {
                    ContentUnavailableView("No wins yet", systemImage: "trophy",
                                           description: Text("Log a workout or meal to start tracking progress."))
                }
            }
            .navigationTitle("Progress")
        }
    }
}
