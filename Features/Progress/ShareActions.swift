import SwiftUI
import LinkPresentation

/// FIT-107: how a card is shared, for wins and recaps alike. Signed in, Share saves the item, draws the card again
/// with its short link, uploads that card for link previews, and shares the link; the image alone is a tap below.
/// Signed out, it's the image. Stop Sharing takes down every link made for the item from this phone.
struct ShareActions: View {
    struct Item {
        /// "win" or "recap", as createShare takes it.
        var kind: String
        /// Which item, so its links can be found again later.
        var key: String
        /// The card's look (style, weights): one link per look in this sheet.
        var look: String
        var title: String
        var payload: () -> [String: Any]
        /// The card, with the link printed on it once there is one.
        var render: (String?) -> UIImage?
    }

    let image: UIImage?
    let item: Item
    @Environment(Account.self) private var account
    @State private var links: [String: URL] = [:]
    @State private var linking = false
    @State private var sharing: SharedLink?
    @State private var failure: String?
    @State private var liveLinks: [String] = []
    @State private var stopping = false

    var body: some View {
        Group {
            if let image, account.isAvailable, account.user != nil {
                VStack(spacing: 6) {
                    Button { share(image) } label: { primary(linking ? "Making your link…" : "Share", working: linking) }
                        .buttonStyle(.plain)
                        .disabled(linking)
                    ShareLink(item: Image(uiImage: image), preview: SharePreview(item.title, image: Image(uiImage: image))) {
                        Text("Share image only").font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                    }
                    .tint(.primary)
                    if !liveLinks.isEmpty {
                        Button(stopping ? "Stopping…" : "Stop Sharing", role: .destructive) { stopSharing() }
                            .font(.subheadline).frame(minHeight: 36).disabled(stopping)
                    }
                }
            } else if let image {
                ShareLink(item: Image(uiImage: image), preview: SharePreview(item.title, image: Image(uiImage: image))) {
                    primary("Share image", working: false)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 58)
            }
        }
        .sheet(item: $sharing) { ActivityView(link: $0).presentationDetents([.medium, .large]) }
        .onAppear { liveLinks = ShareLinks.ids(for: item.key) }
        .alert("Couldn’t make a link", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") {}
        } message: { Text(failure ?? "") }
    }

    private func primary(_ title: String, working: Bool) -> some View {
        HStack(spacing: 8) {
            if working { ProgressView().tint(Color(.systemBackground)) } else { Image(systemName: "square.and.arrow.up") }
            Text(title)
        }
        .font(.headline).frame(maxWidth: .infinity, minHeight: 58).foregroundStyle(Color(.systemBackground))
        .background(Color.primary, in: .capsule)
    }

    private func share(_ image: UIImage) {
        if let url = links[item.look] {
            sharing = SharedLink(url: url, title: item.title, image: item.render(ShareLinks.short(url)) ?? image)
            return
        }
        linking = true
        Task {
            defer { linking = false }
            do {
                let share = try await Cloud.createShare(kind: item.kind, payload: item.payload())
                guard let url = URL(string: share.url) else { throw URLError(.badURL) }
                ShareLinks.add(share.id, for: item.key)
                liveLinks = ShareLinks.ids(for: item.key)
                let card = item.render(ShareLinks.short(url)) ?? image
                if let png = card.pngData() { try? await Cloud.uploadCard(png, for: share.id) }
                links[item.look] = url
                sharing = SharedLink(url: url, title: item.title, image: card)
            } catch {
                failure = "Check your connection and try again, or share the image on its own."
            }
        }
    }

    private func stopSharing() {
        stopping = true
        Task {
            defer { stopping = false }
            for id in liveLinks { try? await Cloud.deleteShare(id) }
            ShareLinks.clear(for: item.key)
            liveLinks = []
            links = [:]
        }
    }
}

/// The links made for each shared item on this phone, so they can be taken down later.
@MainActor enum ShareLinks {
    private static func key(_ item: String) -> String { "shares.\(item)" }
    static func ids(for item: String) -> [String] { UserDefaults.standard.stringArray(forKey: key(item)) ?? [] }
    static func add(_ id: String, for item: String) { UserDefaults.standard.set(ids(for: item) + [id], forKey: key(item)) }
    static func clear(for item: String) { UserDefaults.standard.removeObject(forKey: key(item)) }

    /// "barbrabell.com/w/ae79125c4c25", as printed on the card: the bare domain serves every page too.
    nonisolated static func short(_ url: URL) -> String {
        let host = url.host() ?? ""
        return (host.hasPrefix("share.") ? String(host.dropFirst(6)) : host) + url.path()
    }
}

/// FIT-107: a link to share, with the card for the share sheet's header.
struct SharedLink: Identifiable {
    let url: URL
    let title: String
    var image: UIImage?
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
            metadata.imageProvider = link.image.map { NSItemProvider(object: $0) }
            return metadata
        }
    }
}

