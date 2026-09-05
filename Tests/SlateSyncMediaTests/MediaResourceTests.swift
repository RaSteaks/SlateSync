import Darwin
import Foundation
import SlateSyncDomain
@testable import SlateSyncMedia
import XCTest

@MainActor final class MediaResourceTests: XCTestCase {
    func testTwentyPagesThreeRoundsDrainOwnedResources() async throws {
        let runtime = try FakePaddleRuntime();defer { runtime.cleanup() }
        let bytes = try mediaFixture("pages-20.pdf")
        let descriptorsBefore = try FileManager.default.contentsOfDirectory(atPath:"/dev/fd").count
        let rssBefore = try residentBytes()
        var durations:[Double] = []
        var closedRSS:[UInt64] = []
        for _ in 0..<3 {
            let start = ProcessInfo.processInfo.systemUptime
            let supervisor = OCRProcessSupervisor(paths:runtime.paths)
            let service = PaddleOCRService(paths:runtime.paths,supervisor:supervisor)
            let document = try await MediaPreparationService().prepare(.bytes(bytes,filename:"twenty.pdf"))
            XCTAssertEqual(document.pages.count,20);XCTAssertEqual(document.viewCount,60)
            let result = try await service.recognize(document,operation:.init(),progress:nil)
            XCTAssertEqual(result.pages.count,20);XCTAssertEqual(result.blockCount,60)
            await service.close()
            let drained = await supervisor.snapshot()
            XCTAssertEqual(drained.active,0);XCTAssertEqual(drained.pending,0);XCTAssertFalse(drained.hasWorker)
            durations.append(ProcessInfo.processInfo.systemUptime - start)
            closedRSS.append(try residentBytes())
        }
        for pid in Set(runtime.events().map(\.pid)) { XCTAssertEqual(Darwin.kill(pid,0),-1) }
        let descriptorsAfter = try FileManager.default.contentsOfDirectory(atPath:"/dev/fd").count
        XCTAssertLessThanOrEqual(descriptorsAfter,descriptorsBefore)
        var usage = rusage();getrusage(RUSAGE_SELF,&usage)
        // RSS is measured, not interpreted as an allocator leak or retrofitted
        // into a timing threshold. Ownership/FD assertions are the resource Gate.
        print("SM06_RESOURCES pages=20 views=60 rounds=3 durations=\(durations) peakRSSBytes=\(usage.ru_maxrss) rssBefore=\(rssBefore) closedRSS=\(closedRSS) physicalMemory=\(ProcessInfo.processInfo.physicalMemory) processorCount=\(ProcessInfo.processInfo.processorCount) os=\(ProcessInfo.processInfo.operatingSystemVersionString) descriptorsBefore=\(descriptorsBefore) descriptorsAfter=\(descriptorsAfter) active=0 pending=0 processes=0")
    }
    private func residentBytes() throws -> UInt64 {
        // Query this test process only; no scans of unrelated application PIDs.
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to:&info) { pointer in
            pointer.withMemoryRebound(to:integer_t.self,capacity:Int(count)) {
                task_info(mach_task_self_,task_flavor_t(MACH_TASK_BASIC_INFO),$0,&count)
            }
        }
        XCTAssertEqual(status,KERN_SUCCESS)
        return info.resident_size
    }
}
