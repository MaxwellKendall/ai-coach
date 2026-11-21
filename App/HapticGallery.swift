#if DEBUG
import SwiftUI

/// Launch with `-haptics YES` in Debug to check the patterns on a device.
struct HapticGallery: View {
    @State private var player = HapticPlayer()
    @State private var sounds = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(HapticPattern.allCases) { pattern in
                    Button(pattern.rawValue.capitalized) {
                        player.play(pattern, sound: sounds)
                    }
                }
                Toggle("Play sounds", isOn: $sounds)
            }
            .navigationTitle("Haptics")
        }
        .hapticFallback(for: player)
    }
}
#endif
