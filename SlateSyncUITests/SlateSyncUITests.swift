import XCTest

final class SlateSyncUITests: XCTestCase {
    private var testRoot: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        testRoot = FileManager.default.temporaryDirectory
            .appending(path: "SlateSyncUITests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: testRoot)
    }

    // XCUIAutomation is MainActor-isolated in the macOS 26 SDK.
    @MainActor
    func testLaunchesMainWindowAndProjectLibrary() {
        let app = XCUIApplication()
        app.launchEnvironment["SLATESYNC_TEST_ROOT"] = testRoot.path
        app.launch()

        // Window titles follow the current navigation title, so assert the
        // application-owned front window instead of a localized title.
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["project.create"].waitForExistence(timeout: 3))
    }
}
