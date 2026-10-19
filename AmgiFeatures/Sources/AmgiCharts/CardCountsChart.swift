public import SwiftUI
import AmgiAppCore
import AmgiTheme
import AmgiUI
import Charts
public import AnkiKit

public struct CardCountsChart: View {
    let cardCounts: CardCountsSeries

    public init(cardCounts: CardCountsSeries) {
        self.cardCounts = cardCounts
    }

    @Environment(\.palette) private var palette

    private var chartData: [(name: String, count: Int, color: Color)] {
        let c = cardCounts.excludingInactive
        return [
            (L10n.text("New"), Int(c.newCards), palette.cardStateNew),
            (L10n.text("Learning"), Int(c.learn), palette.cardStateLearning),
            (L10n.text("Relearning"), Int(c.relearn), palette.cardStateRelearn),
            (L10n.text("Young"), Int(c.young), palette.cardStateReview),
            (L10n.text("Mature"), Int(c.mature), palette.cardStateMature),
            (L10n.text("Suspended"), Int(c.suspended), palette.cardStateSuspended),
            (L10n.text("Buried"), Int(c.buried), palette.textTertiary),
        ].filter { $0.count > 0 }
    }

    private var total: Int { chartData.reduce(0) { $0 + $1.count } }

    /// Fits beside the legend in a phone-width card.
    private static let donutSize: CGFloat = 160
    /// Keeps each count close enough to its name to read across.
    private static let legendMaxWidth: CGFloat = 200

    private var donut: some View {
        Chart(chartData, id: \.name) { item in
            SectorMark(
                angle: .value("Count", item.count),
                innerRadius: .ratio(0.5),
                angularInset: 1
            )
            .foregroundStyle(item.color)
        }
        .frame(width: Self.donutSize, height: Self.donutSize)
    }

    /// One row per state, names leading and counts trailing in their own
    /// column, beside the donut rather than under it.
    private var legend: some View {
        Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(chartData, id: \.name) { item in
                GridRow {
                    Circle().fill(item.color).frame(width: 8, height: 8)
                    Text(item.name).amgiFont(.caption)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(item.count)").amgiFont(.captionBold).monospacedDigit()
                        .gridColumnAlignment(.trailing)
                }
            }
        }
    }

    public var body: some View {
        AmgiCard(
            background: .surface,
            shadow: palette.shadows.sm,
            cornerRadius: AmgiRadius.inset,
            contentInsets: EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Card Counts").amgiFont(.bodyEmphasis)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(L10n.format("%lld total", [total])).amgiFont(.caption).foregroundStyle(palette.textSecondary)
                }

                if chartData.isEmpty {
                    Text("No cards").foregroundStyle(palette.textSecondary).frame(height: 180)
                } else {
                    // Side by side wherever the legend fits beside the
                    // donut; stacked on the watch.
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .center, spacing: 16) {
                            donut
                                .frame(maxWidth: .infinity)
                            legend
                                .frame(maxWidth: Self.legendMaxWidth)
                                .frame(maxWidth: .infinity)
                        }
                        VStack(spacing: 12) {
                            donut
                            legend
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    CardCountsChart(cardCounts: .sample)
        .padding()
}
#endif
