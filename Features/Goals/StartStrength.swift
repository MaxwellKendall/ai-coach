import SwiftUI
import SwiftData

// FIT-455: screens 15–23 of the AbMaxx-style spec: the strength check in place of the ab scan, its results with only the
// weakest lift readable, setting the plan up, and the plan. Any animation here is short, and a tap skips it.

/// Screen 15.
struct InviteStep: View {
    let name: String
    let start: () -> Void
    let skip: () -> Void

    var body: some View {
        StartQuestion(name.isEmpty ? "Let’s check your strength." : "\(name), let’s check your strength.",
                      detail: "We’ll score your main lifts and build your plan around the weakest one.") {
            Image(systemName: "gauge.with.needle").font(.system(size: 96, weight: .regular)).foregroundStyle(Plate.current.mark)
                .frame(maxWidth: .infinity, minHeight: 220)
                .accessibilityHidden(true)
        }
        .safeAreaBar(edge: .bottom) {
            StartBar(title: "Start Strength Check", id: "start.check", action: start, secondary: ("Skip for now", skip))
        }
    }
}

/// Screen 16: AbMaxx's three steps, in under ten seconds.
struct ThreeStepsStep: View {
    let next: () -> Void
    let skip: () -> Void

    private let steps = ["Pick the lifts you actually train.", "Enter your best recent set: weight × reps.",
                         "We score each lift against bodyweight standards."]

    var body: some View {
        StartQuestion("3 steps, less than 10 seconds") {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Text("\(index + 1)").font(.headline).foregroundStyle(Plate.current.onAccent)
                            .frame(width: 30, height: 30).background(.tint, in: .circle)
                        Text(step).font(.body.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(Color.fill, in: .rect(cornerRadius: 20))
        }
        .safeAreaBar(edge: .bottom) { StartBar(title: "Continue", action: next, secondary: ("Skip for now", skip)) }
    }
}

/// Screen 17: all four on to start with.
struct LiftsStep: View {
    @Binding var picked: Set<String>
    let next: () -> Void
    let skip: () -> Void

    var body: some View {
        StartQuestion("Which lifts do you want scored?", detail: "Skip any lift you don’t train.") {
            ForEach(StrengthCheck.lifts, id: \.slug) { lift in
                StartOption(lift.name, on: picked.contains(lift.slug)) {
                    if picked.contains(lift.slug) { picked.remove(lift.slug) } else { picked.insert(lift.slug) }
                }
            }
        }
        .safeAreaBar(edge: .bottom) { StartBar(title: "Continue", enabled: !picked.isEmpty, action: next, secondary: ("Skip for now", skip)) }
        .onAppear { if picked.isEmpty { picked = Set(StrengthCheck.lifts.map(\.slug)) } }
    }
}

/// Screen 18: one working set of each, not a theoretical max. Kept in lb; typed in kg when they picked kg.
struct EnterLiftsStep: View {
    @Binding var entries: [StrengthCheck.Entry]
    let metric: Bool
    let next: () -> Void
    let skip: () -> Void
    @State private var weight: [String: String] = [:]
    @State private var reps: [String: String] = [:]
    @FocusState private var focus: String?

    private static let kg = 0.45359237

    /// The sets as typed, in lb; nil while any is half filled or out of range.
    private var typed: [StrengthCheck.Entry]? {
        var out: [StrengthCheck.Entry] = []
        for entry in entries {
            let w = weight[entry.slug, default: ""], r = reps[entry.slug, default: ""]
            if w.isEmpty && r.isEmpty { continue }
            guard let load = Double(w.replacingOccurrences(of: ",", with: ".")), let count = Double(r) else { return nil }
            let lb = metric ? load / Self.kg : load
            guard (1...1500).contains(lb), (1...12).contains(count) else { return nil }
            out.append(StrengthCheck.Entry(slug: entry.slug, weight: lb, reps: count))
        }
        return out
    }

    var body: some View {
        StartQuestion("Your best recent set", detail: "One hard set of each, 1 to 12 reps. Leave any you don’t know.") {
            // One row a lift, so all four fit above the keyboard.
            VStack(alignment: .leading, spacing: 10) {
                ForEach(entries, id: \.slug) { entry in
                    HStack(spacing: 8) {
                        Text(StrengthCheck.name(entry.slug)).font(.subheadline.weight(.semibold))
                            .lineLimit(2).minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        field($weight, entry.slug, metric ? "kg" : "lb", focus: "\(entry.slug).weight", keyboard: .decimalPad)
                            .frame(width: 104)
                        Text("×").foregroundStyle(Color.inkMuted)
                        field($reps, entry.slug, "reps", focus: "\(entry.slug).reps", keyboard: .numberPad)
                            .frame(width: 84)
                    }
                }
            }
        }
        .safeAreaBar(edge: .bottom) {
            StartBar(title: "See My Scores", enabled: typed?.isEmpty == false, id: "start.scores", action: {
                entries = typed ?? []
                next()
            }, secondary: ("Skip for now", skip))
        }
        .onAppear { focus = entries.first.map { "\($0.slug).weight" } }
    }

    private func field(_ values: Binding<[String: String]>, _ slug: String, _ unit: String, focus id: String,
                       keyboard: UIKeyboardType) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            TextField("0", text: Binding(get: { values.wrappedValue[slug, default: ""] }, set: { values.wrappedValue[slug] = $0 }))
                .font(.display(22, weight: .semibold)).monospacedDigit()
                .keyboardType(keyboard)
                .focused($focus, equals: id)
                .accessibilityIdentifier("start.\(id)")
            Text(unit).font(.subheadline).foregroundStyle(Color.inkMuted).fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 54)
        .background(Color.fill, in: .rect(cornerRadius: 14))
        .onTapGesture { focus = id }
    }
}

/// A short checklist that ticks through, then moves on by itself; a tap moves on at once. Theatre around work that's
/// already done (or quick), never a wait for its own sake.
private struct Checklist: View {
    let title: String
    let lines: [String]
    /// False while the work behind it is still going: the list waits on its last line.
    var ready = true
    let done: () -> Void
    @State private var ticked = 0
    @State private var finished = false
    @State private var timeUp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Spacer()
            Text(title).font(.display(30)).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    HStack(spacing: 12) {
                        Image(systemName: index < ticked ? "checkmark.circle.fill" : "circle")
                            .font(.title3).foregroundStyle(index < ticked ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.inkFaint))
                        Text(line).font(.body.weight(.medium))
                    }
                }
            }
            Spacer()
            Text("Tap to skip").font(.footnote).foregroundStyle(Color.inkFaint).frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        .contentShape(.rect)
        .onTapGesture { if ready { finish() } }
        .task {
            // About 2.5 s at most, as the spec caps it.
            let each = min(0.6, 2.4 / Double(max(lines.count, 1)))
            for _ in lines {
                try? await Task.sleep(for: .seconds(each))
                if Task.isCancelled { return }
                withAnimation(.tap) { ticked += 1 }
            }
            try? await Task.sleep(for: .milliseconds(250))
            timeUp = true
        }
        // Read fresh here: the task above holds the view as it was when it started.
        .onChange(of: timeUp && ready) { _, go in if go { finish() } }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        done()
    }
}

/// Screen 20: scoring is local and instant; this is the moment it's shown happening.
struct AnalysisStep: View {
    let name: String
    let lifts: [String]
    let done: () -> Void

    var body: some View {
        Checklist(title: name.isEmpty ? "Analyzing your lifts…" : "Analyzing \(name)’s lifts…",
                  lines: lifts.map { "Scoring \(StrengthCheck.name($0).lowercased()) against bodyweight" }, done: done)
    }
}

/// Screen 21: the overall score and every lift but the weakest blurred past reading; nothing blurred is read aloud.
struct ResultsStep: View {
    let result: StrengthCheck.Result
    let next: () -> Void

    var body: some View {
        StartQuestion("Your strength check") {
            VStack(spacing: 6) {
                Text("\(result.overall)").font(.display(84, weight: .heavy)).monospacedDigit()
                    .blur(radius: 18).accessibilityHidden(true)
                Text("Overall").font(.subheadline.weight(.semibold)).foregroundStyle(Color.inkMuted)
                    .blur(radius: 5).accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 170)
            .background(Color.fill, in: .rect(cornerRadius: 20))
            .clipShape(.rect(cornerRadius: 20))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Overall score, hidden")
            ForEach(StrengthCheck.lifts.map(\.slug).filter { result.scores[$0] != nil }, id: \.self) { slug in
                row(slug, score: result.scores[slug] ?? 0, clear: slug == result.weakest)
            }
            Text("This is the lift your plan makes a goal, and builds toward.")
                .font(.subheadline).foregroundStyle(Color.inkMuted).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
        }
        .safeAreaBar(edge: .bottom) { StartBar(title: "Build My Plan", id: "start.build", action: next) }
    }

    private func row(_ slug: String, score: Int, clear: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(StrengthCheck.name(slug)).font(.headline)
                if clear { Text("Your weakest lift").font(.subheadline).foregroundStyle(Plate.current.mark) }
            }
            Spacer()
            Text("\(score)").font(.display(30, weight: .bold)).monospacedDigit()
                .blur(radius: clear ? 0 : 12)
                .accessibilityHidden(!clear)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, minHeight: 68)
        .background(Color.fill, in: .rect(cornerRadius: 16))
        .clipShape(.rect(cornerRadius: 16))
        .overlay { if clear { RoundedRectangle(cornerRadius: 16).strokeBorder(Plate.current.mark, lineWidth: 2) } }
        .accessibilityElement(children: clear ? .combine : .ignore)
        .accessibilityLabel(clear ? "\(StrengthCheck.name(slug)), \(score), your weakest lift" : "\(StrengthCheck.name(slug)), score hidden")
        .accessibilityIdentifier(clear ? "start.weakest" : "start.blurred")
    }
}

/// Screen 22: the profile and the program are saved here; the checklist moves on once that's done.
struct SetupStep: View {
    let weakest: String?
    var failure: String?
    let work: () throws -> Void
    let done: () -> Void
    @State private var ready = false
    @State private var error: String?

    var body: some View {
        if let error {
            VStack(spacing: 16) {
                Spacer()
                Text("Couldn’t set up your plan").font(.display(28))
                Text(error).font(.body).foregroundStyle(Color.inkMuted).multilineTextAlignment(.center)
                Spacer()
                StartBar(title: "Try Again") { attempt() }
            }
            .padding(.horizontal, 24)
        } else {
            Checklist(title: "Setting everything up for you",
                      lines: ["Building your weekly split"] + (weakest.map { ["Targeting your \(StrengthCheck.name($0).lowercased())"] } ?? [])
                        + ["Writing your first weeks"],
                      ready: ready, done: done)
                .task { attempt() }
        }
    }

    /// Once more on a failure, then the truth and Try Again: never a plan that isn't there.
    private func attempt() {
        Funnel.track(.planStarted)
        error = nil
        do {
            try work()
        } catch {
            do { try work() } catch {
                Funnel.track(.planFailed)
                self.error = "Something went wrong saving it on this phone. Try again."
                return
            }
        }
        ready = true
        Funnel.track(.planCompleted)
    }
}

/// Screen 23: the plan, with week one's sessions as a teaser.
struct PlanReadyStep: View {
    @Query private var templates: [Template]
    let name: String
    let program: ReadyProgram
    let days: Int
    let weakest: String?
    let next: () -> Void

    var body: some View {
        let names = Dictionary(templates.map { ($0.slug, $0.name) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        let sessions = program.sessions.filter { seen.insert($0.name).inserted }
        StartQuestion(name.isEmpty ? "Your \(program.weeks)-week plan is ready" : "\(name), your \(program.weeks)-week plan is ready") {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(program.name).font(.title3.weight(.bold))
                    Text("\(days) days a week · about \(program.minutes) min a session").font(.subheadline).foregroundStyle(Color.inkMuted)
                    if let weakest {
                        Label("Built around your \(StrengthCheck.name(weakest).lowercased())", systemImage: "scope")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Plate.current.mark).padding(.top, 6)
                    }
                }
                Divider()
                Text("WEEK 1").font(.footnote.weight(.semibold)).tracking(0.4).foregroundStyle(Color.inkMuted)
                ForEach(sessions.prefix(days), id: \.name) { session in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.name).font(.headline)
                        Text(session.exercises.prefix(3).compactMap { $0.choices.first.map { names[$0] ?? $0 } }.joined(separator: " · "))
                            .font(.subheadline).foregroundStyle(Color.inkMuted).lineLimit(1)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.fill, in: .rect(cornerRadius: 20))
        }
        .safeAreaBar(edge: .bottom) { StartBar(title: "See My Plan", id: "start.seePlan", action: next) }
    }
}
