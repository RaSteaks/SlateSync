import Foundation

/// Reads a file picked through fileImporter without blocking the main actor:
/// a whole CSV on the main thread freezes every window while bytes stream in.
/// The security scope is opened on the caller's thread and stays open until
/// the background read finishes — closing it early would invalidate the
/// descriptor mid-read, so the pairing spans the whole awaited read.
@MainActor
enum SecurityScopedFileReader {
    static func read(_ url: URL) async throws -> Data {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        return try await Task.detached(priority: .userInitiated) {
            try Data(contentsOf: url)
        }.value
    }
}
