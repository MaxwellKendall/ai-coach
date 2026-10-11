import SwiftUI
import LinkPresentation

/// FIT-15, prototype board B: the card as it will be sent, black or paper, with or without weights, and Share.
struct ShareWinSheet: View {
    let win: WinItem
    /// "Share" from Wins; the celebration after a session says something warmer (FIT-106).
    var heading = "Share"
    @Environment(\.dismiss) private var dismiss
    @State private var style = CardStyle.dark
    @State private var showNumbers = true
    @State private var image: UIImage?
    @Environment(Account.self) private var account
    /// FIT-107: links already made in this sheet, one per look of the card, so sharing twice doesn't save twice.
    @State private var links: [String: URL] = [:]
    @State private var linking = false
    @State private var sharing: SharedLink?
    @State private var failure: String?

    var body: some View {
        let words = WinWords(win, showNumbers: showNumbers)
        VStack(spacing: 0) {
            HStack {
                Color.clear.frame(width: 44, height: 44)
                Spacer()
                Text(heading).font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.body.weight(.semibold)).foregroundStyle(.primary).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, 12).padding(.top, 8)
            ShareCard(win: win, style: style, showNumbers: showNumbers)
                .shadow(color: .black.opacity(0.14), radius: 15, y: 8)
                .id("\(style.rawValue)\(showNumbers)")
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
                .padding(.top, 8)
            VStack(spacing: 12) {
                Picker("Style", selection: $style.animation(.snappy)) {
                    ForEach(CardStyle.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                if win.kind != .streak {
                    Toggle(isOn: $showNumbers.animation(.snappy)) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Show weights")
                            Text(showNumbers ? "Lifts and weights appear on the card" : "Only changes and percents appear")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .tint(.primary)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 16))
                }
            }
            .padding(.horizontal, 24).padding(.top, 20)
            Spacer(minLength: 12)
            Group {
                if let image, account.isAvailable, account.user != nil {
                    // FIT-107: signed in, the link goes, with the card as its preview; the image alone is a tap below.
                    VStack(spacing: 6) {
                        Button { shareLink(image, title: words.title) } label: {
                            primary(linking ? "Making your link…" : "Share", working: linking)
                        }
                        .buttonStyle(.plain)
                        .disabled(linking)
                        ShareLink(item: Image(uiImage: image), preview: SharePreview(words.title, image: Image(uiImage: image))) {
                            Text("Share image only").font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                        }
                        .tint(.primary)
                    }
                } else if let image {
                    ShareLink(item: Image(uiImage: image), preview: SharePreview(words.title, image: Image(uiImage: image))) {
                        primary("Share image", working: false)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 58)
                }
            }
            .padding(.horizontal, 24).padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .task(id: "\(style.rawValue)\(showNumbers)") { image = ShareCard.image(win, style: style, showNumbers: showNumbers) }
        .sheet(item: $sharing) { ActivityView(link: $0).presentationDetents([.medium, .large]) }
        .alert("Couldn’t make a link", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") {}
        } message: { Text(failure ?? "") }
        .presentationDetents([.large])
    }

    private func primary(_ title: String, working: Bool) -> some View {
        HStack(spacing: 8) {
            if working { ProgressView().tint(Color(.systemBackground)) } else { Image(systemName: "square.and.arrow.up") }
            Text(title)
        }
        .font(.headline).frame(maxWidth: .infinity, minHeight: 58).foregroundStyle(Color(.systemBackground))
        .background(Color.primary, in: .capsule)
    }

    /// Saves the win, uploads its card for the preview, then shares the link.
    private func shareLink(_ image: UIImage, title: String) {
        let look = "\(style.rawValue)\(showNumbers)"
        if let url = links[look] {
            sharing = SharedLink(url: url, title: title, image: image)
            return
        }
        linking = true
        Task {
            defer { linking = false }
            do {
                let share = try await Cloud.createShare(kind: "win", payload: SharedWin.payload(win, style: style, showNumbers: showNumbers))
                if let png = image.pngData() { try? await Cloud.uploadCard(png, for: share.id) }
                guard let url = URL(string: share.url) else { throw URLError(.badURL) }
                links[look] = url
                sharing = SharedLink(url: url, title: title, image: image)
            } catch {
                failure = "Check your connection and try again, or share the image on its own."
            }
        }
    }
}

/// FIT-107: a link to share, with the card for the share sheet's header.
struct SharedLink: Identifiable {
    let url: URL
    let title: String
    let image: UIImage
    var id: URL { url }
}

/// The system share sheet for a link, previewed with the card rather than a fetched page.
struct ActivityView: UIViewControllerRepresentable {
    let link: SharedLink

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [Item(link)], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}

    final class Item: NSObject, UIActivityItemSource {
        let link: SharedLink
        init(_ link: SharedLink) { self.link = link }

        func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any { link.url }
        func activityViewController(_ controller: UIActivityViewController, itemForActivityType type: UIActivity.ActivityType?) -> Any? { link.url }

        func activityViewControllerLinkMetadata(_ controller: UIActivityViewController) -> LPLinkMetadata? {
            let metadata = LPLinkMetadata()
            metadata.url = link.url
            metadata.originalURL = link.url
            metadata.title = link.title
            metadata.imageProvider = NSItemProvider(object: link.image)
            return metadata
        }
    }
}

/// FIT-106: a session that earned wins ends here, on the best one's card with Share first; the others are a swipe away.
struct CelebrationSheet: View {
    let wins: [WinItem]
    @State private var appeared = false

    var body: some View {
        TabView {
            ForEach(Array(wins.enumerated()), id: \.element.id) { index, win in
                ShareWinSheet(win: win, heading: wins.count == 1 ? "Nice work" : "Nice work · \(index + 1) of \(wins.count)")
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .background(Color(.systemBackground))
        .sensoryFeedback(.success, trigger: appeared)
        .onAppear { appeared = true }
        .presentationDetents([.large])
    }
}
