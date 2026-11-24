import Foundation
import Testing
@testable import AICoach

/// TKL-466: the first launch's funnel events (shared/funnel.ts on the server).
@MainActor
struct FunnelTests {
    /// The server keeps only these screen ids (shared/funnel.ts SCREENS); anything else is dropped there.
    static let serverScreens: Set<String> = [
        "hero", "goal", "gender", "comparison_chart", "age", "height", "weight", "frequency", "body_type", "activity_level",
        "where_train", "equipment", "holding_back", "name", "strength_invite", "strength_steps", "select_lifts", "enter_lifts",
        "analysis", "results", "setup", "plan_ready", "paywall",
    ]

    @Test func everyStartScreenHasItsOwnServerScreenId() {
        let screens = StartFlow.Step.allCases.map(\.screen)
        #expect(Set(screens).count == screens.count)
        #expect(Set(screens).isSubset(of: Self.serverScreens))
        #expect(StartFlow.Step.goal.screen == "goal")
        #expect(StartFlow.Step.ready.screen == "plan_ready")
    }

    @Test func productsGoByTheirFunnelNames() {
        #expect(StoreProducts.funnelName(StoreProducts.lifterYearly) == "lifter_yearly")
        #expect(StoreProducts.funnelName(StoreProducts.lifterMonthly) == "lifter_monthly")
        #expect(StoreProducts.funnelName(StoreProducts.coachYearly) == "coach_yearly")
        #expect(StoreProducts.funnelName(StoreProducts.coachMonthly) == "coach_monthly")
        #expect(StoreProducts.funnelName("something.else") == nil)
    }

    @Test func theQueueKeepsTheNewestHundred() {
        var queue: [Funnel.Event] = []
        for index in 0..<120 { queue = Funnel.enqueue(Funnel.Event(name: "paywall_viewed", detail: "\(index)"), to: queue) }
        #expect(queue.count == Funnel.maxQueued)
        #expect(queue.first?.detail == "20")
        #expect(queue.last?.detail == "119")
    }

    @Test func anUnsentHeroSurvivesQueueOverflow() {
        let hero = Funnel.Event(name: Funnel.Name.screenViewed.rawValue, detail: "hero")
        var queue = [hero]
        for index in 0..<120 {
            queue = Funnel.enqueue(Funnel.Event(name: "paywall_viewed", detail: "\(index)"), to: queue)
        }
        #expect(queue.count == Funnel.maxQueued)
        #expect(queue.first == hero)
    }

    @Test func theBatchCarriesTheInstallTheStrategyAndNoDetailWhenThereIsNone() throws {
        let batch = Funnel.Batch(install: "3F2504E0-4F89-41D3-9A0C-0305E82C3301", strategy: "hard", app: "1.0 (26)",
                                 events: [Funnel.Event(name: Funnel.Name.paywallViewed.rawValue),
                                          Funnel.Event(name: Funnel.Name.screenViewed.rawValue, detail: "hero")])
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(batch)) as? [String: Any])
        #expect(json["install"] as? String == "3F2504E0-4F89-41D3-9A0C-0305E82C3301")
        #expect(json["strategy"] as? String == "hard")
        let events = try #require(json["events"] as? [[String: Any]])
        #expect(events[0].keys.sorted() == ["name"])
        #expect(events[1]["name"] as? String == "onboarding_screen_viewed")
        #expect(events[1]["detail"] as? String == "hero")
    }

    @Test func theInstallIdStaysTheSameAndIsAUUID() {
        let defaults = UserDefaults(suiteName: "FunnelTests")!
        defaults.removePersistentDomain(forName: "FunnelTests")
        let first = Funnel.install(in: defaults)
        #expect(UUID(uuidString: first) != nil)
        #expect(Funnel.install(in: defaults) == first)
    }

    // MARK: Verify findings (TKL-466 round 2)

    /// The server's question ids (shared/funnel.ts QUESTIONS): answering says which, never what.
    static let serverQuestions: Set<String> = [
        "goal", "gender", "age", "height", "weight", "frequency", "body_type", "activity_level", "where_train", "equipment",
        "holding_back", "name", "select_lifts", "enter_lifts",
    ]

    @Test func everyQuestionScreenReportsItsAnswerByIdOnly() {
        let asked = StartFlow.Step.allCases.filter(\.isQuestion).map(\.screen)
        #expect(Set(asked) == Self.serverQuestions)
        #expect(!StartFlow.Step.chart.isQuestion && !StartFlow.Step.paywall.isQuestion)
    }

    @Test func theNameCountsAsAnsweredOnlyWhenOneWasGiven() {
        #expect(Funnel.answered(.name, name: "  ") == nil)
        #expect(Funnel.answered(.name, name: "Sam") == Funnel.Event(name: Funnel.Name.answerSubmitted.rawValue, detail: "name"))
        #expect(Funnel.answered(.age, name: "") == Funnel.Event(name: Funnel.Name.answerSubmitted.rawValue, detail: "age"))
        #expect(Funnel.answered(.chart, name: "Sam") == nil)
    }

    @Test func theCohortsStrategyIsTheOneTheFirstLaunchRanWith() {
        let defaults = UserDefaults(suiteName: "FunnelCohortTests")!
        defaults.removePersistentDomain(forName: "FunnelCohortTests")
        // An offline first launch runs freemium; a later launch's switch says hard. The queue still goes as freemium.
        #expect(Funnel.cohort(in: defaults, current: .freemium) == "freemium")
        #expect(Funnel.cohort(in: defaults, current: .hard) == "freemium")
    }

    @Test func aTrialIsSentAsATrialThenItsFirstPaidRenewalAsPaidOnce() {
        let watch = Funnel.Watch(product: StoreProducts.lifterYearly)
        let (inTrial, trialEvent) = Funnel.observe(watch, productID: StoreProducts.lifterYearly, product: "lifter_yearly",
                                                   originalID: 7, trial: true, jws: "t.r.ial")
        #expect(trialEvent == Funnel.Event(name: Funnel.Name.trialStarted.rawValue, detail: "lifter_yearly", jws: "t.r.ial"))
        // The same trial seen again at the next launch: nothing more.
        #expect(Funnel.observe(inTrial, productID: StoreProducts.lifterYearly, product: "lifter_yearly", originalID: 7, trial: true, jws: "t.r.ial").1 == nil)
        let (paid, paidEvent) = Funnel.observe(inTrial, productID: StoreProducts.lifterYearly, product: "lifter_yearly",
                                               originalID: 7, trial: false, jws: "p.a.id")
        #expect(paidEvent == Funnel.Event(name: Funnel.Name.purchaseCompleted.rawValue, detail: "lifter_yearly", jws: "p.a.id"))
        #expect(Funnel.observe(paid, productID: StoreProducts.lifterYearly, product: "lifter_yearly", originalID: 7, trial: false, jws: "p.a.id2").1 == nil)
        // Another subscription (a different original transaction) is never this purchase's.
        #expect(Funnel.observe(inTrial, productID: StoreProducts.lifterYearly, product: "lifter_yearly", originalID: 8, trial: false, jws: "x").1 == nil)
    }

    @Test func aPendingPurchaseIsCreditedWhenApproved() {
        // Ask to Buy: nothing is known but the product until Transaction.updates brings the approval.
        let pending = Funnel.Watch(product: StoreProducts.lifterMonthly)
        #expect(Funnel.observe(pending, productID: StoreProducts.lifterYearly, product: "lifter_yearly", originalID: 9, trial: false, jws: "x").1 == nil)
        let (_, approved) = Funnel.observe(pending, productID: StoreProducts.lifterMonthly, product: "lifter_monthly",
                                           originalID: 9, trial: false, jws: "a.pp.roved")
        #expect(approved == Funnel.Event(name: Funnel.Name.purchaseCompleted.rawValue, detail: "lifter_monthly", jws: "a.pp.roved"))
    }
}
