import Testing
@testable import AICoach

/// FIT-215: the pilot's one flag, and what it hides. Each gate reads the flag, so these hold while it's on.
@MainActor
struct PilotTests {
    @Test func thePilotIsFreeAndSimple() {
        #expect(Pilot.simple)
        // FIT-437: Lifter Pro and Coach Pro are sold; the rest stays hidden.
        #expect(Pilot.sellsPro)
        #expect(!Pilot.gifts)
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

    /// FIT-437: the App Store is no longer skipped (StoreKitTests drive it), so this checks the pilot's own switch:
    /// gifts stay hidden, and what the first Pro gated stays free.
    @Test func refreshingDoesNotTurnProOff() async {
        let pro = Pro()
        await pro.refreshGift(signedIn: true)
        #expect(pro.active)
        #expect(pro.giftUntil == nil)
    }

    /// FIT-201: the app plans weeks only for a program of its own; a coach's client gets the coach's weeks.
    @Test func onlyAProgramOfItsOwnIsPlannedByTheApp() {
        func plans(_ hasProgram: Bool, _ coached: Bool) -> Bool {
            WeekSource.of(lifterPro: false, coached: coached, hasProgram: hasProgram)?.plansItself == true
        }
        #expect(plans(true, false))
        #expect(!plans(true, true))
        #expect(!plans(false, true))
        #expect(!plans(false, false))
    }
}
