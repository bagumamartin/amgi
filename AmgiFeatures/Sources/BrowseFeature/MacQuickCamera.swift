#if os(macOS)
import AppKit
@preconcurrency import AVFoundation
import Combine
import SwiftUI

/// Uses AVFoundation's system camera devices, including Continuity Camera.
/// All capture-session configuration and callbacks stay on the capture queue.
struct MacQuickCamera: View {
    let onPhoto: (Data) -> Void
    let onChooseFile: () -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = MacQuickCameraModel()
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Camera Capture").font(.headline)
                Spacer()
                Button("Close", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
            }
            if let engine = model.engine {
                MacCameraPreview(session: engine.session).frame(minHeight: 280)
            } else { ContentUnavailableView("Camera", systemImage: "camera", description: Text(model.status)) }
            if !model.devices.isEmpty {
                Picker("Camera", selection: $model.selectedID) {
                    ForEach(model.devices, id: \.id) { Text($0.name).tag($0.id) }
                }.onChange(of: model.selectedID) { model.select() }
            }
            Text(model.status).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Choose image…") { dismiss(); onChooseFile() }
                Spacer()
                Button("Capture", systemImage: "camera.fill") { model.capture() }
                    .buttonStyle(.glassProminent).disabled(!model.ready || model.capturing)
            }
        }.padding(24).frame(minWidth: 500, minHeight: 430)
        .task { await model.prepare() }
        .onChange(of: model.photo) { if let data = model.photo { onPhoto(data); dismiss() } }
        .onDisappear { model.engine?.stop() }
    }
}

@MainActor private final class MacQuickCameraModel: ObservableObject {
    struct Device: Identifiable { let id: String; let name: String }
    @Published var devices: [Device] = []
    @Published var selectedID = ""
    @Published var status = "Connect a camera or use your iPhone with Continuity Camera."
    @Published var ready = false
    @Published var capturing = false
    @Published var photo: Data?
    @Published var engine: MacCameraEngine?
    func prepare() async {
        guard engine == nil else { return }
        guard await AVCaptureDevice.requestAccess(for: .video), !Task.isCancelled else { status = "Camera access is off. You can choose an image instead."; return }
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified).devices
        devices = found.map { Device(id: $0.uniqueID, name: $0.localizedName) }
        guard let first = devices.first else { status = "No camera is available. Connect a camera or choose an image."; return }
        selectedID = first.id
        engine = MacCameraEngine { [weak self] event in
            guard let self else { return }
            switch event {
            case .ready: ready = true; status = "Ready"
            case .failure(let message): ready = false; capturing = false; status = message
            case .photo(let data): capturing = false; photo = data
            }
        }
        select()
    }
    func select() { ready = false; status = "Opening camera…"; engine?.select(selectedID) }
    func capture() { guard ready, !capturing else { return }; capturing = true; engine?.capture() }
}

/// `session` is shared only with the preview layer. Mutation is confined to
/// this serial queue; delegates are delivered there by AVFoundation.
private final class MacCameraEngine: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    enum Event: Sendable { case ready, failure(String), photo(Data) }
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "ijuka.quick-camera", qos: .userInitiated)
    private let output = AVCapturePhotoOutput()
    private let event: @MainActor @Sendable (Event) -> Void
    init(event: @escaping @MainActor @Sendable (Event) -> Void) { self.event = event; super.init() }
    private func publish(_ value: Event) { Task { @MainActor in event(value) } }
    func select(_ id: String) {
        queue.async { [self] in
            session.stopRunning()
            session.beginConfiguration()
            session.inputs.forEach { session.removeInput($0) }
            do {
                guard let device = AVCaptureDevice(uniqueID: id) else { throw CameraError.unavailable }
                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input) else { throw CameraError.unavailable }
                session.addInput(input)
                if session.outputs.isEmpty {
                    guard session.canAddOutput(output) else { throw CameraError.unavailable }
                    session.addOutput(output)
                }
                session.sessionPreset = .photo
                session.commitConfiguration()
                session.startRunning()
                publish(session.isRunning ? .ready : .failure("The camera could not start. Choose another camera or image."))
            } catch {
                session.commitConfiguration()
                publish(.failure("The camera is unavailable. Choose another camera or image."))
            }
        }
    }
    func capture() { queue.async { [self] in output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self) } }
    func stop() { queue.async { [self] in session.stopRunning() } }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: (any Error)?) {
        if error == nil, let data = photo.fileDataRepresentation() { publish(.photo(data)) }
        else { publish(.failure("Capture failed. Please try again.")) }
    }
    private enum CameraError: Error { case unavailable }
}

private struct MacCameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> NSView {
        let view = NSView(); view.wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(session: session); layer.videoGravity = .resizeAspect
        view.layer = layer; return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}
#endif
