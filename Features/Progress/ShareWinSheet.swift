import SwiftUI

/// FIT-15, prototype board B: the card as it will be sent, black or paper, with or without weights, and Share.
struct ShareWinSheet: View {
    let win: WinItem
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
                Text("Share").font(.headline)
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
                if let image {
                    ShareLink(item: Image(uiImage: image), preview: SharePreview(words.title, image: Image(uiImage: image))) {
                        Label("Share image", systemImage: "square.and.arrow.up").font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 58).foregroundStyle(Color(.systemBackground))
                            .background(Color.primary, in: .capsule)
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
        .presentationDetents([.large])
    }
}
