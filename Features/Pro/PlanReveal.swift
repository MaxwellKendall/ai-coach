import SwiftUI
import SwiftData
import Charts

/// FIT-267: the plan revealed before the paywall, as the web quiz shows it (web/src/StartPage.tsx): the first main
/// lift's promise by the program's last day, from their recent set when they gave one, and the line rising to it.
struct PlanReveal: View {
    @Query private var templates: [Template]
    let program: ReadyProgram
    let days: Int
    var recent: StartingSet?
    let ends: Date

    var body: some View {
        let reveal = program.projection(days: days, deloads: program.deloads, recent: recent)
        let name = reveal.flatMap { reveal in templates.first { $0.slug == reveal.exercise }?.name } ?? reveal?.exercise ?? ""
        VStack(alignment: .leading, spacing: 10) {
            Text("YOUR \(program.weeks)-WEEK PLAN IS READY").font(.footnote.weight(.semibold)).tracking(0.4).foregroundStyle(Color.inkMuted)
            Text(Self.headline(program, reveal: reveal, exercise: name, ends: ends))
                .font(.display(38)).textCase(.uppercase).fixedSize(horizontal: false, vertical: true)
            if let reveal {
                Chart(Array(reveal.loads.enumerated()), id: \.offset) { week, load in
                    LineMark(x: .value("Week", week), y: .value("Load", load))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartYScale(domain: reveal.start...max(reveal.end, reveal.start + 1))
                .foregroundStyle(Plate.current.mark)
                .frame(height: 110)
                .padding(.vertical, 6)
                .accessibilityHidden(true)
            }
            Text("\(program.name) · \(days) days a week · about \(program.minutes) min")
                .font(.subheadline).foregroundStyle(Color.inkMuted)
        }
    }

    /// "Back Squat 45 → 120 lb by Jan 16", or the program's shape without a load to promise (the web's `headline`).
    nonisolated static func headline(_ program: ReadyProgram, reveal: ReadyProgram.Projection?, exercise: String, ends: Date) -> String {
        let day = ends.formatted(.dateTime.month(.abbreviated).day())
        guard let reveal else { return "\(program.name): \(program.weeks) weeks, done by \(day)" }
        return "\(exercise) \(reveal.from.formatted()) → \(reveal.end.formatted())\(reveal.perHand ? " lb a hand" : " lb") by \(day)"
    }
}
