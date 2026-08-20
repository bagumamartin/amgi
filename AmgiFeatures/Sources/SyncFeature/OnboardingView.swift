public import SwiftUI
import AmgiTheme
import AmgiUI
import AmgiAppCore
import AnkiSync
import Sharing

public struct OnboardingView: View {
    @Environment(\.palette) private var palette
    @Shared(.onboardingCompleted) private var onboardingCompleted
    @Shared(.syncMode) private var syncMode
    @State private var showServerSetup = false
    @State private var serverURL = ""
    @State private var endpointError: String?

    public init() {}

    public var body: some View {
        VStack(spacing: AmgiSpacing.xxl) {
            Spacer()

            Image(systemName: "rectangle.stack.fill")
                .font(.system(size: 64))
                .foregroundStyle(palette.accent)

            Text("Welcome")
                .amgiFont(.displayHero)
                .foregroundStyle(palette.textPrimary)

            Text("Choose how to sync your collection")
                .amgiFont(.body)
                .foregroundStyle(palette.textSecondary)

            VStack(spacing: AmgiSpacing.md) {
                if showServerSetup {
                    VStack(spacing: AmgiSpacing.md) {
                        AnkiMobileAttributionView()
                            .padding(.horizontal)

                        TextField("Server URL", text: $serverURL)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .padding(.horizontal)

                        if let endpointError {
                            Text(endpointError)
                                .amgiStatusText(.danger, font: .caption)
                                .padding(.horizontal)
                        }

                        Button("Continue") {
                            saveAndContinue()
                        }
                        .buttonStyle(AmgiPrimaryButtonStyle())
                        .disabled(serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button("Back") {
                            withAnimation(AmgiMotion.standard) { showServerSetup = false }
                        }
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                    }
                    .transition(.opacity)
                } else {
                    VStack(spacing: AmgiSpacing.md) {
                        Button {
                            withAnimation(AmgiMotion.standard) { showServerSetup = true }
                        } label: {
                            Label("Custom Server", systemImage: "server.rack")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(AmgiPrimaryButtonStyle())

                        Button {
                            $syncMode.withLock { $0 = .local }
                            $onboardingCompleted.withLock { $0 = true }
                        } label: {
                            Label("Use Locally", systemImage: "iphone")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(AmgiSecondaryButtonStyle())
                    }
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 32)

            Text("You can change this anytime in sync settings")
                .amgiFont(.micro)
                .foregroundStyle(palette.textTertiary)

            Spacer()
        }
        .background(palette.background)
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

// MARK: - Preview

#Preview {
    OnboardingView()
}
