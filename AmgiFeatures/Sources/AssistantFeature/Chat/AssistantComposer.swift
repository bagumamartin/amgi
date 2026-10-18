import AmgiAppCore
import AmgiTheme
import AmgiUI
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The message box: attached contexts and files as chips, the text field,
/// and a bottom bar with the + menu, the model picker and Send.
struct AssistantComposer: View {
    @Bindable var engine: AssistantEngine
    var focused: FocusState<Bool>.Binding
    let send: () -> Void
    let showContextPicker: () -> Void
    let showConnections: () -> Void

    @Environment(\.palette) private var palette
    @State private var showsPhotoPicker = false
    @State private var showsFileImporter = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var attachError: String?

    private var canSend: Bool { !engine.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: AmgiSpacing.md) {
            if !engine.contexts.isEmpty || !engine.attachments.isEmpty {
                chips
            }
            TextField(placeholder, text: $engine.draft, axis: .vertical)
                .amgiFont(.body)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .focused(focused)
                .submitLabel(.send)
                .onSubmit(send)
                .padding(.horizontal, AmgiSpacing.xs)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .contentShape(Rectangle())
                .accessibilityIdentifier("assistant.composer")
            if let attachError {
                Text(attachError)
                    .amgiFont(.micro)
                    .foregroundStyle(palette.warning)
                    .padding(.horizontal, AmgiSpacing.xs)
            }
            HStack(spacing: AmgiSpacing.sm) {
                plusMenu
                AssistantModelMenu(engine: engine, showConnections: showConnections)
                Spacer(minLength: 0)
                #if os(iOS)
                if focused.wrappedValue {
                    Button { focused.wrappedValue = false } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(palette.textSecondary)
                            .frame(width: 34, height: 34)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    .accessibilityLabel("Hide keyboard")
                    .accessibilityIdentifier("assistant.hideKeyboard")
                }
                #endif
                sendButton
            }
            if engine.model.provider == .chatGPT {
                ChatGPTPlanIndicator()
                    .padding(.horizontal, AmgiSpacing.xs)
                    .transition(.opacity)
            }
        }
        .padding(AmgiSpacing.md)
        // The whole box is the place to type, not just the line of text:
        // a tap anywhere that isn't a control focuses the field. Buttons,
        // menus and chip ✕s inside take their own taps first.
        .contentShape(RoundedRectangle(cornerRadius: AmgiRadius.card, style: .continuous))
        .onTapGesture { focused.wrappedValue = true }
        .animation(AmgiMotion.quick, value: focused.wrappedValue)
        .background(palette.surfaceElevated, in: RoundedRectangle(cornerRadius: AmgiRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AmgiRadius.card, style: .continuous)
                .strokeBorder(palette.separator, lineWidth: 1)
        }
        .amgiChromeShadow(RoundedRectangle(cornerRadius: AmgiRadius.card, style: .continuous), radius: 16, y: 6, opacity: 0.08)
        .padding(.horizontal, AmgiSpacing.md)
        .padding(.bottom, AmgiSpacing.sm)
        .photosPicker(isPresented: $showsPhotoPicker, selection: $photoItems, maxSelectionCount: max(1, AssistantAttachment.limit - engine.attachments.count), matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task { await importPhotos(items) }
        }
        .fileImporter(isPresented: $showsFileImporter, allowedContentTypes: [.pdf, .image], allowsMultipleSelection: true) { result in
            importFiles(result)
        }
        .onChange(of: engine.model) { _, model in
            // Files can't go to Apple's model; say so rather than drop them silently.
            if !model.provider.isCloud, !engine.attachments.isEmpty {
                attachError = L10n.text("Photos and files go only to ChatGPT or Claude. They'll be left out on this model.")
            } else {
                attachError = nil
            }
        }
    }

    private var placeholder: String {
        if let first = engine.contexts.first { return L10n.text("Ask about \(first.title)") }
        return engine.turns.isEmpty ? L10n.text("Ask anything") : L10n.text("Ask a follow-up")
    }

    // MARK: Chips

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AmgiSpacing.sm) {
                ForEach(engine.contexts) { context in
                    AssistantContextChip(context: context) {
                        withAnimation(AmgiMotion.quick) { engine.remove(context) }
                    }
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
                ForEach(engine.attachments) { attachment in
                    AssistantAttachmentChip(name: attachment.name, kind: attachment.kind, thumbnail: attachment.thumbnail, dimmed: !engine.acceptsAttachments) {
                        withAnimation(AmgiMotion.quick) { engine.detach(attachment) }
                    }
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
            .padding(.vertical, 1)
        }
        .scrollClipDisabled()
    }

    // MARK: Menus

    private var plusMenu: some View {
        Menu {
            Button("Add Context…", systemImage: "plus.viewfinder", action: showContextPicker)
            Section {
                Button("Photos", systemImage: "photo.on.rectangle") { showsPhotoPicker = true }
                    .disabled(!engine.acceptsAttachments || engine.attachments.count >= AssistantAttachment.limit)
                Button("Files", systemImage: "doc") { showsFileImporter = true }
                    .disabled(!engine.acceptsAttachments || engine.attachments.count >= AssistantAttachment.limit)
            } footer: {
                if !engine.acceptsAttachments {
                    Text("Photos and PDFs need ChatGPT or Claude")
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
                .frame(width: 34, height: 34)
                .background(palette.background, in: Circle())
                .contentShape(Circle())
        }
        .menuIndicator(.hidden)
        #if os(macOS)
        .menuStyle(.button)
        #endif
        .buttonStyle(.plain)
        .accessibilityLabel("Add context or files")
        .accessibilityIdentifier("assistant.add")
    }

    private var sendButton: some View {
        Button {
            if engine.isBusy { engine.stop() } else { send() }
        } label: {
            Image(systemName: engine.isBusy ? "stop.fill" : "arrow.up")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(canSend || engine.isBusy ? palette.background : palette.textTertiary)
                .frame(width: 34, height: 34)
                .background(canSend || engine.isBusy ? palette.textPrimary : palette.separator, in: Circle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .disabled(!canSend && !engine.isBusy)
        .keyboardShortcut(.return, modifiers: .command)
        .accessibilityLabel(engine.isBusy ? "Stop" : "Send")
    }

    // MARK: Import

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        attachError = nil
        for (index, item) in items.enumerated() {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                let attachment = try AssistantAttachment.image(data, name: L10n.text("Photo \(engine.attachments.count + 1)"))
                try withAnimation(AmgiMotion.quick) { try engine.attach(attachment) }
            } catch {
                attachError = AssistantProviderStore.describe(error)
                if index > 0 { break }
            }
        }
    }

    private func importFiles(_ result: Result<[URL], any Error>) {
        attachError = nil
        do {
            for url in try result.get() {
                let attachment = try AssistantAttachment.file(at: url)
                try withAnimation(AmgiMotion.quick) { try engine.attach(attachment) }
            }
        } catch {
            attachError = AssistantProviderStore.describe(error)
        }
    }
}

// MARK: - Chips

/// One attached context: an icon tile, its name and where it lives, and ×.
struct AssistantContextChip: View {
    let context: AssistantContext
    var remove: (() -> Void)?
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: AmgiSpacing.sm) {
            Image(systemName: context.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.accent)
                .frame(width: 28, height: 28)
                .background(palette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: AmgiRadius.small, style: .continuous))
            VStack(alignment: .leading, spacing: 0) {
                Text(context.title)
                    .amgiFont(.captionBold)
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                Text(context.caption)
                    .amgiFont(.micro)
                    .foregroundStyle(palette.textTertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: 180, alignment: .leading)
            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(palette.textTertiary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(context.title)")
            }
        }
        .padding(.leading, AmgiSpacing.xs)
        .padding(.trailing, remove == nil ? AmgiSpacing.md : AmgiSpacing.xs)
        .padding(.vertical, AmgiSpacing.xs)
        .background(palette.background, in: RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct AssistantAttachmentChip: View {
    let name: String
    let kind: AssistantAttachment.Kind
    let thumbnail: Data?
    var dimmed = false
    var remove: (() -> Void)?
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: AmgiSpacing.sm) {
            preview
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: AmgiRadius.small, style: .continuous))
            Text(name)
                .amgiFont(.captionBold)
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: 140, alignment: .leading)
            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(palette.textTertiary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(name)")
            }
        }
        .padding(.leading, AmgiSpacing.xs)
        .padding(.trailing, remove == nil ? AmgiSpacing.md : AmgiSpacing.xs)
        .padding(.vertical, AmgiSpacing.xs)
        .background(palette.background, in: RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous))
        .opacity(dimmed ? 0.5 : 1)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var preview: some View {
        if let thumbnail, let image = AssistantImage.make(thumbnail) {
            image.resizable().scaledToFill()
        } else {
            Image(systemName: kind == .pdf ? "doc.richtext" : "photo")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(palette.accent.opacity(0.12))
        }
    }
}

enum AssistantImage {
    static func make(_ data: Data) -> Image? {
        #if os(macOS)
        NSImage(data: data).map { Image(nsImage: $0) }
        #else
        UIImage(data: data).map { Image(uiImage: $0) }
        #endif
    }
}

// MARK: - Model menu

/// The model a message goes to, grouped by provider, with a way to connect
/// one. A capsule in the composer's bottom bar.
struct AssistantModelMenu: View {
    let engine: AssistantEngine
    let showConnections: () -> Void
    @Environment(\.palette) private var palette

    private var store: AssistantProviderStore { engine.providers }

    var body: some View {
        Menu {
            Section("On This Device") {
                choice(.onDevice, detail: FoundationModelService.availability == .ready ? nil : FoundationModelService.availability.detail)
            }
            ForEach(AssistantProvider.allCases.filter { $0.isCloud && store.isConnected($0) }) { provider in
                Section(provider.title) {
                    let models = store.models[provider] ?? []
                    if models.isEmpty {
                        Button(store.loading.contains(provider) ? "Loading models…" : "Load Models", systemImage: "arrow.clockwise") {
                            Task { await store.refreshModels(provider) }
                        }
                    }
                    ForEach(models.prefix(14)) { model in choice(model, detail: nil) }
                }
            }
            if engine.model.provider == .chatGPT {
                Section("Using ChatGPT plan") {
                    Link(destination: ChatGPTBrand.manageUsageURL) { Label("Manage Usage", systemImage: "gauge.with.dots.needle.33percent") }
                }
            }
            Section {
                Button(store.hasCloudProvider ? "Manage Connections…" : "Connect ChatGPT or Claude…", systemImage: "link", action: showConnections)
            }
        } label: {
            HStack(spacing: AmgiSpacing.xs) {
                ProviderGlyph(provider: engine.model.provider, size: 13)
                Text(engine.model.name)
                    .amgiFont(.captionBold)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(palette.textTertiary)
            }
            .foregroundStyle(palette.textSecondary)
            .padding(.horizontal, AmgiSpacing.md)
            .frame(height: 34)
            .background(palette.background, in: Capsule())
            .contentShape(Capsule())
        }
        .menuIndicator(.hidden)
        #if os(macOS)
        .menuStyle(.button)
        #endif
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Model: \(engine.model.name)")
        .accessibilityIdentifier("assistant.model")
    }

    @ViewBuilder private func choice(_ model: AssistantModel, detail: String?) -> some View {
        Button {
            store.select(model)
        } label: {
            if engine.model == model {
                Label(model.name, systemImage: "checkmark")
            } else if let detail {
                Text("\(model.name) — \(detail)")
            } else {
                Text(model.name)
            }
        }
        .disabled(engine.isBusy)
    }
}
