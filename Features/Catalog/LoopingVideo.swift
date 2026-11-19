import AVFoundation
import SwiftUI

/// FIT-348: a silent clip that plays over and over, with no controls. The clips have no audio track, so playing one
/// doesn't take the audio session from the user's music. TKL-793: `playing` pauses it on its frame; `rate` 0.5 is Slow.
struct LoopingVideo: UIViewRepresentable {
    let url: URL
    var playing = true
    var rate: Float = 1

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        let player = AVQueuePlayer()
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        view.looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        apply(to: player)
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        if let player = view.playerLayer.player { apply(to: player) }
    }

    private func apply(to player: AVPlayer) {
        player.defaultRate = rate
        if playing {
            if player.rate != rate { player.rate = rate }
        } else if player.rate != 0 {
            player.pause()
        }
    }

    static func dismantleUIView(_ view: PlayerView, coordinator: ()) {
        view.playerLayer.player?.pause()
        view.looper = nil
    }

    final class PlayerView: UIView {
        var looper: AVPlayerLooper?
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
