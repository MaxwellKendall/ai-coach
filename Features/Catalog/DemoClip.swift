import SwiftUI

/// FIT-447: an exercise's demo clip, square, looping, muted and inline. Its poster frame shows while the clip loads
/// into the cache. If the clip can't load (offline before it was ever cached, or not on the site yet), `fallback`
/// shows instead, so there's never an empty player.
/// TKL-793: loading shows the poster with a thin moving line under it, never a spinner. `paused` and `slow` control it
/// (the how-to sheet's tap and Slow chip); Reduce Motion stops the loop and shows the poster. `notesOffline` says so
/// under the fallback when there's no connection.
struct DemoClip<Fallback: View>: View {
    let slug: String
    var corner: CGFloat = 12
    var paused = false
    var slow = false
    var notesOffline = false
    /// Set once the clip can't load, so controls drawn over it (Slow, pause) go with it.
    var unavailable: Binding<Bool>?
    @ViewBuilder var fallback: () -> Fallback
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Phase: Equatable { case loading, ready(URL), failed(offline: Bool) }
    @State private var phase = Phase.loading

    private var failed: Bool { if case .failed = phase { true } else { false } }

    var body: some View {
        if let remote = ExerciseDemos.url(slug), !failed {
            Group {
                // Paused, the player holds its frame; Reduce Motion shows the poster instead of any video.
                if case .ready(let file) = phase, !reduceMotion {
                    LoopingVideo(url: file, playing: !paused, rate: DemoPlayback.rate(slow: slow))
                } else {
                    poster
                        .overlay(alignment: .bottom) { if phase == .loading { LoadingLine().padding(8) } }
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(.rect(cornerRadius: corner))
            .task(id: slug) {
                guard phase == .loading else { return }
                do { phase = .ready(try await DemoCache().local(remote)) } catch {
                    phase = .failed(offline: DemoPlayback.offline(error))
                    unavailable?.wrappedValue = true
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Video: one rep of the movement")
        } else if notesOffline, phase == .failed(offline: true) {
            VStack(spacing: 8) {
                fallback()
                Label("You're offline: the video plays once it can load.", systemImage: "wifi.slash")
                    .font(.footnote).foregroundStyle(Color.inkMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            fallback()
        }
    }

    private var poster: some View {
        AsyncImage(url: ExerciseDemos.poster(slug)) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            Color.fill
        }
    }
}

/// TKL-793: a thin line that sweeps while a clip loads: the poster stays in view, so it never reads as waiting.
private struct LoadingLine: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            Capsule().fill(.white.opacity(0.35))
                .overlay(alignment: .leading) {
                    Capsule().fill(.white).frame(width: geo.size.width * 0.3)
                        .offset(x: reduceMotion ? 0 : phase * geo.size.width * 0.7)
                }
        }
        .frame(height: 2)
        .onAppear { if !reduceMotion { withAnimation(.easeInOut(duration: 0.9).repeatForever()) { phase = 1 } } }
        .accessibilityHidden(true)
    }
}

/// TKL-793: what a session row leads with: the clip, else the first photo, else nothing (a dashed placeholder).
enum DemoTileContent: Equatable {
    case clip, photo(URL), none

    static func of(_ slug: String) -> DemoTileContent {
        if ExerciseDemos.url(slug) != nil { return .clip }
        if let first = ExercisePhotos.urls(slug).first { return .photo(first) }
        return .none
    }
}

/// TKL-793: how a demo plays.
enum DemoPlayback {
    /// Slow is half speed.
    static func rate(slow: Bool) -> Float { slow ? 0.5 : 1 }

    /// Whether the clip loops; a paused one, or any with Reduce Motion on, shows its poster.
    static func loops(reduceMotion: Bool, paused: Bool) -> Bool { !reduceMotion && !paused }

    /// No connection, as opposed to a clip missing from the site.
    static func offline(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost,
                .dataNotAllowed, .internationalRoamingOff].contains(error.code)
    }
}

/// TKL-793: the 56 pt tile a session row leads with: the looping clip with a small play badge, else the first photo,
/// else a dashed "No demo" that keeps the rows aligned. Tapping it opens the how-to.
struct DemoTile: View {
    let slug: String
    let name: String
    var size: CGFloat = 56
    let open: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let content = DemoTileContent.of(slug)
        Button(action: open) {
            Group {
                switch content {
                case .clip:
                    DemoClip(slug: slug, corner: 12) { photo(ExercisePhotos.urls(slug).first) }
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "play.fill").font(.system(size: 8, weight: .bold)) // ui-score: allow dynamic-type: badge sized to the fixed tile
                                .foregroundStyle(.white).frame(width: 18, height: 18)
                                .background(.black.opacity(0.55), in: .circle).padding(4)
                        }
                case .photo(let url):
                    photo(url)
                case .none:
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.inkFaint, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .overlay {
                            Text("No demo").font(.system(size: 10, weight: .semibold)) // ui-score: allow dynamic-type: label sized to the fixed tile
                                .foregroundStyle(Color.inkMuted).multilineTextAlignment(.center)
                        }
                }
            }
            .frame(width: size, height: size)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("session.demo")
        .accessibilityLabel("How to do \(name)")
        .accessibilityHint(content == .clip ? "Opens the demo video and steps" : "Opens the steps")
    }

    private func photo(_ url: URL?) -> some View {
        AsyncImage(url: url) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            Color.fill
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: 12))
    }
}
