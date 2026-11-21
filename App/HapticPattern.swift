import AudioToolbox
import CoreHaptics
import SwiftUI
import os

/// TKL-393: the Core Haptics half of the haptic grammar (App/Motion.swift). Each case is a bundled AHAP file in
/// Resources/Haptics: ready (rest over, one tap), crescendo (three rising taps then a strong thud, for a win), cheer
/// (a double tap) and warning. Where Core Haptics is unavailable the player falls back to `sensoryFeedback`.
enum HapticPattern: String, CaseIterable, Identifiable {
    case ready, crescendo, cheer, warning

    var id: Self { self }

    var fallback: SensoryFeedback {
        switch self {
        case .ready: .tap
        case .crescendo: .success
        case .cheer: .tap
        case .warning: .warning
        }
    }
}

/// Plays a pattern; attach `.hapticFallback(for:)` to the view that owns it so devices without Core Haptics still feel
/// something. A matching sound plays only when asked (off by default) and as a system sound, so the silent switch mutes it.
@MainActor @Observable
final class HapticPlayer {
    private static let log = Logger(subsystem: "com.maxwellkendall.aicoach", category: "Haptics")

    private(set) var fallbackTrigger = 0
    private(set) var fallbackFeedback: SensoryFeedback?
    @ObservationIgnored private var engine: CHHapticEngine?

    func play(_ pattern: HapticPattern, sound: Bool = false) {
        if !playHaptics(pattern) {
            fallbackFeedback = pattern.fallback
            fallbackTrigger += 1
        }
        if sound { playSound(pattern) }
    }

    private func playHaptics(_ pattern: HapticPattern) -> Bool {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics,
              let url = Bundle.main.url(forResource: pattern.rawValue, withExtension: "ahap") else { return false }

        do {
            if engine == nil {
                let engine = try CHHapticEngine()
                engine.playsHapticsOnly = true
                engine.isAutoShutdownEnabled = true
                self.engine = engine
            }
            guard let engine else { return false }
            try engine.start()
            let player = try engine.makePlayer(with: CHHapticPattern(contentsOf: url))
            try player.start(atTime: CHHapticTimeImmediate)
            Self.log.info("Started haptic pattern: \(pattern.rawValue, privacy: .public)")
            return true
        } catch {
            engine = nil
            Self.log.error("Could not play \(pattern.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func playSound(_ pattern: HapticPattern) {
        guard let url = Bundle.main.url(forResource: pattern.rawValue, withExtension: "wav") else { return }
        var soundID: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(url as CFURL, &soundID) == noErr else { return }
        // Play as a UI sound so the system controls silent mode and sound effects.
        AudioServicesPlaySystemSoundWithCompletion(soundID) {
            AudioServicesDisposeSystemSoundID(soundID)
        }
    }
}

extension View {
    func hapticFallback(for player: HapticPlayer) -> some View {
        sensoryFeedback(trigger: player.fallbackTrigger) { _, _ in player.fallbackFeedback }
    }
}
