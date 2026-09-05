import Darwin
import Foundation
import SlateSyncDomain
@testable import SlateSyncMedia
import XCTest

struct FakePaddleRuntime: Sendable {
    let root: URL
    let paths: OCRRuntimePaths
    init(bundle: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SM06 中文 \(UUID().uuidString)")
        let resources = root.appendingPathComponent("资源 Root"), work = root.appendingPathComponent("work"), cache = root.appendingPathComponent("models"), home = root.appendingPathComponent("home")
        for url in [resources,work,cache,home] { try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true) }
        let scripts = bundle ? resources : resources.appendingPathComponent("scripts")
        try FileManager.default.createDirectory(at:scripts,withIntermediateDirectories:true)
        try mediaFixture("sm06-fake-runner.py").write(to:scripts.appendingPathComponent("paddleocr_runner.py"))
        paths = try .init(resources:bundle ? .bundle(resources) : .development(resources),python:URL(fileURLWithPath:"/usr/bin/python3"),workingDirectory:work,modelCache:cache,environment:["HOME":home.path,"TMPDIR":work.path,"PATH":"/usr/bin:/bin","OPENAI_API_KEY":"fake-provider-secret","PIP_INDEX_URL":"fake-mirror-secret","LANG":"en_US.UTF-8"])
        if bundle { try FileManager.default.setAttributes([.posixPermissions:0o555],ofItemAtPath:resources.path) }
    }
    func cleanup() { try? FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:root.appendingPathComponent("资源 Root").path); try? FileManager.default.removeItem(at:root) }
    struct Event: Decodable { let event:String; let pid:Int32; let secret:Bool }
    func events() -> [Event] {
        guard let data = try? Data(contentsOf:paths.modelCache.appendingPathComponent("events.jsonl")), let text = String(data:data,encoding:.utf8) else { return [] }
        return text.split(separator:"\n").compactMap { try? JSONDecoder().decode(Event.self,from:Data($0.utf8)) }
    }
    func waitFor(_ name: String, count:Int = 1) async throws {
        for _ in 0..<1000 { if events().filter({ $0.event==name }).count >= count { return }; try await Task.sleep(for:.milliseconds(5)) }
        throw SlateSyncError(code:"TEST_TIMEOUT",message:"Fake runner did not reach \(name)")
    }
}

@MainActor final class PaddleProcessTests: XCTestCase {
    private func document() async throws -> PreparedDocument { try await MediaPreparationService().prepare(.bytes(mediaFixture("tiny.png"),filename:"tiny.png")).selected(.standard) }
    private func config(_ mode:String = "ch") -> PaddleOCRConfiguration { .init(.init([.paddleOCRLanguage:mode])) }
    private func assertExited(_ runtime: FakePaddleRuntime) {
        for pid in Set(runtime.events().map(\.pid)) { XCTAssertEqual(Darwin.kill(pid,0),-1,"child \(pid) survived close") }
    }
    func testSingleWarmupConfigurationSwitchAndBundleEnvironment() async throws {
        let runtime = try FakePaddleRuntime(bundle:true); defer { runtime.cleanup() }
        let supervisor = OCRProcessSupervisor(paths:runtime.paths)
        let configuration = config()
        async let first: Data? = supervisor.execute(configuration:configuration,document:nil,operation:.init())
        async let second: Data? = supervisor.execute(configuration:configuration,document:nil,operation:.init())
        _ = try await (first,second)
        let doc = try await document()
        for _ in 0..<2 { _ = try await supervisor.execute(configuration:config(),document:doc,operation:.init()) }
        var snapshot = await supervisor.snapshot()
        XCTAssertEqual(snapshot.launches,1); XCTAssertEqual(snapshot.warmups,1)
        _ = try await supervisor.execute(configuration:config("fragment"),document:doc,operation:.init())
        snapshot = await supervisor.snapshot(); XCTAssertEqual(snapshot.launches,2); XCTAssertEqual(snapshot.warmups,2)
        XCTAssertFalse(runtime.events().contains { $0.secret })
        XCTAssertEqual(Set(runtime.events().map(\.pid)).count,2)
        await supervisor.close(); assertExited(runtime)
        snapshot = await supervisor.snapshot(); XCTAssertEqual(snapshot.active,0); XCTAssertEqual(snapshot.pending,0); XCTAssertFalse(snapshot.hasWorker)
    }
    func testFragmentedUnicodeLogsAndStderrAreDrained() async throws {
        let runtime = try FakePaddleRuntime(); defer { runtime.cleanup() }
        let doc = try await document()
        for mode in ["fragment","stderr"] {
            let service = PaddleOCRService(configuration:config(mode),paths:runtime.paths)
            let result = try await service.recognize(doc,operation:.init(),progress:nil)
            XCTAssertEqual(result.pages[0].views[0].blocks[0].text,"场 镜 次 C001 😀")
            XCTAssertEqual(result.blockCount,1)
            await service.close()
        }
        assertExited(runtime)
    }
    func testMalformedWrongIDDuplicateOversizeAndEOF() async throws {
        let runtime = try FakePaddleRuntime(); defer { runtime.cleanup() }
        let doc = try await document()
        for mode in ["malformed","wrong-id","duplicate","oversize","no-result"] {
            let supervisor = OCRProcessSupervisor(paths:runtime.paths)
            do { _ = try await supervisor.execute(configuration:config(mode),document:doc,operation:.init()); XCTFail(mode) }
            catch { XCTAssertTrue(["OCR_PROTOCOL","OCR_PROCESS_EXIT"].contains((error as? SlateSyncError)?.code ?? ""),"\(mode): \(error)") }
            await supervisor.close(); assertExited(runtime)
        }
    }
    func testQueuedCancellationAndDeadlineDoNotKillActiveWorker() async throws {
        let runtime = try FakePaddleRuntime(); defer { runtime.cleanup() }
        let clock = ManualOCRClock(), supervisor = OCRProcessSupervisor(paths:runtime.paths,clock:clock)
        let doc = try await document(), delayed = config("delay")
        let first = Task { try await supervisor.execute(configuration:delayed,document:doc,operation:.init()) }
        try await runtime.waitFor("recognize")
        let canceled = MediaOperation()
        let waiter = Task { try await supervisor.execute(configuration:delayed,document:doc,operation:canceled) }
        let expired = Task { try await supervisor.execute(configuration:delayed,document:doc,operation:.init(),deadline:.init(clock:clock,timeoutMilliseconds:10)) }
        for _ in 0..<200 { if await supervisor.snapshot().pending == 2 { break }; try await Task.sleep(for:.milliseconds(5)) }
        waiter.cancel();clock.advance(11)
        do { _ = try await waiter.value;XCTFail() } catch { XCTAssertEqual((error as? SlateSyncError)?.code,"RECOGNITION_CANCELED") }
        do { _ = try await expired.value;XCTFail() } catch { XCTAssertEqual((error as? SlateSyncError)?.code,"OCR_TIMEOUT") }
        _ = try await first.value
        XCTAssertEqual(runtime.events().filter { $0.event=="recognize" }.count,1)
        let snapshot = await supervisor.snapshot();XCTAssertEqual(snapshot.launches,1);XCTAssertTrue(snapshot.hasWorker)
        await supervisor.close();assertExited(runtime)
    }
    func testActiveCancellationTermKillAndTimeoutWarmup() async throws {
        let runtime = try FakePaddleRuntime(); defer { runtime.cleanup() }
        let doc = try await document()
        let supervisor = OCRProcessSupervisor(paths:runtime.paths), operation = MediaOperation(), mode = config("ignore-term")
        let task = Task { try await supervisor.execute(configuration:mode,document:doc,operation:operation) }
        try await runtime.waitFor("recognize")
        // The fixture installs its TERM handler immediately after this event.
        try await Task.sleep(for:.milliseconds(30))
        let start = Date();operation.cancel()
        do { _ = try await task.value;XCTFail() } catch { XCTAssertEqual((error as? SlateSyncError)?.code,"RECOGNITION_CANCELED") }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start),0.95)
        await supervisor.close();assertExited(runtime)
        let clock = ManualOCRClock(), timeoutSupervisor = OCRProcessSupervisor(paths:runtime.paths,clock:clock), warm = config("timeout-warmup")
        let timeout = Task { try await timeoutSupervisor.execute(configuration:warm,document:doc,operation:.init(),deadline:.init(clock:clock,timeoutMilliseconds:100)) }
        try await runtime.waitFor("warmup",count:2);clock.advance(101)
        do { _ = try await timeout.value;XCTFail() } catch { XCTAssertEqual((error as? SlateSyncError)?.code,"OCR_TIMEOUT") }
        let snapshot = await timeoutSupervisor.snapshot();XCTAssertEqual(snapshot.launches,1)
        await timeoutSupervisor.close();assertExited(runtime)
    }
    func testOneShotRecoveryAndForceCloseGeneration() async throws {
        let runtime = try FakePaddleRuntime(); defer { runtime.cleanup() }
        let doc = try await document()
        for mode in ["server-unsupported","server-exit"] {
            let supervisor = OCRProcessSupervisor(paths:runtime.paths)
            let result = try await supervisor.execute(configuration:config(mode),document:doc,operation:.init())
            XCTAssertNotNil(result)
            let snapshot = await supervisor.snapshot();XCTAssertEqual(snapshot.launches,2);XCTAssertFalse(snapshot.hasWorker)
            await supervisor.close();assertExited(runtime)
        }
        // Both child processes report progress against the original 100 ms
        // deadline. Resetting it for one-shot recovery would incorrectly pass.
        let recoveryClock = ManualOCRClock()
        let recovery = OCRProcessSupervisor(paths:runtime.paths,clock:recoveryClock)
        do {
            _ = try await recovery.execute(configuration:config("server-exit"),document:doc,operation:.init(),progress:{ _ in recoveryClock.advance(60) },deadline:.init(clock:recoveryClock,timeoutMilliseconds:100))
            XCTFail("One-shot recovery reset the shared deadline")
        } catch { XCTAssertEqual((error as? SlateSyncError)?.code,"OCR_TIMEOUT") }
        let recoverySnapshot = await recovery.snapshot();XCTAssertEqual(recoverySnapshot.launches,2)
        await recovery.close();assertExited(runtime)
        let supervisor = OCRProcessSupervisor(paths:runtime.paths), delayed = config("delay")
        let before = runtime.events().filter { $0.event=="recognize" }.count
        let first = Task { try await supervisor.execute(configuration:delayed,document:doc,operation:.init()) }
        try await runtime.waitFor("recognize",count:before+1)
        let queued = Task { try await supervisor.execute(configuration:delayed,document:nil,operation:.init()) }
        for _ in 0..<200 { if await supervisor.snapshot().pending == 1 { break };try await Task.sleep(for:.milliseconds(5)) }
        async let closeA:Void = supervisor.close(shutdown:true)
        async let closeB:Void = supervisor.close(shutdown:true)
        _ = await (closeA,closeB)
        do { _ = try await first.value;XCTFail() } catch {}
        do { _ = try await queued.value;XCTFail() } catch {}
        do { _ = try await supervisor.execute(configuration:config(),document:doc,operation:.init());XCTFail() } catch { XCTAssertEqual((error as? SlateSyncError)?.code,"OCR_CLOSED") }
        let snapshot = await supervisor.snapshot();XCTAssertEqual(snapshot.launches,1);XCTAssertEqual(snapshot.pending,0)
        assertExited(runtime)
    }
    func testOfflineActualPaddlePrewarmTwiceAndClose() async throws {
        guard ProcessInfo.processInfo.environment["SM06_PADDLE_GATE"] == "1" else { throw XCTSkip("Dedicated offline Paddle Gate supplies isolated runtime/model roots") }
        guard let path = ProcessInfo.processInfo.environment["SM06_PADDLE_RUNTIME_FILE"] else { XCTFail("BLOCKED_ENV: missing explicitly supplied offline runtime fixture");return }
        struct Runtime:Decodable { let python:String;let cache:String;let work:String;let home:String;let configuration:[String:String] }
        let fixture = try JSONDecoder().decode(Runtime.self,from:Data(contentsOf:URL(fileURLWithPath:path)))
        let repository = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let resources:OCRRuntimePaths.Resources = ProcessInfo.processInfo.environment["SM06_BUNDLE_RESOURCES"].map { .bundle(URL(fileURLWithPath:$0)) } ?? .development(repository)
        let paths = try OCRRuntimePaths(resources:resources,python:URL(fileURLWithPath:fixture.python),workingDirectory:URL(fileURLWithPath:fixture.work),modelCache:URL(fileURLWithPath:fixture.cache),environment:["HOME":fixture.home,"TMPDIR":fixture.work,"PATH":"/usr/bin:/bin","LANG":"en_US.UTF-8"])
        let settings = GlobalSettingValues(Dictionary(uniqueKeysWithValues:fixture.configuration.compactMap { key,value in GlobalSettingKey(rawValue:key).map { ($0,value) } }))
        let supervisor = OCRProcessSupervisor(paths:paths)
        let service = PaddleOCRService(configuration:.init(settings),paths:paths,supervisor:supervisor)
        let check = try await service.check();print("SM06_PADDLE_RUNTIME \(String(decoding:check,as:UTF8.self))")
        do {
            try await service.preload()
            let doc = try await MediaPreparationService().prepare(.bytes(mediaFixture("slate.jpg"),filename:"synthetic.jpg")).selected(.standard)
            for _ in 0..<2 {
                let result = try await service.recognize(doc,operation:.init(),progress:nil)
                XCTAssertGreaterThan(result.blockCount,3)
                print("SM06_PADDLE_INFERENCE model=\(result.modelVersion) blocks=\(result.blockCount)")
            }
            let snapshot = await supervisor.snapshot();XCTAssertEqual(snapshot.warmups,1);XCTAssertEqual(snapshot.launches,1)
            await service.close()
            let drained = await supervisor.snapshot();XCTAssertFalse(drained.hasWorker);XCTAssertEqual(drained.active,0);XCTAssertEqual(drained.pending,0)
        } catch { await service.close();throw error }
    }
}
