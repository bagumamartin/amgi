import BrowseFeature
import SwiftUI

/// A content overlay, never a sidebar footer or a full-width bottom bar.
/// The two independent glass shapes share one baseline and trailing anchor.
struct FloatingAssistantEntry: View {
    var showsAssistant = true
    let openAssistant: () -> Void
    let capture: (QuickCaptureKind) -> Void

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                if showsAssistant {
                    Button(action: openAssistant) {
                        Label("Ask AI", systemImage: "sparkles")
                            .font(.body.weight(.medium))
                            .padding(.horizontal, 20)
                            .frame(minHeight: 48)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .accessibilityIdentifier("assistant.entry")
                    .help("Ask AI about your collection")
                }
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

/// Native Liquid Glass controls, coordinated by the scene because the system's
/// separated trailing tab slot represents Search, not a two-action capture menu.
struct AssistantEntryChrome: View {
    let sections: [MainSection]
    @Binding var selection: MainSection
    @Binding var compact: Bool
    var showsAssistant = true
    let openAssistant: () -> Void
    let capture: (QuickCaptureKind) -> Void
    @State private var showCapture = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glass
    var body: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(spacing: 10) {
                if showCapture {
                    VStack(alignment: .trailing, spacing: 16) {
                        captureAction("Camera", icon: "camera", kind: .camera)
                        captureAction("Text", icon: "text.cursor", kind: .text)
                    }.frame(maxWidth: .infinity, alignment: .trailing).padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if showsAssistant {
                HStack(spacing: 10) {
                    if compact {
                        Button {
                            withAnimation(animation) { compact = false }
                        } label: { Image(systemName: selection.systemImage).font(.title3).frame(width: 48, height: 48) }
                            .buttonStyle(.plain).glassEffect(.regular.interactive(), in: .circle)
                            .accessibilityLabel("Expand navigation")
                            .glassEffectID("navigation", in: glass)
                    }
                    Button(action: openAssistant) {
                        HStack(spacing: 12) {
                            Image(systemName: "sparkles")
                            Text("Ask AI").foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }.padding(.horizontal, 18).frame(height: 48).frame(maxWidth: .infinity)
                    }.buttonStyle(.plain).glassEffect(.regular.interactive(), in: .capsule)
                        .accessibilityLabel("Ask AI").glassEffectID("assistant", in: glass)
                    Button {
                        withAnimation(animation) { showCapture.toggle() }
                    } label: {
                        Image(systemName: showCapture ? "xmark" : "plus").font(.title3.weight(.medium)).contentTransition(.symbolEffect(.replace)).frame(width: 48, height: 48)
                    }.buttonStyle(.plain).glassEffect(.regular.interactive(), in: .circle)
                        .accessibilityLabel(showCapture ? "Close Quick Capture options" : "Quick Capture")
                        .glassEffectID("capture", in: glass)
                }
                }
                if !compact || !showsAssistant {
                    HStack(spacing: 0) {
                        ForEach(sections) { section in
                            Button {
                                selection = section
                                withAnimation(animation) { showCapture = false }
                            } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: section.systemImage).font(.system(size: 23))
                                    Text(LocalizedStringKey(section.title)).font(.system(size: 10, weight: .medium))
                                }.foregroundStyle(selection == section ? Color.accentColor : .primary)
                                    .frame(maxWidth: .infinity).frame(height: 54)
                                    .background(selection == section ? Color.primary.opacity(0.07) : Color.clear, in: Capsule())
                            }.buttonStyle(.plain)
                                .accessibilityAddTraits(selection == section ? .isSelected : [])
                        }
                    }.padding(5).glassEffect(.regular, in: .capsule).glassEffectID("navigation", in: glass)
                }
            }
        }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 4)
            .background {
                if showCapture {
                    Rectangle().fill(.ultraThinMaterial).ignoresSafeArea().frame(height: 2000).offset(y: -850)
                        .onTapGesture { withAnimation(animation) { showCapture = false } }
                }
            }
    }
    private var animation: Animation? { reduceMotion ? nil : .smooth(duration: 0.3) }
    private func captureAction(_ title: String, icon: String, kind: QuickCaptureKind) -> some View {
        Button { withAnimation(animation) { showCapture = false }; capture(kind) } label: {
            HStack(spacing: 16) {
                Text(title).font(.headline)
                Image(systemName: icon).font(.title3).frame(width: 48, height: 48).glassEffect(.regular.interactive(), in: .circle)
            }
        }.buttonStyle(.plain).accessibilityLabel("Capture \(title.lowercased())")
    }
}
