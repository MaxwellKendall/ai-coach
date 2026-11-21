import Foundation
import SwiftUI
import Testing
@testable import AICoach

struct SurfaceMotionTests {
    @Test func shimmerWrapsAfterTheBandClearsTheView() {
        #expect(SurfaceMotion.shimmerPhase(at: 0) == 0)
        #expect(SurfaceMotion.shimmerPhase(at: 0.9) == 0.5)
        #expect(SurfaceMotion.shimmerPhase(at: 1.8) == 0)
    }

    @Test func reducedMotionPulsesGentlyAndFreezesSheen() {
        #expect(abs(SurfaceMotion.pulseOpacity(at: 0) - 0.8) < 0.001)
        #expect(abs(SurfaceMotion.pulseOpacity(at: 1.6) - 1) < 0.001)
        #expect(abs(SurfaceMotion.pulseOpacity(at: 3.2) - 0.8) < 0.001)
        #expect(SurfaceMotion.sheenAngle(.degrees(80), reduceMotion: true) ==
                SurfaceMotion.sheenAngle(.degrees(-10), reduceMotion: true))
        #expect(abs(SurfaceMotion.sheenAngle(.degrees(90), reduceMotion: false) - .pi / 2) < 0.001)
    }
}
