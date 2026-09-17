import Foundation
public import AnkiBackend
public import AnkiKit
import AnkiProto
import SwiftProtobuf

// MARK: - getNotetypeNames

extension Request where Response == [NotetypeNameId] {
    /// Lists every notetype as `(id, name)` — the lightweight listing
    /// used by pickers and the templates browser.
    public static var notetypeNames: Self {
        .empty(
            serviceId: ServiceID.notetypes,
            methodId: NotetypesMethod.getNotetypeNames,
            decode: { bytes in
                let resp = try Anki_Notetypes_NotetypeNames(serializedBytes: bytes)
                return resp.entries.map(NotetypeNameId.init)
            }
        )
    }
}

// MARK: - getNotetype

extension Request where Response == Notetype {
    /// Fetches the full notetype (config, fields, templates) by id.
    public static func notetype(for id: NotetypeID) -> Self {
        .decoded(
            serviceId: ServiceID.notetypes,
            methodId: NotetypesMethod.getNotetype,
            encode: {
                var req = Anki_Notetypes_NotetypeId()
                req.ntid = id.rawValue
                return try req.serializedData()
            }
        )
    }
}

// MARK: - change notetype

extension Request where Response == ChangeNotetypeInfo {
    /// Mapping preview for converting notes between notetypes
    /// (desktop Change Notetype dialog source).
    public static func changeNotetypeInfo(oldNotetypeId: NotetypeID, newNotetypeId: NotetypeID) -> Self {
        Self(
            serviceId: ServiceID.notetypes,
            methodId: NotetypesMethod.getChangeNotetypeInfo,
            encode: {
                var proto = Anki_Notetypes_GetChangeNotetypeInfoRequest()
                proto.oldNotetypeID = oldNotetypeId.rawValue
                proto.newNotetypeID = newNotetypeId.rawValue
                return try proto.serializedData()
            },
            decode: { bytes in
                let proto = try Anki_Notetypes_ChangeNotetypeInfo(serializedBytes: bytes)
                return ChangeNotetypeInfo(
                    oldFieldNames: proto.oldFieldNames,
                    oldTemplateNames: proto.oldTemplateNames,
                    newFieldNames: proto.newFieldNames,
                    newTemplateNames: proto.newTemplateNames,
                    oldNotetypeName: proto.oldNotetypeName,
                    currentSchema: proto.input.currentSchema
                )
            }
        )
    }
}

extension Request where Response == Void {
    /// Converts notes between notetypes with explicit field/template maps.
    /// `-1` in either map means null (drop that field/template).
    public static func changeNotetype(
        noteIds: [NoteID],
        oldNotetypeId: NotetypeID,
        newNotetypeId: NotetypeID,
        fieldMap: [Int32],
        templateMap: [Int32],
        currentSchema: Int64,
        oldNotetypeName: String,
        isCloze: Bool
    ) -> Self {
        Self(
            serviceId: ServiceID.notetypes,
            methodId: NotetypesMethod.changeNotetype,
            encode: {
                var proto = Anki_Notetypes_ChangeNotetypeRequest()
                proto.noteIds = noteIds.map(\.rawValue)
                proto.newFields = fieldMap
                proto.newTemplates = templateMap
                proto.oldNotetypeID = oldNotetypeId.rawValue
                proto.newNotetypeID = newNotetypeId.rawValue
                proto.currentSchema = currentSchema
                proto.oldNotetypeName = oldNotetypeName
                proto.isCloze = isCloze
                return try proto.serializedData()
            },
            decode: { _ in () }
        )
    }
}

// MARK: - updateNotetype / removeNotetype

extension Request where Response == Void {
    /// Persists a modified notetype.
    public static func updateNotetype(_ notetype: Notetype) -> Self {
        Self(
            serviceId: ServiceID.notetypes,
            methodId: NotetypesMethod.updateNotetype,
            encode: { try notetype.toProto().serializedData() },
            decode: { _ in () }
        )
    }

    /// Removes a notetype and every card based on it.
    public static func removeNotetype(id: NotetypeID) -> Self {
        Self(
            serviceId: ServiceID.notetypes,
            methodId: NotetypesMethod.removeNotetype,
            encode: {
                var req = Anki_Notetypes_NotetypeId()
                req.ntid = id.rawValue
                return try req.serializedData()
            },
            decode: { _ in () }
        )
    }
}
