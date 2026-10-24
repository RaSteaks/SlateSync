import Foundation
import XCTest

/// An icon with no words must say what it does on hover. Every icon-only label
/// style in the UI sources has to carry a `.help(...)` tooltip within the same
/// control expression, so a new glyph button cannot ship unexplained.
final class IconTooltipContractTests: XCTestCase {
    func testEveryIconOnlyControlHasATooltip() throws {
        // Tests run from the package; locate the UI sources relative to this file.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/SlateSyncUI", isDirectory: true)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var missing: [String] = []
        var seen = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where line.contains(".iconOnly") {
                seen += 1
                // The tooltip may be on the same line or in the modifier chain
                // that follows (a handful of lines, until the next blank line).
                var tail = [line]
                for next in lines.dropFirst(index + 1).prefix(8) {
                    if next.trimmingCharacters(in: .whitespaces).isEmpty { break }
                    tail.append(next)
                }
                if !tail.contains(where: { $0.contains(".help(") }) {
                    missing.append("\(url.lastPathComponent):\(index + 1)")
                }
            }
        }
        XCTAssertGreaterThan(seen, 0, "The scan found no icon-only controls; the pattern or path is stale")
        XCTAssertEqual(missing, [], "Icon-only controls without a .help tooltip")
    }
}
