import SwiftUI

/// FIT-108: a week of the program as a card to share, and on the last week the whole program's recap. Built from
/// the weekly review's numbers; the page (infra/lambda/sharePages.ts, /r/{id}) shows what the card shows.
struct Recap: Equatable {
    struct Lift: Equatable {
        var name: String
        var from: Double
        var to: Double
        var unit: String
    }

    /// 1-based.
    var week: Int
    var weeks: Int
    var phase: String
    var done: Int
    var planned: Int
    var bests: Int
    var lifts: [Lift]

    var finished: Bool { week >= weeks }
    var key: String { "recap.\(weeks).\(week)" }

    /// The week's recap, or nil outside a program. The last week recaps the whole program: every session, every best,
    /// and each lift from where it started.
    @MainActor static func make(_ report: WeekReport, profile: Profile?, wins: [WinItem],
                                sessions program: (done: Int, planned: Int)) -> Recap? {
        guard let index = report.programWeek, let weeks = report.programWeeks else { return nil }
        let last = index + 1 >= weeks
        // A race time isn't a lift on the card (FIT-179).
        let lifts = report.goals.filter { $0.option.measure != .body && $0.option.measure != .time }.prefix(3).map {
            Lift(name: $0.option.liftName, from: last ? $0.start : $0.week.from, to: $0.week.to, unit: $0.goal.unit)
        }
        let bests = wins.filter { $0.kind == .pr && (last || report.days.contains($0.date)) }.count
        return Recap(week: index + 1, weeks: weeks, phase: profile?.program?[safe: index]?.phase.rawValue ?? "base",
                     done: last ? program.done : report.numbers.workoutsDone,
                     planned: last ? program.planned : report.numbers.workoutsPlanned, bests: bests, lifts: Array(lifts))
    }

    /// What's saved for the page. With weights hidden none are sent: each lift goes as percent of where it started.
    func payload(showNumbers: Bool) -> [String: Any] {
        [
            "week": week, "weeks": weeks, "phase": phase,
            "sessions": ["done": done, "planned": planned], "bests": bests, "showNumbers": showNumbers,
            "lifts": lifts.filter { $0.from > 0 }.map { lift -> [String: Any] in
                showNumbers
                    ? ["metric": lift.name, "from": lift.from, "to": lift.to, "unit": lift.unit]
                    : ["metric": lift.name, "from": 100.0, "to": (lift.to / lift.from * 1000).rounded() / 10, "unit": "%"]
            },
        ]
    }

    /// "+15 lb" or "+8%".
    func change(_ lift: Lift, showNumbers: Bool) -> String {
        let up = lift.to - lift.from
        let sign = up >= 0 ? "+" : "−"
        return showNumbers ? "\(sign)\(Coach.number(abs(up))) \(lift.unit)"
            : "\(sign)\(Int((abs(up) / max(lift.from, 1) * 100).rounded()))%"
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// The recap as an image: drawn at the win card's size, so both share the same way.
struct RecapCard: View {
    let recap: Recap
    var style = CardStyle.dark
    var showNumbers = true
    var link: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(recap.finished ? "PROGRAM DONE" : "\(recap.phase.uppercased()) PHASE")
                .font(.system(size: 11, weight: .semibold)).tracking(1.2).foregroundStyle(style.muted)
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text("\(min(recap.week, recap.weeks))").font(.system(size: 64, weight: .bold, design: .rounded)).tracking(-2)
                Text(recap.finished ? "weeks, done" : "of \(recap.weeks) weeks").font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(style.muted)
            }
            .padding(.top, 6)
            Capsule().fill(style.track).frame(height: 6)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule().fill(style.text).frame(width: proxy.size.width * min(1, Double(recap.week) / Double(max(recap.weeks, 1))))
                    }
                }
                .padding(.top, 10)
            HStack(spacing: 8) {
                tile("\(recap.done)/\(recap.planned)", "sessions")
                tile("\(recap.bests)", recap.bests == 1 ? "new best" : "new bests")
            }
            .padding(.top, 14)
            VStack(spacing: 0) {
                ForEach(recap.lifts, id: \.name) { lift in
                    HStack {
                        Text(lift.name).font(.system(size: 14))
                        Spacer()
                        Text(recap.change(lift, showNumbers: showNumbers)).font(.system(size: 14, weight: .semibold, design: .rounded))
                    }
                    .padding(.vertical, 6)
                }
            }
            .padding(.top, 8)
            Spacer(minLength: 0)
            HStack {
                Text(link ?? Date.now.formatted(.dateTime.month(.abbreviated).day().year()))
                    .font(.system(size: 12, weight: link == nil ? .regular : .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "circle.circle.fill").font(.system(size: 12)).symbolRenderingMode(.monochrome)
                    if link == nil { Text(ShareCard.appName).font(.system(size: 12, weight: .semibold)) }
                }
            }
            .foregroundStyle(style.muted)
        }
        .foregroundStyle(style.text)
        .padding(EdgeInsets(top: 24, leading: 24, bottom: 20, trailing: 24))
        .frame(width: ShareCard.size.width, height: ShareCard.size.height, alignment: .topLeading)
        .background(style.background)
        .clipShape(.rect(cornerRadius: 20))
        .overlay { if style == .paper { RoundedRectangle(cornerRadius: 20).strokeBorder(style.track) } }
        .environment(\.colorScheme, style == .dark ? .dark : .light)
    }

    private func tile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(size: 22, weight: .bold, design: .rounded))
            Text(label).font(.system(size: 12)).foregroundStyle(style.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(style.track.opacity(0.55), in: .rect(cornerRadius: 12))
    }

    @MainActor static func image(_ recap: Recap, style: CardStyle, showNumbers: Bool, link: String? = nil) -> UIImage? {
        let renderer = ImageRenderer(content: RecapCard(recap: recap, style: style, showNumbers: showNumbers, link: link))
        renderer.scale = 1080 / ShareCard.size.width
        return renderer.uiImage
    }
}

/// The weekly review's Share: the recap card, black or paper, with or without weights.
struct RecapShareSheet: View {
    let recap: Recap
    @Environment(\.dismiss) private var dismiss
    @State private var style = CardStyle.dark
    @State private var showNumbers = true
    @State private var image: UIImage?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Color.clear.frame(width: 44, height: 44)
                Spacer()
                Text(recap.finished ? "Your program" : "Your week").font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.body.weight(.semibold)).foregroundStyle(.primary).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, 12).padding(.top, 8)
            RecapCard(recap: recap, style: style, showNumbers: showNumbers)
                .shadow(color: .black.opacity(0.14), radius: 15, y: 8)
                .id("\(style.rawValue)\(showNumbers)")
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
                .padding(.top, 8)
            VStack(spacing: 12) {
                Picker("Style", selection: $style.animation(.snappy)) {
                    ForEach(CardStyle.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                if !recap.lifts.isEmpty {
                    Toggle(isOn: $showNumbers.animation(.snappy)) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Show weights")
                            Text(showNumbers ? "Each lift's change in pounds" : "Only percents appear")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .tint(.primary)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 16))
                }
            }
            .padding(.horizontal, 24).padding(.top, 20)
            Spacer(minLength: 12)
            ShareActions(image: image, item: ShareActions.Item(
                kind: "recap", key: recap.key, look: "\(style.rawValue)\(showNumbers)",
                title: recap.finished ? "\(recap.weeks) weeks, done" : "Week \(recap.week) of \(recap.weeks)",
                payload: { recap.payload(showNumbers: showNumbers) },
                render: { RecapCard.image(recap, style: style, showNumbers: showNumbers, link: $0) }))
            .padding(.horizontal, 24).padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .task(id: "\(style.rawValue)\(showNumbers)") { image = RecapCard.image(recap, style: style, showNumbers: showNumbers) }
        .presentationDetents([.large])
    }
}
