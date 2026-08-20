import AnkiClients
import AnkiKit
import AnkiSync
import Dependencies
import os
import SwiftUI

private let logger = Logger(subsystem: "com.amgiapp.AmgiApp", category: "WatchDeckList")

struct WatchDeckListView: View {
    @Dependency(\.deckClient) var deckClient
    @Dependency(\.syncClient) var syncClient
    /// One axis instead of `isLoading` + a `tree` that was also emptied on
    /// failure, which made "your collection has no decks" and "the fetch
    /// threw" render as the same screen.
    enum LoadState {
        case loading
        case loaded([DeckTreeNode])
        case failed
    }

    /// The two sheets are mutually exclusive; as separate flags they could
    /// both be raised at once. Plain `Equatable` rather than `@CasePathable`
    /// so the watch target doesn't have to link SwiftUINavigation.
    enum Destination: Equatable {
        case syncMenu
        case login
    }

    @State private var state: LoadState = .loading
    @State private var expandedDecks: Set<DeckID> = []
    @State private var isSyncing = false
    @State private var destination: Destination?

    private var tree: [DeckTreeNode] {
        if case .loaded(let tree) = state { return tree }
        return []
    }

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView()
            case .failed:
                Text("Couldn't load decks")
                    .foregroundStyle(.secondary)
            case .loaded(let loaded) where loaded.isEmpty:
                Text("No Decks")
                    .foregroundStyle(.secondary)
            case .loaded:
                List {
                    ForEach(flattenedItems) { item in
                        WatchDeckRow(
                            node: item.node,
                            depth: item.depth,
                            isExpanded: expandedDecks.contains(item.id),
                            onToggle: { toggleExpansion(item.id) }
                        )
                    }
                }
                .refreshable {
                    await loadDecks()
                }
            }
        }
        .navigationTitle("Decks")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink(destination: WatchStatsView()) {
                    Image(systemName: "chart.bar.fill")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    destination = .syncMenu
                } label: {
                    if isSyncing {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isSyncing || isLoadingDecks)
            }
        }
        .sheet(isPresented: presenting(.syncMenu)) {
            // WatchOS sheet: minimal actions
            VStack {
                Button("Sync") {
                    destination = nil
                    Task { await sync() }
                }
                Button("Sign out", role: .destructive) {
                    destination = .login
                }
            }
            .padding()
        }
        .sheet(isPresented: presenting(.login)) {
            // Present login flow immediately after sign-out
            WatchLoginView(onLoginSuccess: {
                destination = nil
                Task { await loadDecks() }
            })
        }
        .task {
            await loadDecks()
        }
    }

    private func sync() async {
        isSyncing = true
        do {
            _ = try await syncClient.sync()
            await loadDecks()
        } catch {
            logger.error("Sync error: \(error)")
        }
        isSyncing = false
    }
    /// `isPresented` binding for one destination case.
    private func presenting(_ target: Destination) -> Binding<Bool> {
        Binding(
            get: { destination == target },
            set: { if !$0 && destination == target { destination = nil } }
        )
    }

    private var isLoadingDecks: Bool {
        if case .loading = state { return true }
        return false
    }

    private func loadDecks() async {
        do {
            state = .loaded(try await deckClient.fetchTree())
        } catch {
            logger.error("Deck load error: \(error)")
            state = .failed
        }
    }
    private func toggleExpansion(_ id: DeckID) {
        if expandedDecks.contains(id) {
            expandedDecks.remove(id)
        } else {
            expandedDecks.insert(id)
        }
    }
    // MARK: - Flattened view support for collapsible hierarchy
    private struct FlattenedItem: Identifiable {
        let id: DeckID
        let node: DeckTreeNode
        let depth: Int
    }
    private var flattenedItems: [FlattenedItem] {
        flatten(tree)
    }
    private func flatten(_ nodes: [DeckTreeNode], depth: Int = 0) -> [FlattenedItem] {
        nodes.flatMap { node -> [FlattenedItem] in
            var result: [FlattenedItem] = [FlattenedItem(id: node.id, node: node, depth: depth)]
            if expandedDecks.contains(node.id) {
                result.append(contentsOf: flatten(node.children, depth: depth + 1))
            }
            return result
        }
    }
    // Sign-out no longer clears credentials; login is handled by the login view
}
private struct WatchDeckRow: View {
    let node: DeckTreeNode
    let depth: Int
    let isExpanded: Bool
    let onToggle: () -> Void
    // Indentation per depth level (modifiable to adjust layout density)
    static let indentPerLevel: CGFloat = 10
    var body: some View {
        HStack {
            // Text content is left-aligned; chevron is right-aligned for collapsible nodes
            NavigationLink(value: node.asDeckInfo) {
                VStack(alignment: .leading) {
                    Text(node.name.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.body)
                    DeckCountsView(counts: node.counts)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !node.children.isEmpty {
                Button(action: onToggle) {
                    Image(systemName: "chevron.right")
                        .font(.headline)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 20)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, CGFloat(depth) * Self.indentPerLevel)
    }
}
