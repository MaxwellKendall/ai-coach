import SwiftUI
import SwiftData

struct PlanScreen: View {
    @Query(sort: \PlannedActivity.date) private var items: [PlannedActivity]

    private var thisWeek: [PlannedActivity] {
        let start = Week.monday(of: .now)
        let end = Calendar.current.date(byAdding: .day, value: 7, to: start)!
        return items.filter { $0.date >= start && $0.date < end }
    }

    var body: some View {
        NavigationStack {
            List(thisWeek) { item in
                LabeledContent(item.kind.rawValue.capitalized,
                               value: item.date.formatted(.dateTime.weekday(.abbreviated).day()))
            }
            .overlay {
                if thisWeek.isEmpty {
                    ContentUnavailableView("Nothing planned this week", systemImage: "calendar")
                }
            }
            .navigationTitle("This week")
            .toolbar {
                NavigationLink {
                    CatalogScreen()
                } label: {
                    Label("Catalog", systemImage: "books.vertical")
                }
            }
        }
    }
}
