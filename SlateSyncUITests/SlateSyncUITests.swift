import XCTest

final class SlateSyncUITests: XCTestCase {
    private var testRoot: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        // Stay within the runner's writable sandbox; the packaged xctestrun
        // binds its actual target app so XCTest can coordinate access.
        testRoot = FileManager.default.temporaryDirectory
            .appending(path: "SlateSyncUITests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
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
        // The packaging Gate injects an extracted Release app URL. The same
        // assertions then exercise shipped bytes with a temporary data root.
        let app: XCUIApplication
        if let path = ProcessInfo.processInfo.environment["SLATESYNC_PACKAGED_APP"] {
            print("SM09_PACKAGED_APP \(path)")
            app = XCUIApplication(url: URL(fileURLWithPath: path))
        } else {
            app = XCUIApplication()
        }
        // XCTest runs teardown blocks even after a failed assertion. Stop the
        // database owner before deleting its files; retain evidence if it stays
        // alive instead of unlinking an open SQLite database across tests.
        let root = testRoot!
        addTeardownBlock { @MainActor in
            if app.state != .notRunning { app.terminate() }
            guard app.wait(for: .notRunning, timeout: 5) else {
                XCTFail("Application did not exit; retained isolated root: \(root.path)")
                return
            }
            try FileManager.default.removeItem(at: root)
        }
        app.launchEnvironment["SLATESYNC_TEST_ROOT"] = testRoot.path
        // Consecutive Gate runs can persist a prior no-window termination in
        // SwiftUI's restoration domain, which launches only the menu bar.
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        if app.state != .notRunning { app.terminate() }
        app.launch()
        // Launch can leave the window behind another desktop application.
        // Keyboard and accessibility assertions require the target foreground.
        app.activate()
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
    func testLegacyLibraryCSVExportAndReopenInDeliveredApp() throws {
        // Materialize the frozen pre-cutover export into this test's root.
        // The delivered app opens v1 SQLite itself; no production test hook or
        // real user Library is involved in the upgrade/CSV acceptance path.
        // Copy the canonical fixture into the test bundle at build time. A
        // sandboxed runner must not require runtime access to Desktop sources.
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "sm09-legacy-export", withExtension: "json"
        ))
        struct FrozenLibrary: Decodable {
            struct Entry: Decodable { let path: String; let base64: String }
            let packages: [String: [Entry]]
        }
        let packages = try JSONDecoder().decode(FrozenLibrary.self, from: Data(contentsOf: fixture)).packages
        let library = testRoot.appending(path: "Local SlateSync Library")
        for entry in try XCTUnwrap(packages["library"]) {
            let relative = entry.path
            guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else {
                XCTFail("Unsafe fixture path"); return
            }
            let destination = library.appending(path: relative)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try XCTUnwrap(Data(base64Encoded: entry.base64)).write(to: destination)
        }
        let input = testRoot.appending(path: "source.csv")
        let bytes = Data("File Name,Scene,Shot,Take\r\nA001C001.mov,87A,002,03\r\n".utf8)
        try bytes.write(to: input)
        let outputDirectory = testRoot.appending(path: "export")
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let app = launchIsolatedApp()
        defer { app.terminate() }
        print("SM09_ISOLATED_ROOT \(testRoot.path)")
        let project = app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "SM09 兼容项目")).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8))
        app.activate()
        let legacyScreenshot = XCTAttachment(screenshot: app.screenshot())
        legacyScreenshot.name = "SM09-legacy-library-before-open"
        legacyScreenshot.lifetime = .keepAlways
        add(legacyScreenshot)
        print("SM09_PROJECT_FRAME \(project.frame); WINDOW \(app.windows.firstMatch.frame)")
        project.click()
        app.buttons["打开"].firstMatch.click()
        XCTAssertTrue(app.buttons.matching(identifier: "task.create").firstMatch.waitForExistence(timeout: 8))
        // Workspace.activate selects and loads the project's first task — the
        // frozen v1 task — so the CSV scenario below runs against its restored
        // recognition records, the same state the old renderer exported from.
        let csvTab = app.radioButtons["Resolve CSV"].firstMatch
        XCTAssertTrue(csvTab.waitForExistence(timeout: 5))
        csvTab.click()
        app.buttons["导入 CSV…"].firstMatch.click()
        choosePanelPath(input.path, app: app)
        // Retained Worker fail-closed boundary (public/resolve-csv.js
        // export-resolve): the frozen legacy record carries no 卷号/视频码, so
        // its material key is missing-key, matchedRecordCount stays 0 and no
        // manual edits exist. Merged export must surface the retained
        // CSV_NO_EXPORT error instead of silently exporting the raw table.
        // SwiftUI renders the failure Label as a static text whose
        // accessibility label is empty and whose value carries the message,
        // so the witness reads the value.
        let missing = "没有匹配到可写入的完整记录"
        let export = app.buttons["导出 CSV…"].firstMatch
        expectation(for: NSPredicate { _, _ in export.exists && export.isEnabled }, evaluatedWith: app)
        waitForExpectations(timeout: 8)
        export.click()
        let surfaced = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", missing, missing)
        ).firstMatch
        XCTAssertTrue(surfaced.waitForExistence(timeout: 8), "合并导出必须保留 CSV_NO_EXPORT 报错")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputDirectory.appending(path: "source.csv").path))
        // Standalone export keeps the old <sheetTitle || 场记单>_场记识别.csv
        // naming. The sealed v1 result carries no sheetTitle, so the fallback
        // applies, and its unknown "remark" key stays outside the retained
        // schema, leaving Comments empty.
        let standalone = app.buttons["独立导出…"].firstMatch
        expectation(for: NSPredicate { _, _ in standalone.exists && standalone.isEnabled }, evaluatedWith: app)
        waitForExpectations(timeout: 8)
        standalone.click()
        choosePanelPath(outputDirectory.path, app: app)
        let standaloneOutput = outputDirectory.appending(path: "场记单_场记识别.csv")
        expectation(for: NSPredicate { _, _ in FileManager.default.fileExists(atPath: standaloneOutput.path) }, evaluatedWith: app)
        waitForExpectations(timeout: 8)
        // The retained standalone contract canonicalizes the legacy record
        // {scene A001, shot 002, take 03} to scene width 3 and shot width 2,
        // preserving the UTF-16LE BOM, CRLF and the final newline. The import
        // source stays raw.
        let expectedStandalone = Data("\u{FEFF}Scene,Shot,Take,Comments\r\n001,02,03,\r\n".data(using: .utf16LittleEndian)!)
        XCTAssertEqual(try Data(contentsOf: standaloneOutput), expectedStandalone)
        XCTAssertEqual(try Data(contentsOf: input), bytes)
        // The migrated library must still accept a brand-new task; creation
        // persists it immediately, so the relaunch below sees both rows.
        app.typeKey("n", modifierFlags: .command)
        app.typeKey("s", modifierFlags: .command)
        app.typeKey("q", modifierFlags: .command)
        expectation(for: NSPredicate { _, _ in app.state == .notRunning }, evaluatedWith: app)
        waitForExpectations(timeout: 8)
        app.launch()
        XCTAssertTrue(project.waitForExistence(timeout: 8))
        XCTAssertTrue((project.value as? String)?.contains("2 个任务") == true)
    }

    @MainActor
    private func choosePanelPath(_ path: String, app: XCUIApplication) {
        // Export builds its data asynchronously before presenting NSSavePanel.
        // Wait for the actual panel action before requesting Go to Folder.
        // NSSavePanel exposes its localized title separately from AX label.
        // Its system identifier is shared by open and save confirmation.
        let confirmation = app.buttons["OKButton"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 8))
        app.typeKey("g", modifierFlags: [.command, .shift])
        // Resolve the actual system Go sheet and path field, not an assumed
        // control type or focus. Replace any previously remembered location.
        let goSheet = app.sheets["GoToWindow"]
        XCTAssertTrue(goSheet.waitForExistence(timeout: 5))
        let location = app.textFields["PathTextField"]
        XCTAssertTrue(location.waitForExistence(timeout: 5))
        location.click()
        location.typeKey("a", modifierFlags: .command)
        location.typeText(path)
        XCTAssertEqual(location.value as? String, path)
        // Submit through the field whose value was verified, so XCTest routes
        // Return to the remote Go panel rather than the application's window.
        location.typeKey(.return, modifierFlags: [])
        expectation(for: NSPredicate { _, _ in !goSheet.exists }, evaluatedWith: app)
        waitForExpectations(timeout: 8)
        expectation(for: NSPredicate { _, _ in confirmation.exists && confirmation.isEnabled }, evaluatedWith: app)
        waitForExpectations(timeout: 8)
        confirmation.click()
        expectation(for: NSPredicate { _, _ in !confirmation.exists }, evaluatedWith: app)
        waitForExpectations(timeout: 8)
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
