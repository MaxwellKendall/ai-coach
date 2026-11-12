import Foundation
import StoreKit
import StoreKitTest
import Testing
@testable import AICoach

/// Whether SKTestSession drives StoreKit in this run: its own test purchase goes through.
@MainActor func storeKitTestingIsOn() async -> Bool {
    guard let session = try? SKTestSession(configurationFileNamed: "AICoach") else { return false }
    session.disableDialogs = true
    defer { session.clearTransactions() }
    return (try? await session.buyProduct(identifier: StoreProducts.coachMonthly)) != nil
}

/// FIT-437: buying, restoring, lapsing and cancelling Lifter Pro and Coach Pro against AICoach.storekit, through
/// StoreKit's own test session (no App Store, no money). Serialized: there's one StoreKit test environment.
///
/// They run from Xcode (Product › Test). A command-line `xcodebuild test` here doesn't turn StoreKit testing on:
/// storekitd answers that the app "is not installed for development", whatever the scheme's StoreKit setting, and
/// SKTestSession's calls fail `notEntitled` without reaching the App Store. Then the suite is skipped, rather than
/// falling through to the sandbox (where AppStore.sync waits for an Apple Account sign-in).
@MainActor
@Suite(.serialized, .enabled("StoreKit testing is on (run from Xcode)") { await storeKitTestingIsOn() })
struct StoreKitTests {

    let session: SKTestSession

    init() throws {
        session = try SKTestSession(configurationFileNamed: "AICoach")
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        session.askToBuyEnabled = false
    }

    private func access() async -> Access {
        Access.of(store: await Pro.storeEntitlements(), serverLifter: false, serverCoach: false, giftUntil: nil)
    }

    @Test func theFourProductsLoadWithTheirPricesAndTrial() async throws {
        let products = try await Product.products(for: StoreProducts.all)
        #expect(Set(products.map(\.id)) == Set(StoreProducts.all))
        let price = Dictionary(uniqueKeysWithValues: products.map { ($0.id, $0.price) })
        #expect(price[StoreProducts.lifterMonthly] == Decimal(string: "5.99"))
        #expect(price[StoreProducts.lifterYearly] == Decimal(string: "39.99"))
        #expect(price[StoreProducts.coachMonthly] == Decimal(string: "19.99"))
        #expect(price[StoreProducts.coachYearly] == Decimal(199))
        for product in products {
            let trial = product.subscription?.introductoryOffer
            if StoreProducts.plan(of: product.id) == .lifter {
                #expect(trial?.paymentMode == .freeTrial)
                #expect(trial.map { PaywallView.days($0.period) } == StoreProducts.trialDays)
            } else {
                #expect(trial == nil)
            }
        }
        // Two groups, so one Apple Account can hold both plans.
        let groups = Set(products.compactMap(\.subscription?.subscriptionGroupID))
        #expect(groups.count == 2)
    }

    @Test(arguments: [StoreProducts.Plan.lifter, .coach])
    func buyingAPlanGivesThatPlanOnly(_ plan: StoreProducts.Plan) async throws {
        let account = UUID()
        let transaction = try await session.buyProduct(identifier: plan.monthly, options: [.appAccountToken(account)])
        // The server finds the account from it (infra/lambda/appStore.ts).
        #expect(transaction.appAccountToken == account)
        let access = await access()
        #expect(access.lifter == (plan == .lifter))
        #expect(access.coach == (plan == .coach))
        // Lifter Pro starts with its free trial; Coach Pro has none.
        #expect((access.trialEnds != nil) == (plan == .lifter))
    }

    @Test func oneAppleAccountCanHoldBothPlans() async throws {
        _ = try await session.buyProduct(identifier: StoreProducts.lifterYearly)
        _ = try await session.buyProduct(identifier: StoreProducts.coachYearly)
        let access = await access()
        #expect(access.lifter && access.coach)
        // Lapsing one leaves the other.
        try session.expireSubscription(productIdentifier: StoreProducts.coachYearly)
        let after = await self.access()
        #expect(after.lifter && !after.coach)
    }

    @Test(arguments: [StoreProducts.Plan.lifter, .coach])
    func restoringBringsThePlanBack(_ plan: StoreProducts.Plan) async throws {
        _ = try await session.buyProduct(identifier: plan.yearly)
        try await AppStore.sync()
        let access = await access()
        #expect(plan == .lifter ? access.lifter : access.coach)
    }

    @Test func restoringWithNothingBoughtGivesNothing() async throws {
        let pro = Pro()
        try await pro.restore()
        #expect(!pro.access.lifter && !pro.access.coach)
    }

    @Test(arguments: [StoreProducts.Plan.lifter, .coach])
    func aLapsedPlanEnds(_ plan: StoreProducts.Plan) async throws {
        _ = try await session.buyProduct(identifier: plan.monthly)
        try session.expireSubscription(productIdentifier: plan.monthly)
        let access = await access()
        #expect(!access.lifter && !access.coach)
    }

    /// Cancelling turns off renewal and keeps the plan to the end of what's paid; a refund ends it at once.
    @Test(arguments: [StoreProducts.Plan.lifter, .coach])
    func cancellingKeepsThePlanUntilItEndsAndARefundEndsIt(_ plan: StoreProducts.Plan) async throws {
        let transaction = try await session.buyProduct(identifier: plan.monthly)
        try session.disableAutoRenewForTransaction(identifier: UInt(transaction.id))
        let status = try #require(await Product.products(for: [plan.monthly]).first?.subscription?.status.first)
        guard case .verified(let renewal) = status.renewalInfo else { Issue.record("Unverified renewal info"); return }
        #expect(!renewal.willAutoRenew)
        let cancelled = await access()
        #expect(plan == .lifter ? cancelled.lifter : cancelled.coach)

        try session.refundTransaction(identifier: UInt(transaction.id))
        let refunded = await access()
        #expect(!refunded.lifter && !refunded.coach)
    }
}
