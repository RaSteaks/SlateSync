import Foundation
import SlateSyncDomain
@testable import SlateSyncMedia
import Synchronization
import Vision
import XCTest

final class ManualOCRClock: OCRClock {
    private let time = Mutex(0.0)
    func nowMilliseconds() -> Double { time.withLock { $0 } }
    func advance(_ milliseconds: Double) { time.withLock { $0 += milliseconds } }
    func sleep(milliseconds: Int) async throws { try await Task.sleep(for: .milliseconds(milliseconds)) }
}

@MainActor final class OCRContractTests: XCTestCase {
    func testPaddleSettingsAndSelectionOracles() throws {
        struct Config: Decodable { let raw: [String:String]; let expected: [String:JSONValue] }
        let encoder = JSONEncoder()
        for vector in try JSONDecoder().decode([Config].self, from: mediaFixture("paddle-config.json")) {
            let values = GlobalSettingValues(Dictionary(uniqueKeysWithValues: vector.raw.compactMap { key,value in GlobalSettingKey(rawValue:key).map { ($0,value) } }))
            let configuration = PaddleOCRConfiguration(values)
            var actual = try JSONDecoder().decode([String:JSONValue].self, from: encoder.encode(configuration))
            actual["presetLabel"] = .string(configuration.presetLabel);actual["profileLabel"] = .string(configuration.profileLabel)
            for (key,value) in vector.expected { XCTAssertEqual(actual[key], value, key) }
        }
        struct Selection: Decodable {
            struct Engine: Decodable { let available: Bool; let required: Bool }
            struct Expected: Decodable { let id: OCREngineID?; let mode: String }
            var raw: [String:String]; let vision: Engine; let paddle: Engine; let expected: Expected
        }
        for var vector in try JSONDecoder().decode([Selection].self, from: mediaFixture("selection.json")) {
            vector.raw["VISIONOCR_REQUIRED"] = String(vector.vision.required); vector.raw["PADDLEOCR_REQUIRED"] = String(vector.paddle.required)
            let actual = OCRSelectionPolicy.resolve(raw: vector.raw, visionAvailable: vector.vision.available, paddleAvailable: vector.paddle.available)
            XCTAssertEqual(actual.id, vector.expected.id); XCTAssertEqual(actual.mode, vector.expected.mode)
        }
        XCTAssertEqual(VisionOCRConfiguration().language, "zh-Hans")
        XCTAssertEqual(VisionOCRConfiguration(.init([.visionOCRLanguage:",",.visionOCRRecognitionLevel:"fast",.visionOCRUseLanguageCorrection:"false"])).languages, [])
        XCTAssertEqual(VisionOCRConfiguration(.init([.visionOCRMinConfidence:""])).minimumConfidence, 0)
        XCTAssertEqual(PaddleOCRConfiguration(.init([.paddleOCRMinConfidence:""])).minimumConfidence, 0.1)
        XCTAssertEqual(OCRSettingReader.timeout("auto", engine:.vision, views:60), 910_000)
        XCTAssertEqual(OCRSettingReader.timeout("auto", engine:.paddle, views:60), 2_820_000)
        XCTAssertEqual(OCRSettingReader.timeout("1", engine:.vision, views:1), 10_000)
        XCTAssertEqual(OCRSettingReader.timeout("invalid", engine:.vision, views:1), 60_000)
        // Saved/UI patches first obey SM-03's mutual-exclusion rules. Raw env
        // combinations above deliberately retain their separate precedence.
        let patch = GlobalSettingsPatch([.visionOCREnabled:"true",.visionOCRRequired:"true",.paddleOCREnabled:"true"])
        let normalized = GlobalSettingsValidator.normalizeOcrRoutingPatch(patch)
        let normalizedRaw = Dictionary(uniqueKeysWithValues:normalized.values.compactMap { key,value in value.map { (key.rawValue,$0) } })
        let uiSelection = OCRSelectionPolicy.resolve(raw:normalizedRaw,visionAvailable:true,paddleAvailable:true)
        XCTAssertEqual(uiSelection.id,.paddle);XCTAssertEqual(uiSelection.mode,"explicit")
        let disabled = GlobalSettingsValidator.normalizeOcrRoutingPatch(.init([.visionOCREnabled:"false",.visionOCRRequired:"true",.paddleOCREnabled:"false",.paddleOCRRequired:"true"]))
        let disabledRaw = Dictionary(uniqueKeysWithValues:disabled.values.compactMap { key,value in value.map { (key.rawValue,$0) } })
        XCTAssertNil(OCRSelectionPolicy.resolve(raw:disabledRaw,visionAvailable:true,paddleAvailable:true).id)
    }
    func testVisionNormalizationMatchesExtractedHelper() async throws {
        struct Raw: Decodable { let text: String; let confidence: Double; let box: CGRectValue }
        struct Vector: Decodable { let observations: [Raw]; let cap: Int; let expected: OCRViewEvidence }
        let image = try PreparedImage(jpeg: mediaFixture("slate.jpg"), width:800,height:1000)
        let view = PreparedMediaView(viewIndex:0,viewType:.full,image:image)
        for vector in try JSONDecoder().decode([Vector].self, from: mediaFixture("vision-oracle.json")) {
            let actual = VisionObservationNormalizer.normalize(vector.observations.map { .init(text:$0.text,confidence:Double(Float($0.confidence)),box:$0.box) }, view:view, configuration:.init(.init([.visionOCRMaxBlocksPerView:String(vector.cap)])))
            XCTAssertEqual(actual, vector.expected)
        }
        let invalid = VisionObservationNormalizer.normalize([.init(text:"bad",confidence:.nan,box:.init(x:0,y:0,width:1,height:1)),.init(text:"bad",confidence:1,box:.init(x:.infinity,y:0,width:1,height:1))],view:view,configuration:.init())
        XCTAssertEqual(invalid.blocks.count,0)
        let block = OCRTextBlock(order:0,text:"_OK ng ×",confidence:0.9,bbox:[10,20,80,90],bboxNormalized:[0.1,0.2,0.8,0.9])
        let legacy = try block.legacyBlock()
        XCTAssertEqual(legacy.boundingBox.y,0.1,accuracy:0.00001); XCTAssertEqual(legacy.boundingBox.width,0.7,accuracy:0.00001)
        XCTAssertEqual(legacy.text,"_OK ng ×")
    }
    func testEvidenceUTF16GoldensAndDecimalTies() throws {
        struct Vector: Decodable { let page: OCRPageEvidence; let mode: String; let maxCharacters: Int; let expected: String }
        for vector in try JSONDecoder().decode([Vector].self, from: mediaFixture("evidence.json")) {
            XCTAssertEqual(OCREvidenceFormatter.format(vector.page,engine:"vision",core:vector.mode=="core",maxCharacters:vector.maxCharacters),vector.expected)
        }
        XCTAssertEqual(OCREvidenceFormatter.fixed(0.0625,digits:3),"0.063")
        XCTAssertEqual(OCREvidenceFormatter.fixed(0.00001,digits:4),"0.0000")
    }
    func testRealVisionSmokeAndExplicitMissingBinary() async throws {
        let service = VisionOCRService()
        let document = try await MediaPreparationService().prepare(.bytes(mediaFixture("slate.jpg"),filename:"synthetic.jpg"))
        let result = try await service.recognize(document.selected(.standard))
        XCTAssertGreaterThan(result.blockCount, 3)
        XCTAssertTrue(result.pages.flatMap(\.views).flatMap(\.blocks).contains { $0.text.contains("C0") || $0.text.contains("SLATE") })
        print("SM06_VISION_SMOKE os=\(ProcessInfo.processInfo.operatingSystemVersionString) revision=\(VNRecognizeTextRequest.defaultRevision) model=\(result.modelVersion) blocks=\(result.blockCount)")
        await service.close()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let missing = VisionOCRService(configuration:.init(.init([.visionOCRBinary:root.appendingPathComponent("missing-helper").path])))
        let available = await missing.isAvailable(); XCTAssertFalse(available)
        do { _ = try await missing.recognize(document); XCTFail() }
        catch { XCTAssertEqual((error as? SlateSyncError)?.code,"VISIONOCR_BINARY") }
        await missing.close()
    }
    func testVisionDeadlineCancellationAndLateCompletion() async throws {
        let clock = ManualOCRClock(), source = DelayedVisionSource()
        let service = VisionOCRService(source:source,clock:clock)
        let document = try await MediaPreparationService().prepare(.bytes(mediaFixture("tiny.png"),filename:"tiny.png"))
        let task = Task { try await service.recognize(document) }
        await source.waitStarted(); clock.advance(60_001); await source.release()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertEqual((error as? SlateSyncError)?.code,"OCR_TIMEOUT") }
        let secondSource = DelayedVisionSource(), op = MediaOperation()
        let second = VisionOCRService(source:secondSource)
        let progress = Mutex(0)
        let work = Task { try await second.recognize(document,operation:op,progress:{ _ in progress.withLock { $0 += 1 } }) }
        await secondSource.waitStarted(); op.cancel(); await secondSource.release()
        do { _ = try await work.value; XCTFail() } catch { XCTAssertEqual((error as? SlateSyncError)?.code,"RECOGNITION_CANCELED") }
        XCTAssertEqual(progress.withLock { $0 },0)
        await service.close(); await second.close()
    }
    func testVisionEffectiveConfigurationBoundedQueueAndExternalBridge() async throws {
        let config = VisionOCRConfiguration(.init([.visionOCRLanguage:"en-US,zh-Hans",.visionOCRRecognitionLevel:"fast",.visionOCRUseLanguageCorrection:"false",.visionOCRMinConfidence:"0.3",.visionOCRMaxBlocksPerView:"2"]))
        let source = RecordingVisionSource(), service = VisionOCRService(configuration:config,source:source)
        let document = try await MediaPreparationService().prepare(.bytes(mediaFixture("tiny.png"),filename:"tiny.png"))
        async let first = service.recognize(document)
        async let second = service.recognize(document)
        let results = try await [first,second]
        for result in results { XCTAssertEqual(result.pages[0].views.map(\.viewIndex),[0,1,2]) }
        let configurations = await source.configurations, maximum = await source.maximum
        XCTAssertEqual(configurations,Array(repeating:config,count:6));XCTAssertEqual(maximum,1)
        await service.close()
        let runtime = try FakePaddleRuntime();defer { runtime.cleanup() }
        let binary = runtime.root.appendingPathComponent("vision helper")
        let sourceBytes = Data("#!/usr/bin/python3\n".utf8) + (try mediaFixture("sm06-fake-runner.py"))
        try sourceBytes.write(to:binary)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:binary.path)
        let bridge = VisionOCRService(configuration:.init(.init([.visionOCRBinary:binary.lastPathComponent])),runtimeDirectory:runtime.root,environment:runtime.paths.environment)
        let available = await bridge.isAvailable();XCTAssertTrue(available)
        let result = try await bridge.recognize(document)
        XCTAssertEqual(result.engine,.vision);XCTAssertEqual(result.blockCount,3)
        await bridge.close()
    }
}

private actor RecordingVisionSource: VisionObservationSource {
    var configurations:[VisionOCRConfiguration] = []
    var active = 0, maximum = 0
    func available(configuration:VisionOCRConfiguration) -> Bool { true }
    func observations(_ image:PreparedImage,configuration:VisionOCRConfiguration,deadline:OCRDeadline,operation:MediaOperation) async throws -> [RawVisionObservation] {
        configurations.append(configuration);active += 1;maximum = max(maximum,active)
        defer { active -= 1 }
        try await Task.sleep(for:.milliseconds(5))
        return [.init(text:"C001",confidence:0.9,box:.init(x:0,y:0,width:1,height:1))]
    }
}

private actor DelayedVisionSource: VisionObservationSource {
    private var started = false, released = false
    func available(configuration: VisionOCRConfiguration) -> Bool { true }
    func observations(_ image: PreparedImage, configuration: VisionOCRConfiguration, deadline: OCRDeadline, operation: MediaOperation) async throws -> [RawVisionObservation] {
        started = true
        while !released { try await Task.sleep(for:.milliseconds(5)) }
        return [.init(text:"late",confidence:1,box:.init(x:0,y:0,width:1,height:1))]
    }
    func waitStarted() async { while !started { try? await Task.sleep(for:.milliseconds(5)) } }
    func release() { released = true }
}
