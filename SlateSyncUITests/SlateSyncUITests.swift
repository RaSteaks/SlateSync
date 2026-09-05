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
        let app = launchIsolatedApp()

        // Window titles follow the current navigation title, so assert the
        // application-owned front window instead of a localized title.
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["project.create"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testCreatesProjectAndOpensWorkspaceInIsolatedLibrary() {
        let app = launchIsolatedApp()
        // SwiftUI toolbars may expose both the semantic button and its hosted
        // child with the same identifier; firstMatch targets the front window.
        let create = app.buttons.matching(identifier: "project.create").firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 8))
        create.click()
        let name = app.textFields["project.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.typeText("隔离测试项目")
        app.buttons.matching(identifier: "project.create.confirm").firstMatch.click()

        // HSplitView does not expose its container identifier consistently to
        // XCUI; the workspace-owned task action is the stable route witness.
        let taskCreate = app.buttons.matching(identifier: "task.create").firstMatch
        XCTAssertTrue(taskCreate.waitForExistence(timeout: 8))
    }

    @MainActor
    func testHelpRouteUsesBundleLocalSearch() {
        let app = launchIsolatedApp()
        XCTAssertTrue(app.staticTexts["帮助"].waitForExistence(timeout: 8))
        app.staticTexts["帮助"].click()
        let search = app.textFields["help.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        // Route-level UI evidence verifies that the bundle-local catalog is
        // rendered; deterministic query filtering is covered by HelpModel.
        XCTAssertTrue(app.staticTexts["Provider 与 OCR 设置"].waitForExistence(timeout: 3))
    }

    @MainActor
    private func launchIsolatedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SLATESYNC_TEST_ROOT"] = testRoot.path
        // Consecutive Gate runs can persist a prior no-window termination in
        // SwiftUI's restoration domain, which launches only the menu bar.
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        if app.state != .notRunning { app.terminate() }
        app.launch()
        return app
    }

    @MainActor
    func testIndependentWindowsAndNewWindowAfterClosingLastWindow() {
        let app = launchIsolatedApp()
        XCTAssertTrue(app.buttons.matching(identifier: "project.create").firstMatch.waitForExistence(timeout: 8))
        app.staticTexts["帮助"].firstMatch.click()
        XCTAssertTrue(app.textFields["help.search"].waitForExistence(timeout: 3))
        // Window creation has its own shortcut, leaving Command-N available
        // for the focused workspace's task action.
        app.typeKey("n", modifierFlags: [.command, .option])
        XCTAssertTrue(app.buttons.matching(identifier: "project.create").firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.windows.count, 2)
        app.typeKey("w", modifierFlags: .command)
        waitForWindowCount(1, app: app)
        XCTAssertTrue(app.textFields["help.search"].waitForExistence(timeout: 5))
        app.typeKey("w", modifierFlags: .command)
        waitForWindowCount(0, app: app)
        XCTAssertNotEqual(app.state, .notRunning)
        app.typeKey("n", modifierFlags: [.command, .option])
        XCTAssertTrue(app.buttons.matching(identifier: "project.create").firstMatch.waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "中文项目库-关闭后新建窗口"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testSettingsCanOpenAndCloseWithoutReplacingHelpRoute() {
        let app = launchIsolatedApp()
        XCTAssertTrue(app.staticTexts["帮助"].waitForExistence(timeout: 8))
        app.staticTexts["帮助"].click()
        XCTAssertTrue(app.textFields["help.search"].waitForExistence(timeout: 3))
        app.typeKey(",", modifierFlags: .command)
        waitForWindowCount(2, app: app)
        app.typeKey("w", modifierFlags: .command)
        waitForWindowCount(1, app: app)
        XCTAssertTrue(app.textFields["help.search"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func waitForWindowCount(_ count: Int, app: XCUIApplication) {
        // Query uses dynamic member lookup, so KVC "count" can resolve as a
        // UI query instead of an integer. Read the real count in the predicate.
        let expectedCount = NSPredicate { _, _ in app.windows.count == count }
        expectation(for: expectedCount, evaluatedWith: app)
        waitForExpectations(timeout: 8)
    }
}
