import AmgiAppCore
import AmgiTheme
import AmgiUI
import SwiftUI

/// OpenAI's Sign in with ChatGPT brand pieces, built to their published
/// formats (developers.openai.com/siwc/website, /siwc/ui-ux-guidelines):
/// the official logo, the approved "Continue with ChatGPT" button, the plan
/// indicator and the usage-limit message. Their colours are brand colours,
/// not palette roles, so they stay pure black and white in every theme.
enum ChatGPTBrand {
    static let manageUsageURL = URL(string: "https://chatgpt.com/settings/usage")!
    /// Pure black and white, per the approved button formats.
    static let ink = Color(white: 0)
    static let paper = Color(white: 1)
}

/// The official ChatGPT mark (OpenAI's sign-in button asset), as a template.
struct ChatGPTLogo: View {
    var size: CGFloat = 21

    var body: some View {
        Image("ChatGPTLogo", bundle: .module)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The approved "Continue with ChatGPT" button: 45 pt tall, 12 pt corners,
/// a 21 pt logo 12 pt from a 15 pt medium label, 20 pt side padding. The
/// black format on light surfaces, the white one on dark, so it always
/// stands out from the sheet behind it.
struct ContinueWithChatGPTButton: View {
    var isLoading = false
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var fill: Color { colorScheme == .dark ? ChatGPTBrand.paper : ChatGPTBrand.ink }
    private var ink: Color { colorScheme == .dark ? ChatGPTBrand.ink : ChatGPTBrand.paper }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if isLoading {
                    ProgressView().controlSize(.small).tint(ink).frame(width: 21, height: 21)
                } else {
                    ChatGPTLogo()
                }
                Text("Continue with ChatGPT")
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(ink)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, minHeight: 45)
            // AmgiRadius.inset is 12 pt — the approved buttons' radius.
            .background(fill, in: RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .accessibilityLabel("Continue with ChatGPT")
    }
}

/// "Using ChatGPT plan · Manage usage", shown by the model selector while a
/// ChatGPT-plan model is chosen, as OpenAI's guidelines ask.
struct ChatGPTPlanIndicator: View {
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: AmgiSpacing.xs) {
            ChatGPTLogo(size: 11)
            Text("Using ChatGPT plan")
            Text("·")
            Link("Manage usage", destination: ChatGPTBrand.manageUsageURL)
                .foregroundStyle(palette.accent)
        }
        .amgiFont(.micro)
        .foregroundStyle(palette.textTertiary)
    }
}

/// The compact usage-limit message: the ChatGPT identity stays visible and
/// "Manage usage" is the primary (and, with no app credits, only) action.
struct ChatGPTUsageLimitCard: View {
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(alignment: .top, spacing: AmgiSpacing.md) {
            ChatGPTLogo(size: 18)
                .foregroundStyle(palette.textPrimary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: AmgiSpacing.sm) {
                Text("Usage limit reached")
                    .amgiFont(.bodyEmphasis)
                    .foregroundStyle(palette.textPrimary)
                Text("Review your plan or this app's limit in ChatGPT settings.")
                    .amgiFont(.caption)
                    .foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link(destination: ChatGPTBrand.manageUsageURL) {
                    Text("Manage usage")
                        .amgiFont(.captionBold)
                        .foregroundStyle(palette.background)
                        .padding(.horizontal, AmgiSpacing.md)
                        .frame(height: 32)
                        .background(palette.textPrimary, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(AmgiSpacing.lg)
        .background(palette.background, in: RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous))
    }
}

/// The one-time "You're using your ChatGPT plan" welcome after the first
/// sign-in with plan usage. Never shown again.
struct ChatGPTPlanWelcome: ViewModifier {
    @Bindable var store: AssistantProviderStore
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        content.alert("You're using your ChatGPT plan", isPresented: $store.showsPlanWelcome) {
            Button("Got it") { store.showsPlanWelcome = false }
            Button("Manage usage") { openURL(ChatGPTBrand.manageUsageURL) }
        } message: {
            Text("Eligible AI requests in Ijuka now use your ChatGPT plan. You can manage this app's usage anytime in ChatGPT settings.")
        }
    }
}
