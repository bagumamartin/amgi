package import SwiftUI
import AmgiAppCore
import AmgiAppShared
import AmgiTheme
import AppIntents
import AmgiUI
import AnkiKit
import AnkiClients
import Dependencies
import Sharing

/// Library container: owns navigation, sheets, and the toolbar, and drives
/// a `DeckListModel` for load/refresh + deck mutations. Rendering is
/// delegated to `LibraryListContent` (AmgiUI); data assembly lives in the
/// model. The View is intentionally thin — presentation wiring only.
///
/// Two arrangements over the same model:
/// - **Stack** (iPhone, iPad portrait): the list, with the hero and heatmap
///   in it, pushing deck detail.
/// - **Split** (iPad landscape, Mac): the list as a column beside a detail
///   pane that shows Today (hero + heatmap) or the selected deck. Subdecks
///   push inside that pane, so the parent stays selected in the list.
///
/// The container owns its navigation container for that reason — the host
/// must not wrap it in a `NavigationStack`.
package struct DeckListView: View {
    @Dependency(\.collectionStore) private var store
    @Shared(.appStorage(NavigationPreferences.deckSortOrder)) private var sortOrderRaw: String = DeckSortOrder.mostUsed.rawValue
    @State private var model: DeckListModel
    @State private var showCreateSheet = false
    @State private var showImport = false
    @State private var renameTarget: DeckRowViewData?
    @State private var pendingDeck: DeckInfo?
    @State private var decisionRequest: DeckDecisionRequest?
    @State private var decisionReview: DeckDecisionReviewMode?
    /// What the split's detail pane shows.
    @State private var detail: LibraryDetail = .today
    /// iPad: subdecks opened inside the detail pane, under `detail`'s deck.
    @State private var subdeckPath: [DeckInfo] = []
    /// iPad: subdecks stepped back out of, for Forward.
    @State private var subdeckForward: [DeckInfo] = []
    #if os(iOS)
    @Environment(\.tabBarPlacement) private var tabBarPlacement
    @Environment(\.accountMenuProvider) private var accountMenuProvider
    /// iPad panes draw the profile chip inside their own bar item, so they
    /// own the Settings / Manage Profiles push it opens.
    @State private var paneAccountDestination: AccountMenuDestination?
    /// Tab bar mode: the chip's own width, which doesn't depend on the spacer
    /// after it, so sizing the spacer from it can't feed back.
    @State private var paneChipWidth: CGFloat = 0
    /// The screen's width, which in tab bar mode is the bar's. Measured on
    /// content, never from inside the bar.
    @State private var arrangementWidth: CGFloat = 0
    /// Left edge of this screen in the window. Zero while the portrait
    /// sidebar floats over it; past the sidebar when they sit side by side.
    @State private var arrangementMinX: CGFloat = 0
    /// Each pane's heading has scrolled under the bar, so the bar shows its
    /// title instead — the iPhone large-title behaviour, per pane.
    @State private var listHeadingAway = false
    @State private var deckHeadingAway = false
    #endif
    /// Nil until the first layout pass has measured the width, so the screen
    /// does not build one arrangement only to swap it for the other.
    @State private var usesSplit: Bool?
    #if os(macOS)
    @State private var macColumns: NavigationSplitViewVisibility = .all
    #endif
    /// Deck detail grows out of the row that was tapped, rather than cutting
    /// in from the trailing edge — the row and the screen are the same thing.
    @Namespace private var deckTransition

    /// Profile switching lives on the root sidebar footer (iPad / Mac) or the
    /// toolbar account menu (iPhone), not here — applying it twice doubled
    /// the leading profile pill.
    /// A deck to push once, from a deck-scoped widget. Cleared after use.
    @Binding private var openDeckID: Int64?
    /// macOS: the app's section sidebar. Library then takes the window as a
    /// three-column split — sidebar, list, detail — so each column gets its
    /// own section of the window toolbar.
    private let sidebar: AnyView?
    /// The host's toolbar and destinations for the list column (the
    /// account menu). Applied inside this view's navigation container. The
    /// flag says whether the host should add its profile chip; the iPad
    /// panes draw their own.
    private let columnChrome: (AnyView, Bool) -> AnyView

    package init(
        openDeckID: Binding<Int64?> = .constant(nil),
        sidebar: AnyView? = nil,
        columnChrome: @escaping (AnyView, Bool) -> AnyView = { view, _ in view }
    ) {
        _model = State(initialValue: DeckListModel())
        _openDeckID = openDeckID
        self.sidebar = sidebar
        self.columnChrome = columnChrome
    }

    /// Preview / test seam — internal so the model stays module-private.
    init(model: DeckListModel) {
        _model = State(initialValue: model)
        _openDeckID = .constant(nil)
        sidebar = nil
        columnChrome = { view, _ in view }
    }

    private var sortOrderBinding: Binding<DeckSortOrder> {
        Binding(
            get: { DeckSortOrder(rawValue: sortOrderRaw) ?? .mostUsed },
            set: { newOrder in
                $sortOrderRaw.withLock { $0 = newOrder.rawValue }
                model.resort(sortOrder: newOrder)
            }
        )
    }

    package var body: some View {
        arrangement
            #if os(iOS)
            .onGeometryChange(for: CGRect.self) { proxy in
                let frame = proxy.frame(in: .global)
                return CGRect(x: frame.minX.rounded(), y: 0, width: frame.width.rounded(), height: 0)
            } action: { frame in
                arrangementWidth = frame.width
                arrangementMinX = frame.minX
                usesSplit = frame.width >= LibrarySplitMetrics.minimumSplitWidth
            }
            #endif
            .onChange(of: usesSplit) { old, new in
                carrySelection(from: old, to: new)
            }
            .modifier(DeckDecisionPresentation(model: model, request: $decisionRequest,
                presentsErrors: decisionReview == nil, onViewDeck: { show($0) }))
            .sheet(item: $decisionReview) { mode in
                DeckDecisionReviewView(model: model, mode: mode, onViewDeck: { deck in
                    decisionReview = nil
                    show(deck)
                })
            }
            .sheet(isPresented: $showCreateSheet) {
                CreateDeckSheet {
                    showCreateSheet = false
                }
            }
            .sheet(item: $renameTarget) { row in
                RenameDeckSheet(deckId: DeckID(row.id), currentName: row.fullName) {
                    renameTarget = nil
                }
            }
            .deckImport(isPresented: $showImport)
            // Keyed on the store's generation: any Invalidation (deck mutation,
            // sync, import, review-end) re-runs the load; `.task` still cancels
            // on disappear. Outside both arrangements, so switching between
            // them never reloads.
            .task(id: store.generation) { await model.load(sortOrder: sortOrderBinding.wrappedValue) }
            .task(id: openDeckID) { await openRequestedDeck() }
    }

    @ViewBuilder
    private var arrangement: some View {
        #if os(macOS)
        splitArrangement
        #else
        switch usesSplit {
        case .some(true): splitArrangement
        case .some(false): stackArrangement
        case .none: Color.clear
        }
        #endif
    }

    private var isSplit: Bool {
        #if os(macOS)
        true
        #else
        usesSplit == true
        #endif
    }

    // MARK: Stack

    private var stackArrangement: some View {
        NavigationStack {
            columnChrome(AnyView(listColumn(selection: nil)), true)
                .navigationDestination(item: $pendingDeck) { deck in
                    DeckDetailView(deck: deck)
                        #if os(iOS)
                        .navigationTransition(.zoom(sourceID: deck.id.rawValue, in: deckTransition))
                        #endif
                }
        }
    }

    // MARK: Split

    @ViewBuilder
    private var splitArrangement: some View {
        #if os(macOS)
        if let sidebar {
            NavigationSplitView(columnVisibility: $macColumns) {
                sidebar
            } content: {
                splitList
            } detail: {
                detailStack
            }
        } else {
            NavigationSplitView {
                splitList
            } detail: {
                detailStack
            }
        }
        #else
        paneArrangement
        #endif
    }

    #if os(macOS)
    private var splitList: some View {
        columnChrome(AnyView(listColumn(selection: detail.columnSelection)), true)
            .navigationSplitViewColumnWidth(LibrarySplitMetrics.listWidth)
    }

    /// A fresh stack per selection: picking another deck in the list drops
    /// the subdecks pushed under the previous one.
    private var detailStack: some View {
        NavigationStack {
            switch detail {
            case .today:
                todayPane
            case .deck(let deck):
                DeckDetailView(deck: deck)
            }
        }
        .environment(\.amgiPageIsPane, true)
        .id(detail.columnSelection)
    }
    #endif

    #if os(iOS)
    /// iPad: one stack, two panes. A `NavigationSplitView` here is the
    /// obvious tool and the wrong one — with a split as a tab's content,
    /// iPadOS gives the floating tab bar a row of its own and drops both
    /// column bars under it, and it ignores the list's column width. One
    /// stack keeps a single bar that shares the tab bar's row. The list's
    /// actions end at the list pane's right edge; back and forward start
    /// over the detail pane; the pane's own actions trail. Subdecks open
    /// inside the pane rather than pushing over the list. The structure
    /// is the same with the app sidebar open or collapsed, so toggling it
    /// rebuilds nothing.
    private var paneArrangement: some View {
        NavigationStack {
            columnChrome(AnyView(
                HStack(spacing: 0) {
                    listColumn(selection: detail.columnSelection)
                        .frame(width: LibrarySplitMetrics.listWidth)
                        .environment(\.amgiOnHeadingScrolledAway) { listHeadingAway = $0 }
                        // The seam runs the window's full height, through
                        // the bar above and the home-indicator inset below,
                        // the way the sidebar's edge does. Only the vertical
                        // insets are ignored: the stack itself reaches under
                        // the sidebar, so measuring from its leading edge
                        // would put the seam inside the list.
                        .overlay(alignment: .trailing) {
                            Rectangle()
                                .fill(.separator)
                                .frame(width: 0.5)
                                .ignoresSafeArea(edges: .vertical)
                                .accessibilityHidden(true)
                        }
                    detailPane
                        .frame(maxWidth: .infinity)
                        .environment(\.amgiPageIsPane, true)
                        .environment(\.amgiOnHeadingScrolledAway) { deckHeadingAway = $0 }
                }
                // The heading lives in the list pane; a bar title would sit
                // over both panes. Removing it only takes once the title is
                // inline — a large title ignores the removal.
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(removing: .title)
                .accountMenuDestinations($paneAccountDestination)
            ), false)
        }
        .onChange(of: detail.columnSelection) {
            subdeckPath = []
            subdeckForward = []
        }
        // A newly shown deck opens at its top, heading in view.
        .onChange(of: shownDeckID) { deckHeadingAway = false }
        .animation(AmgiMotion.standard, value: listHeadingAway)
        .animation(AmgiMotion.standard, value: deckHeadingAway)
    }

    @ViewBuilder
    private var detailPane: some View {
        switch detail {
        case .today:
            todayPane
        case .deck(let deck):
            let shown = subdeckPath.last ?? deck
            DeckDetailView(deck: shown, onOpenSubdeck: { subdeck in
                subdeckPath.append(subdeck)
                subdeckForward = []
            })
            .id(shown.id)
        }
    }

    private var shownDeck: DeckInfo? {
        guard case .deck(let deck) = detail else { return nil }
        return subdeckPath.last ?? deck
    }

    private var shownDeckID: Int64? { shownDeck?.id.rawValue }

    private var detailPaneTitle: Text {
        if let shownDeck {
            Text(verbatim: DeckDetailView.leafName(from: shownDeck.name))
        } else {
            Text("Today")
        }
    }

    private var isShowingDeck: Bool {
        if case .deck = detail { true } else { false }
    }

    private func goBack() {
        guard let last = subdeckPath.popLast() else { return }
        subdeckForward.append(last)
    }

    private func goForward() {
        guard let next = subdeckForward.popLast() else { return }
        subdeckPath.append(next)
    }

    #endif

    private var todayPane: some View {
        LibraryTodayPane(
            state: model.state,
            showsHeading: columnTitle != nil,
            onRefresh: { await model.load(sortOrder: sortOrderBinding.wrappedValue) }
        )
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                SyncToolbarButton()
            }
        }
    }

    // MARK: List column

    private func listColumn(selection: LibraryColumnSelection?) -> some View {
        let profile = AccountStore.shared.selectedContext
        return LibraryListContent(
            state: model.state,
            sortOrder: sortOrderBinding,
            onRefresh: { await model.load(sortOrder: sortOrderBinding.wrappedValue) },
            onTapDeck: { row in show(row.asDeckInfo) },
            onDeleteDeck: { rawID in
                if detail.columnSelection == .deck(rawID) { detail = .today }
                await model.delete(DeckID(rawID))
            },
            onRenameDeck: { row in renameTarget = row },
            onCreateDeck: { showCreateSheet = true },
            onDecision: { item, action in decisionRequest = DeckDecisionRequest(item: item, action: action) },
            onReviewDecisions: { model.beginDecisionReview(); decisionReview = .automatic },
            onReviewPausedDecks: { model.beginDecisionReview(); decisionReview = .paused },
            deckTransition: selection == nil ? deckTransition : nil,
            columnSelection: selection,
            columnTitle: columnTitle,
            onSelectToday: { detail = .today }
        )
        // `LibraryListContent` stores its closures, which makes it
        // incomparable to AttributeGraph by default — see the Equatable
        // conformance in AmgiUI. It declares equality over `state`, so this
        // turns a field walk into a value compare.
        .equatable()
        .appEntityIdentifierIfAvailable(forSelectionType: Int64.self) { rawID in
            guard let entity = DeckEntity(
                context: profile,
                deckID: DeckID(rawID),
                name: "Deck"
            ) else { return nil }
            return EntityIdentifier(for: entity)
        }
        .navigationTitle("Library")
        .toolbar { listToolbar(inPanes: selection != nil) }
    }

    /// iPad panes have no bar title, so the list pane carries the heading.
    /// Mac shows it in the list column's toolbar section.
    private var columnTitle: String? {
        #if os(iOS)
        "Library"
        #else
        nil
        #endif
    }

    // MARK: Selection

    /// Select in the split; push in the stack.
    private func show(_ deck: DeckInfo) {
        if isSplit {
            detail = .deck(deck)
            subdeckPath = []
            subdeckForward = []
        } else {
            pendingDeck = deck
        }
    }

    /// Rotating or resizing between the arrangements keeps the open deck
    /// open: a pushed deck becomes the selection, and back.
    private func carrySelection(from old: Bool?, to new: Bool?) {
        guard let old, let new, old != new else { return }
        if new {
            if let pendingDeck {
                detail = .deck(pendingDeck)
                self.pendingDeck = nil
            }
        } else if case .deck(let deck) = detail {
            pendingDeck = subdeckPath.last ?? deck
            subdeckPath = []
            detail = .today
        }
    }

    /// Subdecks are not Library rows, so resolve against the whole tree.
    private func openRequestedDeck() async {
        guard let id = openDeckID else { return }
        defer { openDeckID = nil }
        guard let deck = try? await store.tree().find(DeckID(id)) else { return }
        show(deck.asDeckInfo)
    }

    @ToolbarContentBuilder
    private func listToolbar(inPanes: Bool) -> some ToolbarContent {
        #if os(iOS)
        if inPanes {
            // One bar over both panes, so placement alone can't put these
            // over the list. With the sidebar open the list pane is a fixed
            // width from the bar's start, so one fixed-width item spans it
            // with the tools at its end. Nothing in it is measured. A version that sized itself from its own
            // on-screen position looped: every state change rebuilds bar
            // items, the rebuilt item measured again, and iOS killed the app.
            if let paneProfileChip {
                // Tab bar mode. The bar won't draw a fixed-width custom item
                // here (it shows only the item's first button), so these are
                // native items: the profile at the start, the tools pushed up
                // against the floating tab bar.
                ToolbarItem(placement: .topBarLeading) {
                    paneProfileChip
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                            settle(&paneChipWidth, $0)
                        }
                }
                if tabModeToolsFitBeforeTabBar {
                    ToolbarItem(placement: .topBarLeading) {
                        Color.clear
                            .frame(width: tabModeToolsOffset, height: 1)
                            .accessibilityHidden(true)
                    }
                    .sharedBackgroundVisibility(.hidden)
                    ToolbarItemGroup(placement: .topBarLeading) {
                        listActionButtons()
                    }
                } else {
                    // Portrait: no room before the tab bar. Left to itself the
                    // bar overflowed the whole leading side, profile included;
                    // the tools fold into one menu so the profile keeps the end.
                    // The menu sits up against the tab bar, apart from the
                    // profile, the way the tools sit at the list's edge in
                    // landscape.
                    ToolbarItem(placement: .topBarLeading) {
                        Color.clear
                            .frame(width: tabModeMenuOffset, height: 1)
                            .accessibilityHidden(true)
                    }
                    .sharedBackgroundVisibility(.hidden)
                    ToolbarItem(placement: .topBarLeading) {
                        Menu("Library actions", systemImage: "ellipsis") {
                            listActionButtons()
                        }
                    }
                }
            } else {
                ToolbarItem(placement: .topBarLeading) {
                    LibraryPaneBarItem(
                        title: Text("Library"),
                        showsTitle: listHeadingAway,
                        actions: AnyView(HStack(spacing: 0) { listActionButtons(framed: true) })
                    )
                }
                .sharedBackgroundVisibility(.hidden)
            }
            // With the app sidebar open, back/forward start just past the
            // list's edge, over the deck pane. With it collapsed the floating
            // tab bar sits there, and the leading side must stay within the
            // space before it: overflowing it made the bar shift the span,
            // which resized it, which shifted the bar — a layout loop that
            // got the app killed. There they lead the pane's trailing group.
            if isShowingDeck, !sidebarFloatsOverPanes {
                ToolbarItemGroup(placement: historyPlacement) {
                    Button("Back", systemImage: "chevron.left", action: goBack)
                        .disabled(subdeckPath.isEmpty)
                    Button("Forward", systemImage: "chevron.right", action: goForward)
                        .disabled(subdeckForward.isEmpty)
                }
                // Its own capsule, apart from the deck's actions after it.
                ToolbarSpacer(.fixed, placement: historyPlacement)
            }
            // The pane's title once its heading scrolls away, after back/
            // forward. Only with the sidebar beside the panes: in tab bar
            // mode the tab bar holds the middle of the bar.
            if showsPaneTitles {
                ToolbarItem(placement: .topBarLeading) {
                    LibraryPaneBarTitle(text: detailPaneTitle, isShown: deckHeadingAway)
                }
                .sharedBackgroundVisibility(.hidden)
            }
        } else {
            ToolbarItemGroup(placement: .topBarTrailing) {
                SyncToolbarButton()
                listActionButtons()
            }
        }
        #else
        // Mac's list column has its own toolbar section; Sync belongs to
        // the detail.
        ToolbarItemGroup(placement: .topBarTrailing) {
            listActionButtons()
        }
        #endif
    }

    #if os(iOS)
    /// The profile chip for the panes' bar item — tab bar mode only; the
    /// sidebar carries the profile in its footer.
    private var paneProfileChip: AnyView? {
        guard showsPaneProfileChip, let accountMenuProvider else { return nil }
        return AnyView(
            accountMenuProvider.menu(open: $paneAccountDestination)
                .environment(\.accountMenuShowsName, true)
                .contextMenu {
                    Button("Manage Profiles", systemImage: "person.2") {
                        paneAccountDestination = .manageProfiles
                    }
                }
        )
    }

    /// Pushes the tools so they end at the list pane's right edge. A bar item
    /// is rebuilt on every state change, so only real size changes are kept.
    private func settle(_ value: inout CGFloat, _ new: CGFloat) {
        guard new > 0, abs(new - value) >= 1 else { return }
        value = new.rounded()
    }

    /// Whether the chip, and the tools at the list's edge, fit in the bar
    /// before the centred tab bar starts. True in landscape, false in
    /// portrait.
    private var tabModeToolsFitBeforeTabBar: Bool {
        let tabBarStart = (arrangementWidth - LibrarySplitMetrics.floatingTabBarWidth) / 2
        let toolsEnd = LibrarySplitMetrics.listWidth - LibrarySplitMetrics.barEdgeInset
        return toolsEnd + LibrarySplitMetrics.barItemGap <= tabBarStart
    }

    /// Portrait: the gap that puts the tools menu just before the tab bar.
    private var tabModeMenuOffset: CGFloat {
        let tabBarStart = (arrangementWidth - LibrarySplitMetrics.floatingTabBarWidth) / 2
        let used = LibrarySplitMetrics.barLeadingInset + paneChipWidth + LibrarySplitMetrics.barItemHeight
            + LibrarySplitMetrics.barItemGap * 3
        return max(1, tabBarStart - used)
    }

    private var tabModeToolsOffset: CGFloat {
        let used = LibrarySplitMetrics.barLeadingInset + paneChipWidth + LibrarySplitMetrics.barToolsGroupWidth
            + LibrarySplitMetrics.barItemGap * 2 + LibrarySplitMetrics.barEdgeInset
        return max(1, LibrarySplitMetrics.listWidth - used)
    }

    /// The sidebar carries the profile in its footer; the tab bar doesn't.
    private var showsPaneProfileChip: Bool {
        tabBarPlacement != .sidebar
    }

    /// Portrait: the sidebar floats over the panes rather than pushing them.
    /// Back/forward hide under it rather than jump sides.
    private var sidebarFloatsOverPanes: Bool {
        tabBarPlacement == .sidebar && arrangementMinX < 1
    }

    /// The panes' titles go in the bar when the sidebar sits beside them.
    private var showsPaneTitles: Bool {
        tabBarPlacement == .sidebar && !sidebarFloatsOverPanes
    }

    private var historyPlacement: ToolbarItemPlacement {
        tabBarPlacement == .sidebar ? .topBarLeading : .topBarTrailing
    }
    #endif

    /// Import · Export · New Deck. Browse is its own tab — a Library push
    /// was leftover from the old drill-in.
    /// `framed` sizes each to a 44pt target for the hand-drawn iPad capsule;
    /// the system bar sizes its own items.
    @ViewBuilder
    private func listActionButtons(framed: Bool = false) -> some View {
        Button {
            showImport = true
        } label: {
            Label("Import files", systemImage: "square.and.arrow.down")
                .modifier(LibraryBarButtonFrame(isOn: framed))
        }
        .help("Import deck files")
        Button {
            ExportRequestRouter.shared.request(
                scope: .collection,
                allowsScopeChange: true,
                sourceName: "Library"
            )
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
                .modifier(LibraryBarButtonFrame(isOn: framed))
        }
        .help("Export a deck, collection, or notes")
        // Deck-specific glyph: the bare `+` belongs to Quick Capture.
        Button {
            showCreateSheet = true
        } label: {
            Label("New Deck", systemImage: "rectangle.stack.badge.plus")
                .modifier(LibraryBarButtonFrame(isOn: framed))
        }
    }
}

#if os(iOS)
/// The iPad panes' leading bar item with the app sidebar open: one
/// fixed-width item spanning the list pane, the list's tools at its end.
///
/// A view type of its own on purpose. Given an `HStack` directly, the bar
/// unpacks it into separate items and drops the frame, so only the first
/// button showed.
private struct LibraryPaneBarItem: View {
    let title: Text
    let showsTitle: Bool
    let actions: AnyView

    var body: some View {
        HStack(spacing: 0) {
            LibraryPaneBarTitle(text: title, isShown: showsTitle)
                .padding(.leading, 8)
            Spacer(minLength: 8)
            actions
                .buttonStyle(.plain)
                .labelStyle(.iconOnly)
                .font(.system(size: 17, weight: .regular))
                .padding(.horizontal, 6)
                .frame(height: LibrarySplitMetrics.barItemHeight)
                .amgiMaterial(.regular, in: Capsule(), interactive: true)
                .padding(.trailing, LibrarySplitMetrics.barEdgeInset)
        }
        .frame(width: LibrarySplitMetrics.listWidth - LibrarySplitMetrics.barLeadingInset)
    }
}
#endif

/// A pane's inline title in the shared bar. Always laid out, faded in and
/// out, so showing it never moves the items around it.
private struct LibraryPaneBarTitle: View {
    let text: Text
    let isShown: Bool

    var body: some View {
        text
            .font(.headline)
            .lineLimit(1)
            // Its full width: left to the bar, a leading item is squeezed
            // to an ellipsis.
            .fixedSize()
            .opacity(isShown ? 1 : 0)
            .accessibilityHidden(!isShown)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct LibraryBarButtonFrame: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        if isOn {
            content
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        } else {
            content
        }
    }
}


/// The split's detail pane.
private enum LibraryDetail: Hashable {
    case today
    case deck(DeckInfo)

    var columnSelection: LibraryColumnSelection {
        switch self {
        case .today: .today
        case .deck(let deck): .deck(deck.id.rawValue)
        }
    }
}

enum LibrarySplitMetrics {
    /// iPad landscape with the app sidebar open is about 874pt; portrait
    /// with the tab bar is 834pt and keeps the stack.
    static let minimumSplitWidth: CGFloat = 860
    static let listWidth: CGFloat = 360
    /// The list's bar actions stop this far short of the pane edge.
    static let barEdgeInset: CGFloat = 16
    /// Where the iPad bar starts its first leading item, from the screen
    /// edge under it. The pane item is sized from it instead of measuring.
    static let barLeadingInset: CGFloat = 10
    static let barItemHeight: CGFloat = 44
    /// Space the bar puts between neighbouring leading items.
    static let barItemGap: CGFloat = 15
    /// The system's glass group around the three list tools. Not measured:
    /// a geometry reader on a group's content attaches to each button and
    /// splits the group apart.
    static let barToolsGroupWidth: CGFloat = 162
    /// The floating tab bar with Library's five tabs, centred in the bar.
    static let floatingTabBarWidth: CGFloat = 470
}

// MARK: - Preview
//
// None here, deliberately. Previews of a package target run in XCPreviewAgent
// with no app host, and the JIT can only resolve symbols from dylibs in the
// products dir — `libanki_bridge_ios.a` is a static archive, so anything whose
// preview transitively reaches AnkiBackend fails to link with
// "Symbols not found: [_anki_open_backend, …]". DeckListView reaches it through
// DeckListModel, DeckDetailView, and ReviewView. It rendered while this file
// lived in the app target (AmgiApp.debug.dylib exports those four symbols);
// it cannot since the DecksFeature extraction.
//
// The deck list surface previews from `LibraryListContent` in AmgiUI instead —
// same pixels, engine-free, including the minimal-palette variant this file
// used to pin.
