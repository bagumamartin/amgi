import Foundation
public import AnkiBackend
public import AnkiKit
import AnkiProto
import SwiftProtobuf

// MARK: - aux service (anki-bridge-rs, service 200)

/// Amgi-only methods implemented inside our FFI crate and intercepted
/// before engine dispatch. Wire format is JSON on both sides — see
/// `handle_aux_method` in anki-bridge-rs/src/lib.rs. The engine's
/// protobuf error envelope does NOT apply here: failures surface as a
/// UTF-8 message with the same exit-code convention.
extension Request where Response == FindDuplicatesResult {
    /// Exact duplicate finder over one field (desktop `find_dupes`
    /// semantics). Optional `search` restricts the corpus.
    public static func findDuplicatesExact(search: String, fieldName: String) -> Self {
        Self(
            serviceId: ServiceID.aux,
            methodId: AuxMethod.findDupesExact,
            encode: {
                let payload: [String: String] = [
                    "search": search,
                    "field_name": fieldName,
                ]
                return try JSONSerialization.data(withJSONObject: payload)
            },
            decode: { bytes in
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                return try decoder.decode(FindDuplicatesResult.self, from: bytes)
            }
        )
    }
}

extension Request where Response == ImportPackageInspection {
    /// Reads package facts without changing the destination collection.
    public static func inspectAnkiPackage(path: String) -> Self {
        Self(
            serviceId: ServiceID.aux,
            methodId: AuxMethod.inspectAnkiPackage,
            encode: {
                try JSONSerialization.data(withJSONObject: ["path": path])
            },
            decode: { bytes in
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                return try decoder.decode(ImportPackageInspection.self, from: bytes)
            }
        )
    }
}

extension Request where Response == MnemosyneImportInspection {
    /// Reads Mnemosyne database facts without changing the collection.
    public static func inspectMnemosyne(path: String) -> Self {
        Self(
            serviceId: ServiceID.aux,
            methodId: AuxMethod.inspectMnemosyne,
            encode: {
                try JSONSerialization.data(withJSONObject: ["path": path])
            },
            decode: { bytes in
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                return try decoder.decode(MnemosyneImportInspection.self, from: bytes)
            }
        )
    }
}

extension Request where Response == ImportLogSummary {
    /// Converts a Mnemosyne database to Anki's interchange JSON and imports it.
    public static func importMnemosyne(path: String, deckName: String) -> Self {
        Self(
            serviceId: ServiceID.aux,
            methodId: AuxMethod.importMnemosyne,
            encode: {
                try JSONSerialization.data(withJSONObject: [
                    "path": path,
                    "deck_name": deckName,
                ])
            },
            decode: { bytes in
                let response = try Anki_ImportExport_ImportResponse(serializedBytes: bytes)
                let log = response.log
                return ImportLogSummary(
                    foundNotes: Int(log.foundNotes),
                    newCount: log.new.count,
                    updatedCount: log.updated.count,
                    duplicateCount: log.duplicate.count,
                    conflictingCount: log.conflicting.count,
                    firstFieldMatchCount: log.firstFieldMatch.count,
                    missingNotetypeCount: log.missingNotetype.count,
                    missingDeckCount: log.missingDeck.count,
                    emptyFirstFieldCount: log.emptyFirstField.count
                )
            }
        )
    }
}
