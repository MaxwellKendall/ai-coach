import SwiftUI
import StoreKit

/// FIT-83, FIT-120, FIT-437: a plan's offer. Lifter Pro, where a lifter training themselves starts a program (AI-designed
/// weeks, FIT-426); Coach Pro, where a coach reaches coaching from Claude (the exhaustive MCP, FIT-284). Each shows
/// what the plan adds, the App Store's monthly and yearly prices, the free trial when there is one, the auto-renew
/// terms, Restore Purchases, and the terms and privacy links App Review asks for (guideline 3.1.2). With the plan
/// already, it's how to manage it: Apple's sheet for the App Store's, the web's Billing for Stripe's.
struct PaywallView: View {
    let plan: StoreProducts.Plan
    @Environment(Pro.self) private var pro
    @Environment(Account.self) private var account
    @Environment(\.dismiss) private var dismiss
    @Environment(\.purchase) private var purchase
    @State private var products: [Product] = []
    @State private var loaded = false
    @State private var selected = ""
    @State private var trialEligible = false
    @State private var working = false
    @State private var message: String?
    @State private var signingIn = false
    @State private var managing = false

    private var product: Product? { products.first { $0.id == selected } ?? products.first }
    /// The selected product's free trial, while this Apple Account can still have it.
    private var trial: Product.SubscriptionOffer? {
        guard plan.hasTrial, trialEligible, let offer = product?.subscription?.introductoryOffer, offer.paymentMode == .freeTrial else { return nil }
        return offer
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(Self.benefits(plan), id: \.title) { benefit in row(benefit) }
                    }
                    Text(Self.stillFree(plan)).font(.footnote).foregroundStyle(Color.inkMuted)
                    if pro.has(plan) {
                        subscribed
                    } else {
                        offer
                    }
                    footer
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .screenBackground()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(pro.has(plan) ? "Done" : "Not Now") { dismiss() }.accessibilityIdentifier("paywall.close")
                }
            }
        }
        .accessibilityIdentifier("paywall.\(plan.rawValue)")
        .task { await load() }
        .sheet(isPresented: $signingIn) {
            SignInSheet(reason: "Sign in first, so \(plan.name) is on your account: in the app, on the web and in Claude.")
                .presentationDetents([.medium])
        }
        .manageSubscriptionsSheet(isPresented: $managing)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(plan.name).font(.display(34, weight: .bold)).tracking(-0.4)
            Text(plan == .lifter ? "Your training, planned by AI from what you lift." : "Your roster, coached from Claude.")
                .font(.title3).foregroundStyle(.secondary)
        }
        .padding(.top, 16)
    }

    // MARK: The offer

    @ViewBuilder private var offer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !loaded {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            } else if products.isEmpty {
                Text("The App Store isn't answering. Check your connection and try again.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("Try Again") { Task { await load() } }
            } else {
                ForEach(products) { product in option(product) }
                if let trial, let product {
                    timeline(trial, product)
                }
                buy
                Text(terms).font(.footnote).foregroundStyle(Color.inkMuted).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("paywall.terms.renewal")
            }
            if let message {
                Text(message).font(.footnote).foregroundStyle(.red).accessibilityIdentifier("paywall.message")
            }
        }
    }

    private func option(_ product: Product) -> some View {
        let on = product.id == self.product?.id
        let yearly = product.id == plan.yearly
        return Button { withAnimation(.tap) { selected = product.id } } label: {
            HStack(spacing: 14) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.title2)
                    .foregroundStyle(on ? Color.primary : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(yearly ? "Yearly" : "Monthly").font(.headline)
                    if plan.hasTrial, trialEligible, let offer = product.subscription?.introductoryOffer, offer.paymentMode == .freeTrial {
                        Text("\(Self.length(offer.period)) free").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(Self.price(product)).font(.headline).monospacedDigit()
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(Color.fill, in: .rect(cornerRadius: 18))
            .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(on ? Color.primary : .clear, lineWidth: 2) }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(yearly ? "paywall.yearly" : "paywall.monthly")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Blinkist's trial timeline: no surprise on the day it's billed.
    private func timeline(_ trial: Product.SubscriptionOffer, _ product: Product) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Self.timeline(trialDays: Self.days(trial.period), plan: plan.name, price: Self.price(product)), id: \.day) { step in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(step.day).font(.subheadline.weight(.semibold)).frame(width: 64, alignment: .leading)
                    Text(step.what).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .background(Color.fill, in: .rect(cornerRadius: 18))
    }

    private var buy: some View {
        Button {
            if account.user == nil, account.isAvailable { signingIn = true } else if let product { Task { await buy(product) } }
        } label: {
            Group {
                if working { ProgressView() } else { Text(buyTitle) }
            }
            .font(.headline).frame(maxWidth: .infinity, minHeight: 54)
        }
        .buttonStyle(.primary)
        .disabled(working || product == nil)
        .accessibilityIdentifier("paywall.buy")
    }

    private var buyTitle: String {
        if account.user == nil, account.isAvailable { return "Sign In to Subscribe" }
        return trial.map { "Try Free for \(Self.length($0.period).capitalized)" } ?? "Subscribe"
    }

    private var terms: String {
        guard let product else { return "" }
        return Self.renewalTerms(plan: plan, price: Self.price(product), trial: trial.map { Self.adjective(value: $0.period.value, unit: $0.period.unit) })
    }

    // MARK: With the plan

    private var subscribed: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("You have \(plan.name)", systemImage: "checkmark.seal.fill").font(.headline)
            if plan == .coach {
                Link(destination: Backend.current.web.appending(path: "claude")) {
                    Text("Connect Claude").font(.headline).frame(maxWidth: .infinity, minHeight: 54)
                }
                .buttonStyle(.primary)
                .accessibilityIdentifier("paywall.connect")
                Text("Connect with the same sign-in as this app, so Claude has your clients.")
                    .font(.footnote).foregroundStyle(Color.inkMuted)
            }
            if pro.inAppStore(plan) {
                Button("Manage Subscription") { managing = true }.accessibilityIdentifier("paywall.manage")
            } else if pro.sources[plan] == "stripe" {
                // Bought on the web (Stripe): managed there.
                Link("Manage on the Web", destination: Backend.current.web.appending(path: "billing"))
                    .accessibilityIdentifier("paywall.manage")
            }
        }
    }

    // MARK: Restore and the links

    private var footer: some View {
        VStack(spacing: 14) {
            Button("Restore Purchases") { Task { await restore() } }
                .disabled(working)
                .accessibilityIdentifier("paywall.restore")
            HStack(spacing: 20) {
                Link("Terms of Use", destination: StoreProducts.terms).accessibilityIdentifier("paywall.terms")
                Link("Privacy Policy", destination: StoreProducts.privacy).accessibilityIdentifier("paywall.privacy")
            }
        }
        .font(.subheadline)
        .tint(.primary)
        .frame(maxWidth: .infinity)
    }

    // MARK: Doing

    private func load() async {
        loaded = false
        let found = (try? await Product.products(for: plan.products)) ?? []
        // Yearly first, as on the web.
        products = found.sorted { a, _ in a.id == plan.yearly }
        if selected.isEmpty { selected = plan.yearly }
        loaded = true
        // The prices first; whether the trial is still there can take the App Store a moment.
        #if DEBUG
        // `-trialEligible YES`: a new Apple Account's paywall, without asking an App Store with no one signed in
        // (the review screenshot, PaywallScreenshotUITests).
        if UserDefaults.standard.bool(forKey: "trialEligible") { trialEligible = plan.hasTrial; return }
        #endif
        if plan.hasTrial, let subscription = products.first?.subscription {
            trialEligible = await subscription.isEligibleForIntroOffer
            pro.trialEligible = trialEligible
        }
    }

    private func buy(_ product: Product) async {
        working = true
        message = nil
        defer { working = false }
        do {
            switch try await pro.buy(product, with: purchase) {
            case .bought: dismiss()
            case .pending: message = "Waiting for approval. \(plan.name) starts as soon as it's approved."
            case .cancelled: break
            }
        } catch {
            message = error.localizedDescription
        }
    }

    private func restore() async {
        working = true
        message = nil
        defer { working = false }
        do {
            try await pro.restore()
            if pro.has(plan) { dismiss() } else { message = "No \(plan.name) subscription to restore on this Apple Account." }
        } catch {
            message = error.localizedDescription
        }
    }

    private func row(_ benefit: (symbol: String, title: String, detail: String)) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Image(systemName: benefit.symbol).font(.body.weight(.semibold)).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(benefit.title).font(.body.weight(.semibold))
                Text(benefit.detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Words

    /// What the plan adds, as the web's Billing says it (web/src/billing.ts).
    nonisolated static func benefits(_ plan: StoreProducts.Plan) -> [(symbol: String, title: String, detail: String)] {
        switch plan {
        case .lifter:
            [("figure.strengthtraining.traditional", "Weeks designed for you",
              "Each week's sessions, sets and weights, planned by AI from what you logged the week before."),
             ("bubble.left.and.text.bubble.right", "Plan from Claude",
              "Connect Claude to plan and change your training and review your week.")]
        case .coach:
            [("person.3", "Your whole roster in Claude",
              "Claude can program and review every client's training through the Barbrabell connector."),
             ("calendar", "Weeks you check first",
              "Ask Claude for a client's next week; nothing changes until you agree to it.")]
        }
    }

    nonisolated static func stillFree(_ plan: StoreProducts.Plan) -> String {
        plan == .lifter
            ? "Without it, your program's weeks are still planned for you, and logging and progress stay free."
            : "Coaching in the app and on the web stays free, with any number of clients."
    }

    /// "$39.99/year".
    static func price(_ product: Product) -> String {
        guard let period = product.subscription?.subscriptionPeriod else { return product.displayPrice }
        return "\(product.displayPrice)/\(unit(period.unit, value: period.value))"
    }

    nonisolated static func unit(_ unit: Product.SubscriptionPeriod.Unit, value: Int) -> String {
        let name = switch unit {
        case .day: "day"
        case .week: "week"
        case .month: "month"
        case .year: "year"
        @unknown default: "period"
        }
        return value == 1 ? name : "\(value) \(name)s"
    }

    /// "2 weeks", "14 days".
    nonisolated static func length(_ period: Product.SubscriptionPeriod) -> String { length(value: period.value, unit: period.unit) }
    nonisolated static func length(value: Int, unit: Product.SubscriptionPeriod.Unit) -> String {
        value == 1 ? "1 \(Self.unit(unit, value: 1))" : Self.unit(unit, value: value)
    }

    /// "2-week", as in "the 2-week free trial".
    nonisolated static func adjective(value: Int, unit: Product.SubscriptionPeriod.Unit) -> String {
        "\(value)-\(Self.unit(unit, value: 1))"
    }

    nonisolated static func days(_ period: Product.SubscriptionPeriod) -> Int { days(value: period.value, unit: period.unit) }
    nonisolated static func days(value: Int, unit: Product.SubscriptionPeriod.Unit) -> Int {
        switch unit {
        case .day: value
        case .week: value * 7
        case .month: value * 30
        case .year: value * 365
        @unknown default: StoreProducts.trialDays
        }
    }

    /// Auto-renewal said plainly, as App Review asks (guideline 3.1.2).
    nonisolated static func renewalTerms(plan: StoreProducts.Plan, price: String, trial: String?) -> String {
        let start = trial.map { "After the \($0) free trial, \(plan.name) is \(price)." } ?? "\(plan.name) is \(price)."
        return "\(start) It renews automatically until cancelled; cancel at least 24 hours before renewal in Settings › Apple Account › Subscriptions. Payment is charged to your Apple Account."
    }

    /// What happens on each day of the free trial.
    nonisolated static func timeline(trialDays: Int, plan: String = "Lifter Pro", price: String = "the plan's price") -> [(day: String, what: String)] {
        [("Today", "Your weeks start being designed for you."),
         ("Day \(trialDays - 2)", "A reminder that the trial is ending."),
         ("Day \(trialDays)", "\(plan) begins at \(price). Cancel any time before, in Settings.")]
    }
}
