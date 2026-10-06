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
    let onBrowse: (() -> Void)?

    @Environment(\.palette) private var palette
    @Environment(\.locale) private var locale

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
        onStudy: @escaping () -> Void,
        onBrowse: (() -> Void)? = nil
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
        self.onBrowse = onBrowse
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let subtitle = row.subtitle {
                    Label(subtitle, systemImage: "info.circle")
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                }
                deckBlock
                if matchCount == 0 {
                    if let message {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .amgiFont(.caption)
                            .foregroundStyle(palette.warning)
                    }
                    ContentUnavailableView(
                        row.emptyMessage,
                        systemImage: "calendar",
                        description: Text(row.detailTitle)
                    )
                } else {
                    AmgiCard(
                        background: .surface,
                        shadow: palette.shadows.sm,
                        cornerRadius: AmgiRadius.inset
                    ) {
                        VStack(alignment: .leading, spacing: AmgiSpacing.lg) {
                            countBlock
                            limitBlock
                            Toggle(AmgiL10n.text("Answering reschedules these cards", locale: locale), isOn: $reschedules)
                                .amgiFont(.body)
                                .tint(palette.accent)
                            if reschedules {
                                Label(
                                    AmgiL10n.text("These cards will move to a new schedule.", locale: locale),
                                    systemImage: "arrow.triangle.2.circlepath"
                                )
                                .amgiFont(.caption)
                                .foregroundStyle(palette.warning)
                            }
                            studyButton
                            if let onBrowse {
                                Button(AmgiL10n.text("Browse matching cards", locale: locale), action: onBrowse)
                                    .buttonStyle(AmgiSecondaryButtonStyle())
                                    .frame(maxWidth: .infinity)
                            }
                            if let message {
                                Text(message)
                                    .amgiFont(.caption)
                                    .foregroundStyle(palette.warning)
                            }
                        }
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
            Text(matchCount == 1 ? AmgiL10n.text("card", locale: locale) : AmgiL10n.text("Cards", locale: locale).lowercased(with: locale))
                .amgiFont(.body)
                .foregroundStyle(palette.textSecondary)
        }
    }

    private var deckBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(AmgiL10n.text("Deck", locale: locale), selection: $deckID) {
                ForEach(decks) { deck in
                    Text(deck.id == StudyDeckChoice.all.id ? AmgiL10n.text("All decks", locale: locale) : deck.title).tag(deck.id)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: deckID) { _, _ in onScopeChange() }
            if deckID != StudyDeckChoice.all.id {
                Toggle(AmgiL10n.text("Include subdecks", locale: locale), isOn: $includeSubdecks)
                    .amgiFont(.body)
                    .tint(palette.accent)
                    .onChange(of: includeSubdecks) { _, _ in onScopeChange() }
            }
        }
    }

    private var limitBlock: some View {
        Stepper(value: $limit, in: 1...max(matchCount, 1)) {
            Text(AmgiL10n.format("Study %lld", [limit], locale: locale))
                .amgiFont(.body)
                .foregroundStyle(palette.textPrimary)
                .monospacedDigit()
        }
        .disabled(matchCount <= 1)
    }

    private var studyButton: some View {
        Button(action: onStudy) {
            HStack(spacing: AmgiSpacing.sm) {
                if isBusy {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 14, weight: .bold))
                }
                Text(AmgiL10n.format("Study · %lld", [limit], locale: locale))
                    .bold()
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
        }
        .buttonStyle(AmgiPrimaryButtonStyle())
        .disabled(isBusy || limit < 1)
    }
}
