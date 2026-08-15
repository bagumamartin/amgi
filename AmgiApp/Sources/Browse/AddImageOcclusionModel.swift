import AnkiKit
import AnkiClients
import AnkiServices
import Dependencies
import PhotosUI
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Data state + load/save logic for the Add Image Occlusion form. The View
/// owns the modal chrome, the photo picker selection, and the occlusion
/// editor cover; the model owns deck loading, image ingestion, and the note
/// write so the form stays testable and the View stays thin.
@Observable
@MainActor
final class AddImageOcclusionModel {
    var decks: [DeckInfo] = []
    var selectedDeckId: DeckID
    var selectedImage: PlatformImage?
    var masks: [IOMask] = []
    var header: String = ""
    var backExtra: String = ""
    var tagsText: String = ""
    var isSaving = false
    var errorMessage: String?
    var imageURL: URL?

    @ObservationIgnored @Dependency(\.deckClient) private var deckClient
    @ObservationIgnored @Dependency(\.decksService) private var decksService
    @ObservationIgnored @Dependency(\.imageOcclusionClient) private var client
    @ObservationIgnored private let preselectedDeckId: DeckID?

    init(preselectedDeckId: DeckID? = nil) {
        self.preselectedDeckId = preselectedDeckId
        self.selectedDeckId = preselectedDeckId ?? DeckID(0)
    }

    /// In Anki's IO notetype, occlusions are the first required field; header
    /// is a later optional field.
    var canSave: Bool {
        selectedDeckId.rawValue != 0 && selectedImage != nil && imageURL != nil && !masks.isEmpty
    }

    func loadDecks() async {
        decks = (try? await deckClient.fetchAll()) ?? []

        if let preselectedDeckId, decks.contains(where: { $0.id == preselectedDeckId }) {
            selectedDeckId = preselectedDeckId
            return
        }

        if let currentDeckId = try? decksService.getCurrentDeck().id,
           decks.contains(where: { $0.id == currentDeckId }) {
            selectedDeckId = currentDeckId
            return
        }

        if let firstDeck = decks.first {
            selectedDeckId = firstDeck.id
        }
    }

    func loadImage(from item: PhotosPickerItem?) async {
        guard let item else { return }
        masks = []

        if let data = try? await item.loadTransferable(type: Data.self),
           let img = PlatformImage(data: data) {
            selectedImage = img

            // Write a temporary file for the upload path
            let tempDir = FileManager.default.temporaryDirectory
            let filename = "io_pick_\(Int(Date().timeIntervalSince1970)).jpg"
            let url = tempDir.appendingPathComponent(filename)
            if let jpegData = jpegRepresentation(of: img) {
                try? jpegData.write(to: url)
                imageURL = url
            }
        }
    }

    private func jpegRepresentation(of image: PlatformImage) -> Data? {
        #if canImport(UIKit)
        return image.jpegData(compressionQuality: 0.92)
        #else
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92])
        #endif
    }

    /// Persist the image-occlusion note. Returns whether the write succeeded;
    /// on failure `errorMessage` carries the reason.
    func save() async -> Bool {
        guard selectedDeckId.rawValue != 0 else { return false }
        guard let url = imageURL else {
            errorMessage = "Image is missing."
            return false
        }
        guard !masks.isEmpty else {
            errorMessage = "Add at least one mask before saving."
            return false
        }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        let occlusions = masks.enumerated().map { idx, mask in
            mask.occlusionText(index: idx)
        }.joined(separator: "\n")
        let tags = tagsText.split(separator: " ").map(String.init).filter { !$0.isEmpty }

        do {
            try await client.addNote(url, occlusions, header, backExtra, tags, selectedDeckId, NotetypeID(0))
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
