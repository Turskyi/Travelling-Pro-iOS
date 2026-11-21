import SwiftUI
import WidgetKit

private struct TravelProgressEntry: TimelineEntry {
    let date: Date
    let visitedCount: Int
    let countryCount: Int
    let latestCountry: String
    let latestFlag: String
    let hasSharedData: Bool
}

private struct TravelProgressProvider: TimelineProvider {
    private let defaults = UserDefaults(suiteName: "group.io.github.turskyi.Travelling")

    func placeholder(in context: Context) -> TravelProgressEntry {
        TravelProgressEntry(
            date: .now,
            visitedCount: 0,
            countryCount: 0,
            latestCountry: "",
            latestFlag: "",
            hasSharedData: false
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (TravelProgressEntry) -> Void) {
        completion(entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TravelProgressEntry>) -> Void) {
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 30, to: .now) ?? .now.addingTimeInterval(1800)
        completion(Timeline(entries: [entry()], policy: .after(nextUpdate)))
    }

    private func entry() -> TravelProgressEntry {
        TravelProgressEntry(
            date: .now,
            visitedCount: defaults?.integer(forKey: "visitedCount") ?? 0,
            countryCount: defaults?.integer(forKey: "countryCount") ?? 0,
            latestCountry: defaults?.string(forKey: "latestCountry") ?? "",
            latestFlag: defaults?.string(forKey: "latestFlag") ?? "",
            hasSharedData: defaults?.object(forKey: "countryCount") != nil
        )
    }
}

private struct TravelProgressWidgetView: View {
    let entry: TravelProgressEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "airplane")
                    .foregroundStyle(.cyan)
                Text("TRAVELLING")
                    .font(.caption2.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
            }
            if entry.hasSharedData {
                Text("\(entry.visitedCount) / \(entry.countryCount)")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                Text("countries visited")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !entry.latestCountry.isEmpty {
                    HStack(spacing: 6) {
                        Text(entry.latestFlag)
                        Text(entry.latestCountry)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                    }
                }
                if family == .systemMedium {
                    ProgressView(
                        value: Double(entry.visitedCount),
                        total: Double(max(entry.countryCount, 1))
                    )
                    .tint(.cyan)
                }
            } else {
                Text("Open Travelling to refresh your progress.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding()
        .containerBackground(.background, for: .widget)
    }
}

private struct TravelProgressWidget: Widget {
    let kind = "TravelProgressWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TravelProgressProvider()) { entry in
            TravelProgressWidgetView(entry: entry)
        }
        .configurationDisplayName("Travel progress")
        .description("See how many countries you've visited.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct TravellingWidgetBundle: WidgetBundle {
    var body: some Widget {
        TravelProgressWidget()
    }
}
