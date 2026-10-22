import Testing
@testable import AICoach

/// FIT-215: the pilot's one flag, and what it hides. Each gate reads the flag, so these hold while it's on.
@MainActor
struct PilotTests {
    @Test func thePilotIsFreeAndSimple() {
        #expect(Pilot.simple)
        #expect(!Pilot.sellsPro)
        #expect(!Pilot.inAppAI)
        #expect(!Pilot.groups)
    }

    /// No model means no coach tab, no mic (so no mic or Speech prompt), and weeks from the rules.
    @Test func thereIsNoInAppModel() async {
        #expect(!LanguageModel.isAvailable)
        #expect(!LanguageModel.programs(signedIn: true).isAvailable)
        #expect(!LanguageModel.programs(signedIn: false).isAvailable)
        await #expect(throws: (any Error).self) {
            try await LanguageModel.programs(signedIn: true).session(instructions: "").respond(to: "hi")
        }
    }

    /// Everything Pro gated is free, and nothing asks to buy it.
    @Test func everythingProGatedIsFree() {
        let pro = Pro()
        #expect(pro.active)
        var ran = false
        pro.gate { ran = true }
        #expect(ran)
        #expect(!pro.paywall)
    }

    @Test func refreshingDoesNotTurnProOff() async {
        let pro = Pro()
        await pro.refresh()
        await pro.refreshGift(signedIn: true)
        #expect(pro.active)
        #expect(pro.giftUntil == nil)
    }
}
