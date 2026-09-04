public import Foundation
public import AnkiBackend
public import AnkiKit
import AnkiProto
import SwiftProtobuf

// MARK: - collection config (raw JSON)

extension Request where Response == Data {
    /// Reads a raw config value as JSON bytes. A missing key surfaces
    /// as `BackendError.notFoundError` — callers map that to nil.
    public static func configGetRaw(key: String) -> Self {
        Self(
            serviceId: ServiceID.config,
            methodId: ConfigMethod.getConfigJson,
            encode: {
                var proto = Anki_Generic_String()
                proto.val = key
                return try proto.serializedData()
            },
            decode: { bytes in
                try Anki_Generic_Json(serializedBytes: bytes).json
            }
        )
    }
}

extension Request where Response == Void {
    /// Writes a raw config value without touching the undo stack —
    /// same semantics as `AnkiBackend.setConfigJSONValue`.
    public static func configSetRawNoUndo(key: String, json: Data) -> Self {
        Self(
            serviceId: ServiceID.config,
            methodId: ConfigMethod.setConfigJsonNoUndo,
            encode: {
                var proto = Anki_Config_SetConfigJsonRequest()
                proto.key = key
                proto.valueJson = json
                proto.undoable = false
                return try proto.serializedData()
            },
            decode: { _ in () }
        )
    }
}

// MARK: - addMediaFile

extension Request where Response == String {
    /// Stores media bytes under `desiredName` and returns the canonical
    /// filename chosen by the backend (extension/dedup rules may rename
    /// it). Note fields reference the returned name.
    public static func addMediaFile(desiredName: String, data: Data) -> Self {
        Self(
            serviceId: ServiceID.media,
            methodId: MediaMethod.addMediaFile,
            encode: {
                var proto = Anki_Media_AddMediaFileRequest()
                proto.desiredName = desiredName
                proto.data = data
                return try proto.serializedData()
            },
            decode: { bytes in
                try Anki_Generic_String(serializedBytes: bytes).val
            }
        )
    }
}

// MARK: - checkMedia

extension Request where Response == MediaCheckResult {
    /// Runs the backend's media-check pass and returns the orphan/missing
    /// snapshot. No request body — the backend infers context from the
    /// open collection.
    public static var checkMedia: Self {
        .empty(
            serviceId: ServiceID.media,
            methodId: MediaMethod.checkMedia,
            decode: { bytes in
                let proto = try Anki_Media_CheckMediaResponse(serializedBytes: bytes)
                return MediaCheckResult(
                    missing: proto.missing,
                    unused: proto.unused,
                    missingNoteIDs: proto.missingMediaNotes.map { NoteID($0) },
                    report: proto.report,
                    haveTrash: proto.haveTrash
                )
            }
        )
    }
}

// MARK: - trash + restore (Void)

extension Request where Response == Void {
    /// Moves the named media files into the trash directory (recoverable
    /// until `emptyTrash` runs).
    public static func trashMediaFiles(filenames: [String]) -> Self {
        Self(
            serviceId: ServiceID.media,
            methodId: MediaMethod.trashMediaFiles,
            encode: {
                var proto = Anki_Media_TrashMediaFilesRequest()
                proto.fnames = filenames
                return try proto.serializedData()
            },
            decode: { _ in () }
        )
    }

    /// Permanently deletes everything currently in the media trash.
    public static var emptyMediaTrash: Self {
        .empty(
            serviceId: ServiceID.media,
            methodId: MediaMethod.emptyTrash,
            decode: { _ in () }
        )
    }

    /// Restores files in the media trash back into the active media folder.
    public static var restoreMediaTrash: Self {
        .empty(
            serviceId: ServiceID.media,
            methodId: MediaMethod.restoreTrash,
            decode: { _ in () }
        )
    }
}
