import SwiftUI

/// Everything that isn't today's workout, one tap from Today's header (FIT-27).
struct YouScreen: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                NavigationLink { GoalsScreen() } label: { Label("Goals", systemImage: "target") }
                NavigationLink { ProgressScreen() } label: { Label("Progress", systemImage: "chart.line.uptrend.xyaxis") }
                NavigationLink { CatalogScreen() } label: { Label("Library", systemImage: "books.vertical") }
            }
            .navigationTitle("You")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
