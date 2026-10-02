import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            Tab("Goals", systemImage: "target") { GoalsScreen() }
            Tab("Plan", systemImage: "calendar") { PlanScreen() }
            Tab("Log", systemImage: "square.and.pencil") { LogScreen() }
            Tab("Progress", systemImage: "chart.line.uptrend.xyaxis") { ProgressScreen() }
        }
    }
}
