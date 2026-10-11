import SwiftUI

/// FIT-113/111: a shared session or program as a card, the win card's size and look, uploaded with the share so
/// link previews (iMessage) show it.
struct PlanCard: View {
    var tag: String
    var title: String
    var subtitle: String
    var rows: [(String, String)]
    var link: String?

    var body: some View {
        let style = CardStyle.dark
        VStack(alignment: .leading, spacing: 0) {
            Text(tag.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(1.2).foregroundStyle(style.muted)
            Text(title).font(.system(size: 30, weight: .bold)).tracking(-0.5).lineLimit(2).minimumScaleFactor(0.7).padding(.top, 6)
            Text(subtitle).font(.system(size: 14)).foregroundStyle(style.soft).padding(.top, 6)
            VStack(spacing: 0) {
                ForEach(Array(rows.prefix(6).enumerated()), id: \.offset) { _, row in
                    HStack {
                        Text(row.0).font(.system(size: 14)).lineLimit(1)
                        Spacer()
                        Text(row.1).font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(style.soft)
                    }
                    .padding(.vertical, 6)
                }
            }
            .padding(.top, 16)
            Spacer(minLength: 0)
            HStack {
                Text(link ?? ShareCard.appName).font(.system(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                Spacer()
                Image(systemName: "circle.circle.fill").font(.system(size: 12)).symbolRenderingMode(.monochrome)
            }
            .foregroundStyle(style.muted)
        }
        .foregroundStyle(style.text)
        .padding(EdgeInsets(top: 24, leading: 24, bottom: 20, trailing: 24))
        .frame(width: ShareCard.size.width, height: ShareCard.size.height, alignment: .topLeading)
        .background(style.background)
        .clipShape(.rect(cornerRadius: 20))
        .environment(\.colorScheme, .dark)
    }

    @MainActor func image() -> UIImage? {
        let renderer = ImageRenderer(content: self)
        renderer.scale = 1080 / ShareCard.size.width
        return renderer.uiImage
    }

    /// "Train with me" for a session.
    static func session(_ shared: SharedSession.Shared, who: String = "Train with me", link: String? = nil) -> PlanCard {
        let date = SharedSession.date(shared.date)?.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()) ?? shared.date
        return PlanCard(tag: who, title: shared.title,
                        subtitle: [date, shared.time, shared.minutes.map { "~\($0) min" }].compactMap { $0 }.joined(separator: " · "),
                        rows: shared.exercises.map { ($0.name, "\($0.sets) × \($0.reps.map(String.init) ?? $0.seconds.map { "\($0) s" } ?? "")") },
                        link: link)
    }

    /// "Train my program" for a program.
    static func program(_ shared: SharedProgram.Shared, link: String? = nil) -> PlanCard {
        PlanCard(tag: "Train my program", title: shared.name,
                 subtitle: "\(shared.weeks) weeks · \(shared.days) days a week · \(shared.equipment)",
                 rows: shared.phases.map { ("\($0.phase.capitalized) · weeks \($0.from)\($0.to > $0.from ? "–\($0.to)" : "")", "× \($0.mainReps)") },
                 link: link)
    }
}
