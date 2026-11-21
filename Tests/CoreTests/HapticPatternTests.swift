import CoreHaptics
import Foundation
import SwiftUI
import Testing
@testable import AICoach

/// TKL-393: the bundled Core Haptics patterns decode, have the shapes the haptic grammar names, and fall back to
/// `sensoryFeedback` without Core Haptics.
struct HapticPatternTests {
    @Test(arguments: HapticPattern.allCases)
    func bundledPatternsDecode(pattern: HapticPattern) throws {
        let url = try #require(Bundle.main.url(forResource: pattern.rawValue, withExtension: "ahap"))
        _ = try CHHapticPattern(contentsOf: url)
    }

    @Test func patternSetIsTheFourNamed() {
        #expect(HapticPattern.allCases.map(\.rawValue) == ["ready", "crescendo", "cheer", "warning"])
    }

    @Test func crescendoIsThreeRisingTapsThenAStrongThud() throws {
        let taps = try transients(.crescendo)
        #expect(taps.count == 4)
        let intensities = taps.map(\.intensity)
        #expect(intensities == intensities.sorted())
        #expect(Set(intensities).count == 4)
        #expect(intensities.last == 1)
        #expect(zip(taps, taps.dropFirst()).allSatisfy { $0.time < $1.time })
    }

    @Test func cheerIsADoubleTap() throws {
        #expect(try transients(.cheer).count == 2)
    }

    @Test func readyIsOneTap() throws {
        #expect(try transients(.ready).count == 1)
    }

    @Test func warningIsSharperThanCheer() throws {
        let warning = try transients(.warning), cheer = try transients(.cheer)
        #expect(warning.map(\.intensity).max()! > cheer.map(\.intensity).max()!)
        #expect(warning.map(\.sharpness).max()! > cheer.map(\.sharpness).max()!)
    }

    @Test func everyPatternHasAFallback() {
        #expect(HapticPattern.crescendo.fallback == .success)
        #expect(HapticPattern.warning.fallback == .warning)
        #expect(HapticPattern.ready.fallback == .tap)
        #expect(HapticPattern.cheer.fallback == .tap)
    }

    /// The simulator has no haptics hardware, so playing takes the `sensoryFeedback` path.
    @MainActor @Test func playsTheFallbackWithoutCoreHaptics() throws {
        try #require(!CHHapticEngine.capabilitiesForHardware().supportsHaptics)
        let player = HapticPlayer()
        player.play(.crescendo)
        #expect(player.fallbackTrigger == 1)
        #expect(player.fallbackFeedback == .success)
        player.play(.warning)
        #expect(player.fallbackTrigger == 2)
        #expect(player.fallbackFeedback == .warning)
    }

    private struct Transient { let time, intensity, sharpness: Double }

    private func transients(_ pattern: HapticPattern) throws -> [Transient] {
        let url = try #require(Bundle.main.url(forResource: pattern.rawValue, withExtension: "ahap"))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let events = try #require(json["Pattern"] as? [[String: Any]]).compactMap { $0["Event"] as? [String: Any] }
        return try events.map { event in
            #expect(event["EventType"] as? String == "HapticTransient")
            let params = try #require(event["EventParameters"] as? [[String: Any]])
            func value(_ id: String) throws -> Double {
                try #require(params.first { $0["ParameterID"] as? String == id }?["ParameterValue"] as? Double)
            }
            return Transient(time: try #require(event["Time"] as? Double), intensity: try value("HapticIntensity"),
                             sharpness: try value("HapticSharpness"))
        }
    }
}
