#if !os(watchOS)
public import SwiftUI
import AmgiTheme

/// A focused Library decision surface. It shows one automatic concern at a
/// time while keeping manual paused-deck review inside the same card.
public struct DeckTriageCard: View {
    public let data: DeckTriageData
    public let onAction: (DeckTriageItem, DeckTriageAction) -> Void
    public let onReviewAll: (() -> Void)?
    public let onReviewPaused: (() -> Void)?
    @Environment(\.palette) private var palette
    @Environment(\.locale) private var locale

    public init(data: DeckTriageData,
                onAction: @escaping (DeckTriageItem, DeckTriageAction) -> Void,
                onReviewAll: (() -> Void)? = nil,
                onReviewPaused: (() -> Void)? = nil) {
        self.data = data
        self.onAction = onAction
        self.onReviewAll = onReviewAll
        self.onReviewPaused = onReviewPaused
    }

    public var body: some View {
        if !data.isHidden {
            AmgiCard(background: .surfaceElevated, shadow: nil) {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    if data.isResolved, let item = data.focusedItem {
                        decision(item)
                    } else if data.isResolved || data.readiness == .unavailable {
                        pausedInvitation
                    } else {
                        loadingDecision
                    }

                    if data.manualReviewCount > 0,
                       (data.isResolved && data.focusedItem != nil || data.readiness == .loading) {
                        Divider().overlay(palette.border)
                        pausedReviewAction
                    }
                }
                .foregroundStyle(palette.textPrimary)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: "checklist")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.accent)
                    .frame(width: 32, height: 32)
                    .background(palette.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityHidden(true)

                Text("Needs a decision")
                    .amgiFont(.sectionHeading)
                    .foregroundStyle(palette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
            }

            Spacer(minLength: 8)

            if data.isResolved, !data.items.isEmpty {
                countBadge
            } else if !data.isResolved, data.manualReviewCount == 0 {
                Text("0")
                    .amgiFont(.caption)
                    .redacted(reason: .placeholder)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(palette.accentSoft, in: Capsule())
                    .accessibilityHidden(true)
            }
        }
    }

    private var countBadge: some View {
        let count = data.items.count
        return Text("\(count)")
            .amgiFont(.captionBold)
            .monospacedDigit()
            .foregroundStyle(palette.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(palette.accentSoft, in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(AmgiL10n.format("%lld pending decisions", [count], locale: locale)))
    }

    private func decision(_ item: DeckTriageItem) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                DeckTile(name: item.row.name, iconName: item.row.iconName, isFiltered: false)
                    .frame(width: 42, height: 42)
                    .accessibilityHidden(true)

                Text(item.row.name)
                    .amgiFont(.bodyEmphasis)
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 4)

                Button { onAction(item, .viewDeck) } label: {
                    Label("View deck", systemImage: "arrow.up.right")
                        .labelStyle(.titleAndIcon)
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: issueSymbol(item.issue))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(palette.accent)
                    .frame(width: 34, height: 34)
                    .background(palette.surfaceElevated, in: Circle())
                    .accessibilityHidden(true)

                Text(item.question)
                    .amgiFont(.sectionHeading)
                    .foregroundStyle(palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.accentSoft, in: RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous))

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.textTertiary)
                    .padding(.top, 2)
                    .accessibilityHidden(true)

                Text(item.evidence)
                    .amgiFont(.body)
                    .foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            choiceButtons(item)

            if let error = data.errorMessage {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .amgiFont(.caption)
                    .foregroundStyle(palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(error)
            }

            HStack(spacing: 12) {
                Button { onAction(item, .deferDecision) } label: {
                    Text("Not now")
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityHint("Remind me in a week")
                .help("Remind me in a week")

                Spacer(minLength: 8)

                if let onReviewAll {
                    Button(action: onReviewAll) {
                        Label("Review all", systemImage: "list.bullet")
                            .labelStyle(.titleAndIcon)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                }

                if data.busyID == item.id {
                    ProgressView()
                        .accessibilityLabel("Saving decision")
                }
            }
            .amgiFont(.caption)
            .buttonStyle(.plain)
            .foregroundStyle(palette.textSecondary)
        }
        .disabled(data.busyID != nil || !data.isResolved)
        .accessibilityElement(children: .contain)
    }

    private func choiceButtons(_ item: DeckTriageItem) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                ForEach(Array(item.actions.enumerated()), id: \.element) { index, action in
                    choiceButton(action, index: index, item: item)
                }
            }
            VStack(spacing: 10) {
                ForEach(Array(item.actions.enumerated()), id: \.element) { index, action in
                    choiceButton(action, index: index, item: item)
                }
            }
        }
    }

    @ViewBuilder
    private func choiceButton(_ action: DeckTriageAction, index: Int, item: DeckTriageItem) -> some View {
        let label = actionTitle(action, item: item)
            .frame(maxWidth: .infinity, minHeight: 44)

        if action == .delete {
            Button(role: .destructive) { onAction(item, action) } label: { label }
                .buttonStyle(.bordered)
                .tint(palette.danger)
        } else if index == 0 {
            Button { onAction(item, action) } label: { label }
                .buttonStyle(AmgiPrimaryButtonStyle())
        } else {
            Button { onAction(item, action) } label: { label }
                .buttonStyle(AmgiSecondaryButtonStyle())
        }
    }

    private var pausedInvitation: some View {
        VStack(alignment: .leading, spacing: 14) {
            pausedReviewAction

            if let error = data.errorMessage {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .amgiFont(.caption)
                    .foregroundStyle(palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var pausedReviewAction: some View {
        Button { onReviewPaused?() } label: {
            HStack(spacing: 12) {
                Image(systemName: "pause.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.accent)
                    .frame(width: 34, height: 34)
                    .background(palette.surfaceElevated, in: Circle())
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Review paused decks")
                        .amgiFont(.bodyEmphasis)
                        .foregroundStyle(palette.textPrimary)
                        .multilineTextAlignment(.leading)
                    Text("Choose which decks to bring back.")
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 4)

                Text("\(data.manualReviewCount)")
                    .amgiFont(.captionBold)
                    .monospacedDigit()
                    .foregroundStyle(palette.accent)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(palette.surfaceElevated, in: Capsule())
                    .accessibilityHidden(true)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(palette.accentSoft, in: RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous)
                    .strokeBorder(palette.border, lineWidth: 0.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Review paused decks")
        .accessibilityValue(Text("Paused decks to review: \(data.manualReviewCount)"))
        .disabled(data.busyID != nil)
        .accessibilityHint("Choose which decks to bring back.")
        .frame(minHeight: 64)
    }

    private var loadingDecision: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(palette.separator)
                    .frame(width: 42, height: 42)
                Text("Deck name").amgiFont(.bodyEmphasis)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .frame(width: 44, height: 44)
            }
            HStack(spacing: 12) {
                Circle().fill(palette.separator).frame(width: 34, height: 34)
                Text("Still want to study this deck?").amgiFont(.sectionHeading)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.accentSoft, in: RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous))
            Text("Last studied · cards waiting").amgiFont(.body)
            HStack(spacing: 10) {
                Text("Study now").frame(maxWidth: .infinity, minHeight: 44)
                Text("Pause deck").frame(maxWidth: .infinity, minHeight: 44)
            }
            .amgiFont(.body)
            .foregroundStyle(palette.textSecondary)
        }
        .redacted(reason: .placeholder)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading decisions")
    }

    private func issueSymbol(_ issue: DeckTriageIssue) -> String {
        switch issue {
        case .neglected: "clock.fill"
        case .neverStarted: "play.fill"
        case .newBacklog: "slider.horizontal.3"
        case .empty: "tray"
        case .parked: "pause.fill"
        }
    }

    @ViewBuilder
    private func actionTitle(_ action: DeckTriageAction, item: DeckTriageItem) -> some View {
        switch action {
        case .study:
            if item.issue == .neverStarted { Text("Start studying") } else { Text("Study now") }
        case .pause: Text("Pause deck")
        case .pace:
            if case .newBacklog = item.issue { Text("Adjust pace") } else { Text("Review study settings") }
        case .keepPace: Text("Keep this pace")
        case .addCards: Text("Add cards")
        case .delete: Text("Delete deck")
        case .resume: Text("Resume")
        case .chooseCards: Text("Choose cards")
        case .keepPaused: Text("Keep paused")
        case .deferDecision: Text("Not now")
        case .viewDeck: Text("View deck")
        }
    }
}

#if DEBUG
#Preview("Decision — populated") {
    DeckTriageCard(data: .sample, onAction: { _, _ in }, onReviewAll: {}, onReviewPaused: {})
        .padding().environment(\.palette, .vividLight)
}
#Preview("Decision — paused-only entry") {
    DeckTriageCard(data: DeckTriageData(items: [], manualReviewCount: 3), onAction: { _, _ in }, onReviewPaused: {})
        .padding().environment(\.palette, .vividLight)
}
#Preview("Decision — active and paused decks") {
    DeckTriageCard(data: DeckTriageData(items: [DeckTriageData.sample.items[0]], manualReviewCount: 3),
        onAction: { _, _ in }, onReviewAll: {}, onReviewPaused: {})
        .padding().environment(\.palette, .vividLight)
}
#Preview("Decision — unused") {
    DeckTriageCard(data: DeckTriageData(items: [DeckTriageData.sample.items[1]]), onAction: { _, _ in })
        .padding().environment(\.palette, .vividLight)
}
#Preview("Decision — backlog") {
    DeckTriageCard(data: DeckTriageData(items: [DeckTriageData.sample.items[2]]), onAction: { _, _ in })
        .padding().environment(\.palette, .vividLight)
}
#Preview("Decision — loading") {
    DeckTriageCard(data: .unresolved, onAction: { _, _ in })
        .padding().environment(\.palette, .vividLight)
}
#Preview("Decision — empty deck and large text") {
    DeckTriageCard(data: DeckTriageData(items: [DeckTriageItem(
        row: DeckRowViewData(id: 90, name: "A long deck name that needs room to wrap", fullName: "Empty",
            newCount: 0, learnCount: 0, reviewCount: 0, isFiltered: false, subdeckCount: 2, cardCount: 0),
        issue: .empty)]), onAction: { _, _ in })
        .padding().environment(\.palette, .vividLight).environment(\.dynamicTypeSize, .accessibility3)
}
#Preview("Decision — paused and error") {
    DeckTriageCard(data: DeckTriageData(items: [DeckTriageItem(row: DeckTriageData.sample.items[0].row,
        issue: .parked)], errorMessage: "Couldn't restore cards. Try again.", manualReviewCount: 2), onAction: { _, _ in })
        .padding().environment(\.palette, ThemeRegistry.shared.palette(id: .minimal, scheme: .dark))
}
#endif
#endif
