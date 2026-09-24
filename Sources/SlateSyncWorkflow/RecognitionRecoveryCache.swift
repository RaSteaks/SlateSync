import Foundation
import SlateSyncDomain

/// In-memory results for retrying one task after its backup chain exhausts.
/// The pipeline key includes all inputs that affect a page's interpretation;
/// no partial sheet is committed as a completed task.
public actor RecognitionRecoveryCache {
    private var pages: [String: [Int: RecognitionPagePipeline.PageOutput]] = [:]
    private var order: [String] = []

    public init() {}

    public func result(key: String, pageNumber: Int) -> RecognitionPagePipeline.PageOutput? {
        pages[key]?[pageNumber]
    }

    public func store(_ output: RecognitionPagePipeline.PageOutput, key: String) {
        if pages[key] == nil {
            // Keep only a small number of failed task attempts in memory.
            if order.count >= 8 {
                pages.removeValue(forKey: order.removeFirst())
            }
            order.append(key)
        }
        pages[key, default: [:]][output.pageNumber] = output
    }

    public func clear(key: String) {
        pages.removeValue(forKey: key)
        order.removeAll { $0 == key }
    }

    public func clearAll() {
        pages.removeAll()
        order.removeAll()
    }
}
