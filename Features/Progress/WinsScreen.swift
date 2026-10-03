import SwiftUI
import SwiftData

/// FIT-15, prototype board C: every win, newest first, by week. A row opens in place with its card and why it
/// counted; Share is one tap from there.
struct WinsScreen: View {
    @Query private var profiles: [Profile]
    @Query(sort: \Goal.createdAt) private var goals: [Goal]
    @Query(sort: \LogEntry.timestamp) private var entries: [LogEntry]
    @Query private var planned: [PlannedActivity]
    @Query private var templates: [Template]
    @State private var open: String?
    @State private var sharing: WinItem?

    var body: some View {
        let wins = WinFeed.wins(profile: profiles.first, goals: goals, entries: entries, planned: planned, templates: templates)
        let thisWeek = Week.monday(of: .now)
        let groups = Self.groups(wins, thisWeek: thisWeek)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text("\(wins.count) so far\(groups.first?.title.hasPrefix("THIS") == true ? " · \(groups[0].wins.count) this week" : "")")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 8)
                ForEach(groups, id: \.title) { group in
                    Text(group.title).font(.footnote.weight(.semibold)).tracking(0.4).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.top, 20).padding(.bottom, 8)
                    VStack(spacing: 0) {
                        ForEach(Array(group.wins.enumerated()), id: \.element.key) { index, win in
                            row(win).overlay(alignment: .top) { if index > 0 { Divider().padding(.leading, 70) } }
                        }
                    }
                    .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 22))
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 40)
        }
        .overlay {
            if wins.isEmpty {
                ContentUnavailableView("No wins yet", systemImage: "trophy",
                                       description: Text("Personal bests, goal milestones and full weeks in a row show up here."))
            }
        }
        .navigationTitle("Wins")
        .sheet(item: $sharing) { ShareWinSheet(win: $0) }
    }

    private func row(_ win: WinItem) -> some View {
        let words = WinWords(win)
        let isOpen = open == win.key
        return VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.snappy) { open = isOpen ? nil : win.key } } label: {
                HStack(spacing: 14) {
                    Image(systemName: symbol(win.kind)).font(.body.weight(.semibold))
                        .frame(width: 40, height: 40).background(Color(.tertiarySystemFill), in: .circle)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(words.title).font(.body.weight(.semibold)).multilineTextAlignment(.leading)
                        Text(words.line).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(isOpen ? "Hide the card" : "Show the card and share it")
            if isOpen {
                HStack(alignment: .bottom, spacing: 14) {
                    ShareCard(win: win)
                        .scaleEffect(112 / ShareCard.size.width, anchor: .topLeading)
                        .frame(width: 112, height: ShareCard.size.height * 112 / ShareCard.size.width, alignment: .topLeading)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(words.why).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button { sharing = win } label: {
                            Label("Share", systemImage: "square.and.arrow.up").font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 16).frame(minHeight: 40)
                                .foregroundStyle(Color(.systemBackground)).background(Color.primary, in: .capsule)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 70).padding(.trailing, 16).padding(.bottom, 16)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func symbol(_ kind: WinItem.Kind) -> String {
        switch kind {
        case .pr: "arrow.up.right"
        case .milestone: "target"
        case .streak: "chart.bar.fill"
        }
    }

    struct Group { var title: String; var wins: [WinItem] }

    static func groups(_ wins: [WinItem], thisWeek: Date, calendar: Calendar = .current) -> [Group] {
        let lastWeek = calendar.date(byAdding: .day, value: -7, to: thisWeek)!
        func span(_ monday: Date) -> String {
            let sunday = calendar.date(byAdding: .day, value: 6, to: monday)!
            let format = Date.FormatStyle.dateTime.month(.abbreviated).day()
            return "\(monday.formatted(format)) – \(sunday.formatted(format))".uppercased()
        }
        let buckets = [("THIS WEEK · \(span(thisWeek))", wins.filter { $0.date >= thisWeek }),
                       ("LAST WEEK · \(span(lastWeek))", wins.filter { $0.date >= lastWeek && $0.date < thisWeek }),
                       ("EARLIER", wins.filter { $0.date < lastWeek })]
        return buckets.filter { !$0.1.isEmpty }.map { Group(title: $0.0, wins: $0.1) }
    }
}
