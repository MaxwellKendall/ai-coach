import SwiftUI

/// FIT-447: an exercise's demo clip, square, looping, muted and inline. Its poster frame shows while the clip loads
/// into the cache. If the clip can't load (offline before it was ever cached, or not on the site yet), `fallback`
/// shows instead, so there's never an empty player.
struct DemoClip<Fallback: View>: View {
    let slug: String
    var corner: CGFloat = 12
    @ViewBuilder var fallback: () -> Fallback

    private enum Phase: Equatable { case loading, ready(URL), failed }
    @State private var phase = Phase.loading

    var body: some View {
        if let remote = ExerciseDemos.url(slug), phase != .failed {
            Group {
                if case .ready(let file) = phase {
                    LoopingVideo(url: file)
                } else {
                    AsyncImage(url: ExerciseDemos.poster(slug)) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Color.clear
                    }
                    .task(id: slug) {
                        do { phase = .ready(try await DemoCache().local(remote)) } catch { phase = .failed }
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(.rect(cornerRadius: corner))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Video: one rep of the movement")
        } else {
            fallback()
        }
    }
}
