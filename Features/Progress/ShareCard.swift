import SwiftUI

/// FIT-15: the image a win is shared as. Fixed colors, so it looks the same however it's rendered.
enum CardStyle: String, CaseIterable, Identifiable {
    case dark = "Black", paper = "Paper"

    var id: String { rawValue }
    var background: Color { self == .dark ? Color(red: 0.067, green: 0.067, blue: 0.067) : Color(red: 0.965, green: 0.965, blue: 0.957) }
    var text: Color { self == .dark ? .white : Color(red: 0.067, green: 0.067, blue: 0.067) }
    var muted: Color { self == .dark ? Color(red: 0.71, green: 0.71, blue: 0.69) : Color(red: 0.37, green: 0.37, blue: 0.35) }
    var soft: Color { self == .dark ? Color(red: 0.84, green: 0.84, blue: 0.82) : Color(red: 0.25, green: 0.25, blue: 0.24) }
    var track: Color { self == .dark ? Color(red: 0.23, green: 0.23, blue: 0.24) : Color(red: 0.86, green: 0.86, blue: 0.85) }
}

struct ShareCard: View {
    /// Until the app has a name.
    static let appName = "AI Coach"
    /// Drawn at this size and scaled, so every use looks the same.
    static let size = CGSize(width: 306, height: 382)

    let win: WinItem
    var style = CardStyle.dark
    var showNumbers = true

    var body: some View {
        let words = WinWords(win, showNumbers: showNumbers)
        VStack(alignment: .leading, spacing: 0) {
            Text(words.tag).font(.system(size: 11, weight: .semibold)).tracking(1.2).foregroundStyle(style.muted)
            Text(words.heading).font(.system(size: 18, weight: .semibold)).padding(.top, 4)
            switch win.kind {
            case .milestone: ring(words)
            default: figure(words)
            }
            HStack {
                Text(win.date.formatted(.dateTime.month(.abbreviated).day().year())).font(.system(size: 12))
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "circle.circle.fill").font(.system(size: 12)).symbolRenderingMode(.monochrome)
                    Text(Self.appName).font(.system(size: 12, weight: .semibold))
                }
            }
            .foregroundStyle(style.muted)
            .padding(.top, 14)
        }
        .foregroundStyle(style.text)
        .padding(EdgeInsets(top: 24, leading: 24, bottom: 20, trailing: 24))
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(style.background)
        .clipShape(.rect(cornerRadius: 20))
        .overlay { if style == .paper { RoundedRectangle(cornerRadius: 20).strokeBorder(style.track) } }
        .environment(\.colorScheme, style == .dark ? .dark : .light)
    }

    /// A personal best or a streak: a big number, a line under it, and a trend or the weeks.
    private func figure(_ words: WinWords) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text(words.big).font(.system(size: 84, weight: .bold, design: .rounded)).tracking(-2).minimumScaleFactor(0.6).lineLimit(1)
                Text(words.unit).font(.system(size: 22, weight: .semibold)).foregroundStyle(style.muted)
            }
            .padding(.top, 30)
            Text(words.sub).font(.system(size: 15)).foregroundStyle(style.soft).padding(.top, 8)
            Spacer(minLength: 8)
            if win.kind == .pr {
                Sparkline(values: win.trend, color: style.text).frame(height: 70)
            } else {
                HStack(spacing: 6) {
                    ForEach(0..<min(Int(win.value), 8), id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 8).fill(style.text).frame(height: 36)
                    }
                }
            }
        }
    }

    private func ring(_ words: WinWords) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            ZStack {
                Circle().stroke(style.track, lineWidth: 11)
                Circle().trim(from: 0, to: Double(win.percent ?? 0) / 100)
                    .stroke(style.text, style: StrokeStyle(lineWidth: 11, lineCap: .round)).rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text(words.big).font(.system(size: 40, weight: .bold, design: .rounded)).tracking(-1).minimumScaleFactor(0.6).lineLimit(1)
                    Text(words.unit).font(.system(size: 13)).foregroundStyle(style.muted)
                }
            }
            .frame(width: 170, height: 170)
            Spacer(minLength: 0)
            Text(words.sub).font(.system(size: 15)).foregroundStyle(style.soft).frame(maxWidth: .infinity)
        }
    }

    /// The card as one image, 1080 px wide, for the share sheet.
    @MainActor static func image(_ win: WinItem, style: CardStyle, showNumbers: Bool) -> UIImage? {
        let renderer = ImageRenderer(content: ShareCard(win: win, style: style, showNumbers: showNumbers))
        renderer.scale = 1080 / size.width
        return renderer.uiImage
    }
}

/// The best so far, drawn as a line to its latest point.
struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            let points = points(in: proxy.size)
            ZStack {
                Path { $0.addLines(points) }.stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                if let last = points.last { Circle().fill(color).frame(width: 11, height: 11).position(last) }
            }
        }
    }

    private func points(in size: CGSize) -> [CGPoint] {
        guard values.count > 1, let low = values.min(), let high = values.max() else { return [] }
        let inset = 6.0, span = max(high - low, 1)
        return values.enumerated().map { index, value in
            CGPoint(x: inset + (size.width - 2 * inset) * Double(index) / Double(values.count - 1),
                    y: size.height - inset - (size.height - 2 * inset) * (value - low) / span)
        }
    }
}

/// A win at a glance on Today's finished workout (FIT-15): the number, one line, and Share.
struct WinCard: View {
    let win: WinItem
    let share: () -> Void

    var body: some View {
        let words = WinWords(win)
        Button(action: share) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(words.tag).font(.caption2.weight(.semibold)).tracking(1).foregroundStyle(.white.opacity(0.65))
                    Text(words.heading).font(.subheadline.weight(.semibold)).lineLimit(2)
                    if win.kind != .milestone {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(words.big).font(.system(size: 34, weight: .bold, design: .rounded)).tracking(-0.5)
                            Text(words.unit).font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.65))
                        }
                    }
                    Text(words.sub).font(.footnote).foregroundStyle(.white.opacity(0.8)).lineLimit(2)
                }
                Spacer(minLength: 8)
                Image(systemName: "square.and.arrow.up").font(.body.weight(.semibold)).foregroundStyle(.black)
                    .frame(width: 44, height: 44).background(.white, in: .circle)
            }
            .foregroundStyle(.white)
            .padding(.leading, 16).padding(.trailing, 10).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(white: 0.07), in: .rect(cornerRadius: 22))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Share this win")
    }
}
