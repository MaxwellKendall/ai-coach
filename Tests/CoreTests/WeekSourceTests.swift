import Foundation
import Testing
@testable import AICoach

/// FIT-422 and FIT-423: where a week's sessions come from, for each of the four modes.
@MainActor
struct WeekSourceTests {
    @Test func eachModeHasItsSource() {
        #expect(WeekSource.of(lifterPro: false, coached: false, hasProgram: true) == .code)
        #expect(WeekSource.of(lifterPro: true, coached: false, hasProgram: true) == .ai)
        #expect(WeekSource.of(lifterPro: false, coached: true, hasProgram: true) == .coach)
        // The app's AI stays out of a coach's weeks, Pro or not (author, 2026-11-11).
        #expect(WeekSource.of(lifterPro: true, coached: true, hasProgram: false) == .coach)
    }

    /// FIT-201: in the pilot, someone with no program of their own and no coach has nothing planned for them.
    @Test func noProgramPlansNothingInThePilot() {
        #expect(WeekSource.of(lifterPro: true, coached: false, hasProgram: false) == (Pilot.simple ? nil : .ai))
        #expect(WeekSource.coach.plansItself == false)
        #expect(WeekSource.code.plansItself && WeekSource.ai.plansItself)
    }

    /// Stripe's statuses that keep Pro match the server's HAS_PLAN.
    @Test func webProCountsWhileStripeStillHasThePlan() {
        #expect(["active", "trialing", "past_due"].allSatisfy(Cloud.hasPlan))
        #expect(!["none", "canceled", "unpaid", "incomplete", "incomplete_expired"].contains(where: Cloud.hasPlan))
    }

    /// A cold launch offline keeps the last answer: web Pro and the coaches are read from the phone, so the mode
    /// doesn't flicker to "no coach" or "free" before the server answers.
    @Test func theModeHoldsOnALaunchBeforeTheServerAnswers() {
        let before = Pro()
        let coaches = before.coaches
        let web = before.webPro
        defer {
            before.setCoaches(coaches)
            before.setWebPro(web)
        }
        before.setCoaches([])
        before.setWebPro(true)
        #expect(Pro().weekSource(hasProgram: true) == .ai)
        before.setCoaches([Cloud.Person(uid: "coach", name: "Sam", since: "2026-11-01")])
        #expect(Pro().weekSource(hasProgram: true) == .coach)
        before.setCoaches([])
        before.setWebPro(false)
        #expect(Pro().lifterPro == UserDefaults.standard.bool(forKey: "pro"))
    }
}
