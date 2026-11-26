import CryptoKit
import Darwin
import Foundation
import SQLite3

/// Local v2 backing for large project databases. The encrypted manifest is the
/// commit point. Each immutable block has an opaque name and its authenticated
/// digest and position live in the manifest. Portable backups still use SQLite.
enum EncryptedSQLiteBlocks {
    static let directoryName = ".project.sqlite.chunks"
    static let blockSize = 256 * 1024
    static let threshold = 1024 * 1024
    static let magic = Data("SlateSync local SQLite blocks v2\n".utf8)

    struct Block: Codable, Sendable {
        let id: UUID
        let digest: Data
        let length: Int
        var filename: String { id.uuidString + ".chunk" }
    }
    struct Manifest: Codable {
        let bytes: Int
        let blocks: [Block]
    }
    struct FileStamp: Equatable, Sendable {
        let inode: ino_t
        let size: off_t
        let changed: Int
        let nanoseconds: Int
        init(url: URL) throws {
            var s = stat()
            guard lstat(url.path, &s) == 0, (s.st_mode & S_IFMT) == S_IFREG else { throw damaged() }
            inode = s.st_ino; size = s.st_size
            changed = s.st_ctimespec.tv_sec; nanoseconds = s.st_ctimespec.tv_nsec
        }
    }
    struct Cached: Sendable {
        let block: Block
        let plaintext: Data
        let stamp: FileStamp
    }

    static func directory(for url: URL, create: Bool = false) throws -> URL {
        let directory = url.deletingLastPathComponent().appending(path: directoryName, directoryHint: .isDirectory)
        var s = stat()
        if lstat(directory.path, &s) != 0 {
            guard create, errno == ENOENT else { throw damaged() }
            try SecureFilePermissions.prepareDirectory(at: directory)
        } else if (s.st_mode & S_IFMT) != S_IFDIR { throw damaged() }
        return directory
    }

    /// Reads into SQLite-owned memory a block at a time. Authentication and all
    /// bounds checks finish before SQLite can see a partially restored database.
    static func restore(_ payload: Data, from url: URL, into handle: OpaquePointer) throws -> [Cached] {
        let manifest = try JSONDecoder().decode(Manifest.self, from: payload.dropFirst(magic.count))
        guard manifest.bytes > 0, !manifest.blocks.isEmpty,
              (manifest.bytes - 1) / blockSize + 1 == manifest.blocks.count else { throw damaged() }
        let directory = try directory(for: url)
        var blocks: [Cached] = []
        var remaining = manifest.bytes
        for block in manifest.blocks {
            guard block.length == min(blockSize, remaining), block.digest.count == 32 else { throw damaged() }
            blocks.append(try read(block, in: directory))
            remaining -= block.length
        }
        guard remaining == 0, let buffer = sqlite3_malloc64(UInt64(manifest.bytes)) else { throw damaged() }
        var offset = 0
        for entry in blocks {
            entry.plaintext.copyBytes(to: buffer.advanced(by: offset).assumingMemoryBound(to: UInt8.self), count: entry.block.length)
            offset += entry.block.length
        }
        // FREEONCLOSE transfers ownership even when deserialize fails.
        guard sqlite3_deserialize(handle, "main", buffer.assumingMemoryBound(to: UInt8.self),
                                  Int64(offset), Int64(offset), UInt32(SQLITE_DESERIALIZE_FREEONCLOSE | SQLITE_DESERIALIZE_RESIZEABLE)) == SQLITE_OK else { throw damaged() }
        return blocks
    }

    static func save(_ bytes: UnsafePointer<UInt8>, count: Int, at url: URL, keyID: String,
                     previous: [Cached]) throws -> EncryptedSQLiteSnapshot.State {
        let directory = try directory(for: url, create: true)
        let writer = FileManagerAtomicFileWriter()
        var current: [Cached] = []
        current.reserveCapacity((count - 1) / blockSize + 1)
        for offset in stride(from: 0, to: count, by: blockSize) {
            let length = min(blockSize, count - offset)
            // The borrowed serialization remains valid until the next SQLite
            // operation. Only changed blocks will be copied, hashed and sealed.
            let view = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: bytes + offset), count: length, deallocator: .none)
            var normalized = view
            if offset == 0 && length >= 20 && (view[18] != 1 || view[19] != 1) {
                normalized = Data(bytes: bytes, count: length)
                normalized[18] = 1; normalized[19] = 1
            }
            if current.count < previous.count {
                let cached = previous[current.count]
                if cached.plaintext == normalized {
                    let stamp = try FileStamp(url: directory.appending(path: cached.block.filename))
                    current.append(stamp == cached.stamp ? cached : try read(cached.block, in: directory))
                    continue
                }
            }
            // Never retain a Data view into SQLite beyond this save.
            let owned = normalized.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: $0.count) }
            let block = Block(id: UUID(), digest: Data(SHA256.hash(data: owned)), length: length)
            let path = directory.appending(path: block.filename)
            try writer.writeRaw(LocalProjectEncryption.seal(owned, id: keyID), to: path, permissions: 0o600)
            let verified = try read(block, in: directory)
            try synchronize(path)
            current.append(verified)
        }
        try synchronize(directory)
        let manifest = Manifest(bytes: count, blocks: current.map(\.block))
        let payload = try magic + JSONEncoder().encode(manifest)
        let envelope = try LocalProjectEncryption.seal(payload, id: keyID)
        guard try LocalProjectEncryption.open(envelope) == payload else { throw damaged() }
        try writer.writeRaw(envelope, to: url, permissions: 0o600)
        try synchronize(url)
        try synchronize(url.deletingLastPathComponent())
        // The new manifest is durable. Reclaim interrupted staging and superseded
        // blocks only now, under the database owner's cross-process lock.
        reclaimOrphans(in: directory, keeping: Set(current.map { $0.block.filename }))
        return .init(envelope: envelope, blocks: current)
    }

    private static func read(_ block: Block, in directory: URL) throws -> Cached {
        let url = directory.appending(path: block.filename)
        let stamp = try FileStamp(url: url)
        guard stamp.size > 0, stamp.size <= blockSize + 256 else { throw damaged() }
        let envelope = try Data(contentsOf: url)
        guard LocalProjectEncryption.isEncrypted(envelope) else { throw damaged() }
        let plaintext = try LocalProjectEncryption.open(envelope)
        guard plaintext.count == block.length, Data(SHA256.hash(data: plaintext)) == block.digest else { throw damaged() }
        return .init(block: block, plaintext: plaintext, stamp: stamp)
    }

    private static func synchronize(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw damaged() }
        defer { Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw LocalProjectEncryption.error("无法同步项目分块，请检查存储设备") }
    }

    static func reclaimOrphans(in directory: URL, keeping: Set<String>) {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in entries where name.hasSuffix(".chunk") && !keeping.contains(name) {
            guard UUID(uuidString: String(name.dropLast(6))) != nil else { continue }
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }

    private static func damaged() -> Error { LocalProjectEncryption.error("项目分块缺失或验证失败，请恢复完整项目库或导入 v1 备份。") }
}
