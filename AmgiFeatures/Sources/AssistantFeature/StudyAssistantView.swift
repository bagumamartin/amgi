public import SwiftUI
import AmgiAppCore
import AmgiTheme
import AmgiUI
import AnkiKit
import Foundation

/// A focused, private study assistant sheet. The first release is read-only:
/// it can explain the live review card, summarize today's deterministic study
/// load, and answer from a small bounded set of matching notes. It never rates,
/// schedules, edits, or deletes collection content.
public struct StudyAssistantView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.palette) private var palette

    @State private var model = StudyAssistantModel()
    @FocusState private var composerFocused: Bool

    private let initialPrompt: String?
    private let onOpenNote: (AssistantCitation) -> Void

    public init(
        initialPrompt: String? = nil,
        onOpenNote: @escaping (AssistantCitation) -> Void = { _ in }
    ) {
        self.initialPrompt = initialPrompt
        self.onOpenNote = onOpenNote
    }

    private var prefersWideLayout: Bool {
        #if os(macOS)
        true
        #else
        horizontalSizeClass == .regular
        #endif
    }

    public var body: some View {
        NavigationStack {
            Group {
                if prefersWideLayout {
                    regularLayout
                } else {
                    compactLayout
                }
            }
            .background(AssistantBackground())
            .navigationTitle("Study Assistant")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            #else
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            #endif
        }
        .task(id: initialPrompt ?? "initial") {
            await model.prepare(initialPrompt: initialPrompt)
        }
    }

    private var compactLayout: some View {
        VStack(spacing: 0) {
            assistantHeader
            conversation
            suggestions
            composer
        }
    }

    private var regularLayout: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: AmgiSpacing.xl) {
                    assistantHeader
                    overviewCard
                    suggestions
                    privacyNote
                }
                .padding(AmgiSpacing.xl)
            }
            .frame(maxWidth: 310)
            .amgiMaterial(.light, in: Rectangle())

            Divider()

            VStack(spacing: 0) {
                conversation
                composer
            }
        }
    }

    private var assistantHeader: some View {
        HStack(spacing: AmgiSpacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: AmgiRadius.hero, style: .continuous)
                    .fill(assistantGradient)
                Image(systemName: "sparkles")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(palette.surface)
            }
            .frame(width: 46, height: 46)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Study with context")
                    .amgiFont(.bodyEmphasis)
                Text(model.availability.detail)
                    .amgiFont(.caption)
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: AmgiSpacing.sm)
            AvailabilityPill(availability: model.availability)
        }
        .padding(.horizontal, AmgiSpacing.xl)
        .padding(.vertical, prefersWideLayout ? 0 : AmgiSpacing.lg)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: AmgiSpacing.lg) {
                    if !prefersWideLayout {
                        overviewCard
                    }

                    ForEach(model.messages) { message in
                        AssistantMessageView(
                            message: message,
                            onOpenCitation: { citation in
                                onOpenNote(citation)
                                dismiss()
                            }
                        )
                        .id(message.id)
                    }

                    if model.isThinking {
                        ThinkingRow()
                            .id("thinking")
                    }

                    if let errorMessage = model.errorMessage {
                        AssistantErrorBanner(message: errorMessage)
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, AmgiSpacing.xl)
                .padding(.vertical, AmgiSpacing.lg)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.messages.count) {
                withAnimation(AmgiMotion.standard) {
                    proxy.scrollTo(model.messages.last?.id, anchor: .bottom)
                }
            }
            .onChange(of: model.isThinking) {
                guard model.isThinking else { return }
                withAnimation(AmgiMotion.standard) { proxy.scrollTo("thinking", anchor: .bottom) }
            }
        }
    }

    private var overviewCard: some View {
        AmgiCard(background: .surfaceElevated) {
            VStack(alignment: .leading, spacing: AmgiSpacing.lg) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Today")
                            .amgiFont(.caption)
                            .foregroundStyle(palette.textSecondary)
                        Text("\(model.overview.due.total)")
                            .amgiFont(.displayHero, .monospacedDigits)
                            .contentTransition(.numericText())
                    }
                    Spacer()
                    Text(model.overview.profileName)
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(1)
                }

                HStack(spacing: AmgiSpacing.sm) {
                    CountMetric(
                        title: "New",
                        value: model.overview.due.newCount,
                        systemImage: "sparkle",
                        color: palette.cardStateNew
                    )
                    CountMetric(
                        title: "Learning",
                        value: model.overview.due.learnCount,
                        systemImage: "arrow.triangle.2.circlepath",
                        color: palette.cardStateLearning
                    )
                    CountMetric(
                        title: "Review",
                        value: model.overview.due.reviewCount,
                        systemImage: "checkmark.circle",
                        color: palette.cardStateReview
                    )
                }
            }
        }
    }

    private var suggestions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AmgiSpacing.sm) {
                ForEach(AssistantSuggestion.all) { suggestion in
                    Button {
                        if suggestion.action == .askCollection {
                            composerFocused = true
                        }
                        Task { await model.perform(suggestion) }
                    } label: {
                        HStack(spacing: AmgiSpacing.sm) {
                            Image(systemName: suggestion.systemImage)
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(suggestion.title)
                                    .amgiFont(.captionBold)
                                if prefersWideLayout {
                                    Text(suggestion.subtitle)
                                        .amgiFont(.micro)
                                        .foregroundStyle(palette.textSecondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .foregroundStyle(palette.textPrimary)
                        .padding(.horizontal, 14)
                        .frame(height: prefersWideLayout ? 54 : 42)
                        .background(
                            palette.surfaceElevated,
                            in: Capsule(style: .continuous)
                        )
                        .overlay {
                            Capsule(style: .continuous)
                                .stroke(palette.separator, lineWidth: 0.5)
                        }
                    }
                    .buttonStyle(.pressScale)
                    .disabled(model.isThinking)
                }
            }
            .padding(.horizontal, AmgiSpacing.xl)
            .padding(.vertical, AmgiSpacing.sm)
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: AmgiSpacing.sm) {
            TextField(
                model.composerPlaceholder,
                text: $model.draft,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .lineLimit(1...5)
            .focused($composerFocused)
            .submitLabel(.send)
            .onSubmit { Task { await model.sendDraft() } }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(palette.surfaceElevated, in: RoundedRectangle(cornerRadius: AmgiRadius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AmgiRadius.card, style: .continuous)
                    .stroke(palette.separator, lineWidth: 0.5)
            }

            Button {
                Task { await model.sendDraft() }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(palette.surface)
                    .frame(width: 42, height: 42)
                    .background(palette.accent, in: Circle())
            }
            .buttonStyle(.pressScale)
            .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isThinking)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, AmgiSpacing.xl)
        .padding(.vertical, AmgiSpacing.md)
        .amgiMaterial(.regular, in: Rectangle())
    }

    private var privacyNote: some View {
        Label {
            Text("Only bounded note results are sent to Apple’s on-device model. Ijuka never sends assistant requests to its own server.")
                .amgiFont(.caption)
                .foregroundStyle(palette.textSecondary)
        } icon: {
            Image(systemName: "lock.shield")
                .foregroundStyle(.tint)
        }
        .padding(.horizontal, 4)
    }

    private var assistantGradient: LinearGradient {
        LinearGradient(
            colors: [palette.accent, palette.info.opacity(0.88)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

private struct AvailabilityPill: View {
    @Environment(\.palette) private var palette
    let availability: AssistantModelAvailability

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(availability.title)
                .amgiFont(.micro)
                .fontWeight(.semibold)
        }
        .foregroundStyle(palette.textSecondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .amgiMaterial(.light, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Model status: \(availability.title), \(availability.detail)")
    }

    private var color: Color {
        switch availability {
        case .ready: palette.positive
        case .disabled: palette.textSecondary
        case .unavailable: palette.warning
        }
    }
}

private struct CountMetric: View {
    let title: String
    let value: Int
    let systemImage: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: systemImage)
                .amgiFont(.micro)
                .foregroundStyle(color)
                .lineLimit(1)
            Text("\(value)")
                .amgiFont(.bodyEmphasis, .monospacedDigits)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous))
    }
}

private struct AssistantMessageView: View {
    @Environment(\.palette) private var palette
    let message: AssistantMessage
    let onOpenCitation: (AssistantCitation) -> Void

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 44) }
            VStack(alignment: .leading, spacing: AmgiSpacing.sm) {
                Text(message.text)
                    .amgiFont(.body)
                    .foregroundStyle(message.role == .user ? palette.surface : palette.textPrimary)
                    .textSelection(.enabled)

                if !message.citations.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Sources")
                            .amgiFont(.micro)
                            .foregroundStyle(palette.textSecondary)
                        ForEach(message.citations) { citation in
                            Button {
                                onOpenCitation(citation)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "note.text")
                                    Text(citation.title)
                                        .lineLimit(1)
                                    Spacer(minLength: 4)
                                    Image(systemName: "arrow.up.right")
                                        .amgiFont(.caption)
                                }
                                .amgiFont(.caption)
                                .foregroundStyle(palette.textPrimary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .padding(message.role == .user
                ? EdgeInsets(top: 11, leading: 15, bottom: 11, trailing: 15)
                : EdgeInsets(top: AmgiSpacing.lg, leading: AmgiSpacing.lg, bottom: AmgiSpacing.lg, trailing: AmgiSpacing.lg)
            )
            .background(
                message.role == .user ? AnyShapeStyle(palette.accent) : AnyShapeStyle(palette.textTertiary.opacity(0.08)),
                in: RoundedRectangle(cornerRadius: AmgiRadius.card, style: .continuous)
            )
            if message.role != .user { Spacer(minLength: 44) }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct ThinkingRow: View {
    @Environment(\.palette) private var palette
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
            Text("Thinking on device…")
                .amgiFont(.caption)
                .foregroundStyle(palette.textSecondary)
            ProgressView()
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .amgiMaterial(.light, in: Capsule())
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(450))
                phase = (phase + 1) % 3
            }
        }
        .accessibilityLabel("Thinking on device")
    }
}

private struct AssistantErrorBanner: View {
    @Environment(\.palette) private var palette
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .amgiFont(.caption)
            .foregroundStyle(palette.warning)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(palette.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous))
    }
}

private struct AssistantBackground: View {
    @Environment(\.palette) private var palette

    var body: some View {
        LinearGradient(
            colors: [palette.accent.opacity(0.06), Color.clear, palette.info.opacity(0.04)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}
