import Foundation
import SwiftUI

/// TKL-846: Lifter Pro's AI planning a week on request, on this week's and next week's cards, with or without a
/// program. The first design and `Planner.redesignsPerWeek` redos a week, counted by `Plan.designs`; a free lifter is
/// offered Lifter Pro; a coach's week offers nothing.
enum WeekRedo: Equatable {
    /// A coach's week, or a card that doesn't offer AI planning.
    case hidden
    /// A free lifter: the button, with "Lifter Pro" under it. `designed` when the AI designed the week before.
    case upsell(designed: Bool)
    /// A week the AI hasn't designed yet.
    case plan
    case redo(left: Int)
    /// Three designs this week: no more.
    case capped
    /// The AI is designing the week now.
    case designing

    /// What a week's card offers. `offered` is whether the card offers AI planning at all: Lifter Pro sold, a lifter on
    /// their own, and a profile the AI can plan from.
    @MainActor
    static func state(plan: Plan?, lifterPro: Bool, offered: Bool, designing: Bool = false) -> WeekRedo {
        guard offered, plan.map(Planner.isCoached) != true else { return .hidden }
        let designs = plan?.designs ?? 0
        guard lifterPro else { return .upsell(designed: designs > 0) }
        if designing { return .designing }
        if designs == 0 { return .plan }
        return Planner.canRedesign(plan) ? .redo(left: 1 + Planner.redesignsPerWeek - designs) : .capped
    }

    /// Which week a card's AI action plans, or nil when the card is neither this week nor next.
    enum Target: Equatable { case thisWeek, nextWeek }

    /// The card's own week decides this, never the program's week index. The program deck clamps its current index
    /// to the last week of the program, so once the program is over that card still reads "This week" while the week
    /// it shows is in the past. Planning it spent one of the three paid redos on a week that was already over and
    /// left the real current week unplanned (verify, 2026-11-24). A card may only plan the week it shows.
    static func target(cardWeek: Date, now: Date = .now, calendar: Calendar = .current) -> Target? {
        let here = Week.start(of: now, calendar: calendar)
        let card = Week.start(of: cardWeek, calendar: calendar)
        switch calendar.dateComponents([.day], from: here, to: card).day ?? 0 {
        case 0: return .thisWeek
        case 7: return .nextWeek
        default: return nil
        }
    }

    private static func week(_ next: Bool) -> String { next ? "next week" : "this week" }
    /// "this week" or "for next week", after a count of redos.
    private static func whose(_ next: Bool) -> String { next ? "for next week" : "this week" }

    /// The button's title; nil when the card shows no button.
    @MainActor
    static func button(_ state: WeekRedo, next: Bool) -> String? {
        switch state {
        case .plan, .upsell(designed: false): "Plan \(week(next)) with AI"
        case .redo, .upsell(designed: true): "Redo \(week(next)) with AI"
        case .hidden, .capped, .designing: nil
        }
    }

    /// The line under the button, or in its place.
    @MainActor
    static func caption(_ state: WeekRedo, next: Bool) -> String? {
        switch state {
        case .hidden: nil
        case .upsell: "Lifter Pro"
        case .plan: "Then \(Planner.redesignsPerWeek) redos \(whose(next)) if you want changes"
        case .redo(let left): "\(left) \(left == 1 ? "redo" : "redos") left \(whose(next)) · logged days stay"
        case .capped: "No redos left \(whose(next)). \(1 + Planner.redesignsPerWeek) AI designs a week is the most; this one stays as planned."
        case .designing: "Redesigning \(week(next))… days you’ve logged stay as they are."
        }
    }

    /// The model failed or wasn't there: the week is as it was, and no redo was used.
    static let failed = "Couldn’t redo the week. It’s as it was."
}

/// TKL-846: a day being redesigned: a soft bar where its lifts will be, shimmering, a share of the row's width.
struct SkeletonLine: View {
    var width: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(paused: reduceMotion)) { timeline in
                let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2
                RoundedRectangle(cornerRadius: 8)
                    .fill(LinearGradient(colors: [.fill, .fillStrong, .fill],
                                         startPoint: UnitPoint(x: phase * 2 - 1, y: 0.5),
                                         endPoint: UnitPoint(x: phase * 2, y: 0.5)))
                    .frame(width: geometry.size.width * width)
            }
        }
        .frame(height: 18)
    }
}

/// TKL-846: the redesign under way, inline: a thin bar that eases toward the end while the model works. It has no real
/// fraction to show, so it never reaches it; the week landing replaces it.
struct RedoProgress: View {
    @State private var start = Date.now

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1)) { timeline in
            let seconds = timeline.date.timeIntervalSince(start)
            // Half way in ~6 s, 95% at most.
            let fraction = 0.05 + 0.9 * (1 - exp(-seconds / 9))
            GeometryReader { geometry in
                Capsule().fill(Color.fill)
                    .overlay(alignment: .leading) {
                        Capsule().fill(Plate.current.mark).frame(width: geometry.size.width * fraction)
                    }
            }
            .frame(height: 4)
        }
        .padding(.vertical, 6)
    }
}
