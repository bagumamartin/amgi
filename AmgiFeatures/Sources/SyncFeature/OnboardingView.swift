package import SwiftUI
import AmgiTheme
import AmgiUI
import AmgiAppCore
import AnkiSync
import Sharing
#if canImport(UIKit)
import UIKit
#endif

package struct OnboardingView: View {
    @Environment(\.palette) private var palette
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Shared(.onboardingCompleted) private var onboardingCompleted
    @Shared(.syncMode) private var syncMode
    @State private var showServerSetup = false
    @State private var serverURL = ""
    @State private var endpointError: String?

    package init() {}

    private var isRegular: Bool {
        #if os(macOS)
        return true
        #else
        return horizontalSizeClass == .regular
        #endif
    }

    private var localDeviceIcon: String {
        #if os(macOS)
        return "macbook"
        #elseif os(watchOS)
        return "applewatch"
        #elseif os(visionOS)
        return "visionpro"
        #elseif canImport(UIKit)
        switch UIDevice.current.userInterfaceIdiom {
        case .pad:
            return "ipad"
        case .mac:
            return "macbook"
        case .vision:
            return "visionpro"
        default:
            return "iphone"
        }
        #else
        return "internaldrive"
        #endif
    }

    package var body: some View {
        GeometryReader { geometry in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    if isRegular {
                        AmgiCard(
                            background: .surfaceElevated,
                            shadow: palette.shadows.md,
                            cornerRadius: AmgiRadius.card,
                            contentInsets: EdgeInsets(
                                top: AmgiSpacing.xxl,
                                leading: AmgiSpacing.xl,
                                bottom: AmgiSpacing.xxl,
                                trailing: AmgiSpacing.xl
                            )
                        ) {
                            cardContent
                        }
                        .frame(maxWidth: 460)
                        .padding(.horizontal, AmgiSpacing.lg)
                        .padding(.vertical, AmgiSpacing.xxl)
                    } else {
                        cardContent
                            .frame(maxWidth: 460)
                            .padding(.horizontal, AmgiSpacing.lg)
                            .padding(.vertical, AmgiSpacing.xl)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height)
            }
        }
        .background(palette.background.ignoresSafeArea())
    }

    @ViewBuilder
    private var cardContent: some View {
        VStack(spacing: AmgiSpacing.xl) {
            heroSection

            if showServerSetup {
                serverSetupSection
                    .transition(.opacity)
            } else {
                optionsSection
                    .transition(.opacity)
            }

            footerSection
        }
    }

    private var heroSection: some View {
        VStack(spacing: AmgiSpacing.md) {
            ZStack {
                if showServerSetup {
                    RoundedRectangle(cornerRadius: AmgiRadius.hero, style: .continuous)
                        .fill(palette.accent.opacity(0.12))
                        .frame(width: 72, height: 72)

                    Image(systemName: "server.rack")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(palette.accent)
                        .contentTransition(.symbolEffect(.replace))
                } else {
                    Image("IjukaAppIcon", bundle: .main)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: AmgiRadius.hero, style: .continuous))
                }
            }

            Text(showServerSetup ? "Sync Server Setup" : "Welcome to Ijuka")
                .amgiFont(.displayHero)
                .foregroundStyle(palette.textPrimary)
                .multilineTextAlignment(.center)

            Text(
                showServerSetup
                    ? "Enter your Anki-compatible sync server URL to get started."
                    : "Choose how to store and sync your collection."
            )
            .amgiFont(.body)
            .foregroundStyle(palette.textSecondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, AmgiSpacing.sm)
        }
    }

    private var optionsSection: some View {
        VStack(spacing: AmgiSpacing.md) {
            OnboardingOptionTile(
                icon: localDeviceIcon,
                title: "Use Locally",
                subtitle: "Store cards on this device. You can connect a sync server anytime in Settings.",
                isElevatedContainer: isRegular
            ) {
                $syncMode.withLock { $0 = .local }
                $onboardingCompleted.withLock { $0 = true }
            }

            OnboardingOptionTile(
                icon: "server.rack",
                title: "Custom Sync Server",
                subtitle: "Connect to an Anki-compatible or self-hosted server to sync across devices.",
                isElevatedContainer: isRegular
            ) {
                withAnimation(AmgiMotion.standard) {
                    showServerSetup = true
                    endpointError = nil
                }
            }
        }
    }

    private var serverSetupSection: some View {
        VStack(spacing: AmgiSpacing.md) {
            AnkiMobileAttributionView()

            VStack(alignment: .leading, spacing: AmgiSpacing.xs) {
                HStack(spacing: AmgiSpacing.sm) {
                    Image(systemName: "link")
                        .font(.system(size: 15))
                        .foregroundStyle(palette.textTertiary)

                    TextField("https://sync.example.com", text: $serverURL)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .amgiFont(.body)
                        .onSubmit {
                            if !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                saveAndContinue()
                            }
                        }

                    if !serverURL.isEmpty {
                        Button {
                            serverURL = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(palette.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, AmgiSpacing.md)
                .padding(.vertical, AmgiSpacing.md)
                .background(
                    RoundedRectangle(cornerRadius: AmgiRadius.control, style: .continuous)
                        .fill(isRegular ? palette.surface : palette.surfaceElevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AmgiRadius.control, style: .continuous)
                        .strokeBorder(endpointError != nil ? palette.danger : palette.separator, lineWidth: 1)
                )

                if let endpointError {
                    Text(endpointError)
                        .amgiStatusText(.danger, font: .caption)
                        .padding(.horizontal, AmgiSpacing.xs)
                }
            }

            Button {
                saveAndContinue()
            } label: {
                Text("Connect & Continue")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(AmgiPrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button {
                withAnimation(AmgiMotion.standard) {
                    showServerSetup = false
                    endpointError = nil
                }
            } label: {
                HStack(spacing: AmgiSpacing.xs) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Back to options")
                }
                .amgiFont(.captionBold)
                .foregroundStyle(palette.textSecondary)
                .padding(.vertical, AmgiSpacing.xs)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
    }

    private var footerSection: some View {
        Text("You can change this anytime in sync settings")
            .amgiFont(.micro)
            .foregroundStyle(palette.textTertiary)
            .multilineTextAlignment(.center)
    }
}

// MARK: - Option Tile

private struct OnboardingOptionTile: View {
    @Environment(\.palette) private var palette
    let icon: String
    let title: String
    let subtitle: String
    let isElevatedContainer: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: AmgiSpacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous)
                        .fill(palette.accent.opacity(0.12))
                        .frame(width: 44, height: 44)

                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(palette.accent)
                }

                VStack(alignment: .leading, spacing: AmgiSpacing.xxs) {
                    Text(title)
                        .amgiFont(.bodyEmphasis)
                        .foregroundStyle(palette.textPrimary)

                    Text(subtitle)
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: AmgiSpacing.xs)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isHovered ? palette.accent : palette.textTertiary)
            }
            .padding(AmgiSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous)
                    .fill(isHovered ? hoverBackground : defaultBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous)
                    .strokeBorder(isHovered ? palette.accent.opacity(0.5) : palette.separator, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous))
        }
        .buttonStyle(.pressScale)
        .onHover { isHovered = $0 }
        .animation(AmgiMotion.quick, value: isHovered)
        .accessibilityElement(children: .combine)
    }

    private var defaultBackground: Color {
        isElevatedContainer ? palette.surface : palette.surfaceElevated
    }

    private var hoverBackground: Color {
        isElevatedContainer ? palette.surfaceElevated : palette.surface
    }
}

private extension OnboardingView {
    func saveAndContinue() {
        do {
            let url = try SyncEndpoint.normalized(serverURL)
            try KeychainHelper.saveEndpoint(url)
            endpointError = nil
            $syncMode.withLock { $0 = .custom }
            $onboardingCompleted.withLock { $0 = true }
        } catch {
            endpointError = error.localizedDescription
        }
    }
}

#if DEBUG

// MARK: - Preview

#Preview("Regular (Mac/iPad)") {
    OnboardingView()
}

#Preview("Compact (Phone)") {
    OnboardingView()
        .environment(\.horizontalSizeClass, .compact)
}
#endif
