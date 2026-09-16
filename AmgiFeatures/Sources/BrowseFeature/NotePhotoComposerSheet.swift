#if os(iOS)
import AVFoundation
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import AmgiTheme
import AmgiUI
import UIKit

enum NotePhotoPane: String, CaseIterable, Identifiable {
    case recents
    case camera

    var id: String { rawValue }
}

struct NotePhotoSelection {
    var image: UIImage
    var sourceFrame: CGRect
}

private enum NotePhotoChrome {
    static let button: CGFloat = 48
    static let shutterOuter: CGFloat = 76
    static let shutterInner: CGFloat = 54
    static let mosaicGap: CGFloat = 2
    static let librarySelectionLimit = 10
    static var bottomReserve: CGFloat { shutterOuter + AmgiSpacing.lg + AmgiSpacing.md }
}

private struct NotePhotoGlassCircle: View {
    var systemName: String
    var label: String
    var action: () -> Void

    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
                .frame(width: NotePhotoChrome.button, height: NotePhotoChrome.button)
                .contentShape(Circle())
        }
        .buttonStyle(.pressScale)
        .amgiMaterial(.regular, in: Circle(), interactive: true)
        .amgiMaterialElevation(Circle())
        .accessibilityLabel(label)
    }
}

struct NotePhotoComposerSheet: View {
    var initialPane: NotePhotoPane
    var onPick: ([NotePhotoSelection]) -> Void
    /// Library picks hand back providers, not images: the sheet closes the
    /// instant the picker confirms, and decoding happens after the dismissal.
    var onLibraryPick: ([NSItemProvider]) -> Void

    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var pane: NotePhotoPane
    @State private var recents = NotePhotoRecentsStore()
    @State private var showLimitedPicker = false
    @State private var showLibraryPicker = false

    init(
        initialPane: NotePhotoPane,
        onPick: @escaping ([NotePhotoSelection]) -> Void,
        onLibraryPick: @escaping ([NSItemProvider]) -> Void
    ) {
        self.initialPane = initialPane
        self.onPick = onPick
        self.onLibraryPick = onLibraryPick
        _pane = State(initialValue: initialPane)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            palette.background.ignoresSafeArea()
            paneBody
            if recents.authorization == .limited, pane == .recents {
                VStack {
                    limitedBanner
                    Spacer()
                }
            }
            chrome
        }
        .background(palette.background)
        .task { await recents.prepare() }
        .background {
            LimitedLibraryPickerHost(isPresented: $showLimitedPicker)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            NoteSystemPhotoPickerHost(
                isPresented: $showLibraryPicker,
                onPick: onLibraryPick
            )
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var paneBody: some View {
        switch pane {
        case .recents:
            recentsPane
        case .camera:
            NoteInSheetCamera(
                onCapture: { image, frame in
                    onPick([NotePhotoSelection(image: image, sourceFrame: frame)])
                },
                onBack: { pane = .recents },
                onUnavailable: openLibrary
            )
        }
    }

    @ViewBuilder
    private var chrome: some View {
        if pane == .recents {
            HStack(alignment: .center, spacing: AmgiSpacing.md) {
                NotePhotoGlassCircle(systemName: "chevron.left", label: "Close", action: dismiss.callAsFunction)
                    .frame(height: NotePhotoChrome.shutterOuter)
                Spacer(minLength: 0)
                allPhotosButton
                    .frame(height: NotePhotoChrome.shutterOuter)
            }
            .padding(.horizontal, AmgiSpacing.lg)
            .padding(.bottom, AmgiSpacing.lg)
            .ignoresSafeArea(edges: .bottom)
        }
    }

    private var allPhotosButton: some View {
        Button {
            openLibrary()
        } label: {
            Text("All Photos")
                .amgiFont(.bodyEmphasis)
                .foregroundStyle(palette.textPrimary)
                .padding(.horizontal, AmgiSpacing.xl)
                .frame(height: NotePhotoChrome.button)
                .contentShape(Capsule())
        }
        .buttonStyle(.pressScale)
        .amgiMaterial(.regular, in: Capsule(), interactive: true)
        .amgiMaterialElevation(Capsule())
        .accessibilityLabel("All photos")
    }

    private func openLibrary() {
        showLibraryPicker = true
    }

    private var limitedBanner: some View {
        HStack(alignment: .center, spacing: AmgiSpacing.sm) {
            Text("This is a subset of your photos.")
                .amgiFont(.caption)
                .foregroundStyle(palette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Manage") { showLimitedPicker = true }
                .amgiFont(.captionBold)
                .foregroundStyle(palette.accent)
            Button("Settings") { openSettings() }
                .amgiFont(.captionBold)
                .foregroundStyle(palette.accent)
        }
        .padding(.horizontal, AmgiSpacing.md)
        .padding(.vertical, AmgiSpacing.sm)
        .padding(.top, AmgiSpacing.md)
        .background(palette.accentSoft)
    }

    @ViewBuilder
    private var recentsPane: some View {
        switch recents.authorization {
        case .notDetermined:
            permissionPrompt(
                title: "Allow photo access",
                message: "Amgi can show your recent photos so you can drop them onto a card.",
                action: "Continue"
            ) {
                Task { await recents.prepare() }
            }
        case .denied, .restricted:
            permissionPrompt(
                title: "Photos are locked",
                message: "You can still pick from All Photos, or allow access in Settings.",
                action: "Open Settings",
                secondary: "Use Library"
            ) {
                openSettings()
            } secondaryAction: {
                openLibrary()
            }
        case .authorized, .limited:
            recentsGrid
        @unknown default:
            recentsGrid
        }
    }

    private var recentsGrid: some View {
        GeometryReader { geo in
            let spacing = NotePhotoChrome.mosaicGap
            let columns = 3
            let side = max(0, (geo.size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columns),
                    spacing: spacing
                ) {
                    ForEach(recents.assets, id: \.localIdentifier) { asset in
                        NotePhotoThumbnail(asset: asset, side: side) { image, frame in
                            onPick([NotePhotoSelection(image: image, sourceFrame: frame)])
                        }
                    }
                }
                .padding(.bottom, NotePhotoChrome.bottomReserve)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func permissionPrompt(
        title: String,
        message: String,
        action: String,
        secondary: String? = nil,
        primaryAction: @escaping () -> Void,
        secondaryAction: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: AmgiSpacing.md) {
            Spacer()
            Text(title)
                .amgiFont(.bodyEmphasis)
                .foregroundStyle(palette.textPrimary)
            Text(message)
                .amgiFont(.caption)
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AmgiSpacing.lg)
            Button(action, action: primaryAction)
                .amgiFont(.bodyEmphasis)
                .foregroundStyle(palette.accent)
            if let secondary, let secondaryAction {
                Button(secondary, action: secondaryAction)
                    .amgiFont(.caption)
                    .foregroundStyle(palette.textSecondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - Recents store

@Observable
@MainActor
final class NotePhotoRecentsStore: NSObject, PHPhotoLibraryChangeObserver {
    var authorization: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    var assets: [PHAsset] = []

    override init() {
        super.init()
        PHPhotoLibrary.shared().register(self)
    }

    nonisolated deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    func prepare() async {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if current == .notDetermined {
            authorization = await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                    continuation.resume(returning: status)
                }
            }
        } else {
            authorization = current
        }
        fetch()
    }

    func fetch() {
        guard authorization == .authorized || authorization == .limited else {
            assets = []
            return
        }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 80
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var next: [PHAsset] = []
        next.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            next.append(asset)
        }
        assets = next
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in
            fetch()
        }
    }
}

// MARK: - Thumbnail

private struct NotePhotoThumbnail: View {
    var asset: PHAsset
    var side: CGFloat
    var onPick: (UIImage, CGRect) -> Void

    @Environment(\.palette) private var palette
    @State private var thumbnail: UIImage?
    @State private var requestID: PHImageRequestID?

    var body: some View {
        GeometryReader { geo in
            Button {
                let frame = geo.frame(in: .global)
                Task { await pickFullImage(sourceFrame: frame) }
            } label: {
                ZStack {
                    Rectangle().fill(palette.surfaceElevated)
                    if let thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                    }
                }
                .frame(width: side, height: side)
                .clipped()
            }
            .buttonStyle(.plain)
        }
        .frame(width: side, height: side)
        .task(id: asset.localIdentifier) { await loadThumbnail() }
        .onDisappear { cancelRequest() }
        .accessibilityLabel("Photo")
    }

    private func loadThumbnail() async {
        cancelRequest()
        let scale = UIScreen.main.scale
        let size = CGSize(width: side * scale, height: side * scale)
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        requestID = PHImageManager.default().requestImage(
            for: asset,
            targetSize: size,
            contentMode: .aspectFill,
            options: options
        ) { image, _ in
            Task { @MainActor in
                if let image { thumbnail = image }
            }
        }
    }

    private func pickFullImage(sourceFrame: CGRect) async {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .none
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        let image = await withCheckedContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                let loaded = data.flatMap(UIImage.init(data:))
                continuation.resume(returning: loaded)
            }
        }
        if let image {
            onPick(image, sourceFrame)
        } else if let thumbnail {
            onPick(thumbnail, sourceFrame)
        }
    }

    private func cancelRequest() {
        if let requestID {
            PHImageManager.default().cancelImageRequest(requestID)
        }
        requestID = nil
    }
}

// MARK: - System photo picker

/// `PHPickerViewController` only lays out correctly as a UIKit presentation, so
/// it is presented over the composer instead of being swapped into the sheet's
/// content. On confirm the picker is left standing: the composer's own
/// dismissal takes it down with it, so both leave in one animation.
private struct NoteSystemPhotoPickerHost: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    var onPick: ([NSItemProvider]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented, onPick: onPick)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        context.coordinator.isPresented = $isPresented
        context.coordinator.onPick = onPick
        context.coordinator.sync(from: uiViewController, isPresented: isPresented)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        var isPresented: Binding<Bool>
        var onPick: ([NSItemProvider]) -> Void
        private weak var presented: PHPickerViewController?

        init(isPresented: Binding<Bool>, onPick: @escaping ([NSItemProvider]) -> Void) {
            self.isPresented = isPresented
            self.onPick = onPick
        }

        func sync(from host: UIViewController, isPresented: Bool) {
            if isPresented {
                guard presented == nil, host.presentedViewController == nil else { return }
                guard host.view.window != nil else {
                    DispatchQueue.main.async { [weak self, weak host] in
                        guard let host else { return }
                        self?.sync(from: host, isPresented: true)
                    }
                    return
                }
                var configuration = PHPickerConfiguration(photoLibrary: .shared())
                configuration.filter = .images
                configuration.selectionLimit = NotePhotoChrome.librarySelectionLimit
                configuration.selection = .default
                configuration.preferredAssetRepresentationMode = .current
                let picker = PHPickerViewController(configuration: configuration)
                picker.delegate = self
                presented = picker
                host.present(picker, animated: true)
            } else if let picker = presented {
                presented = nil
                picker.dismiss(animated: true)
            }
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !results.isEmpty else {
                presented = nil
                isPresented.wrappedValue = false
                picker.dismiss(animated: true)
                return
            }
            // Leave the picker on screen and hand the providers up; closing the
            // composer dismisses this picker along with it.
            presented = nil
            onPick(results.map(\.itemProvider))
        }
    }
}

// MARK: - In-sheet camera

private struct NoteInSheetCamera: View {
    var onCapture: (UIImage, CGRect) -> Void
    var onBack: () -> Void
    var onUnavailable: () -> Void

    @Environment(\.palette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    @State private var controller = NoteCameraSession()
    @State private var authorization: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var showTools = false
    @State private var flashEnabled = false

    var body: some View {
        Group {
            if !controller.isAvailable {
                unavailable
            } else {
                switch authorization {
                case .notDetermined:
                    permission
                case .denied, .restricted:
                    denied
                default:
                    cameraPreview
                }
            }
        }
        .task { await configure() }
        .onDisappear {
            showTools = false
            controller.stop()
        }
    }

    private var cameraPreview: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                NoteCameraPreview(session: controller.session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                cameraControls(in: geo)
            }
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private func cameraControls(in geo: GeometryProxy) -> some View {
        HStack(alignment: .bottom, spacing: AmgiSpacing.md) {
            NotePhotoGlassCircle(systemName: "chevron.left", label: "Back", action: onBack)
                .frame(height: NotePhotoChrome.shutterOuter)
            Spacer(minLength: 0)
            shutterButton(in: geo)
            Spacer(minLength: 0)
            VStack(spacing: AmgiSpacing.md) {
                if showTools {
                    NotePhotoGlassCircle(
                        systemName: flashEnabled ? "bolt.fill" : "bolt.slash.fill",
                        label: flashEnabled ? "Flash on" : "Flash off"
                    ) {
                        flashEnabled.toggle()
                    }
                    NotePhotoGlassCircle(
                        systemName: "arrow.triangle.2.circlepath",
                        label: "Flip camera"
                    ) {
                        controller.flip()
                    }
                }
                NotePhotoGlassCircle(
                    systemName: showTools ? "xmark" : "ellipsis",
                    label: showTools ? "Close tools" : "More camera tools"
                ) {
                    withAnimation(AmgiMotion.standard) { showTools.toggle() }
                }
                .frame(height: NotePhotoChrome.shutterOuter)
            }
        }
        .padding(.horizontal, AmgiSpacing.lg)
        .padding(.bottom, AmgiSpacing.lg)
    }

    private func shutterButton(in geo: GeometryProxy) -> some View {
        Button {
            let frame = geo.frame(in: .global)
            controller.capture(flash: flashEnabled) { image in
                if let image {
                    onCapture(image, frame)
                }
            }
        } label: {
            Circle()
                .fill(shutterFill)
                .frame(width: NotePhotoChrome.shutterInner, height: NotePhotoChrome.shutterInner)
                .frame(width: NotePhotoChrome.shutterOuter, height: NotePhotoChrome.shutterOuter)
                .contentShape(Circle())
        }
        .buttonStyle(.pressScale)
        .amgiMaterial(.regular, in: Circle(), interactive: true)
        .amgiMaterialElevation(Circle())
        .accessibilityLabel("Take photo")
    }

    /// Solid disc on the glass shutter. Light themes use `surface` (white on
    /// vivid/muted); dark themes use `textPrimary` so it stays the light disc
    /// ChatGPT layers on the glass — not a stroked ring of `textPrimary`.
    private var shutterFill: Color {
        colorScheme == .dark ? palette.textPrimary : palette.surface
    }

    private var permission: some View {
        VStack(spacing: AmgiSpacing.md) {
            Spacer()
            Text("Allow camera access")
                .amgiFont(.bodyEmphasis)
                .foregroundStyle(palette.textPrimary)
            Text("Amgi uses the camera to add pictures to your cards.")
                .amgiFont(.caption)
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AmgiSpacing.lg)
            Button("Continue") {
                Task { await configure() }
            }
            .amgiFont(.bodyEmphasis)
            .foregroundStyle(palette.accent)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var denied: some View {
        VStack(spacing: AmgiSpacing.md) {
            Spacer()
            Text("Camera is locked")
                .amgiFont(.bodyEmphasis)
                .foregroundStyle(palette.textPrimary)
            Text("Allow access in Settings, or pick a photo from All Photos.")
                .amgiFont(.caption)
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AmgiSpacing.lg)
            Button("Open Settings") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
            .amgiFont(.bodyEmphasis)
            .foregroundStyle(palette.accent)
            Button("Use Library") { onUnavailable() }
                .amgiFont(.caption)
                .foregroundStyle(palette.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var unavailable: some View {
        VStack(spacing: AmgiSpacing.md) {
            Spacer()
            Text("Camera isn’t available")
                .amgiFont(.bodyEmphasis)
                .foregroundStyle(palette.textPrimary)
            Text("Use All Photos to attach a picture instead.")
                .amgiFont(.caption)
                .foregroundStyle(palette.textSecondary)
            Button("Use Library") { onUnavailable() }
                .amgiFont(.bodyEmphasis)
                .foregroundStyle(palette.accent)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func configure() async {
        authorization = AVCaptureDevice.authorizationStatus(for: .video)
        if authorization == .notDetermined {
            authorization = await AVCaptureDevice.requestAccess(for: .video) ? .authorized : .denied
        }
        if authorization == .authorized {
            controller.start()
        }
    }
}

@MainActor
private final class NoteCameraSession: NSObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private var continuation: ((UIImage?) -> Void)?
    var isAvailable: Bool {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil
            || AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) != nil
    }

    private var currentPosition: AVCaptureDevice.Position = .back

    func start() {
        guard !session.isRunning else { return }
        attach(position: currentPosition)
        let capture = session
        DispatchQueue.global(qos: .userInitiated).async {
            capture.startRunning()
        }
    }

    func flip() {
        let next: AVCaptureDevice.Position = currentPosition == .back ? .front : .back
        let running = session.isRunning
        if running { session.stopRunning() }
        attach(position: next)
        if running {
            let capture = session
            DispatchQueue.global(qos: .userInitiated).async {
                capture.startRunning()
            }
        }
    }

    private func attach(position: AVCaptureDevice.Position) {
        session.beginConfiguration()
        session.sessionPreset = .photo
        session.inputs.forEach { session.removeInput($0) }
        if session.outputs.contains(where: { $0 === output }) == false, session.canAddOutput(output) {
            session.addOutput(output)
        }
        let device =
            AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position == .back ? .front : .back)
        if let device, let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
            currentPosition = device.position
        }
        session.commitConfiguration()
    }

    func stop() {
        let capture = session
        DispatchQueue.global(qos: .userInitiated).async {
            if capture.isRunning { capture.stopRunning() }
        }
    }

    func capture(flash: Bool, completion: @escaping (UIImage?) -> Void) {
        continuation = completion
        let settings = AVCapturePhotoSettings()
        if flash, output.supportedFlashModes.contains(.on) {
            settings.flashMode = .on
        } else if output.supportedFlashModes.contains(.off) {
            settings.flashMode = .off
        }
        output.capturePhoto(with: settings, delegate: self)
    }

    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: (any Error)?
    ) {
        let image = photo.fileDataRepresentation().flatMap(UIImage.init(data:))
        Task { @MainActor in
            continuation?(image)
            continuation = nil
        }
    }
}

private struct NoteCameraPreview: UIViewRepresentable {
    var session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.previewLayer.session = session
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

// MARK: - Limited library

private struct LimitedLibraryPickerHost: UIViewControllerRepresentable {
    @Binding var isPresented: Bool

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        guard isPresented, uiViewController.view.window != nil else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: uiViewController)
        DispatchQueue.main.async {
            isPresented = false
        }
    }
}

@MainActor
enum NotePhotoFlight {
    static func play(image: UIImage, from: CGRect, to: CGRect, completion: @escaping () -> Void) {
        guard let window = keyWindow else {
            completion()
            return
        }
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = AmgiRadius.small
        imageView.frame = from == .zero ? CGRect(x: window.bounds.midX - 40, y: window.bounds.maxY - 160, width: 80, height: 80) : from
        window.addSubview(imageView)
        let target = to == .zero
            ? CGRect(x: window.bounds.midX - 36, y: window.safeAreaInsets.top + 120, width: 72, height: 72)
            : to
        let duration = AmgiMotion.prefersReducedMotion ? 0.15 : 0.35
        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseInOut]) {
            imageView.frame = target
            imageView.alpha = 0.92
        } completion: { _ in
            imageView.removeFromSuperview()
            completion()
        }
    }

    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }
}

#endif
