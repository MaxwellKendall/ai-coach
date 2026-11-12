import Foundation

/// FIT-437: the App Store's two plans and their four products, the one place the app names them. They match
/// appstore/subscriptions.json (what `npm run release` sets up, FIT-386) and AICoach.storekit. Each plan is its own
/// subscription group, so one Apple Account can hold Lifter Pro and Coach Pro at once, and monthly and yearly switch
/// within a plan.
enum StoreProducts {
    enum Plan: String, CaseIterable, Identifiable, Sendable {
        /// AI planning for someone training themselves (FIT-422, FIT-426, FIT-327's connector gate).
        case lifter
        /// The exhaustive coach MCP (FIT-284); coaching itself is free.
        case coach

        var id: String { rawValue }
        var name: String { self == .lifter ? "Lifter Pro" : "Coach Pro" }
        var monthly: String { self == .lifter ? StoreProducts.lifterMonthly : StoreProducts.coachMonthly }
        var yearly: String { self == .lifter ? StoreProducts.lifterYearly : StoreProducts.coachYearly }
        var products: [String] { [yearly, monthly] }
        /// Only Lifter Pro has a free trial.
        var hasTrial: Bool { self == .lifter }
    }

    static let lifterMonthly = "com.maxwellkendall.aicoach.pro.monthly"
    static let lifterYearly = "com.maxwellkendall.aicoach.pro.yearly"
    static let coachMonthly = "com.maxwellkendall.aicoach.coach.monthly"
    static let coachYearly = "com.maxwellkendall.aicoach.coach.yearly"
    static let all = Plan.allCases.flatMap(\.products)

    /// Lifter Pro's free trial: 14 days, confirmed against the live catalog (FIT-437, 2026-11-12). The same length is in
    /// subscriptions.json and AICoach.storekit, and the paywall reads the App Store's offer when it has one.
    static let trialDays = 14

    /// The approved paywall copy's prices, shown only when StoreKit has no product to read them from.
    static let lifterYearlyFallback = "$39.99"
    static let lifterMonthlyFallback = "$5.99"
    static let lifterPerMonthFallback = "$3.33"

    static func plan(of productID: String) -> Plan? {
        Plan.allCases.first { $0.products.contains(productID) }
    }

    // App Review guideline 3.1.2: the terms and the privacy policy, on every paywall.
    static let terms = URL(string: "https://barbrabell.com/terms")!
    static let privacy = URL(string: "https://barbrabell.com/privacy")!
}
