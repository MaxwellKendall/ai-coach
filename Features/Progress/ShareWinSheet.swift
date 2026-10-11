import SwiftUI

/// FIT-15, prototype board B: the card as it will be sent, black or paper, with or without weights, and Share.
struct ShareWinSheet: View {
    let win: WinItem
    /// "Share" from Wins; the celebration after a session says something warmer (FIT-106).
    var heading = "Share"
    @Environment(\.dismiss) private var dismiss
    @State private var style = CardStyle.dark
    @State private var showNumbers = true
    @State private var image: UIImage?

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
            ShareActions(image: image, item: ShareActions.Item(
                kind: "win", key: win.key, look: "\(style.rawValue)\(showNumbers)", title: words.title,
                payload: { SharedWin.payload(win, style: style, showNumbers: showNumbers) },
                render: { ShareCard.image(win, style: style, showNumbers: showNumbers, link: $0) }))
            .padding(.horizontal, 24).padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .task(id: "\(style.rawValue)\(showNumbers)") { image = ShareCard.image(win, style: style, showNumbers: showNumbers) }
        .presentationDetents([.large])
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
