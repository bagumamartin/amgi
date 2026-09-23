import SwiftUI
import AmgiUI
import Combine
import PhotosUI
import UniformTypeIdentifiers
import Dependencies
import AnkiClients
import AmgiTheme
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif

struct NoteFieldMediaBridge: ViewModifier {
    @Bindable var session: NoteFieldEditingSession
    @Environment(\.palette) private var palette
    @State private var libraryItem: PhotosPickerItem?
    @State private var showLibrary = false
    @State private var showCamera = false
    @State private var showFiles = false
    @State private var showRecorder = false
    #if os(iOS)
    @State private var showComposer = false
    @State private var composerPane: NotePhotoPane = .recents
    @State private var destinationFrame: CGRect = .zero
    #endif
    @Dependency(\.mediaClient) private var mediaClient

    func body(content: Content) -> some View {
        let pending = session.pendingMediaSource
        content
            #if os(iOS)
            .background {
                GeometryReader { geo in
                    Color.clear.preference(
                        key: NotePhotoDestinationKey.self,
                        value: geo.frame(in: .global)
                    )
                }
            }
            .onPreferenceChange(NotePhotoDestinationKey.self) { destinationFrame = $0 }
            #endif
            .onChange(of: pending) { _, source in
                guard let source else { return }
                session.pendingMediaSource = nil
                handle(source)
            }
            .onChange(of: session.pendingAudioRecord) { _, requested in
                guard requested else { return }
                session.pendingAudioRecord = false
                showRecorder = true
            }
            .sheet(isPresented: $showRecorder) {
                NoteAudioRecorderSheet { url in
                    showRecorder = false
                    if let url { Task { await importAudio(url) } }
                }
                .presentationDetents([.medium])
            }
            .photosPicker(
                isPresented: $showLibrary,
                selection: $libraryItem,
                matching: .images,
                photoLibrary: .shared()
            )
            .onChange(of: libraryItem) { _, item in
                guard let item else { return }
                libraryItem = nil
                Task { await importItem(item) }
            }
            .fileImporter(
                isPresented: $showFiles,
                allowedContentTypes: [.image, .audio, .movie, .pdf],
                allowsMultipleSelection: false
            ) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                Task { await importFile(url) }
            }
            #if os(iOS)
            .sheet(isPresented: $showComposer) {
                NotePhotoComposerSheet(
                    initialPane: composerPane,
                    onPick: { selections in
                        showComposer = false
                        flyAndInsert(selections)
                    },
                    onLibraryPick: { providers in
                        showComposer = false
                        Task { await importProviders(providers) }
                    }
                )
                .presentationDetents([.fraction(0.82), .large])
                .presentationDragIndicator(.hidden)
                .presentationCornerRadius(AmgiRadius.sheet)
                .presentationBackground(palette.background)
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { image in
                    showCamera = false
                    Task { await importImage(image) }
                } onCancel: {
                    showCamera = false
                }
                .ignoresSafeArea()
            }
            #endif
    }

    private func handle(_ source: NoteFieldMediaSource) {
        switch source {
        case .files:
            showFiles = true
        case .library:
            #if os(iOS)
            if usesCustomPhotoSheet {
                openComposer(pane: .recents)
            } else {
                showLibrary = true
            }
            #else
            showLibrary = true
            #endif
        case .camera:
            #if os(iOS)
            if usesCustomPhotoSheet {
                openComposer(pane: .camera)
            } else {
                showCamera = true
            }
            #else
            showLibrary = true
            #endif
        }
    }

    #if os(iOS)
    private var usesCustomPhotoSheet: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    private func openComposer(pane: NotePhotoPane) {
        composerPane = pane
        session.perform(.dismiss)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(280))
            showComposer = true
        }
    }

    private func flyAndInsert(_ selections: [NotePhotoSelection]) {
        guard let first = selections.first else { return }
        let landing = landingFrame(from: destinationFrame)
        NotePhotoFlight.play(image: first.image, from: first.sourceFrame, to: landing) {
            Task {
                for selection in selections {
                    await importImage(selection.image)
                }
            }
        }
    }

    private func landingFrame(from container: CGRect) -> CGRect {
        let size: CGFloat = 72
        guard container.width > 0 else { return .zero }
        return CGRect(
            x: container.midX - size / 2,
            y: container.minY + 24,
            width: size,
            height: size
        )
    }
    #endif

    private func importItem(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        #if os(iOS)
        if let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.85) {
            await addMedia(data: jpeg, ext: "jpg")
            return
        }
        #endif
        await addMedia(data: data, ext: Self.inferredExtension(from: data, fallback: "jpg"))
    }

    private func importFile(_ url: URL) async {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        let ext = url.pathExtension.isEmpty
            ? Self.inferredExtension(from: data, fallback: "bin")
            : url.pathExtension.lowercased()
        await addMedia(data: data, ext: ext)
    }

    #if os(iOS)
    private func importImage(_ image: UIImage) async {
        guard let data = image.jpegData(compressionQuality: 0.85) else { return }
        await addMedia(data: data, ext: "jpg")
    }

    private func importProviders(_ providers: [NSItemProvider]) async {
        for provider in providers {
            guard let data = await Self.loadImageData(from: provider) else { continue }
            await addMedia(data: data, ext: Self.inferredExtension(from: data, fallback: "jpg"))
        }
    }

    private static func loadImageData(from provider: NSItemProvider) async -> Data? {
        let data: Data? = await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
        if let data { return data }
        let image: UIImage? = await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                continuation.resume(returning: object as? UIImage)
            }
        }
        return image?.jpegData(compressionQuality: 0.85)
    }
    #endif

    private func importAudio(_ url: URL) async {
        guard let data = try? Data(contentsOf: url) else { return }
        try? FileManager.default.removeItem(at: url)
        await addMedia(data: data, ext: "m4a")
    }

    private func addMedia(data: Data, ext: String) async {
        let desired = "paste-\(UUID().uuidString).\(ext)"
        do {
            let filename = try await mediaClient.addFile(desired, data)
            guard mediaClient.localURL(filename) != nil else { return }
            await MainActor.run {
                session.insertMedia(filename: filename)
            }
        } catch {
            do {
                try await mediaClient.save(data, desired)
                guard mediaClient.localURL(desired) != nil else { return }
                await MainActor.run {
                    session.insertMedia(filename: desired)
                }
            } catch {
                return
            }
        }
    }

    private static func inferredExtension(from data: Data, fallback: String) -> String {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if data.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
        if data.count >= 3, data[0] == 0xFF, data[1] == 0xD8, data[2] == 0xFF { return "jpg" }
        return fallback
    }
}

/// Audio recording + attachment-insertion playback (desktop editor parity).
/// Records AAC/m4a, offers play-before-insert verification, then hands the
/// file to the media bridge for collection-aware import (`[sound:…]`).
struct NoteAudioRecorderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    let onDone: (URL?) -> Void

    @StateObject private var recorder = NoteAudioRecorder()

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text(recorder.statusText)
                    .amgiFont(.bodyEmphasis, .monospacedDigits)
                HStack(spacing: 16) {
                    Button(recorder.isRecording ? "Stop" : "Record") {
                        recorder.toggle()
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Play") {
                        recorder.play()
                    }
                    .buttonStyle(.bordered)
                    .disabled(recorder.recordedURL == nil || recorder.isRecording)
                }
                if recorder.recordedURL != nil, !recorder.isRecording {
                    Text("Review the take, then insert it as a sound attachment.")
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Record Audio")
            .navigationBarTitleDisplayMode(.inline)
            .onDisappear { recorder.shutdown() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        recorder.cancel()
                        onDone(nil)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Insert") {
                        let url = recorder.recordedURL
                        recorder.keep()
                        onDone(url)
                    }
                    .disabled(recorder.recordedURL == nil || recorder.isRecording)
                }
            }
        }
    }
}

@MainActor
final class NoteAudioRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var recordedURL: URL?
    @Published private(set) var statusText = "Ready"
    @Published private(set) var elapsed: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var keepFile = false

    override init() {
        super.init()
    }

    func toggle() {
        isRecording ? stop() : start()
    }

    func start() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
        } catch {
            statusText = "Microphone unavailable"
            return
        }
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                guard granted else {
                    self.statusText = "Microphone permission denied"
                    return
                }
                self.beginRecording()
            }
        }
        #else
        // macOS: AVAudioRecorder prompts for microphone access on first use.
        beginRecording()
        #endif
    }

    private func beginRecording() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("amgi-audio-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        do {
            recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder?.delegate = self
            recorder?.record()
            isRecording = true
            recordedURL = url
            keepFile = false
            elapsed = 0
            statusText = "Recording… 0.0s"
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.elapsed += 0.1
                    self.statusText = String(format: "Recording… %.1fs", self.elapsed)
                }
            }
        } catch {
            statusText = "Couldn't start recording"
        }
    }

    func stop() {
        recorder?.stop()
        timer?.invalidate()
        timer = nil
        isRecording = false
        statusText = recordedURL == nil ? "Ready" : "Recorded — play to verify"
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    func play() {
        guard let url = recordedURL, !isRecording else { return }
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.delegate = self
            player?.play()
            statusText = "Playing…"
        } catch {
            statusText = "Couldn't play that take"
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        statusText = flag ? "Recorded — play to verify" : "Playback failed"
    }

    /// Discards the take file.
    func cancel() {
        timer?.invalidate()
        timer = nil
        recorder?.stop()
        recorder = nil
        player?.stop()
        player = nil
        if !keepFile, let url = recordedURL {
            try? FileManager.default.removeItem(at: url)
        }
        recordedURL = nil
        isRecording = false
    }

    /// Keeps the file for the caller (prevents cleanup on dismiss).
    func keep() {
        keepFile = true
        shutdown()
    }

    /// Stops timers/recorder/player without deleting a kept file.
    func shutdown() {
        timer?.invalidate()
        timer = nil
        recorder?.stop()
        recorder = nil
        player?.stop()
        player = nil
    }
}

#if os(iOS)
private struct NotePhotoDestinationKey: PreferenceKey {
    static var defaultValue: CGRect { .zero }
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next.height > 0 { value = next }
    }
}

private struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onImage: onImage, onCancel: onCancel) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onImage: (UIImage) -> Void
        let onCancel: () -> Void

        init(onImage: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
            self.onImage = onImage
            self.onCancel = onCancel
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                onImage(image)
            } else {
                onCancel()
            }
        }
    }
}
#endif
