import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import Dependencies
import AnkiClients
#if canImport(UIKit)
import UIKit
#endif

struct NoteFieldMediaBridge: ViewModifier {
    var session: NoteFieldEditingSession
    @State private var libraryItem: PhotosPickerItem?
    @State private var showLibrary = false
    @State private var showCamera = false
    @State private var showFiles = false
    @Dependency(\.mediaClient) private var mediaClient

    func body(content: Content) -> some View {
        content
            .onChange(of: session.pendingMediaSource) { _, source in
                guard let source else { return }
                session.pendingMediaSource = nil
                switch source {
                case .library:
                    showLibrary = true
                case .camera:
                    #if os(iOS)
                    showCamera = true
                    #else
                    showLibrary = true
                    #endif
                case .files:
                    showFiles = true
                }
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
    #endif

    private func addMedia(data: Data, ext: String) async {
        let desired = "paste-\(UUID().uuidString).\(ext)"
        do {
            let filename = try await mediaClient.addFile(desired, data)
            await MainActor.run {
                session.insertMedia(filename: filename)
            }
        } catch {
            try? await mediaClient.save(data, desired)
            await MainActor.run {
                session.insertMedia(filename: desired)
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

#if os(iOS)
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
