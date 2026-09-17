import SwiftUI
import AmgiTheme
#if canImport(GameController)
import GameController
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Shared between the field hosts and the Add/Edit chrome so format
/// controls can live on the keyboard accessory, the hardware-keyboard nav
/// bar, or a Mac tool strip without each field drawing its own row.
@Observable
@MainActor
final class NoteFieldEditingSession {
    weak var responder: (any NoteFieldFormatResponder)?
    /// Kept after the keyboard resigns so camera/library sheets can still
    /// insert into the field that invoked them.
    weak var insertionResponder: (any NoteFieldFormatResponder)?
    var focusedFieldIndex: Int?
    var hasHardwareKeyboard = false
    var currentStyle: NoteFieldHTML.Style = .init()
    var currentListKind: NoteFieldHTML.ListKind = .none
    var currentAlignment: NoteFieldHTML.Alignment = .unspecified
    var currentIndent = 0
    var canUndo = false
    var canRedo = false
    var showsClozeTools = false
    /// Image attachment tapped in the rich surface (nil in HTML-source mode).
    /// Drives the format bar's Image Size menu; cleared on taps elsewhere.
    var selectedImage: SelectedFieldImage?
    var clozeFields: [String] = []
    var lastClozeOrdinal = 1
    var pendingMediaSource: NoteFieldMediaSource?
    var htmlSourceFields: Set<Int> = []
    /// Configurable automatic closing tags in HTML-source mode (desktop parity).
    var htmlAutoCloseTags = true
    /// Cursor line/column for the source status readout (HTML-source only).
    var sourceCursor: (line: Int, column: Int)?

    private static let autoCloseKey = "browse.html.autoCloseTags"

    init() {
        if let saved = UserDefaults.standard.object(forKey: Self.autoCloseKey) as? Bool {
            htmlAutoCloseTags = saved
        }
    }

    func setHTMLAutoClose(_ enabled: Bool) {
        htmlAutoCloseTags = enabled
        UserDefaults.standard.set(enabled, forKey: Self.autoCloseKey)
    }

    var isEditing: Bool { responder != nil }

    var chrome: NoteFieldChromeState {
        NoteFieldChromeState(
            style: currentStyle,
            listKind: currentListKind,
            alignment: currentAlignment,
            indent: currentIndent,
            canUndo: canUndo,
            canRedo: canRedo,
            showsCloze: showsClozeTools,
            isHTMLSource: focusedFieldIndex.map { htmlSourceFields.contains($0) } ?? false,
            selectedImage: selectedImage,
            sourceCursorLine: sourceCursor?.line,
            sourceCursorColumn: sourceCursor?.column
        )
    }

    /// Hardware keyboards leave `inputAccessoryView` stranded at the bottom
    /// of the screen; surface the same bar in navigation chrome instead.
    var showsNavigationFormatBar: Bool {
        #if os(iOS)
        isEditing && hasHardwareKeyboard
        #else
        false
        #endif
    }

    func attach(responder: any NoteFieldFormatResponder, fieldIndex: Int) {
        self.responder = responder
        insertionResponder = responder
        focusedFieldIndex = fieldIndex
        refreshHardwareKeyboard()
        refreshChrome()
    }

    func detach(responder: any NoteFieldFormatResponder) {
        if self.responder === responder {
            self.responder = nil
            focusedFieldIndex = nil
            currentStyle = .init()
            currentListKind = .none
            currentAlignment = .unspecified
            currentIndent = 0
            canUndo = false
            canRedo = false
        }
    }

    func refreshChrome() {
        currentStyle = responder?.currentStyle ?? .init()
        currentListKind = responder?.currentListKind ?? .none
        currentAlignment = responder?.currentAlignment ?? .unspecified
        currentIndent = responder?.currentIndent ?? 0
        canUndo = responder?.canUndo ?? false
        canRedo = responder?.canRedo ?? false
    }

    /// Audio recording request (handled by `NoteFieldMediaBridge`, which owns
    /// the recorder lifecycle + media import, not the text responder).
    var pendingAudioRecord = false

    func perform(_ action: NoteFieldFormatAction) {
        switch action {
        case .camera:
            pendingMediaSource = .camera
        case .photoLibrary:
            pendingMediaSource = .library
        case .attach:
            pendingMediaSource = .files
        case .recordAudio:
            pendingAudioRecord = true
        default:
            responder?.perform(action)
        }
    }

    func insertMedia(filename: String) {
        let target = responder ?? insertionResponder
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        if Self.imageExtensions.contains(ext) {
            target?.insertImage(filename: filename)
        } else {
            target?.insertSound(filename: filename)
        }
    }

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "heic",
    ]

    /// Cloze ordinals initialize from existing content (upstream parity):
    /// "new number" is max+1, "same number" is max (or 1 when empty) —
    /// never a session-fixed 1 that collides with existing clozes.
    func nextClozeOrdinal(increment: Bool) -> Int {
        if increment {
            lastClozeOrdinal = NoteFieldHTML.nextClozeOrdinal(in: clozeFields)
        } else {
            lastClozeOrdinal = max(1, NoteFieldHTML.nextClozeOrdinal(in: clozeFields) - 1)
        }
        return lastClozeOrdinal
    }

    func refreshHardwareKeyboard() {
        #if canImport(GameController) && os(iOS)
        hasHardwareKeyboard = GCKeyboard.coalesced != nil
        #elseif os(macOS)
        hasHardwareKeyboard = true
        #else
        hasHardwareKeyboard = false
        #endif
    }
}

extension EnvironmentValues {
    @Entry var noteFieldEditingSession: NoteFieldEditingSession? = nil
}

#if os(iOS)
struct NoteFieldKeyboardMonitor: ViewModifier {
    var session: NoteFieldEditingSession

    func body(content: Content) -> some View {
        content
            .onAppear { session.refreshHardwareKeyboard() }
            .onReceive(
                NotificationCenter.default.publisher(for: .GCKeyboardDidConnect)
            ) { _ in session.refreshHardwareKeyboard() }
            .onReceive(
                NotificationCenter.default.publisher(for: .GCKeyboardDidDisconnect)
            ) { _ in session.refreshHardwareKeyboard() }
    }
}
#endif

struct NoteFieldFormatChrome: ViewModifier {
    var session: NoteFieldEditingSession

    func body(content: Content) -> some View {
        content
            .environment(\.noteFieldEditingSession, session)
            #if os(iOS)
            .modifier(NoteFieldKeyboardMonitor(session: session))
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if session.showsNavigationFormatBar {
                    formatBar(showsDismiss: true)
                }
            }
            #endif
            #if os(macOS)
            .safeAreaInset(edge: .top, spacing: 0) {
                formatBar(showsDismiss: false)
            }
            #endif
            .background { formatShortcuts }
    }

    private func formatBar(showsDismiss: Bool) -> some View {
        NoteFieldFormatBar(
            showsDismiss: showsDismiss,
            chrome: session.chrome,
            perform: { session.perform($0) },
            autoCloseEnabled: session.htmlAutoCloseTags,
            onToggleAutoClose: { session.setHTMLAutoClose(!session.htmlAutoCloseTags) }
        )
    }

    @ViewBuilder
    private var formatShortcuts: some View {
        Group {
            Button("Bold") { session.perform(.bold) }
                .keyboardShortcut("b", modifiers: .command)
            Button("Italic") { session.perform(.italic) }
                .keyboardShortcut("i", modifiers: .command)
            Button("Underline") { session.perform(.underline) }
                .keyboardShortcut("u", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}
