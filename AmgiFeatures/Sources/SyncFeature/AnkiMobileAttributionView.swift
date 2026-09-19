package import SwiftUI
import AmgiTheme
#if canImport(AppKit)
import AppKit
#endif

package struct AnkiMobileAttributionView: View {
    @Environment(\.palette) private var palette

    package init() {}

    package var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Sync Server Compatibility", systemImage: "arrow.triangle.2.circlepath")
                .amgiFont(.bodyEmphasis)
                .foregroundStyle(palette.textPrimary)
            Text("Amgi syncs with self-hosted and custom Anki-compatible sync servers. Amgi is an independent application and is not affiliated with, sponsored by, or endorsed by AnkiWeb or Damien Elmes.")
                .amgiFont(.caption)
                .foregroundStyle(palette.textSecondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: AmgiRadius.inset))
    }
}

#if DEBUG

#Preview {
    AnkiMobileAttributionView()
        .padding()
}
#endif
