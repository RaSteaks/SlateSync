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
        XCTAssertTrue(app.buttons.matching(identifier: "project.create").firstMatch.waitForExistence(timeout: 8))
        // SwiftUI toolbars can expose a duplicate hosted child whose click
        // lands on toolbar chrome. The menu shortcut targets the same focused
        // action and adds deterministic keyboard-path coverage.
        app.typeKey("n", modifierFlags: [.command, .shift])
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
    func testLogsRouteRendersLocalLogSurface() {
        let app = launchIsolatedApp()
        XCTAssertTrue(app.staticTexts["运行日志"].waitForExistence(timeout: 8))
        app.staticTexts["运行日志"].firstMatch.click()
        // The list can legitimately be empty in a fresh isolated root; the
        // route's refresh action is the stable witness for the Logs surface.
        XCTAssertTrue(app.buttons["刷新"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["运行日志"].exists)
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
    func testChineseKeyboardWorkflowAndApplicationReopen() {
        let app = launchIsolatedApp()
        let projectName = "中文键盘退出重开项目"
        let prompt = "中文输入与自动保存"
        XCTAssertTrue(app.buttons.matching(identifier: "project.create").firstMatch.waitForExistence(timeout: 8))

        // Exercise the focused menu owners without relying on duplicated
        // SwiftUI toolbar accessibility children.
        app.typeKey("n", modifierFlags: [.command, .shift])
        let name = app.textFields["project.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.typeText(projectName)
        XCTAssertEqual(name.value as? String, projectName)
        app.buttons.matching(identifier: "project.create.confirm").firstMatch.click()
        XCTAssertTrue(app.buttons.matching(identifier: "task.create").firstMatch.waitForExistence(timeout: 8))
        app.typeKey("n", modifierFlags: .command)
        let customPrompt = app.textFields["workspace.custom-prompt"]
        XCTAssertTrue(customPrompt.waitForExistence(timeout: 5))
        // Multiline macOS fields do not implicitly acquire the field editor
        // when XCUI sends text, so focus the accessible control first.
        customPrompt.click()
        customPrompt.typeText(prompt)
        app.typeKey("s", modifierFlags: .command)

        app.typeKey("q", modifierFlags: .command)
        let stopped = NSPredicate { _, _ in app.state == .notRunning }
        expectation(for: stopped, evaluatedWith: app)
        waitForExpectations(timeout: 8)
        app.launch()
        // Project rows combine name, archive state, and task count into one
        // VoiceOver value. Match that semantic value and then reopen it to
        // verify the task snapshot, not just the library index, survived.
        let projectRow = app.staticTexts.matching(
            NSPredicate(format: "value CONTAINS %@", projectName)
        ).firstMatch
        XCTAssertTrue(projectRow.waitForExistence(timeout: 8))
        XCTAssertTrue((projectRow.value as? String)?.contains("1 个任务") == true)
        // The visible row text is a combined accessibility child; select it
        // once and use the explicit toolbar action instead of depending on a
        // mouse-only double-click gesture reaching its parent List row.
        projectRow.click()
        let openProject = app.buttons["打开"].firstMatch
        XCTAssertTrue(openProject.waitForExistence(timeout: 3))
        openProject.click()
        XCTAssertTrue(app.buttons.matching(identifier: "task.create").firstMatch.waitForExistence(timeout: 8))
        let restoredPrompt = app.textFields["workspace.custom-prompt"]
        XCTAssertTrue(restoredPrompt.waitForExistence(timeout: 5))
        XCTAssertEqual(restoredPrompt.value as? String, prompt)
    }

    @MainActor
    func testMinimumWindowAccessibilityAndLightDarkAppearance() {
        let app = launchIsolatedApp()
        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 8))
        XCTAssertGreaterThanOrEqual(mainWindow.frame.width, 960)
        XCTAssertGreaterThanOrEqual(mainWindow.frame.height, 600)
        XCTAssertTrue(app.outlines["sidebar"].exists || app.tables["sidebar"].exists || app.otherElements["sidebar"].exists)

        app.typeKey(",", modifierFlags: .command)
        waitForWindowCount(2, app: app)
        let appearance = app.popUpButtons["settings.appearance"].firstMatch
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        appearance.click()
        app.menuItems["浅色"].click()
        let light = XCTAttachment(screenshot: app.screenshot())
        light.name = "浅色-辅助功能树"
        light.lifetime = .keepAlways
        add(light)

        appearance.click()
        app.menuItems["深色"].click()
        let dark = XCTAttachment(screenshot: app.screenshot())
        dark.name = "深色-辅助功能树"
        dark.lifetime = .keepAlways
        add(dark)
        XCTAssertTrue(app.buttons["通用"].exists || app.radioButtons["通用"].exists)
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
