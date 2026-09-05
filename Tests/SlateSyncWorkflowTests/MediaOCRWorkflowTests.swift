import Foundation
import SlateSyncDomain
import SlateSyncMedia
@testable import SlateSyncWorkflow
import XCTest

private actor MediaHandoffLog {
    var entries:[String] = []
    func append(_ entry:String) { entries.append(entry) }
    func reset() { entries = [] }
}
private actor HandoffPreparation: MediaPreparing {
    let log:MediaHandoffLog
    init(_ log:MediaHandoffLog) { self.log = log }
    func prepare(_ input:MediaInput,options:MediaPreparationOptions,operation:MediaOperation,progress:MediaProgressSink?) async throws -> PreparedDocument {
        await log.append("prepare")
        return try await MediaPreparationService().prepare(input,options:options,operation:operation,progress:progress)
    }
}
private actor HandoffEngine: LocalOCREngine {
    let log:MediaHandoffLog
    var mode = "success"
    var calls = 0
    init(_ log:MediaHandoffLog) { self.log = log }
    func setMode(_ value:String) { mode = value }
    func recognize(_ document:PreparedDocument,operation:MediaOperation,progress:MediaProgressSink?) async throws -> OCREngineResult {
        calls += 1;await log.append("ocr")
        if mode == "failure" { throw MediaFailure.protocolError }
        if mode == "cancel" { operation.cancel();throw MediaFailure.canceled }
        if mode == "wait" { while !operation.isCanceled { try await Task.sleep(for:.milliseconds(5)) };throw MediaFailure.canceled }
        return .init(engine:.vision,modelVersion:"fixture",pages:document.pages.map { page in
            .init(pageNumber:page.pageNumber,views:page.views.map { view in
                .init(viewIndex:view.viewIndex,viewType:view.viewType,width:view.image.width,height:view.image.height,blocks:[.init(order:0,text:"\(mode) _OK 保 ng ×",confidence:0.9,bbox:[0,0,1,1],bboxNormalized:[0,0,1,1])])
            })
        })
    }
    func close() {}
    func waitStarted() async { while calls == 0 { try? await Task.sleep(for:.milliseconds(5)) } }
}

@MainActor final class MediaOCRWorkflowTests: XCTestCase {
    private func input() throws -> MediaInput {
        let url = try XCTUnwrap(Bundle.module.url(forResource:"sm06-integration",withExtension:"pdf"))
        return .bytes(try Data(contentsOf:url),filename:"slate.pdf")
    }
    func testOCRFirstHandoffOptionalDegradationAndDirectPDFRejection() async throws {
        let log = MediaHandoffLog()
        let engine = HandoffEngine(log)
        let policy = LocalOCRService(vision:engine,paddle:nil,settings:.init(),visionAvailable:true,paddleAvailable:false)
        let workflow = MediaOCRWorkflow(preparation:HandoffPreparation(log),ocr:policy)
        let result = try await workflow.run(input:input(),session:"A",consume:{ artifact,operation in
            try operation.check();await log.append("downstream")
            XCTAssertTrue(artifact.document.pages.flatMap(\.views).allSatisfy { $0.image.jpeg.starts(with:[255,216,255]) })
            XCTAssertTrue(artifact.summary.used)
        })
        XCTAssertEqual(result.document.viewCount,3);XCTAssertEqual(result.summary.blockCount,3)
        XCTAssertTrue(result.observation.pages[0].views[0].blocks[0].text.contains("_OK 保 ng ×"))
        let sequence = await log.entries;XCTAssertEqual(sequence,["prepare","ocr","downstream"])
        await log.reset()
        do { _ = try await workflow.run(input:input(),session:"A",legacyRequest:Data(#"{"pdfDataUrl":"data:application/pdf;base64,AAAA"}"#.utf8),consume:{ _,_ in await log.append("forbidden") });XCTFail() }
        catch { XCTAssertEqual((error as? SlateSyncError)?.code,"DIRECT_PDF_UNSUPPORTED") }
        let afterPDF = await log.entries;XCTAssertEqual(afterPDF,[])
        await engine.setMode("failure")
        let degraded = try await workflow.run(input:input(),session:"B",consume:{ artifact,operation in
            try operation.check();await log.append("degraded-downstream")
            XCTAssertEqual(artifact.document.viewCount,3);XCTAssertNotNil(artifact.summary.warning);XCTAssertTrue(artifact.evidence.isEmpty)
        })
        if case .degraded = degraded.outcome {} else { XCTFail() }
        await workflow.close()
    }
    func testRequiredAndCancellationHaveZeroDownstreamThenRetry() async throws {
        let log = MediaHandoffLog(), engine = HandoffEngine(MediaHandoffLog())
        await engine.setMode("failure")
        let required = MediaOCRWorkflow(ocr:LocalOCRService(vision:engine,paddle:nil,settings:.init([.visionOCRRequired:"true"]),visionAvailable:true,paddleAvailable:false))
        do { _ = try await required.run(input:input(),session:"A",consume:{ _,_ in await log.append("forbidden") });XCTFail() }
        catch { XCTAssertEqual((error as? SlateSyncError)?.code,"OCR_REQUIRED") }
        let workflow = MediaOCRWorkflow(ocr:LocalOCRService(vision:engine,paddle:nil,settings:.init(),visionAvailable:true,paddleAvailable:false))
        await engine.setMode("cancel")
        do { _ = try await workflow.run(input:input(),session:"A",consume:{ _,_ in await log.append("forbidden") });XCTFail() }
        catch { XCTAssertEqual((error as? SlateSyncError)?.code,"RECOGNITION_CANCELED") }
        let calls = await log.entries;XCTAssertEqual(calls,[])
        await engine.setMode("success")
        _ = try await workflow.run(input:input(),session:"A",consume:{ _,op in try op.check();await log.append("retry") })
        let retried = await log.entries;XCTAssertEqual(retried,["retry"])
        await workflow.close();await required.close()
    }
    func testProjectSwitchCacheIsolationAndCloseDrain() async throws {
        let log = MediaHandoffLog(), engine = HandoffEngine(MediaHandoffLog())
        let workflow = MediaOCRWorkflow(ocr:LocalOCRService(vision:engine,paddle:nil,settings:.init(),visionAvailable:true,paddleAvailable:false))
        await engine.setMode("project-A")
        _ = try await workflow.run(input:input(),session:"A")
        let cached = try await workflow.run(input:input(),session:"A")
        XCTAssertTrue(cached.summary.cacheHit)
        await engine.setMode("project-B")
        let next = try await workflow.run(input:input(),session:"B")
        XCTAssertFalse(next.summary.cacheHit);XCTAssertTrue(next.evidence[0].contains("project-B"));XCTAssertFalse(next.evidence[0].contains("project-A"))
        await workflow.close()
        let delayed = HandoffEngine(MediaHandoffLog());await delayed.setMode("wait")
        let closing = MediaOCRWorkflow(ocr:LocalOCRService(vision:delayed,paddle:nil,settings:.init(),visionAvailable:true,paddleAvailable:false))
        let source = try input()
        let task = Task { try await closing.run(input:source,session:"A",consume:{ _,_ in await log.append("forbidden") }) }
        await delayed.waitStarted();await closing.close()
        do { _ = try await task.value;XCTFail() } catch { XCTAssertEqual((error as? SlateSyncError)?.code,"RECOGNITION_CANCELED") }
        let calls = await log.entries;XCTAssertTrue(calls.isEmpty)
    }
    func testScenarioEvidenceAdapterPreservesV1Fingerprint() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource:"observation",withExtension:"json"))
        let source = try JSONDecoder().decode(ScenarioObservationInput.self,from:Data(contentsOf:url))
        let evidence = OCREngineResult(engine:.paddle,modelVersion:"fixture",pages:source.pages.map { page in
            .init(pageNumber:page.pageNumber,views:page.views.enumerated().map { index,view in
                .init(viewIndex:index,viewType:index==0 ? .full : .coreDetail,width:view.width,height:view.height,blocks:view.blocks.enumerated().map { index,block in
                    .init(order:index,text:block.text,confidence:block.confidence,bbox:[0,0,1,1],bboxNormalized:block.bboxNormalized)
                })
            })
        })
        let adapted = ScenarioOCRAdapter.observation(filename:source.filename,outcome:.used(evidence,cacheHit:false))
        XCTAssertEqual(adapted,source)
        let profile = try await ScenarioProfileEngine().profile(from:adapted,resolve:.init())
        XCTAssertEqual(profile.fingerprint,"e6ac0b81193ca50f1612d66ce5f1d586")
    }
}
