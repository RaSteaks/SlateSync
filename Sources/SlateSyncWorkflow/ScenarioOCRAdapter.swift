import SlateSyncDomain

public enum ScenarioOCRAdapter {
    /// Pass raw OCR words and view-local normalized boxes into the unchanged
    /// Scenario v1 fingerprint. _OK/_KP/过/保/ng/x/× mapping belongs to SM-07;
    /// no automatic learning, take-status interpretation or SQLite write occurs.
    public static func observation(filename: String, outcome: OCROutcome) -> ScenarioObservationInput {
        let result = outcome.result
        return .init(filename: filename, ocrEngine: result?.engine.rawValue, ocrUsed: result?.used ?? false, pages: (result?.pages ?? []).map { page in
            .init(pageNumber: page.pageNumber, views: page.views.map { view in
                .init(width: view.width, height: view.height, blocks: view.blocks.map { .init(text: $0.text, confidence: $0.confidence, bboxNormalized: $0.bboxNormalized) })
            })
        })
    }
}
