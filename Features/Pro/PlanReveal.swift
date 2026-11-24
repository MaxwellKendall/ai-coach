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

    var stage: MotionStage = .start
    var titleProgress = 1.0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum MotionStage: Int, CaseIterable, Comparable {
        case title, numbers, line, crescendo, date, details, start

        nonisolated static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        nonisolated var elapsed: Duration {
            switch self {
            case .title: .zero
            case .numbers: .milliseconds(220)
            case .line: .milliseconds(400)
            case .crescendo: .milliseconds(700)
            case .date: .milliseconds(1_000)
            case .details: .milliseconds(1_120)
            case .start: .milliseconds(1_320)
            }
        }
    }

    var body: some View {
        let reveal = program.projection(days: days, deloads: program.deloads, recent: recent)
        let name = reveal.flatMap { reveal in templates.first { $0.slug == reveal.exercise }?.name } ?? reveal?.exercise ?? ""
        let target = reveal.map { stage >= .line ? $0.end : $0.from }
        let title = "YOUR \(program.weeks)-WEEK PLAN IS READY"
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .opacity(0)
                .overlay(alignment: .topLeading) {
                    Text(String(title.prefix(Int(Double(title.count) * titleProgress))))
                }
                .font(.footnote.weight(.semibold)).tracking(0.4).foregroundStyle(Color.inkMuted)
                .accessibilityLabel(title)
            promise(reveal, name: name, target: target)
                .font(.display(30)).monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(reduceMotion ? .identity : .numericText(value: target ?? Double(program.weeks)))
                .accessibilityLabel(Self.headline(program, reveal: reveal, exercise: name, ends: ends))
                .opacity(stage >= .numbers ? 1 : 0)
            if let reveal { projectionChart(reveal) }
            Text("\(program.name) · \(days) days a week · about \(program.minutes) min")
                .font(.subheadline).foregroundStyle(Color.inkMuted)
                .opacity(stage >= .details ? 1 : 0)
        }
        .animation(reduceMotion ? nil : .settle, value: reveal)
        .animation(reduceMotion ? nil : .settle, value: ends)
    }

    private func promise(_ reveal: ReadyProgram.Projection?, name: String, target: Double?) -> Text {
        let date = Text(ends, format: .dateTime.month(.abbreviated).day())
            .foregroundColor(stage >= .date ? nil : .clear)
        guard let reveal, let target else { return Text("\(program.name): \(program.weeks) weeks, done by \(date)") }
        let unit = reveal.perHand ? "lb a hand" : "lb"
        return Text("\(name) \(reveal.from.formatted()) → \(target.formatted()) \(unit) by \(date)")
    }

    private func projectionChart(_ reveal: ReadyProgram.Projection) -> some View {
        let loads = Self.chartLoads(reveal.loads, deloads: program.deloads)
        return ProjectionPlot(samples: ChartSamples(loads: loads), showEnd: stage >= .date,
                              pulse: stage == .date && !reduceMotion)
            .mask(alignment: .leading) {
                GeometryReader { geometry in
                    Rectangle().frame(width: stage >= .line ? geometry.size.width : 0)
                }
            }
            .frame(height: 110)
            .padding(.vertical, 6)
            .accessibilityHidden(true)
    }

    private struct ProjectionPlot: View, Animatable {
        nonisolated var samples: ChartSamples
        var showEnd: Bool
        var pulse: Bool

        nonisolated var animatableData: ChartSamples {
            get { samples }
            set { samples = newValue }
        }

        var body: some View {
            Chart {
                ForEach(Array(samples.values.enumerated()), id: \.offset) { index, height in
                    LineMark(x: .value("Week", index), y: .value("Load", height))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
                        .foregroundStyle(Plate.current.mark)
                }
                PointMark(x: .value("Week", samples.values.count - 1), y: .value("Load", samples.values.last ?? 0))
                    .symbol {
                        Circle().fill(Plate.current.mark)
                            .frame(width: 8, height: 8)
                            .scaleEffect(pulse ? 1.75 : 1)
                            .opacity(showEnd ? 1 : 0)
                    }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartXScale(domain: 0...(samples.values.count - 1), range: .plotDimension(padding: 8))
            .chartYScale(domain: 0.0...1.0, range: .plotDimension(padding: 8))
        }
    }

    /// Equal-length, normalized plots interpolate even when a program changes the number of weeks or load range.
    struct ChartSamples: VectorArithmetic, Sendable {
        private static let intervals = 64
        private(set) var values: [Double]

        init(loads: [Double]) {
            let floor = loads.min() ?? 0
            let range = max((loads.max() ?? 0) - floor, 1)
            let last = max(0, loads.count - 1)
            values = (0...Self.intervals).map { index in
                guard !loads.isEmpty else { return 0 }
                let position = Double(index * last) / Double(Self.intervals)
                let low = Int(position)
                let high = min(low + 1, last)
                let load = loads[low] + (loads[high] - loads[low]) * (position - Double(low))
                return (load - floor) / range
            }
        }

        private init(values: [Double]) { self.values = values }

        static var zero: Self { Self(values: Array(repeating: 0, count: intervals + 1)) }
        static func + (lhs: Self, rhs: Self) -> Self { Self(values: zip(lhs.values, rhs.values).map(+)) }
        static func - (lhs: Self, rhs: Self) -> Self { Self(values: zip(lhs.values, rhs.values).map(-)) }
        mutating func scale(by factor: Double) { values = values.map { $0 * factor } }
        var magnitudeSquared: Double { values.reduce(0) { $0 + $1 * $1 } }
    }

    /// The projection records progression loads; its chart also shows the lighter week actually trained.
    nonisolated static func chartLoads(_ loads: [Double], deloads: Set<Int>) -> [Double] {
        loads.enumerated().map { week, load in
            deloads.contains(week - 1) ? load * TrainingGenerator.deloadLoad : load
        }
    }

    /// "Back Squat 45 → 120 lb by Jan 16", or the program's shape without a load to promise (the web's `headline`).
    nonisolated static func headline(_ program: ReadyProgram, reveal: ReadyProgram.Projection?, exercise: String, ends: Date) -> String {
        let day = ends.formatted(.dateTime.month(.abbreviated).day())
        guard let reveal else { return "\(program.name): \(program.weeks) weeks, done by \(day)" }
        return "\(exercise) \(reveal.from.formatted()) → \(reveal.end.formatted())\(reveal.perHand ? " lb a hand" : " lb") by \(day)"
    }
}
