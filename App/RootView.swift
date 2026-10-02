import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            Tab("Today", systemImage: "calendar") { TodayScreen() }
            Tab("Goals", systemImage: "target") { GoalsScreen() }
            Tab("Log", systemImage: "square.and.pencil") { LogScreen() }
            Tab("Progress", systemImage: "chart.line.uptrend.xyaxis") { ProgressScreen() }
        }
        .tint(Color(red: 0.94, green: 0.39, blue: 0.09)) // FIT-19 prototype accent #F06418
    }
}
