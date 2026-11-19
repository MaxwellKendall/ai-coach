#if DEBUG
import SwiftUI
import WidgetKit

/// TKL-802, Debug only: the today widget's views in every family for one state, at an iPhone 17 Pro's widget sizes on a
/// home-screen-like wallpaper, so the simulator can screenshot them (`-widgets workout`, or rest, done, setup, nodata;
/// light or dark from the simulator's appearance; `-plate red` for another plate).
struct WidgetGallery: View {
    let state: String

    private var content: TodaySnapshot.Content {
        let state: TodaySnapshot.State = switch self.state {
        case "rest": .rest
        case "done": .done
        case "setup": .notSetUp
        case "nodata": .noData
        default: .workout
        }
        return TodayWidgetSample.content(state)
    }

    private var plate: String { Plate.current.rawValue }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    widget(.systemSmall, width: 170, height: 170)
                    // The Lock Screen's two, beside it so one screenshot has every family.
                    VStack(alignment: .leading, spacing: 10) {
                        Text("LOCK SCREEN").font(.system(size: 11)).tracking(0.55).foregroundStyle(.white.opacity(0.85))
                        TodayWidgetView(content: content, plate: plate, family: .accessoryRectangular)
                            .foregroundStyle(.white).frame(width: 162, height: 64, alignment: .leading)
                            .padding(.horizontal, 8).background(.black.opacity(0.35), in: .rect(cornerRadius: 14))
                        TodayWidgetView(content: content, plate: plate, family: .accessoryInline)
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                            .padding(.vertical, 6).padding(.horizontal, 8).background(.black.opacity(0.35), in: .capsule)
                    }
                    .frame(width: 178, alignment: .leading)
                }
                widget(.systemMedium, width: 364, height: 170)
                widget(.systemLarge, width: 364, height: 382)
            }
            .padding(.horizontal, 19).padding(.top, 12)
        }
        .background(LinearGradient(colors: [Color(red: 0.81, green: 0.85, blue: 0.9), Color(red: 0.56, green: 0.64, blue: 0.76)],
                                   startPoint: .top, endPoint: .bottom).ignoresSafeArea())
        .accessibilityIdentifier("widget-gallery")
    }

    private func widget(_ family: WidgetFamily, width: CGFloat, height: CGFloat) -> some View {
        TodayWidgetView(content: content, plate: plate, family: family)
            .padding(16)
            .frame(width: width, height: height)
            .background(TodayTone(plate: plate).surface, in: .rect(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 8, y: 6)
    }
}
#endif
