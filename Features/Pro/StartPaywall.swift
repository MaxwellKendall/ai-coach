import SwiftUI
import StoreKit

/// FIT-456: the paywall at the end of the first launch (spec screen 24). Lifter Pro yearly is picked, monthly is the
/// other choice, and Coach Pro is a row of its own. In hard mode there's no way past it but a plan: no close button, no
/// Free. In freemium (FIT-454's switch) Not Now opens the free app.
/// Guideline 3.1.2: the App Store's real prices, a savings badge worked out from them, the trial only when this Apple
/// Account can have it, the renewal terms always on screen, Restore Purchases, Terms of Use and the Privacy Policy.
/// No sign-in: the purchase is the Apple Account's, and signing in later registers it to an account (`Pro.signedIn`).
struct StartPaywall: View {
    let name: String
    var onDone: () -> Void
    @Environment(Pro.self) private var pro
    @Environment(\.purchase) private var purchase
    @State private var products: [Product] = []
    @State private var coachProducts: [Product] = []
    @State private var loaded = false
    @State private var selected = StoreProducts.lifterYearly
    @State private var trialEligible = false
    @State private var working = false
    @State private var message: String?
    @State private var coach = false

    private let plan = StoreProducts.Plan.lifter
    private var yearly: Product? { products.first { $0.id == plan.yearly } }
    private var monthly: Product? { products.first { $0.id == plan.monthly } }
    private var product: Product? { products.first { $0.id == selected } }
    private var trialDays: Int? {
        guard trialEligible, let offer = product?.subscription?.introductoryOffer, offer.paymentMode == .freeTrial else { return nil }
        return PaywallView.days(offer.period)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(name.isEmpty ? "Unlock your plan" : "\(name), unlock your plan").font(.display(34, weight: .bold)).tracking(-0.4)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("paywall.headline")
                    Text("Your plan is ready. Subscribe to start week 1.").font(.title3).foregroundStyle(Color.inkMuted)
                }
                .padding(.top, 24)
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(PaywallView.benefits(.lifter), id: \.title) { benefit in
                        Label(benefit.title, systemImage: "checkmark").font(.body.weight(.medium))
                    }
                    Label("Logging, history and progress", systemImage: "checkmark").font(.body.weight(.medium))
                }
                if !loaded {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 160)
                } else if products.isEmpty {
                    Text("The App Store isn’t answering. Check your connection and try again.").font(.subheadline).foregroundStyle(Color.inkMuted)
                    Button("Try Again") { Task { await load() } }
                } else {
                    VStack(spacing: 10) {
                        if let yearly { option(yearly, badge: Self.savings(yearly: yearly.price, monthly: monthly?.price)) }
                        if let monthly { option(monthly, badge: nil) }
                    }
                    if let message {
                        Text(message).font(.footnote).foregroundStyle(.red).accessibilityIdentifier("paywall.message")
                    }
                    Text(terms).font(.footnote).foregroundStyle(Color.inkMuted).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("paywall.terms.renewal")
                }
                coachRow
                footer
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaBar(edge: .bottom) {
            VStack(spacing: 4) {
            Button { if let product { Task { await buy(product) } } } label: {
                Group {
                    if working { ProgressView() } else {
                        Text(trialDays.map { "Start \($0)-Day Free Trial" } ?? "Subscribe")
                    }
                }
                .font(.headline).frame(maxWidth: .infinity, minHeight: 54)
            }
            .buttonStyle(.primary)
            .disabled(working || product == nil)
            .accessibilityIdentifier("paywall.buy")
            .padding(.horizontal, 24)
            // FIT-454: freemium's way past it, into the free app; hard mode has none.
            if Monetization.current == .freemium {
                Button("Not Now") {
                    Funnel.track(.paywallDismissed)
                    Funnel.track(.completed, "not_now")
                    onDone()
                }
                    .font(.subheadline).foregroundStyle(Color.inkMuted)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityIdentifier("paywall.notNow")
            }
            Color.clear.frame(height: 8)
            }
        }
        .screenBackground()
        .task { await load() }
        .onAppear { Funnel.track(.paywallViewed) }
        .onChange(of: selected) { _, now in Funnel.track(.planSelected, StoreProducts.funnelName(now)) }
        .onChange(of: pro.lifterPro || pro.coachPro, initial: true) { _, has in if has { onDone() } }
        .sheet(isPresented: $coach) { PaywallView(plan: .coach, tracksOnboarding: true) }
    }

    private func option(_ product: Product, badge: String?) -> some View {
        let on = product.id == selected
        let isYearly = product.id == plan.yearly
        return Button { selected = product.id } label: {
            HStack(spacing: 14) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.title2)
                    .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.inkFaint))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(isYearly ? "Yearly" : "Monthly").font(.headline)
                        if let badge {
                            Text(badge).font(.caption.weight(.bold)).foregroundStyle(Plate.current.onAccent)
                                .padding(.horizontal, 8).padding(.vertical, 3).background(.tint, in: .capsule)
                        }
                    }
                    if isYearly {
                        Text("About \((product.price / 12).formatted(product.priceFormatStyle))/month, billed yearly")
                            .font(.subheadline).foregroundStyle(Color.inkMuted)
                    }
                }
                Spacer()
                Text(PaywallView.price(product)).font(.headline).monospacedDigit()
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(Color.fill, in: .rect(cornerRadius: 18))
            .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 2) }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(isYearly ? "paywall.yearly" : "paywall.monthly")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var terms: String {
        PaywallView.lifterRenewalTerms(year: yearly?.displayPrice ?? StoreProducts.lifterYearlyFallback,
                                       month: monthly?.displayPrice ?? StoreProducts.lifterMonthlyFallback, trialDays: trialDays)
    }

    /// Coach Pro, there and never picked for them.
    private var coachRow: some View {
        Button { coach = true } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Coaching clients? Coach Pro").font(.subheadline.weight(.semibold))
                    if !coachProducts.isEmpty {
                        Text(coachProducts.sorted { a, _ in a.id == StoreProducts.coachMonthly }.map(PaywallView.price).joined(separator: " or "))
                            .font(.footnote).foregroundStyle(Color.inkMuted)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color.inkFaint)
            }
            .padding(.horizontal, 16).frame(minHeight: 56)
            .background(Color.fill, in: .rect(cornerRadius: 14))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("paywall.coachPro")
    }

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

    /// "Save 44%": yearly against twelve months of monthly, from the App Store's own prices, rounded down.
    nonisolated static func savings(yearly: Decimal, monthly: Decimal?) -> String? {
        guard let monthly, monthly > 0 else { return nil }
        let saved = NSDecimalNumber(decimal: 1 - yearly / (monthly * 12)).doubleValue
        let percent = Int((saved * 100).rounded(.down))
        return percent > 0 ? "Save \(percent)%" : nil
    }

    private func load() async {
        loaded = false
        products = (try? await Product.products(for: plan.products)) ?? []
        coachProducts = (try? await Product.products(for: StoreProducts.Plan.coach.products)) ?? []
        loaded = true
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "trialEligible") { trialEligible = true; return }
        #endif
        if let subscription = products.first?.subscription {
            trialEligible = await subscription.isEligibleForIntroOffer
            pro.trialEligible = trialEligible
        }
    }

    private func buy(_ product: Product) async {
        working = true
        message = nil
        defer { working = false }
        // TKL-466: the trial or payment itself is sent from StoreKit's signed transaction (Funnel.observe, from Pro).
        Funnel.purchaseStarting(product.id)
        do {
            switch try await pro.buy(product, with: purchase) {
            case .bought:
                Funnel.track(.completed, "purchase")
                onDone()
            case .pending:
                // Ask to Buy: followed until Transaction.updates brings the approval.
                Funnel.track(.purchaseFailed, "pending")
                message = "Waiting for approval. Lifter Pro starts as soon as it’s approved."
            case .cancelled:
                Funnel.track(.purchaseFailed, "cancelled")
                Funnel.purchaseAbandoned()
            }
        } catch {
            Funnel.track(.purchaseFailed, "error")
            Funnel.purchaseAbandoned()
            message = error.localizedDescription
        }
    }

    private func restore() async {
        working = true
        message = nil
        defer { working = false }
        do {
            try await pro.restore()
            if !pro.lifterPro && !pro.coachPro { message = "No subscription to restore on this Apple Account." } else {
                Funnel.track(.purchaseRestored)
                Funnel.track(.completed, "restore")
            }
        } catch {
            message = error.localizedDescription
        }
    }
}
