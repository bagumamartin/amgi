import SwiftUI
import AmgiUI
package import AmgiCardWeb
import AmgiTheme
import AmgiAppCore
import Sharing
import AmgiReviewCore

extension CardRenderEngine {
    package var displayName: String {
        switch self {
        case .auto: L10n.text("Auto")
        case .alwaysNative: L10n.text("Native")
        case .alwaysHTML: L10n.text("HTML")
        }
    }

    package var summary: String {
        switch self {
        case .auto: L10n.text("Simple cards render natively, the rest use the template's HTML.")
        case .alwaysNative: L10n.text("Prefer native rendering wherever the card allows it.")
        case .alwaysHTML: L10n.text("Always render the template's HTML in the sandboxed web view.")
        }
    }
}

/// R11 render-mode sheet: global engine radio (Auto / Native / HTML), a
/// "This card" explainer, and a per-template override row. Writes go to
/// appStorage; `onChanged` lets the reviewer re-resolve the current card.
struct RenderModeSheet: View {
    let explainer: String
    let template: ReviewSession.TemplateTarget?
    let templateName: String?
    let onChanged: () -> Void

    @Shared(.appStorage(ReviewPreferences.Keys.cardRenderEngine))
    private var engineRaw: String = CardRenderEngine.auto.rawValue

    @Shared(.appStorage(ReviewPreferences.Keys.templateRenderOverrides))
    private var overridesRaw: String = "{}"

    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(CardRenderEngine.allCases, id: \.self) { engine in
                        engineRow(engine)
                    }
                } footer: {
                    Text(L10n.format("This card: %@", [explainer]))
                }

                if let template {
                    Section {
                        Picker(L10n.text("Override"), selection: overrideBinding(for: template)) {
                            Text(L10n.text("Default")).tag(CardRenderEngine?.none)
                            Text(L10n.text("Native")).tag(CardRenderEngine?.some(.alwaysNative))
                            Text(L10n.text("HTML")).tag(CardRenderEngine?.some(.alwaysHTML))
                        }
                    } header: {
                        Text(templateName.map { L10n.format("Template · %@", [$0]) } ?? L10n.text("This template"))
                    } footer: {
                        Text(L10n.text("Overrides the global choice for every card of this template. Stored on this device only."))
                    }
                }
            }
            .navigationTitle(L10n.text("Card Rendering"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("Done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var globalEngine: CardRenderEngine {
        CardRenderEngine(rawValue: engineRaw) ?? .auto
    }

    private func engineRow(_ engine: CardRenderEngine) -> some View {
        Button {
            $engineRaw.withLock { $0 = engine.rawValue }
            onChanged()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(engine.displayName)
                        .foregroundStyle(palette.textPrimary)
                    Text(engine.summary)
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if engine == globalEngine {
                    Image(systemName: "checkmark")
                        .foregroundStyle(palette.accent)
                }
            }
        }
    }

    private func overrideBinding(for template: ReviewSession.TemplateTarget) -> Binding<CardRenderEngine?> {
        Binding(
            get: {
                TemplateRenderOverrides.engine(
                    for: template.notetypeId,
                    ord: template.ordinal,
                    in: overridesRaw
                )
            },
            set: { newValue in
                let updated = TemplateRenderOverrides.setting(
                    newValue,
                    mid: template.notetypeId,
                    ord: template.ordinal,
                    in: overridesRaw
                )
                $overridesRaw.withLock { $0 = updated }
                onChanged()
            }
        )
    }
}

#if DEBUG
#Preview {
    RenderModeSheet(
        explainer: "rendered natively — passes the simplicity check.",
        template: nil,
        templateName: "Card 1",
        onChanged: {}
    )
}
#endif
