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

}
