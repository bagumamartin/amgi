package import SwiftUI
import AmgiTheme
import AmgiUI
package import AmgiAppCore

/// Sidebar footer: iOS uses ChatGPT-style floating chips (profile capsule +
/// Settings gear). macOS uses a Cursor-style avatar + name row under the
/// list; Settings stays in the menu bar, so there is no gear.
package struct AccountSidebarFooter: View {
    let onSwitch: (AmgiAccount) async -> Void
    let onOpenSettings: () -> Void

    #if os(iOS)
    @Environment(\.palette) private var palette
    #endif

    package init(
        onSwitch: @escaping (AmgiAccount) async -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        self.onSwitch = onSwitch
        self.onOpenSettings = onOpenSettings
    }

    package var body: some View {
        #if os(macOS)
        ProfilePickerMenu(onSwitch: onSwitch, chrome: .sidebar)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .padding(.horizontal, AmgiSpacing.lg)
            .padding(.vertical, AmgiSpacing.sm)
        #else
        HStack(spacing: AmgiSpacing.sm) {
            ProfilePickerMenu(onSwitch: onSwitch, chrome: .sidebar)
                .padding(.leading, AmgiSpacing.md)
                .padding(.trailing, AmgiSpacing.lg)
                .frame(height: 44)
                .amgiMaterial(.regular, in: Capsule(), interactive: true)
                .amgiMaterialElevation(Capsule())

            Spacer(minLength: AmgiSpacing.sm)

            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .amgiFont(.body)
                    .foregroundStyle(palette.textPrimary)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.pressScale)
            .accessibilityLabel("Settings")
            .amgiMaterial(.regular, in: Circle(), interactive: true)
            .amgiMaterialElevation(Circle())
        }
        .padding(.horizontal, AmgiSpacing.md)
        .padding(.vertical, AmgiSpacing.md)
        .accessibilityElement(children: .contain)
        #endif
    }
}
