package import SwiftUI
import AmgiTheme
package import AmgiAppCore
package import AmgiAppShared
#if canImport(UIKit)
import UIKit
#endif

/// Profile selector. Toolbar chrome keeps Settings inside the menu; sidebar
/// chrome is profiles-only so Settings can sit beside it as its own control.
/// macOS Settings lives in the menu bar — never in this control.
///
/// `onSwitch` is injected from the composition root — it closes/reopens the
/// collection — so this view does not import that machinery.
package struct ProfilePickerMenu: View {
    package enum Chrome: Sendable {
        /// Compact toolbar control. iPhone is icon-only; iPad/Mac show the name.
        /// iOS also offers Settings inside the menu.
        case toolbar
        /// Bottom-of-sidebar row: always shows the name, no Settings item.
        case sidebar
    }

    let onSwitch: (AmgiAccount) async -> Void
    @Binding var open: AccountMenuDestination?
    var chrome: Chrome

    @State private var store = AccountStore.shared
    @State private var iconStore = ProfileIconStore.shared
    @Environment(\.palette) private var palette

    package init(
        onSwitch: @escaping (AmgiAccount) async -> Void,
        open: Binding<AccountMenuDestination?>,
        chrome: Chrome = .toolbar
    ) {
        self.onSwitch = onSwitch
        self._open = open
        self.chrome = chrome
    }

    package init(
        onSwitch: @escaping (AmgiAccount) async -> Void,
        chrome: Chrome
    ) {
        self.onSwitch = onSwitch
        self._open = .constant(nil)
        self.chrome = chrome
    }

    /// iPhone toolbar is icon-only; iPad/Mac keep the name beside the emoji.
    /// Sidebar chrome always shows the name.
    private var showsNameInLabel: Bool {
        if chrome == .sidebar { return true }
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom != .phone
        #else
        return true
        #endif
    }

    private var includesSettings: Bool {
        #if os(macOS)
        false
        #else
        chrome == .toolbar
        #endif
    }

    package var body: some View {
        Menu {
            Section {
                ForEach(store.accounts) { account in
                    Button {
                        Task { await onSwitch(account) }
                    } label: {
                        HStack {
                            Text(profileTitle(for: account))
                            if account.id == store.selectedID {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } header: {
                Text("Switch profile")
            }
            if includesSettings {
                Section {
                    Button("Settings…", systemImage: "gearshape") {
                        open = .settings
                    }
                }
            }
        } label: {
            label
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel("Profile: \(store.current.displayName)")
        .task { await iconStore.refresh() }
    }

    @ViewBuilder
    private var label: some View {
        #if os(macOS)
        if chrome == .sidebar {
            macSidebarLabel
        } else {
            toolbarLabel
        }
        #else
        toolbarLabel
        #endif
    }

    #if os(macOS)
    /// Cursor-style Mac sidebar row: circular avatar + uppercase name.
    /// No bezel, no disclosure chevron — the whole row is the menu.
    private var macSidebarLabel: some View {
        HStack(spacing: AmgiSpacing.md) {
            ProfileSidebarAvatar(
                name: store.current.displayName,
                emoji: iconStore.icon(for: store.current.id),
                size: 32
            )
            Text(store.current.displayName)
                .amgiFont(size: 13, weight: .medium, tracking: 0.8, relativeTo: .caption)
                .textCase(.uppercase)
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
    #endif

    private var toolbarLabel: some View {
        HStack(spacing: chrome == .sidebar ? AmgiSpacing.sm : 4) {
            if let emoji = iconStore.icon(for: store.current.id) {
                Text(emoji)
                    .font(.system(size: chrome == .sidebar ? 22 : 18))
            } else {
                Image(systemName: "person.crop.circle")
                    .foregroundStyle(palette.accent)
                    .amgiFont(chrome == .sidebar ? .cardTitle : .body)
            }
            if showsNameInLabel {
                Text(store.current.displayName)
                    .amgiFont(.bodyEmphasis)
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }

    private func profileTitle(for account: AmgiAccount) -> String {
        let icon = iconStore.icon(for: account.id) ?? "👤"
        return "\(icon) \(account.displayName)"
    }
}

#if os(macOS)
/// Circular profile mark for the Mac sidebar row. Emoji when the profile
/// has one; otherwise a monogram on the accent-soft fill.
private struct ProfileSidebarAvatar: View {
    @Environment(\.palette) private var palette

    let name: String
    let emoji: String?
    var size: CGFloat = 32

    private var initial: String {
        String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
    }

    var body: some View {
        Group {
            if let emoji {
                Text(emoji)
                    .font(.system(size: size * 0.55))
            } else {
                Text(initial)
                    .amgiFont(.captionBold)
                    .foregroundStyle(palette.accent)
            }
        }
        .frame(width: size, height: size)
        .background(palette.accentSoft, in: Circle())
        .accessibilityHidden(true)
    }
}
#endif
