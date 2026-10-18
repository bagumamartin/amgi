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

extension Request where Response == ReaderNotesResult {
    /// Notes matching `search`, read in one pass. `fields` limits which
    /// fields come back (nil = all); notes with any `requireNonempty` field
    /// missing or empty are skipped without that field crossing the bridge.
    public static func readerNotes(
        search: String,
        fields: [String]?,
        requireNonempty: [String]
    ) -> Self {
        Self(
            serviceId: ServiceID.aux,
            methodId: AuxMethod.readerNotes,
            encode: {
                var payload: [String: Any] = [
                    "search": search,
                    "require_nonempty": requireNonempty,
                ]
                if let fields { payload["fields"] = fields }
                return try JSONSerialization.data(withJSONObject: payload)
            },
            decode: { bytes in
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                return try decoder.decode(ReaderNotesResult.self, from: bytes)
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

private struct ReviewTimesPayload: Decodable {
    let answeredAtMs: [Int64]
}

extension Request where Response == [Int64] {
    /// When each answer in `[startMs, endMs)` was given, as UTC millis
    /// (`revlog.id`), ascending. Manual and rescheduled entries are left
    /// out, matching the engine's review-count graph. `scope` is a backend
    /// search expression (`""` = whole collection).
    public static func reviewTimes(scope: String, startMs: Int64, endMs: Int64) -> Self {
        Self(
            serviceId: ServiceID.aux,
            methodId: AuxMethod.reviewTimes,
            encode: {
                try JSONSerialization.data(withJSONObject: [
                    "scope_search": scope,
                    "start_ms": startMs,
                    "end_ms": endMs,
                ])
            },
            decode: { bytes in
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                return try decoder.decode(ReviewTimesPayload.self, from: bytes).answeredAtMs
            }
        )
    }
}

extension Request where Response == StudyLedger {
    /// Rebuilds each window's due / studied / left counts. `deckId` 0 is the
    /// whole collection; otherwise that deck and its subdecks. The day at
    /// `detailOffset` also carries card IDs and per-deck rows.
    public static func studyLedger(
        deckId: Int64,
        rolloverHour: Int,
        days: [StudyLedger.Window],
        detailOffset: Int?
    ) -> Self {
        Self(
            serviceId: ServiceID.aux,
            methodId: AuxMethod.studyLedger,
            encode: {
                var payload: [String: Any] = [
                    "deck_id": deckId,
                    "rollover_hour": rolloverHour,
                    "days": days.map { ["offset": $0.offset, "start_ms": $0.startMs, "end_ms": $0.endMs] },
                ]
                if let detailOffset { payload["detail_offset"] = detailOffset }
                return try JSONSerialization.data(withJSONObject: payload)
            },
            decode: { bytes in
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                return try decoder.decode(StudyLedger.self, from: bytes)
            }
        )
    }
}
