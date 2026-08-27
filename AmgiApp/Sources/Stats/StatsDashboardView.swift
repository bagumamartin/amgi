import SwiftUI
import AmgiTheme
import AnkiKit
import AnkiClients
import Dependencies

struct StatsDashboardView: View {
    @Environment(\.palette) private var palette

    /// Sync is wanted on every concerned screen; stats has no collection
    /// mutations of its own, so its trailing chrome is sync-only.
    @ToolbarContentBuilder
    private var chrome: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            SyncToolbarButton()
        }
    }

    @State private var model = StatsDashboardModel()
    @State private var period: StatsPeriod = .month
    @State private var selectedDeck: DeckInfo?

    var body: some View {
        ScrollView {

            LazyVStack(spacing: AmgiSpacing.lg) {
                if model.isLoading {
                    ProgressView("Loading statistics...")
                        .padding(.top, 40)
                } else if let error = model.errorMessage {
                    ContentUnavailableView(
                        "Failed to Load Stats",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error)
                    )
                } else if let graphs = model.graphs {
                    // Filters row
                    HStack(spacing: AmgiSpacing.sm) {
                        deckMenu
                        periodMenu
                        Spacer()
                    }

                    PeriodStatsCard(period: period, today: graphs.today, reviews: graphs.reviews)
                    FutureDueChart(futureDue: graphs.futureDue, period: period)
                    HeatmapChartOptimized(
                        reviews: model.heatmapReviews ?? graphs.reviews,
                        attentionDays: period.days
                    )
                    ReviewsChart(reviews: graphs.reviews, period: period)
                    CardCountsChart(cardCounts: graphs.cardCounts)
                    IntervalsChart(intervals: graphs.intervals)
                    EaseChart(eases: graphs.eases)
                    HourlyChart(hours: graphs.hours, period: period)
                    ButtonsChart(buttons: graphs.buttons, period: period)
                    AddedChart(added: graphs.added, period: period)
                    RetentionChart(trueRetention: graphs.trueRetention)
                    RetrievabilityChart(retrievability: graphs.retrievability)
                }
            }
            .frame(maxWidth: StatsColumn.maxWidth)
            .frame(maxWidth: .infinity)
            .padding(AmgiSpacing.lg)
        }
        .scrollContentBackground(.hidden)
        .background(palette.surface)
        .navigationTitle("Statistics")
        .toolbar { chrome }
        .task {
            await model.loadDecks()
            await reloadStats()
        }
        .onAppear {
            Task { await reloadStats() }
        }
        .refreshable { await reloadStats() }
        .onChange(of: selectedDeck) {
            Task { await reloadStats() }
        }
        .onChange(of: period) {
            Task { await reloadStats() }
        }
    }

    // MARK: - Deck Menu

    private var deckMenu: some View {
        Menu {
            Button { selectedDeck = nil } label: {
                if selectedDeck == nil { Label("Whole Collection", systemImage: "checkmark") }
                else { Text("Whole Collection") }
            }
            Divider()
            ForEach(model.decks.filter({ !$0.name.contains("::") })) { deck in
                Button { selectedDeck = deck } label: {
                    if selectedDeck?.id == deck.id { Label(deck.name, systemImage: "checkmark") }
                    else { Text(deck.name) }
                }
            }
        } label: {
            filterCapsule(
                icon: "rectangle.stack",
                label: selectedDeck?.name ?? "Collection"
            )
        }
    }

    // MARK: - Period Menu

    private var periodMenu: some View {
        Menu {
            ForEach(StatsPeriod.allCases, id: \.self) { p in
                Button { period = p } label: {
                    if period == p { Label(p.rawValue, systemImage: "checkmark") }
                    else { Text(p.rawValue) }
                }
            }
        } label: {
            filterCapsule(
                icon: "calendar",
                label: period.shortLabel
            )
        }
    }

    // MARK: - Shared Capsule

    // MARK: - Data
}

private extension StatsDashboardView {
    func filterCapsule(icon: String, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .amgiFont(.caption)
            Text(label)
                .fontWeight(.medium)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8))
        }
        .amgiFont(.body)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(palette.surface)
        .clipShape(Capsule())
    }

    /// Bridge the view's filter state into the model's stats load.
    func reloadStats() async {
        let search = selectedDeck.map { "deck:\"\($0.name)\"" } ?? ""
        await model.loadStats(search: search, days: period.days)
    }
}

// MARK: - Preview

/// Centered content column for the Stats dashboard, matching the
/// Library/Study columns so the charts stay readable on regular-width
/// layouts instead of stretching full-width.
private enum StatsColumn {
    static let maxWidth: CGFloat = 800
}

#if DEBUG
#Preview {
    // `prepareDependencies` sets the defaults the view reads via @Dependency in
    // its body; `.previewValue` returns a fully-populated snapshot so every
    // chart renders.
    let _ = prepareDependencies {
        $0.statsClient = .previewValue
        $0.deckClient = .previewValue
    }
    NavigationStack {
        StatsDashboardView()
    }
}
#endif
