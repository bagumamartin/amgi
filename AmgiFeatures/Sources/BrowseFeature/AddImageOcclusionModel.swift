import AnkiBackend
import AnkiKit
import AnkiClients
import AnkiServices
import Dependencies
import PhotosUI
import SwiftUI
import UIKit

/// Data state + load/save logic for the Add Image Occlusion form. The View
/// owns the modal chrome, the photo picker selection, and the occlusion
/// editor cover; the model owns deck loading, image ingestion, and the note
/// write so the form stays testable and the View stays thin.
@Observable
@MainActor
final class AddImageOcclusionModel {
    var decks: [DeckInfo] = []
    var selectedDeckId: DeckID
    var selectedImage: UIImage?
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

        let service = decksService
        if let currentDeckId = try? await backendOffload({ try service.getCurrentDeck() }).id,
           decks.contains(where: { $0.id == currentDeckId }) {
            selectedDeckId = currentDeckId
            return
        }

        if let firstDeck = decks.first {
            selectedDeckId = firstDeck.id
        }
    }

    /// Longest edge the occlusion editor ever needs. Masks are stored
    /// normalized (0...1), so downsampling the on-screen image does not
    /// change what gets written to the note.
    private static let maxDisplayEdge: CGFloat = 2048

    private static func displayFit(for size: CGSize) -> CGSize {
        let longest = max(size.width, size.height)
        guard longest > maxDisplayEdge, longest > 0 else { return size }
        let scale = maxDisplayEdge / longest
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    func loadImage(from item: PhotosPickerItem?) async {
        guard let item else { return }
        masks = []

        // Load as UIImage
        if let data = try? await item.loadTransferable(type: Data.self),
           let img = UIImage(data: data) {
            // Write a temporary file for the upload path. The encode and the
            // write both go off the main actor: this model is @MainActor, and
            // re-encoding a full-resolution camera photo there froze the UI
            // for the length of the encode right after the picker dismissed.
            let tempDir = FileManager.default.temporaryDirectory
            let filename = "io_pick_\(UUID().uuidString).jpg"
            let url = tempDir.appendingPathComponent(filename)
            let result = await Task.detached(priority: .userInitiated) {
                // The note gets the full-resolution encode; the editor gets a
                // display-sized copy. Holding the 12 MP original as a decoded
                // ~48 MB backing store for the whole editing session (plus the
                // canvas's own scaled bitmap) was a jetsam risk on older
                // devices.
                let displayImage = await img.byPreparingThumbnail(
                    ofSize: Self.displayFit(for: img.size)
                ) ?? img
                guard let jpegData = img.jpegData(compressionQuality: 0.92) else {
                    return (displayImage, false)
                }
                do {
                    try jpegData.write(to: url)
                    return (displayImage, true)
                } catch {
                    return (displayImage, false)
                }
            }.value
            selectedImage = result.0
            if result.1 { imageURL = url }
        }
    }

    /// Persist the image-occlusion note. Returns whether the write succeeded;
    /// on failure `errorMessage` carries the reason.
    func save() async -> Bool {
        guard selectedDeckId.rawValue != 0 else {
            // Returning bare made Save do nothing at all with no
            // explanation, unlike the two guards below it.
            errorMessage = "Choose a deck before saving."
            return false
        }
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
