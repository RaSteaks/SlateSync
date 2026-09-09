import Foundation
import SlateSyncDomain

/// Injectable snapshot-file deleter. Production uses `FileManager.default`;
/// tests inject failures exactly where an operator's disk would fail, without
/// staging real filesystem faults.
public protocol FileRemoving: Sendable {
    func removeItem(at url: URL) throws
}

extension FileManager: @unchecked Sendable {}
extension FileManager: FileRemoving {}

/// Recoverable row+snapshot deletion shared by `ProjectTaskStore` and
/// `DiagnosticsStore`. The order is frozen: confirm the SQLite row exists,
/// remove the JSON snapshot, then delete the row. A failed snapshot removal
/// leaves the row untouched; a failed row delete restores the original
/// snapshot bytes — after any failure a restart must still see the record,
/// because SQLite stays authoritative at every step.
public enum SnapshotDeletion {
    public static func deleteRowAndSnapshot(
        database: SQLiteDatabase,
        table: String,
        id: String,
        snapshotURL: URL,
        notFoundMessage: String,
        remover: any FileRemoving,
        writer: any AtomicFileWriting,
        allowMissingRow: Bool = false
    ) async throws {
        // `table` only ever receives compile-time constants from the stores;
        // `id` has already passed PersistenceIdentifiers validation.
        let existing = try await database.rows(
            "SELECT data_json FROM \(table) WHERE id = ?;",
            bindings: [id]
        ).first?["data_json"] ?? nil
        guard existing != nil else {
            if allowMissingRow { return }
            throw SlateSyncError(code: "ENOENT", message: notFoundMessage)
        }
        // Capture the current snapshot bytes so a failed row delete can put
        // the file back exactly as it was.
        let originalSnapshot = try? Data(contentsOf: snapshotURL)
        do {
            try remover.removeItem(at: snapshotURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Already absent is the target snapshot state.
        }
        do {
            guard try await database.execute(
                "DELETE FROM \(table) WHERE id = ?;",
                bindings: [id]
            ) > 0 else {
                throw SlateSyncError(code: "ENOENT", message: notFoundMessage)
            }
        } catch {
            // The row delete failed: restore the snapshot before propagating
            // so a restart cannot observe a record with a missing sibling.
            if let originalSnapshot {
                try? writer.writeAtomically(originalSnapshot, to: snapshotURL, permissions: 0o600)
            }
            throw error
        }
    }
}
