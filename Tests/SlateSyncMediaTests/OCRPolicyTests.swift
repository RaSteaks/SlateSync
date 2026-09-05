import Foundation
import SlateSyncDomain
@testable import SlateSyncMedia
import XCTest

actor PolicyEngine: LocalOCREngine {
    enum Behavior: Sendable { case success, empty, unused, failure, cancellation, delayed }
    var behavior: Behavior
    private(set) var calls = 0
    var released = false
    init(_ behavior: Behavior = .success) { self.behavior = behavior }
    func recognize(_ document: PreparedDocument, operation: MediaOperation, progress: MediaProgressSink?) async throws -> OCREngineResult {
        calls += 1
        if behavior == .delayed { while !released { try await Task.sleep(for:.milliseconds(5)) } }
        if behavior == .failure { throw MediaFailure.protocolError }
        if behavior == .cancellation { operation.cancel();throw MediaFailure.canceled }
        progress?(.init(stage:"late-fake",completed:1,total:1))
        return .init(engine:.vision,modelVersion:"fake",used:behavior != .unused,pages:document.pages.map { page in
            .init(pageNumber:page.pageNumber,views:page.views.map { view in .init(viewIndex:view.viewIndex,viewType:view.viewType,width:view.image.width,height:view.image.height,blocks:behavior == .empty ? [] : [.init(order:0,text:"C001",confidence:0.9,bbox:[0,0,1,1],bboxNormalized:[0,0,1,1])]) })
        })
    }
    func close() {}
    func release() { released = true }
    func waitStarted() async { while calls == 0 { try? await Task.sleep(for:.milliseconds(5)) } }
}

@MainActor final class OCRPolicyTests: XCTestCase {
    private func document() async throws -> PreparedDocument { try await MediaPreparationService().prepare(.bytes(mediaFixture("tiny.png"),filename:"tiny.png")) }
    func testRequiredOptionalDisabledAndCancellationPolicies() async throws {
        let document = try await document()
        for required in [false,true] {
            for behavior in [PolicyEngine.Behavior.failure,.empty,.unused,.cancellation] {
                let engine = PolicyEngine(behavior)
                let service = LocalOCRService(vision:engine,paddle:nil,settings:.init([.visionOCREnabled:"true",.visionOCRRequired:String(required)]),visionAvailable:true,paddleAvailable:false)
                do {
                    let outcome = try await service.recognize(document,session:"project",operation:.init())
                    if required || behavior == .cancellation { XCTFail("Expected terminal OCR failure") }
                    if case .degraded(let id,let warning) = outcome { XCTAssertEqual(id,.vision);XCTAssertFalse(warning.isEmpty) } else { XCTFail() }
                    XCTAssertNil(outcome.result)
                } catch { XCTAssertEqual((error as? SlateSyncError)?.code,behavior == .cancellation ? "RECOGNITION_CANCELED" : "OCR_REQUIRED") }
                await service.close()
            }
        }
        let engine = PolicyEngine()
        let disabled = LocalOCRService(vision:engine,paddle:engine,settings:.init([.visionOCREnabled:"false",.paddleOCREnabled:"false"]),visionAvailable:true,paddleAvailable:true)
        let result = try await disabled.recognize(document,session:"project",operation:.init())
        XCTAssertEqual(result,.disabled); let calls = await engine.calls;XCTAssertEqual(calls,0)
        let absent = LocalOCRService(vision:nil,paddle:nil,settings:.init([.visionOCRRequired:"true"]),visionAvailable:false,paddleAvailable:false)
        do { _ = try await absent.recognize(document,session:"project",operation:.init());XCTFail() } catch { XCTAssertEqual((error as? SlateSyncError)?.code,"OCR_REQUIRED") }
        await disabled.close();await absent.close()
    }
    func testStructuredKeysLRUEvictionAndClearGeneration() async throws {
        let document = try await document(), settings = GlobalSettingValues()
        let key = try OCRResultCache.key(document:document,engine:.vision,settings:settings,session:"A")
        let regrouped = PreparedDocument(filename:document.filename,pages:document.pages[0].views.enumerated().map { index,view in .init(pageNumber:index+1,views:[view]) })
        XCTAssertNotEqual(key,try OCRResultCache.key(document:regrouped,engine:.vision,settings:settings,session:"A"))
        let reversed = PreparedDocument(filename:document.filename,pages:[.init(pageNumber:1,views:document.pages[0].views.reversed())])
        XCTAssertNotEqual(key,try OCRResultCache.key(document:reversed,engine:.vision,settings:settings,session:"A"))
        XCTAssertNotEqual(key,try OCRResultCache.key(document:document,engine:.vision,settings:settings,session:"B"))
        for (setting,value) in [(GlobalSettingKey.visionOCRLanguage,"en-US"),(.visionOCRRecognitionLevel,"fast"),(.visionOCRUseLanguageCorrection,"false"),(.visionOCRMinConfidence,"0.8"),(.visionOCRMaxBlocksPerView,"2")] {
            XCTAssertNotEqual(key,try OCRResultCache.key(document:document,engine:.vision,settings:.init([setting:value]),session:"A"))
        }
        let paddleKey = try OCRResultCache.key(document:document,engine:.paddle,settings:settings,session:"A")
        // v6/custom/accurate already resolves batch=4; an equivalent explicit
        // setting must hit, while batch=8 changes the effective configuration.
        XCTAssertEqual(paddleKey,try OCRResultCache.key(document:document,engine:.paddle,settings:.init([.paddleOCRRecognitionBatchSize:"4"]),session:"A"))
        for (setting,value) in [(GlobalSettingKey.paddleOCRPreset,"fast"),(.paddleOCRModelVersion,"PP-OCRv5"),(.paddleOCRDetectionModel,"custom-det"),(.paddleOCRRecognitionModel,"custom-rec"),(.paddleOCRRecognitionBatchSize,"8"),(.paddleOCRTextDetLimitSideLen,"736"),(.paddleOCRLanguage,"en"),(.paddleOCRDevice,"gpu"),(.paddleOCRMinConfidence,"0.9"),(.paddleOCRMaxBlocksPerView,"5")] {
            XCTAssertNotEqual(paddleKey,try OCRResultCache.key(document:document,engine:.paddle,settings:.init([setting:value]),session:"A"))
        }
        let cache = OCRResultCache(), engine = PolicyEngine()
        let result = try await engine.recognize(document,operation:.init(),progress:nil)
        let generation = await cache.currentGeneration()
        for index in 0..<8 { await cache.insert(result,key:String(index),generation:generation,operation:.init()) }
        _ = await cache.lookup("0",engine:.vision)
        await cache.insert(result,key:"8",generation:generation,operation:.init())
        let evicted = await cache.lookup("1",engine:.vision), promoted = await cache.lookup("0",engine:.vision)
        XCTAssertNil(evicted);XCTAssertNotNil(promoted)
        await cache.clear();await cache.insert(result,key:"stale",generation:generation,operation:.init())
        let stale = await cache.lookup("stale",engine:.vision);XCTAssertNil(stale)
        let canceled = MediaOperation();canceled.cancel()
        await cache.insert(result,key:"cancel",generation:await cache.currentGeneration(),operation:canceled)
        let absent = await cache.lookup("cancel",engine:.vision);XCTAssertNil(absent)
    }
    func testCacheDisabledSessionIsolationAndClearDuringCompletion() async throws {
        let document = try await document(), engine = PolicyEngine()
        let service = LocalOCRService(vision:engine,paddle:nil,settings:.init(),visionAvailable:true,paddleAvailable:false)
        _ = try await service.recognize(document,session:"A",cacheEnabled:false,operation:.init())
        _ = try await service.recognize(document,session:"A",operation:.init())
        let hit = try await service.recognize(document,session:"A",operation:.init())
        if case .used(_,let cacheHit) = hit { XCTAssertTrue(cacheHit) } else { XCTFail() }
        // Disable must bypass an existing cache entry as well as avoid writes.
        let bypass = try await service.recognize(document,session:"A",cacheEnabled:false,operation:.init())
        if case .used(_,let cacheHit) = bypass { XCTAssertFalse(cacheHit) } else { XCTFail() }
        _ = try await service.recognize(document,session:"B",operation:.init())
        let calls = await engine.calls;XCTAssertEqual(calls,4)
        await service.clearSession()
        _ = try await service.recognize(document,session:"A",operation:.init())
        let afterClear = await engine.calls;XCTAssertEqual(afterClear,5)
        await service.close()
        let delayed = PolicyEngine(.delayed), operation = MediaOperation()
        let late = LocalOCRService(vision:delayed,paddle:nil,settings:.init(),visionAvailable:true,paddleAvailable:false)
        let work = Task { try await late.recognize(document,session:"A",operation:operation) }
        await delayed.waitStarted()
        let clear = Task { await late.clearSession() }
        while !operation.isCanceled { try await Task.sleep(for:.milliseconds(5)) }
        await delayed.release(); await clear.value
        do { _ = try await work.value;XCTFail() } catch { XCTAssertEqual((error as? SlateSyncError)?.code,"RECOGNITION_CANCELED") }
        _ = try await late.recognize(document,session:"A",operation:.init())
        let lateCalls = await delayed.calls;XCTAssertEqual(lateCalls,2)
        await late.close()
    }
}
