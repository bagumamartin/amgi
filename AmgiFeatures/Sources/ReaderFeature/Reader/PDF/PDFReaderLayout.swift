import AmgiReader
import AmgiReaderPDF
import PDFKit
import SwiftUI

/// The reader's chrome: sidebar, canvas, toolbar and the page field.
///
/// Split by size class rather than by platform, because the decision that
/// matters is how much room there is, not what the device is. A Mac window
/// dragged narrow should collapse the sidebar exactly as an iPhone does.
struct PDFReaderLayout: View {
    let model: PDFReaderModel
    /// A binding, because the toolbar edits the transition, zoom, rotation and
    /// two-up setting directly, and routing each of those through a method would
    /// mean a setter per control.
    ///
    /// Explicitly a `Binding` rather than `@Bindable`: the projection of
    /// `@Bindable` is not itself a `Binding`, and passing one where the other is
    /// expected is the kind of thing that reads as a missing `&`.
    @Binding var navigation: PDFReaderNavigation

    @State private var sidebarTab: PDFSidebarTab = .thumbnails
    @State private var searchText: String = ""
    @State private var isSearchVisible = false
    @State private var searchResultCount = 0
    @State private var activeTool: PDFAnnotationTool?
    @State private var activeKind: PDFAnnotationKind = .highlight
    @State private var activeColour: PDFAnnotationColour = .yellow
    @State private var showsThickness = false

    var body: some View {
        VStack(spacing: 0) {
            if isSearchVisible {
                PDFSearchBar(
                    text: $searchText,
                    resultCount: searchResultCount,
                    onNext: { PDFViewCoordinatorRegistry.shared.coordinator?.stepSearchResult(by: 1) },
                    onPrevious: { PDFViewCoordinatorRegistry.shared.coordinator?.stepSearchResult(by: -1) },
                    onDismiss: {
                        isSearchVisible = false
                        searchText = ""
                    }
                )
                Divider()
            }
            HStack(spacing: 0) {
                if navigation.isSidebarVisible {
                    PDFSidebar(
                        model: model,
                        pageIndex: navigation.pageIndex,
                        tab: $sidebarTab,
                        onGoToPage: { index in
                            navigation.move(
                                toPage: index,
                                label: model.label(forPage: index),
                                count: model.pageCount,
                                userInitiated: true
                            )
                        },
                        onSelectAnnotation: { identifier in
                            model.selectedAnnotationID = identifier
                        }
                    )
                    .frame(width: 240)
                    Divider()
                }
                PDFPageCanvasContainer(
                    model: model,
                    navigation: navigation,
                    searchTerm: isSearchVisible && !searchText.isEmpty ? searchText : nil,
                    activeTool: activeTool,
                    activeKind: activeKind,
                    activeColour: activeColour,
                    onDraftCompleted: { kind, rect in
                        Task {
                            await model.addAnnotation(
                                kind: kind,
                                pageIndex: navigation.pageIndex,
                                bounds: rect,
                                colour: activeColour
                            )
                            // The tool stays selected, as it does in Preview:
                            // highlighting three phrases in a row is the common
                            // case, and deselecting after each one would make
                            // that three round trips through the toolbar.
                        }
                    },
                    onPageChanged: { index in
                        navigation.move(
                            toPage: index,
                            label: model.label(forPage: index),
                            count: model.pageCount,
                            userInitiated: true
                        )
                    },
                    onSearchResultsChanged: { count in
                        searchResultCount = count
                    }
                )
            }
            Divider()
            PDFReaderToolbar(
                navigation: $navigation,
                model: model,
                activeTool: $activeTool,
                activeKind: $activeKind,
                activeColour: $activeColour,
                showsThickness: $showsThickness,
                onToggleSidebar: { navigation.isSidebarVisible.toggle() },
                onGoToPage: { index in
                    navigation.move(
                        toPage: index,
                        label: model.label(forPage: index),
                        count: model.pageCount,
                        userInitiated: true
                    )
                },
                onSearch: {
                    isSearchVisible.toggle()
                    if !isSearchVisible { searchText = "" }
                },
                onEditAnnotation: { identifier in
                    // Editing is a text field over the annotation, which the
                    // model commits; the sheet is the only place the text can be
                    // typed without a custom keyboard over the page.
                    Task { await model.updateAnnotation(identifier: identifier, contents: "") }
                },
                onDeleteAnnotation: { identifier in
                    Task { _ = await model.removeAnnotation(identifier: identifier) }
                }
            )
        }
        .alert(
            "Could not save",
            isPresented: Binding(
                get: { model.writeError != nil },
                set: { if !$0 { model.writeError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.writeError = nil }
        } message: {
            // Said plainly because the consequence is the user's work
            // disappearing, and "something went wrong" does not tell them
            // whether to try again.
            Text(model.writeError ?? "")
        }
        .onChange(of: searchText) { _, term in
            if term.isEmpty {
                _ = PDFViewCoordinatorRegistry.shared.coordinator?.search(nil)
            }
        }
    }
}

/// Which list the sidebar shows.
enum PDFSidebarTab: String, CaseIterable, Identifiable, Sendable {
    case thumbnails
    case outline
    case annotations

    var id: String { rawValue }

    var label: String {
        switch self {
        case .thumbnails: "Pages"
        case .outline: "Contents"
        case .annotations: "Marks"
        }
    }

    var symbolName: String {
        switch self {
        case .thumbnails: "square.grid.2x2"
        case .outline: "list.bullet.indent"
        case .annotations: "highlighter"
        }
    }
}

/// Holds the live coordinator so the toolbar can drive search without it being
/// threaded through every view.
///
/// A small registry rather than an environment value because the coordinator is
/// owned by the representable's context and has to be reachable from the search
/// bar; passing it down would mean every intermediate view carrying a value it
/// does not use.
@MainActor
final class PDFViewCoordinatorRegistry {
    static let shared = PDFViewCoordinatorRegistry()
    weak var coordinator: PDFViewCoordinator?
    private init() {}
}

/// The canvas plus the draft overlay, so the representable stays free of
/// gesture and drawing code.
struct PDFPageCanvasContainer: View {
    let model: PDFReaderModel
    let navigation: PDFReaderNavigation
    let searchTerm: String?
    let activeTool: PDFAnnotationTool?
    let activeKind: PDFAnnotationKind
    let activeColour: PDFAnnotationColour
    let onDraftCompleted: (PDFAnnotationKind, CGRect) -> Void
    let onPageChanged: (Int) -> Void
    let onSearchResultsChanged: (Int) -> Void

    @State private var draft: PDFDraftRegion?

    var body: some View {
        ZStack {
            PDFPageCanvas(
                model: model,
                navigation: navigation,
                searchTerm: searchTerm,
                onPageChanged: onPageChanged,
                onSearchResultsChanged: onSearchResultsChanged
            )
            .overlay {
                if let draft, activeTool != nil {
                    PDFDraftOverlay(draft: draft, kind: activeKind, colour: activeColour)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(draftGesture)
        }
        .onChange(of: searchTerm) { _, term in
            // Search runs through the coordinator rather than through the model,
            // because the matches live on the `PDFView` and the coordinator is
            // the only thing that holds it.
            PDFViewCoordinatorRegistry.shared.coordinator?.search(term)
        }
    }

    /// The drag that creates an annotation.
    ///
    /// Present only while a tool is selected, and `nil` otherwise so SwiftUI
    /// installs no recogniser at all — an always-on drag gesture would consume
    /// every touch in the document and make the page impossible to scroll.
    private var draftGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard activeTool != nil else { return }
                draft = PDFDraftRegion(start: value.startLocation, current: value.location)
            }
            .onEnded { value in
                guard activeTool != nil else { return }
                let region = PDFDraftRegion(start: value.startLocation, current: value.location)
                draft = nil
                // A one-pixel drag is almost always an accidental touch, and
                // writing a zero-area annotation for one is how a page fills up
                // with invisible marks.
                guard region.isMeaningful else { return }
                onDraftCompleted(activeKind, region.rect)
            }
    }
}

/// Draws the region being dragged, so the user can see what they are about to
/// mark up before committing it.
private struct PDFDraftOverlay: View {
    let draft: PDFDraftRegion
    let kind: PDFAnnotationKind
    let colour: PDFAnnotationColour

    var body: some View {
        let rect = draft.rect
        shape(for: kind)
            .frame(width: rect.width, height: shapeHeight(for: kind, in: rect))
            .position(
                x: rect.midX,
                y: shapeMidY(for: kind, in: rect)
            )
    }

    @ViewBuilder
    private func shape(for kind: PDFAnnotationKind) -> some View {
        switch kind {
        case .highlight:
            Rectangle().fill(colour.swiftUIColor.opacity(0.35))
        case .underline:
            Rectangle().fill(colour.swiftUIColor.opacity(0.5))
        case .strikeOut:
            Rectangle().fill(colour.swiftUIColor.opacity(0.5))
        case .square:
            Rectangle().stroke(colour.swiftUIColor, lineWidth: 1.5)
        case .circle:
            Ellipse().stroke(colour.swiftUIColor, lineWidth: 1.5)
        case .line, .ink:
            Path { path in
                path.move(to: draft.start)
                path.addLine(to: draft.current)
            }
            .stroke(colour.swiftUIColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
        case .note, .freeText:
            RoundedRectangle(cornerRadius: 3).fill(colour.swiftUIColor.opacity(0.25))
        }
    }

    /// Underline and strike are bars at a particular edge, not filled regions.
    ///
    /// Drawn full-height they would read as a highlight while the file recorded
    /// an underline, and the mismatch only shows once the annotation is written.
    private func shapeHeight(for kind: PDFAnnotationKind, in rect: CGRect) -> CGFloat {
        switch kind {
        case .underline: max(2, rect.height * 0.12)
        case .strikeOut: max(2, rect.height * 0.1)
        default: rect.height
        }
    }

    private func shapeMidY(for kind: PDFAnnotationKind, in rect: CGRect) -> CGFloat {
        switch kind {
        case .underline: rect.maxY - rect.height * 0.06
        case .strikeOut: rect.midY
        default: rect.midY
        }
    }
}
