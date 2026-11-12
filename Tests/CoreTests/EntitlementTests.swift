import Foundation
import Testing
@testable import AICoach

/// FIT-437: who has Lifter Pro and who has Coach Pro, from the App Store, the server's plan and gifts.
struct EntitlementTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var later: Date { now.addingTimeInterval(30 * 86_400) }
    var earlier: Date { now.addingTimeInterval(-86_400) }

    private func access(_ store: [StoreEntitlement], lifter: Bool = false, coach: Bool = false, gift: Date? = nil) -> Access {
        Access.of(store: store, serverLifter: lifter, serverCoach: coach, giftUntil: gift, now: now)
    }

    @Test func theFourProductsAreTwoPlans() {
        #expect(StoreProducts.plan(of: "com.maxwellkendall.aicoach.pro.monthly") == .lifter)
        #expect(StoreProducts.plan(of: "com.maxwellkendall.aicoach.pro.yearly") == .lifter)
        #expect(StoreProducts.plan(of: "com.maxwellkendall.aicoach.coach.monthly") == .coach)
        #expect(StoreProducts.plan(of: "com.maxwellkendall.aicoach.coach.yearly") == .coach)
        #expect(StoreProducts.plan(of: "com.example.other") == nil)
        #expect(StoreProducts.all.count == 4)
    }

    /// The products match what `npm run release` sets up (appstore/subscriptions.json) and the StoreKit config.
    @Test func theProductsMatchSubscriptionsJSONAndTheStoreKitConfig() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let json = try String(contentsOf: root.appending(path: "appstore/subscriptions.json"), encoding: .utf8)
        let storekit = try String(contentsOf: root.appending(path: "AICoach.storekit"), encoding: .utf8)
        for id in StoreProducts.all {
            #expect(json.contains("\"\(id)\""))
            #expect(storekit.contains("\"\(id)\""))
        }
    }

    @Test func lifterProAndCoachProAreSeparate() {
        let lifter = access([StoreEntitlement(productID: StoreProducts.lifterYearly, expires: later)])
        #expect(lifter.lifter && !lifter.coach)
        let coach = access([StoreEntitlement(productID: StoreProducts.coachMonthly, expires: later)])
        #expect(coach.coach && !coach.lifter)
        let both = access([StoreEntitlement(productID: StoreProducts.lifterMonthly, expires: later),
                           StoreEntitlement(productID: StoreProducts.coachYearly, expires: later)])
        #expect(both.lifter && both.coach)
        #expect(access([]) == Access())
    }

    @Test func aTrialIsLifterProUntilItEnds() {
        let trial = access([StoreEntitlement(productID: StoreProducts.lifterYearly, expires: later, trial: true)])
        #expect(trial.lifter)
        #expect(trial.trialEnds == later)
        let paid = access([StoreEntitlement(productID: StoreProducts.lifterYearly, expires: later)])
        #expect(paid.trialEnds == nil)
    }

    @Test func anExpiredOrRevokedSubscriptionIsNotPro() {
        #expect(!access([StoreEntitlement(productID: StoreProducts.lifterMonthly, expires: earlier)]).lifter)
        #expect(!access([StoreEntitlement(productID: StoreProducts.coachMonthly, expires: earlier)]).coach)
        #expect(!access([StoreEntitlement(productID: StoreProducts.lifterMonthly, expires: later, revoked: true)]).lifter)
        #expect(!access([StoreEntitlement(productID: StoreProducts.coachYearly, expires: later, revoked: true)]).coach)
        // An expired trial says nothing about when a trial ends.
        #expect(access([StoreEntitlement(productID: StoreProducts.lifterYearly, expires: earlier, trial: true)]).trialEnds == nil)
    }

    /// The server's plan is either store's: Stripe on the web, or the App Store on another device or Apple Account.
    @Test func theServersPlanCountsForItsOwnPlanOnly() {
        let web = access([], lifter: true)
        #expect(web.lifter && !web.coach && !web.lifterInStore)
        let coach = access([], coach: true)
        #expect(coach.coach && !coach.lifter)
    }

    /// FIT-122: a gift is Lifter Pro while it lasts, never Coach Pro.
    @Test func aGiftIsLifterProUntilItEnds() {
        let gift = access([], gift: later)
        #expect(gift.lifter && !gift.coach)
        #expect(!access([], gift: earlier).lifter)
    }

    @Test func theServersCoachPlanIsKeptAcrossLaunches() async {
        await MainActor.run {
            let pro = Pro()
            let before = pro.serverCoachPro
            defer { pro.setServerPlan(.coach, before, source: nil) }
            pro.setServerPlan(.coach, true, source: "stripe")
            #expect(Pro().serverCoachPro)
            #expect(pro.sources[.coach] == "stripe")
            #expect(!pro.inAppStore(.coach))
            pro.setServerPlan(.coach, true, source: "appstore")
            #expect(pro.inAppStore(.coach))
            pro.setServerPlan(.coach, false, source: "appstore")
            #expect(pro.sources[.coach] == nil)
        }
    }

    // MARK: The paywall's words

    @Test func thePaywallSaysHowItRenews() {
        let terms = PaywallView.renewalTerms(plan: .lifter, price: "$39.99/year", trial: PaywallView.adjective(value: 2, unit: .week))
        #expect(terms.hasPrefix("After the 2-week free trial, Lifter Pro is $39.99/year."))
        #expect(terms.contains("renews automatically until cancelled"))
        #expect(terms.contains("24 hours before renewal"))
        let coach = PaywallView.renewalTerms(plan: .coach, price: "$19.99/month", trial: nil)
        #expect(coach.hasPrefix("Coach Pro is $19.99/month."))
    }

    @Test func periodsAreSaidInWords() {
        #expect(PaywallView.unit(.month, value: 1) == "month")
        #expect(PaywallView.unit(.year, value: 1) == "year")
        #expect(PaywallView.length(value: 2, unit: .week) == "2 weeks")
        #expect(PaywallView.length(value: 1, unit: .month) == "1 month")
        #expect(PaywallView.days(value: 2, unit: .week) == StoreProducts.trialDays)
    }

    /// No invented numbers: each plan says what it adds, and what stays free.
    @Test func eachPlanSaysWhatItAdds() {
        #expect(!PaywallView.benefits(.lifter).isEmpty)
        #expect(!PaywallView.benefits(.coach).isEmpty)
        #expect(PaywallView.stillFree(.coach).contains("free"))
        #expect(PaywallView.stillFree(.lifter).contains("free"))
    }
}
