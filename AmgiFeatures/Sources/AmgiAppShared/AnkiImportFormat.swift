package import Foundation
package import UniformTypeIdentifiers

/// Built-in desktop Anki import families supported by Amgi. Raw `.anki2` and
/// `.anki21` collection databases are intentionally absent: desktop Anki
/// explicitly rejects them as direct import files.
package enum AnkiImportFormat: Sendable, Equatable, CaseIterable {
    case deckPackage
    case collectionPackage
    case zippedPackage
    case text
    case ankiJSON
    case mnemosyne

    package static let supportedExtensions = [
        "apkg", "colpkg", "zip", "csv", "tsv", "txt", "anki-json", "db",
    ]

    package static var supportedContentTypes: [UTType] {
        var seen: Set<String> = []
        return supportedExtensions.compactMap { extensionName in
            let type = UTType(filenameExtension: extensionName) ?? fallbackType(for: extensionName)
            guard let type, seen.insert(type.identifier).inserted else { return nil }
            return type
        }
    }

    private static func fallbackType(for extensionName: String) -> UTType? {
        switch extensionName {
        case "apkg":
            UTType(exportedAs: "com.bagumamartin.ijuka.anki-package", conformingTo: .zip)
        case "colpkg":
            UTType(exportedAs: "com.bagumamartin.ijuka.anki-collection-package", conformingTo: .zip)
        case "anki-json":
            UTType(exportedAs: "com.bagumamartin.ijuka.anki-json", conformingTo: .json)
        default:
            nil
        }
    }

    package init?(url: URL) {
        let name = url.lastPathComponent.lowercased()
        switch url.pathExtension.lowercased() {
        case "apkg":
            if name == "collection.apkg" || name.hasPrefix("backup-") {
                self = .collectionPackage
            } else {
                self = .deckPackage
            }
        case "colpkg":
            self = .collectionPackage
        case "zip":
            self = .zippedPackage
        case "csv", "tsv", "txt":
            self = .text
        case "anki-json":
            self = .ankiJSON
        case "db":
            self = .mnemosyne
        default:
            return nil
        }
    }

    package var title: String {
        switch self {
        case .deckPackage: "Anki Deck Package"
        case .collectionPackage: "Anki Collection Backup"
        case .zippedPackage: "Anki ZIP Package"
        case .text: "Delimited Text"
        case .ankiJSON: "Anki JSON"
        case .mnemosyne: "Mnemosyne Database"
        }
    }

    package var systemImage: String {
        switch self {
        case .deckPackage, .zippedPackage: "rectangle.stack.fill"
        case .collectionPackage: "externaldrive.fill.badge.timemachine"
        case .text: "tablecells.fill"
        case .ankiJSON: "curlybraces.square.fill"
        case .mnemosyne: "cylinder.split.1x2.fill"
        }
    }

    package var replacesCollection: Bool {
        self == .collectionPackage
    }
}
