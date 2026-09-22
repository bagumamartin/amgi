public import SwiftUI
import AmgiTheme

/// The screen a chart row opens. The count is the whole match for the
/// current deck scope. The number starts there and can only be lowered.
/// Study is absent when nothing matched.
public struct StudyTimeDetailContent: View {
    let row: StudyTimeRow
    let matchCount: Int
    let decks: [StudyDeckChoice]
    @Binding var deckID: Int64
    @Binding var includeSubdecks: Bool
    @Binding var limit: Int
    @Binding var reschedules: Bool
    let isBusy: Bool
    let message: String?
    let onScopeChange: () -> Void
    let onStudy: () -> Void

    @Environment(\.palette) private var palette

    public init(
        row: StudyTimeRow,
        matchCount: Int,
        decks: [StudyDeckChoice],
        deckID: Binding<Int64>,
        includeSubdecks: Binding<Bool>,
        limit: Binding<Int>,
        reschedules: Binding<Bool>,
        isBusy: Bool,
        message: String?,
        onScopeChange: @escaping () -> Void,
        onStudy: @escaping () -> Void
    ) {
        self.row = row
        self.matchCount = matchCount
        self.decks = decks
        self._deckID = deckID
        self._includeSubdecks = includeSubdecks
        self._limit = limit
        self._reschedules = reschedules
        self.isBusy = isBusy
        self.message = message
        self.onScopeChange = onScopeChange
        self.onStudy = onStudy
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                deckBlock
                if matchCount == 0 {
                    ContentUnavailableView(
                        row.emptyMessage,
                        systemImage: "calendar",
                        description: Text(row.detailTitle)
                    )
                } else {
                    countBlock
                    limitBlock
                    Toggle("Answering reschedules these cards", isOn: $reschedules)
                        .amgiFont(.body)
                        .tint(palette.accent)
                    studyButton
                    if let message {
                        Text(message)
                            .amgiFont(.caption)
                            .foregroundStyle(palette.warning)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .amgiScreenCanvas()
        .navigationTitle(row.detailTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var countBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(matchCount)")
                .amgiFont(.displayHero)
                .foregroundStyle(palette.textPrimary)
                .monospacedDigit()
            Text(matchCount == 1 ? "card" : "cards")
                .amgiFont(.body)
                .foregroundStyle(palette.textSecondary)
        }
    }

    private var deckBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Deck", selection: $deckID) {
                ForEach(decks) { deck in
                    Text(deck.title).tag(deck.id)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: deckID) { _, _ in onScopeChange() }
            if deckID != StudyDeckChoice.all.id {
                Toggle("Include subdecks", isOn: $includeSubdecks)
                    .amgiFont(.body)
                    .tint(palette.accent)
                    .onChange(of: includeSubdecks) { _, _ in onScopeChange() }
            }
        }
    }

    private var limitBlock: some View {
        Stepper(value: $limit, in: 1...max(matchCount, 1)) {
            Text("Study \(limit)")
                .amgiFont(.body)
                .foregroundStyle(palette.textPrimary)
                .monospacedDigit()
        }
        .disabled(matchCount <= 1)
    }

    private var studyButton: some View {
        Button(action: onStudy) {
            HStack(spacing: 8) {
                if isBusy {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 14, weight: .bold))
                }
                Text("Study · \(limit)")
                    .amgiFont(.body)
                    .bold()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(palette.accent, in: Capsule())
        }
        .buttonStyle(.pressScale)
        .disabled(isBusy || limit < 1)
    }
}
