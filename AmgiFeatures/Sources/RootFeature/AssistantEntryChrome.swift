import AmgiUI
import BrowseFeature
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// A content overlay, never a sidebar footer or a full-width bottom bar.
/// The two independent glass shapes share one baseline and trailing anchor.
struct FloatingAssistantEntry: View {
    let openAssistant: () -> Void
    let capture: (QuickCaptureKind) -> Void

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                Button(action: openAssistant) {
                    Label {
                        Text("Ask AI")
                    } icon: {
                        // Bottom-trailing corner: the content is up and left.
                        AssistantHead(.idle, gaze: CGPoint(x: -0.5, y: -0.6)).frame(width: 26, height: 26)
                    }
                        .font(.body.weight(.medium))
                        .padding(.horizontal, 20)
                        .frame(minHeight: 48)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .accessibilityIdentifier("assistant.entry")
                .help("Ask AI about your collection")
                Menu {
                    Button("Camera", systemImage: "camera") { capture(.camera) }
                    Button("Text", systemImage: "text.cursor") { capture(.text) }
                } label: {
                    Image(systemName: "plus")
                        .font(.title3.weight(.medium))
                        .frame(width: 48, height: 48)
                        .contentShape(Circle())
                }
                #if os(macOS)
                .menuStyle(.borderlessButton)
                #endif
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .frame(width: 48, height: 48)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("Quick Capture")
                .accessibilityIdentifier("capture.entry")
                .help("Quick Capture")
            }
        }
    }
}

#if os(iOS)
/// Ask AI pill + Quick Capture circle for iPhone, sharing one row.
///
/// Two separate controls, two separate glasses. Hosted in
/// `tabViewBottomAccessory` for its positioning (floating above the bar,
/// docking to the low row on minimize); the capsule the system draws behind
/// accessory content is removed by `AccessoryCapsuleHider`.
struct AssistantEntryRow: View {
    let openAssistant: () -> Void
    @Binding var showsCapture: Bool
    /// Global frames of the row and the `+`, for `QuickCaptureOverlay`.
    let onRowFrame: (CGRect) -> Void
    let onCaptureButtonFrame: (CGRect) -> Void
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                Button(action: openAssistant) {
                    HStack(spacing: 10) {
                        // Leading end of the bottom row: it looks up and
                        // across at the screen, not off its edge.
                        AssistantHead(.idle, gaze: CGPoint(x: 0.5, y: -0.6)).frame(width: 28, height: 28)
                        Text("Ask AI").foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 11)
                    .padding(.trailing, 18)
                    .frame(height: 48)
                    .frame(maxWidth: .infinity)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .accessibilityLabel("Ask AI")
                .accessibilityIdentifier("assistant.entry")
                Button {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { showsCapture.toggle() }
                } label: {
                    Image(systemName: showsCapture ? "xmark" : "plus")
                        .font(.title3.weight(.medium))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 48, height: 48)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onCaptureButtonFrame($0) }
                .accessibilityLabel(showsCapture ? "Close Quick Capture options" : "Quick Capture")
                .accessibilityIdentifier("capture.entry")
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onRowFrame($0) }
        .background(AccessoryCapsuleHider(placement: placement))
    }
}

/// The `+` button's expansion: Camera and Text stacked above it, with an
/// invisible tap-outside-to-close layer. Drawn by the scene rather than inside
/// the accessory, which can neither render nor take touches outside its own
/// row; positioned from the row's live global frames so it tracks expanded
/// and minimized placements. The tap layer stops at the row's top edge so
/// the `×` stays tappable.
struct QuickCaptureOverlay: View {
    @Binding var isPresented: Bool
    let rowFrame: CGRect
    let buttonFrame: CGRect
    let capture: (QuickCaptureKind) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            let rowTop = max(rowFrame.minY - origin.y, 0)
            let trailing = max(proxy.size.width - (buttonFrame.maxX - origin.x), 0)
            ZStack(alignment: .top) {
                if isPresented {
                    // Invisible: only here so a tap outside closes the menu.
                    Color.clear
                        .frame(height: rowTop)
                        .contentShape(Rectangle())
                        .onTapGesture { dismiss() }
                        .accessibilityHidden(true)
                }
                VStack(alignment: .trailing, spacing: 16) {
                    Spacer(minLength: 0)
                    if isPresented {
                        VStack(alignment: .trailing, spacing: 16) {
                            action("Camera", icon: "camera", kind: .camera)
                            action("Text", icon: "text.cursor", kind: .text)
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(.trailing, trailing)
                .padding(.bottom, 18)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .frame(height: rowTop)
                // The actions rise out of the row's top edge, never across it.
                .clipped()
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(isPresented)
    }

    private var animation: Animation? { reduceMotion ? nil : .smooth(duration: 0.3) }

    private func dismiss() { withAnimation(animation) { isPresented = false } }

    private func action(_ title: String, icon: String, kind: QuickCaptureKind) -> some View {
        Button {
            dismiss()
            capture(kind)
        } label: {
            HStack(spacing: 12) {
                Text(title)
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .frame(height: 40)
                    .glassEffect(.regular.interactive(), in: .capsule)
                Image(systemName: icon)
                    .font(.title3)
                    .frame(width: 48, height: 48)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Capture \(title.lowercased())")
    }
}

/// Hides the glass capsule `tabViewBottomAccessory` draws behind its content.
/// There is no public opt-out (as of iOS 26.x), so this reaches into
/// private UIKit structure, found by dumping the hierarchy on device:
///
///     _UIMultiLayer
///     ├─ _UIBottomTabBarGroupView   (tab bar + _UITabAccessoryContainer)
///     └─ _GlassGroupView            (renders the group's glass)
///        ├─ GlassGroupLayerView #0  the tab bar's capsule
///        └─ GlassGroupLayerView #1  the accessory's capsule
///
/// The two layer views are indistinguishable except by order, so this acts
/// only when exactly two exist and hides the second. Any change to that
/// shape in a later release makes it a no-op: the system capsule reappears
/// behind the row, nothing breaks.
///
/// UIKit restores the capsule when the bar comes back from minimized, so this
/// re-applies on every placement change (through the transition) and re-hides
/// the layer the moment anything un-hides it. It also turns off the accessory
/// host's capsule clip, which otherwise trims the row's outer glass rims, and
/// removes its press interaction, which flashes a full-row glow on every tap.
private struct AccessoryCapsuleHider: UIViewRepresentable {
    let placement: TabViewBottomAccessoryPlacement?

    func makeUIView(context: Context) -> HiderView { HiderView() }
    func updateUIView(_ view: HiderView, context: Context) {
        guard view.placement != placement else { return }
        view.placement = placement
        view.hideThroughTransition()
    }

    final class HiderView: UIView {
        var placement: TabViewBottomAccessoryPlacement?
        private var hiddenObservation: NSKeyValueObservation?
        private weak var hiddenLayer: CALayer?
        private var clipObservation: NSKeyValueObservation?
        private weak var clippedLayer: CALayer?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            hideSystemCapsule()
            // The glass group may be built after the accessory lands.
            DispatchQueue.main.async { [weak self] in self?.hideSystemCapsule() }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            hideSystemCapsule()
        }

        /// Placement changes animate; catch the capsule however late UIKit
        /// rebuilds it.
        func hideThroughTransition() {
            hideSystemCapsule()
            for delay in [0.05, 0.25, 0.5, 1.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.hideSystemCapsule() }
            }
        }

        private func hideSystemCapsule() {
            guard window != nil else { return }
            var node = superview
            while let view = node, Self.name(of: view) != "_UIBottomTabBarGroupView" {
                if Self.name(of: view) == "UIKitTabBarBottomAccessory" { prepareHost(view) }
                node = view.superview
            }
            guard let group = node,
                  let glassGroup = group.layer.superlayer?.sublayers?
                      .first(where: { $0.delegate.map(Self.name) == "_GlassGroupView" })
            else { return }
            let layerViews = (glassGroup.sublayers ?? []).compactMap { $0.delegate as? UIView }
            guard layerViews.count == 2,
                  layerViews.allSatisfy({ Self.name(of: $0).hasSuffix("GlassGroupLayerView") })
            else { return }
            let capsule = layerViews[1]
            capsule.isHidden = true
            guard hiddenLayer !== capsule.layer else { return }
            hiddenLayer = capsule.layer
            // Synchronously: deferring even one run-loop pass lets the capsule
            // render for a frame.
            hiddenObservation = capsule.layer.observe(\.isHidden, options: [.new]) { [weak self] _, change in
                guard change.newValue == false else { return }
                MainActor.assumeIsolated { self?.hideSystemCapsule() }
            }
        }

        /// Strips the accessory host of what assumes the system capsule.
        /// Its capsule clip shaves the glass rim off the row's outer ends
        /// (pill's left, circle's right).
        private func prepareHost(_ host: UIView) {
            host.clipsToBounds = false
            // The accessory-wide press feedback (scale bounce + a capsule
            // glow, `GlowContainerView`) is for single-control accessories;
            // here it flashes a full-row pill behind the two buttons, which
            // carry their own interactive glass.
            for interaction in host.interactions where Self.name(of: interaction) == "_UIFlexInteraction" {
                host.removeInteraction(interaction)
            }
            guard clippedLayer !== host.layer else { return }
            clippedLayer = host.layer
            clipObservation = host.layer.observe(\.masksToBounds, options: [.new]) { [weak self] _, change in
                guard change.newValue == true else { return }
                MainActor.assumeIsolated { self?.hideSystemCapsule() }
            }
        }

        private static func name(of object: Any) -> String { String(describing: type(of: object)) }
    }
}

extension View {
    /// `tabViewBottomAccessory` draws its glass capsule even around empty
    /// content, so an `if` inside the builder leaves a blank pill (iPad
    /// regular width, the Reader screen). `isEnabled:` removes the slot
    /// outright but is iOS 26.1+; on 26.0 the blank pill is the fallback.
    @ViewBuilder
    func assistantEntryAccessory(isEnabled: Bool, @ViewBuilder content: () -> some View) -> some View {
        if #available(iOS 26.1, *) {
            tabViewBottomAccessory(isEnabled: isEnabled, content: content)
        } else {
            let content = content()
            tabViewBottomAccessory {
                if isEnabled { content }
            }
        }
    }
}
#endif
