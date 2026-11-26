import Foundation
import SQLite3
import SlateSyncDomain

/// SQLite plaintext exists only in memory. The database owner checks snapshot
/// bytes under the cross-process lock and reloads when another writer has
/// committed, so repeated reads can reuse memory without losing updates.
enum EncryptedSQLiteSnapshot {
    struct State: Sendable {
        let envelope: Data
        let blocks: [EncryptedSQLiteBlocks.Cached]
    }
    /// Return only the envelope actually authenticated by this load. Legacy WAL
    /// databases cannot be cached by their main-file bytes alone.
    static func load(url: URL, into handle: OpaquePointer, bytes suppliedBytes: Data? = nil) throws -> State? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let bytes = try suppliedBytes ?? Data(contentsOf: url)
        var blocks: [EncryptedSQLiteBlocks.Cached] = []
        if LocalProjectEncryption.isEncrypted(bytes) {
            let plain = try LocalProjectEncryption.open(bytes)
            if plain.starts(with: EncryptedSQLiteBlocks.magic) {
                guard url.lastPathComponent == SQLiteV1.projectDatabaseFilename else { throw LocalProjectEncryption.error("项目分块入口无效") }
                blocks = try EncryptedSQLiteBlocks.restore(plain, from: url, into: handle)
            } else {
                guard let buffer = sqlite3_malloc64(UInt64(plain.count)) else { throw LocalProjectEncryption.error("项目数据库内存不足") }
                plain.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: plain.count)
                let status = sqlite3_deserialize(handle, "main", buffer.assumingMemoryBound(to: UInt8.self), Int64(plain.count), Int64(plain.count), UInt32(SQLITE_DESERIALIZE_FREEONCLOSE | SQLITE_DESERIALIZE_RESIZEABLE))
                // FREEONCLOSE transfers ownership even if deserialization fails.
                guard status == SQLITE_OK else { throw LocalProjectEncryption.error("无法打开加密项目数据库") }
            }
            // An encrypted database never uses SQLite sidecars. Clean any
            // plaintext artifacts left by an interrupted snapshot replacement.
            try LocalProjectEncryption.removeSQLiteSidecars(for: url)
        } else {
            // Online backup includes committed WAL pages from the old format;
            // no intermediate plaintext copy is created during migration.
            var source: OpaquePointer?
            guard sqlite3_open_v2(url.path, &source, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
                if let source { sqlite3_close(source) }
                throw LocalProjectEncryption.error("无法读取旧项目数据库")
            }
            defer { sqlite3_close(source) }
            guard let backup = sqlite3_backup_init(handle, "main", source, "main") else { throw LocalProjectEncryption.error("无法迁移项目数据库") }
            let step = sqlite3_backup_step(backup, -1)
            let finish = sqlite3_backup_finish(backup)
            guard step == SQLITE_DONE, finish == SQLITE_OK else { throw LocalProjectEncryption.error("项目数据库正在使用或损坏，请关闭其他 SlateSync 后重试") }
        }
        // In-memory databases must not retain the legacy WAL header flags.
        guard sqlite3_exec(handle, "PRAGMA journal_mode=MEMORY; PRAGMA temp_store=MEMORY;", nil, nil, nil) == SQLITE_OK else {
            throw LocalProjectEncryption.error("无法初始化加密数据库")
        }
        return LocalProjectEncryption.isEncrypted(bytes) ? .init(envelope: bytes, blocks: blocks) : nil
    }

    @discardableResult
    static func save(handle: OpaquePointer, to url: URL, id: String, previous: State? = nil) throws -> State {
        var count: Int64 = 0
        let borrowed = sqlite3_serialize(handle, "main", &count, UInt32(SQLITE_SERIALIZE_NOCOPY))
        guard let bytes = borrowed ?? sqlite3_serialize(handle, "main", &count, 0) else {
            throw LocalProjectEncryption.error("无法序列化项目数据库")
        }
        defer { if borrowed == nil { sqlite3_free(bytes) } }
        if url.lastPathComponent == SQLiteV1.projectDatabaseFilename && (count >= EncryptedSQLiteBlocks.threshold || previous?.blocks.isEmpty == false) {
            let state = try EncryptedSQLiteBlocks.save(bytes, count: Int(count), at: url, keyID: id, previous: previous?.blocks ?? [])
            try LocalProjectEncryption.removeSQLiteSidecars(for: url)
            return state
        }
        var data = Data(bytes: bytes, count: Int(count))
        if data.count >= 20 { data[18] = 1; data[19] = 1 }
        let encrypted = try LocalProjectEncryption.seal(data, id: id)
        guard try LocalProjectEncryption.open(encrypted) == data else { throw LocalProjectEncryption.error("项目数据库加密校验失败") }
        try FileManagerAtomicFileWriter().writeRaw(encrypted, to: url, permissions: 0o600)
        try LocalProjectEncryption.removeSQLiteSidecars(for: url)
        return State(envelope: encrypted, blocks: [])
    }
}
