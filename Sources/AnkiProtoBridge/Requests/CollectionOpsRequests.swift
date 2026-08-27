import Foundation
public import AnkiBackend
public import AnkiKit
import AnkiProto
import SwiftProtobuf

// MARK: - undo / hasUndoableAction

extension Request where Response == Void {
    /// Undoes the last user-visible operation. No-op if the undo stack
    /// is empty (the backend returns an `undoEmpty` error which the
    /// service-level code is free to swallow).
    public static var undoLastAction: Self {
        .empty(
            serviceId: ServiceID.collectionOps,
            methodId: CollectionOpsMethod.undo,
            decode: { _ in () }
        )
    }

    /// Redoes the last undone operation. Same empty-stack semantics as
    /// undo (engine surfaces `undoEmpty`).
    public static var redoLastAction: Self {
        .empty(
            serviceId: ServiceID.collectionOps,
            methodId: CollectionOpsMethod.redo,
            decode: { _ in () }
        )
    }
}

/// (moved to AnkiKit.BrowseTypes — proto mapping lives here)

extension Request where Response == UndoStatusInfo {
    public static var undoStatus: Self {
        .empty(
            serviceId: ServiceID.collectionOps,
            methodId: CollectionOpsMethod.getUndoStatus,
            decode: { bytes in
                let proto = try Anki_Collection_UndoStatus(serializedBytes: bytes)
                return UndoStatusInfo(
                    canUndo: !proto.undo.isEmpty,
                    undoText: proto.undo,
                    canRedo: !proto.redo.isEmpty,
                    redoText: proto.redo
                )
            }
        )
    }
}

extension Request where Response == Bool {
    /// Returns true when the next call to `.undoLastAction` would have
    /// something to undo. Surfaces `!UndoStatus.undo.isEmpty`.
    public static var hasUndoableAction: Self {
        .empty(
            serviceId: ServiceID.collectionOps,
            methodId: CollectionOpsMethod.getUndoStatus,
            decode: { bytes in
                let proto = try Anki_Collection_UndoStatus(serializedBytes: bytes)
                return !proto.undo.isEmpty
            }
        )
    }
}
