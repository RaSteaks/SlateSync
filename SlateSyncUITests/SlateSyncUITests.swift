import AppKit
import PDFKit
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

    /// Exercise the actual persisted setting rather than a launch-time locale
    /// override. Each restart reuses the isolated library and preference suite.
    @MainActor
    func testApplicationLanguageRoundTripIncludesHelpMenusAndUserContent() {
        let app = launchIsolatedApp()
        XCTAssertTrue(app.buttons["project.create"].firstMatch.waitForExistence(timeout: 15))
        _ = openSettingsWindow(app)
        let language = app.popUpButtons["settings.applicationLanguage"].firstMatch
        XCTAssertTrue(language.waitForExistence(timeout: 10))
        language.click()
        app.menuItems["English"].firstMatch.click()
        XCTAssertTrue(app.descendants(matching: .any)["settings.languageRestart"].firstMatch.waitForExistence(timeout: 6))
        app.terminate()
        app.launch()
        app.activate()

        XCTAssertTrue(app.staticTexts["Project Library"].firstMatch.waitForExistence(timeout: 15))
        app.staticTexts["Help"].firstMatch.click()
        XCTAssertTrue(app.textFields["help.search"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Quick start"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(app.popUpButtons["settings.helpLanguage"].exists)
        attachReview("English help", app: app)
        app.staticTexts["Logs"].firstMatch.click()
        XCTAssertTrue(app.buttons["Refresh"].firstMatch.waitForExistence(timeout: 3))
        app.staticTexts["Project Library"].firstMatch.click()
        app.typeKey("n", modifierFlags: [.command, .shift])
        let name = app.textFields["project.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.typeText("中文项目 English")
        app.buttons["project.create.confirm"].firstMatch.click()
        XCTAssertTrue(app.buttons["task.create"].firstMatch.waitForExistence(timeout: 8))
        app.staticTexts["Project Settings"].firstMatch.click()
        let savedName = app.textFields["project.settings.name"]
        XCTAssertTrue(savedName.waitForExistence(timeout: 3))
        XCTAssertEqual(savedName.value as? String, "中文项目 English")
        XCTAssertTrue(app.menuBars.menuBarItems["Recognition"].exists)
        attachReview("English workspace with original project name", app: app)

        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(language.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Appearance"].firstMatch.exists)
        attachReview("English general settings", app: app)
        language.click()
        app.menuItems["简体中文"].firstMatch.click()
        app.terminate()
        app.launch()
        app.activate()
        XCTAssertTrue(app.staticTexts["项目库"].firstMatch.waitForExistence(timeout: 8))
        app.staticTexts["帮助"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["快速开始"].firstMatch.waitForExistence(timeout: 3))
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
        // The sidebar keeps the acquired project visible beside its group
        // heading, independent of the workspace's current detail route.
        let currentProjectName = app.staticTexts["sidebar.currentProjectName"]
        XCTAssertTrue(currentProjectName.waitForExistence(timeout: 3))
        // macOS combines both texts in the native Section header for
        // VoiceOver, so assert the user-authored portion without depending on
        // the localized heading or accessibility punctuation.
        XCTAssertTrue(currentProjectName.label.contains("隔离测试项目"))

        // Reopen through the native row primary action, not the toolbar. This
        // catches regressions where double-click only changes List selection.
        app.staticTexts["项目库"].firstMatch.click()
        let row = app.descendants(matching: .any).matching(
            // SwiftUI exposes a combined native List row as either a label or
            // a static-text value depending on the current macOS list style.
            NSPredicate(format: "label == %@ OR value == %@",
                        "隔离测试项目，活跃，0 个任务", "隔离测试项目，活跃，0 个任务")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.doubleClick()
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
        XCTAssertTrue(app.staticTexts["Provider 配置"].waitForExistence(timeout: 3))
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
        addTeardownBlock { @MainActor [weak self] in
            // Keep visual evidence for assertions as well as XCUI exceptions.
            if (self?.testRun?.failureCount ?? 0) > 0, app.state != .notRunning {
                self?.attachReview("失败现场", app: app)
            }
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
        // A freshly extracted Release app can take longer to publish its first
        // SwiftUI window while LaunchServices and the runtime warm up. Wait for
        // the native window once here so each test's semantic control timeout
        // measures UI readiness rather than process cold-start overhead.
        _ = app.windows.firstMatch.waitForExistence(timeout: 15)
        app.activate()
        return app
    }

    @MainActor
    private func openSettingsWindow(_ app: XCUIApplication) -> XCUIElement {
        app.activate()
        app.typeKey(",", modifierFlags: .command)
        let settingsWindow = app.windows["com_apple_SwiftUI_Settings_window"]
        if !settingsWindow.waitForExistence(timeout: 10) {
            // A freshly launched packaged app can accept the command before
            // its Settings scene has registered with AppKit. Retry only when
            // the native Settings window is absent, so an existing window is
            // never toggled closed by a blind second shortcut.
            app.activate()
            app.typeKey(",", modifierFlags: .command)
            XCTAssertTrue(settingsWindow.waitForExistence(timeout: 10))
        }
        app.activate()
        return settingsWindow
    }

    @MainActor
    func testIndependentWindowsAndNewWindowAfterClosingLastWindow() {
        let app = launchIsolatedApp()
        XCTAssertTrue(app.buttons.matching(identifier: "project.create").firstMatch.waitForExistence(timeout: 15))
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
        XCTAssertTrue(name.waitForExistence(timeout: 8))
        name.typeText(projectName)
        XCTAssertEqual(name.value as? String, projectName)
        app.buttons.matching(identifier: "project.create.confirm").firstMatch.click()
        XCTAssertTrue(app.buttons.matching(identifier: "task.create").firstMatch.waitForExistence(timeout: 8))
        app.typeKey("n", modifierFlags: .command)
        revealAdvancedConfiguration(app)
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
        revealAdvancedConfiguration(app)
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
        XCTAssertTrue(
            app.outlines["sidebar"].exists || app.tables["sidebar"].exists || app.otherElements["sidebar"].exists)

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
        try installLegacyLibrary()
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
        choosePanelPath(input.path, operation: .openFile, app: app)
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
        // The workbench intentionally has one export route. A manual sparse
        // edit makes this otherwise unmatched CSV exportable; assert the actual
        // delivered file and raw-source preservation instead of a removed button.
        let table = app.tables["可编辑 Resolve CSV"].firstMatch
        let scene = table.textFields["第 1 行，Scene"].firstMatch
        XCTAssertTrue(scene.waitForExistence(timeout: 5))
        // Native row selection does not itself begin field editing. Return
        // enters the first column; Tab follows the grid's existing keyboard route.
        table.tableRows.firstMatch.click()
        app.typeKey(.return, modifierFlags: [])
        app.typeKey(.tab, modifierFlags: [])
        app.typeKey("a", modifierFlags: .command)
        app.typeText("087B")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(scene.value as? String, "087B")
        export.click()
        // Scope to the actual sheet: macOS 26 also exposes a same-named
        // Touch Bar item that exists but cannot receive an ordinary click.
        let confirmWarnings = app.sheets.buttons["仍要导出 CSV"].firstMatch
        XCTAssertTrue(confirmWarnings.waitForExistence(timeout: 8))
        confirmWarnings.click()
        choosePanelPath(outputDirectory.path, operation: .saveDirectory, app: app)
        let exported = outputDirectory.appending(path: "source_场记已回填.csv")
        expectation(
            for: NSPredicate { _, _ in FileManager.default.fileExists(atPath: exported.path) },
            evaluatedWith: app)
        waitForExpectations(timeout: 8)
        // The merger adds the configured Comments column while leaving all
        // existing unmatched cells untouched except the explicit Scene edit.
        let expected = Data("File Name,Scene,Shot,Take,Comments\r\nA001C001.mov,087B,002,03,\r\n".utf8)
        XCTAssertEqual(try Data(contentsOf: exported), expected)
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
    func testPreviewPagingPreservesResultSelection() throws {
        try installLegacyLibrary()
        let imageURL = try makeReviewImage()
        let image = try XCTUnwrap(NSImage(contentsOf: imageURL))
        let document = PDFDocument()
        document.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        document.insert(try XCTUnwrap(PDFPage(image: image)), at: 1)
        let pdfURL = testRoot.appending(path: "双页场记单.pdf")
        XCTAssertTrue(document.write(to: pdfURL))
        let app = launchIsolatedApp()
        let project = app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "SM09 兼容项目")).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8))
        project.click()
        app.buttons["打开"].firstMatch.click()
        XCTAssertTrue(app.buttons["task.create"].firstMatch.waitForExistence(timeout: 8))
        app.buttons["选择 PDF 或图像…"].firstMatch.click()
        choosePanelPath(pdfURL.path, operation: .openFile, app: app)
        XCTAssertTrue(app.buttons["workspace.preview.next"].waitForExistence(timeout: 10))
        app.buttons["workspace.preview.next"].click()
        XCTAssertTrue(app.staticTexts["2 / 2"].waitForExistence(timeout: 5))
        app.radioButtons["识别结果"].firstMatch.click()
        let table = app.tables["可编辑识别结果"].firstMatch
        XCTAssertTrue(table.waitForExistence(timeout: 5))
        let row = table.tableRows.firstMatch
        row.click()
        XCTAssertTrue(row.isSelected)
        app.descendants(matching: .any).matching(identifier: "workspace.original.toggle").firstMatch.click()
        XCTAssertTrue(app.staticTexts["2 / 2"].waitForExistence(timeout: 5))
        // The second source page is unrelated to the one restored result row.
        // Paging in the comparison panel must preserve native row selection.
        app.buttons["workspace.preview.previous"].click()
        XCTAssertTrue(app.staticTexts["1 / 2"].waitForExistence(timeout: 5))
        XCTAssertEqual(table.tableRows.count, 1)
        XCTAssertTrue(row.isSelected)
    }

    @MainActor
    func testSettingsWindowResizesWithoutLosingPreferences() {
        let app = launchIsolatedApp()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 8))
        let settingsWindow = openSettingsWindow(app)
        let appearance = settingsWindow.popUpButtons["settings.appearance"].firstMatch
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        let value = appearance.value as? String
        // Window ordering can change during native resize activation. Keep
        // the Settings identity instead of reevaluating a firstMatch query.
        // Packaged Release launches can leave the newly created Settings
        // window behind the app until activation is restored explicitly.
        app.activate()
        // Focus the title bar before the first edge drag; the packaged app can
        // expose the settings sheet without making it the key resize target.
        settingsWindow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
            .withOffset(CGVector(dx: 0, dy: 16))
            .click()
        resize(settingsWindow, to: CGSize(width: 700, height: 540))
        XCTAssertTrue(appearance.isHittable)
        resize(settingsWindow, to: CGSize(width: 780, height: 620))
        XCTAssertEqual(appearance.value as? String, value)
        attachReview("设置窗口缩放", app: app)
    }

    @MainActor
    func testWorkspaceAppearanceDensityAndComparisonMatrix() throws {
        try installLegacyLibrary()
        let mediaURL = try makeReviewImage()
        let app = launchIsolatedApp()
        let project = app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "SM09 兼容项目")).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8))
        attachReview("项目库", app: app)
        project.click()
        app.buttons["打开"].firstMatch.click()
        XCTAssertTrue(app.buttons["task.create"].firstMatch.waitForExistence(timeout: 8))
        app.buttons["选择 PDF 或图像…"].firstMatch.click()
        choosePanelPath(mediaURL.path, operation: .openFile, app: app)
        XCTAssertTrue(app.buttons["workspace.preview.enlarge"].waitForExistence(timeout: 10))

        let main = app.windows.firstMatch
        for appearance in ["浅色", "深色"] {
            for density in ["舒适", "紧凑"] {
                app.typeKey(",", modifierFlags: .command)
                let appearancePicker = app.popUpButtons["settings.appearance"].firstMatch
                XCTAssertTrue(appearancePicker.waitForExistence(timeout: 5))
                appearancePicker.click()
                app.menuItems[appearance].click()
                app.popUpButtons["settings.density"].firstMatch.click()
                app.menuItems[density].click()
                attachReview("设置-\(appearance)-\(density)", app: app)
                app.typeKey("w", modifierFlags: .command)
                waitForWindowCount(1, app: app)
                for size in [CGSize(width: 1440, height: 900), CGSize(width: 960, height: 600)] {
                    resize(main, to: size)
                    // Window resizing can leave another desktop app in front;
                    // restore activation before checking physical hit targets.
                    app.activate()
                    let name = "\(appearance)-\(density)-\(Int(size.width))x\(Int(size.height))"
                    attachReview("输入-\(name)", app: app)
                    let config = app.buttons["workspace.configuration.toggle"].firstMatch
                    XCTAssertTrue(config.isHittable)
                    config.click()
                    attachReview("配置-\(name)", app: app)
                    if app.buttons["workspace.configuration.close"].firstMatch.exists
                        && app.buttons["workspace.configuration.close"].firstMatch.isHittable
                    {
                        app.buttons["workspace.configuration.close"].firstMatch.click()
                    }
                    app.radioButtons["识别结果"].firstMatch.click()
                    let toggle = app.descendants(matching: .any).matching(identifier: "workspace.original.toggle")
                        .firstMatch
                    XCTAssertTrue(toggle.waitForExistence(timeout: 5))
                    toggle.click()
                    XCTAssertTrue(app.buttons["workspace.original.close"].waitForExistence(timeout: 5))
                    attachReview("原稿对照-\(name)", app: app)
                    app.buttons["workspace.original.close"].click()
                    app.radioButtons["Resolve CSV"].firstMatch.click()
                    XCTAssertTrue(app.buttons["导入 CSV…"].firstMatch.isHittable)
                    attachReview("CSV-\(name)", app: app)
                    app.radioButtons["输入"].firstMatch.click()
                }
            }
        }
        // Local filtering must not change the selected task or its prepared media.
        let search = app.textFields["workspace.task.search"]
        search.click()
        search.typeText("不存在的场记任务")
        XCTAssertTrue(app.staticTexts["无匹配任务"].waitForExistence(timeout: 5))
        app.buttons["workspace.task.search.clear"].click()
        XCTAssertEqual(search.value as? String, "")
        XCTAssertTrue(app.buttons["workspace.preview.enlarge"].exists)
        app.buttons["workspace.tasks.toggle"].firstMatch.click()
        XCTAssertFalse(search.exists && search.isHittable)
        app.buttons["workspace.tasks.toggle"].firstMatch.click()
        XCTAssertTrue(search.isHittable)
        for route in ["项目设置", "运行日志", "帮助"] {
            app.staticTexts[route].firstMatch.click()
            // Capture the loaded form rather than its asynchronous entry state.
            if route == "项目设置" {
                XCTAssertTrue(app.textFields["project.settings.name"].waitForExistence(timeout: 8))
            } else if route == "帮助" {
                XCTAssertTrue(app.textFields["help.search"].waitForExistence(timeout: 5))
            }
            attachReview(route, app: app)
        }
    }

    @MainActor
    private func resize(_ window: XCUIElement, to size: CGSize) {
        // The native size clamp uses the display's work-area SIZE, regardless
        // of a window's temporary origin while dragging. Move it to that area's
        // top-left first, keeping all resize handles clear of the Dock.
        let screen = NSScreen.main!
        let visible = screen.visibleFrame
        let target = CGSize(width: min(size.width, visible.width), height: min(size.height, visible.height))
        let origin = CGPoint(x: visible.minX, y: screen.frame.maxY - visible.maxY)
        let title = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
            .withOffset(CGVector(dx: 0, dy: 16))
        title.press(forDuration: 0.15, thenDragTo: title.withOffset(
            CGVector(dx: origin.x - window.frame.minX, dy: origin.y - window.frame.minY)))

        // Tahoe's rounded corners are outside the resize hit region. Drag the
        // middle of each straight edge separately; no app-side resize hook or
        // display preference change is needed, and both dimensions are asserted.
        if abs(window.frame.width - target.width) > 4 {
            let edge = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
                .withOffset(CGVector(dx: -1, dy: 0))
            edge.press(forDuration: 0.15, thenDragTo: edge.withOffset(
                CGVector(dx: target.width - window.frame.width, dy: 0)))
            if abs(window.frame.width - target.width) > 4 {
                // Tahoe accepts the inset hit point while older AppKit can
                // require the exact border. Refocus through the title bar and
                // retry the still-visible right edge at its native boundary;
                // the left edge is parked against the display and unavailable.
                title.click()
                let retryEdge = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
                retryEdge.press(forDuration: 0.15, thenDragTo: retryEdge.withOffset(
                    CGVector(dx: target.width - window.frame.width, dy: 0)))
            }
        }
        if abs(window.frame.height - target.height) > 4 {
            let shrinking = target.height < window.frame.height
            let shrinkFromTop = shrinking && window.frame.height >= visible.height - 4
            // A full-height window puts its bottom resize edge on the display
            // boundary; use the visible top edge only for that case. Smaller
            // windows keep the native bottom-edge path used by Settings.
            let edge = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: shrinkFromTop ? 0 : 1))
                .withOffset(CGVector(dx: 0, dy: shrinkFromTop ? 1 : -1))
            edge.press(forDuration: 0.15, thenDragTo: edge.withOffset(
                CGVector(dx: 0, dy: shrinkFromTop ? window.frame.height - target.height : target.height - window.frame.height)))
            if abs(window.frame.height - target.height) > 4 {
                // Match the horizontal compatibility path: retain Tahoe's
                // inset first, then retry the same visible edge on the exact
                // AppKit border with only the remaining height delta.
                title.click()
                let retryEdge = window.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.5, dy: shrinkFromTop ? 0 : 1))
                retryEdge.press(forDuration: 0.15, thenDragTo: retryEdge.withOffset(
                    CGVector(dx: 0, dy: shrinkFromTop
                        ? window.frame.height - target.height
                        : target.height - window.frame.height)))
            }
        }
        print("UI_RESIZE requested=\(size) supported=\(target) visible=\(visible) actual=\(window.frame)")
        XCTAssertEqual(window.frame.width, target.width, accuracy: 4)
        XCTAssertEqual(window.frame.height, target.height, accuracy: 4)
    }

    @MainActor
    private func attachReview(_ name: String, app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        let size = app.windows.firstMatch.frame.size
        screenshot.name = "UI-\(name)-actual-\(Int(size.width))x\(Int(size.height))"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    private func makeReviewImage() throws -> URL {
        // Deterministic, non-sensitive slate artwork belongs only to the test
        // fixture. Production preview still uses the real media preparation API.
        let image = NSImage(size: NSSize(width: 1000, height: 700))
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1000, height: 700)).fill()
        let ink: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 30, weight: .medium), .foregroundColor: NSColor.black,
        ]
        ("SLATESYNC / CAMERA REPORT" as NSString).draw(at: NSPoint(x: 40, y: 620), withAttributes: ink)
        for (index, text) in [
            "PRODUCTION   北岸来信", "ROLL     SCENE     SHOT     TAKE", "A001     087A      002      03",
            "A001     088       001      01", "A002     089       004      02",
        ].enumerated() {
            (text as NSString).draw(at: NSPoint(x: 40, y: 510 - index * 80), withAttributes: ink)
            NSColor.lightGray.setStroke()
            let line = NSBezierPath()
            line.move(to: NSPoint(x: 40, y: 490 - index * 80))
            line.line(to: NSPoint(x: 960, y: 490 - index * 80))
            line.stroke()
        }
        image.unlockFocus()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
        let url = testRoot.appending(path: "北岸来信_第十二拍摄日_场记单长文件名检查.png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    @MainActor
    private func installLegacyLibrary() throws {
        // Materialize the frozen pre-cutover export into this test's root.
        // The delivered app opens v1 SQLite itself; no production test hook or
        // real user Library is involved in the upgrade/CSV acceptance path.
        // Copy the canonical fixture into the test bundle at build time. A
        // sandboxed runner must not require runtime access to Desktop sources.
        let fixture = try XCTUnwrap(
            Bundle(for: Self.self).url(
                forResource: "sm09-legacy-export", withExtension: "json"
            ))
        struct FrozenLibrary: Decodable {
            struct Entry: Decodable {
                let path: String
                let base64: String
            }
            let packages: [String: [Entry]]
        }
        let packages = try JSONDecoder().decode(FrozenLibrary.self, from: Data(contentsOf: fixture)).packages
        let library = testRoot.appending(path: "Local SlateSync Library")
        for entry in try XCTUnwrap(packages["library"]) {
            let relative = entry.path
            guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else {
                XCTFail("Unsafe fixture path")
                return
            }
            let destination = library.appending(path: relative)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try XCTUnwrap(Data(base64Encoded: entry.base64)).write(to: destination)
        }
    }

    @MainActor
    private func revealAdvancedConfiguration(_ app: XCUIApplication) {
        // The native panel starts inline only when there is enough room.
        let advanced = app.buttons["workspace.advanced.toggle"].firstMatch
        if !advanced.exists || !advanced.isHittable {
            app.buttons["workspace.configuration.toggle"].firstMatch.click()
        }
        XCTAssertTrue(advanced.waitForExistence(timeout: 5))
        if !app.textFields["workspace.custom-prompt"].exists { advanced.click() }
    }

    private enum PanelOperation: String {
        case openFile
        case saveDirectory

        var panelIdentifier: String {
            switch self {
            case .openFile:
                return "open-panel"
            case .saveDirectory:
                return "save-panel"
            }
        }

        var displayName: String {
            switch self {
            case .openFile:
                return "打开文件"
            case .saveDirectory:
                return "选择保存目录"
            }
        }
    }

    private enum PanelWaitStage: String {
        case panelAppeared = "面板出现"
        case goToWindowAppeared = "路径导航面板出现"
        case pathFieldAppeared = "路径字段出现"
        case pathNavigationCompleted = "路径导航完成"
        case confirmationReady = "确认按钮可操作"
        case panelClosed = "面板关闭"
    }

    // System panels can be delayed by the test host or by asynchronous export
    // preparation. Keep every panel state transition bounded without adding a
    // fixed sleep or changing the application's performance policy.
    private static let panelWaitTimeout: TimeInterval = 20

    @MainActor
    private func choosePanelPath(_ path: String, operation: PanelOperation, app: XCUIApplication) {
        app.activate()
        let startedAt = ProcessInfo.processInfo.systemUptime
        // NSSavePanel and NSOpenPanel expose stable, different AX identifiers;
        // keeping the query scoped prevents a same-named Touch Bar control from
        // satisfying the confirmation lookup.
        let panel = app.sheets[operation.panelIdentifier].firstMatch
        let confirmation = panel.buttons["OKButton"].firstMatch
        guard waitForPanelState(
            { panel.exists },
            operation: operation,
            stage: .panelAppeared,
            path: path,
            startedAt: startedAt,
            app: app,
            panel: panel,
            confirmation: confirmation
        ) else { return }

        app.typeKey("g", modifierFlags: [.command, .shift])
        // GoToWindow is a system child sheet. The path field is deliberately
        // queried from that sheet instead of from the application root, where
        // another PathTextField can force a larger accessibility snapshot.
        let goToWindow = app.sheets["GoToWindow"].firstMatch
        guard waitForPanelState(
            { goToWindow.exists },
            operation: operation,
            stage: .goToWindowAppeared,
            path: path,
            startedAt: startedAt,
            app: app,
            panel: panel,
            confirmation: confirmation,
            goToWindow: goToWindow
        ) else { return }
        let location = goToWindow.textFields["PathTextField"].firstMatch
        guard waitForPanelState(
            { location.exists },
            operation: operation,
            stage: .pathFieldAppeared,
            path: path,
            startedAt: startedAt,
            app: app,
            panel: panel,
            confirmation: confirmation,
            goToWindow: goToWindow,
            location: location
        ) else { return }

        location.click()
        location.typeKey("a", modifierFlags: .command)
        location.typeText(path)
        XCTAssertEqual(location.value as? String, path)
        // Submit through the verified field so Return is delivered to the
        // system navigation sheet rather than to the application window.
        location.typeKey(.return, modifierFlags: [])
        guard waitForPanelState(
            { !goToWindow.exists },
            operation: operation,
            stage: .pathNavigationCompleted,
            path: path,
            startedAt: startedAt,
            app: app,
            panel: panel,
            confirmation: confirmation,
            goToWindow: goToWindow,
            location: location
        ) else { return }

        // On macOS, an exact file path can accept an open panel immediately.
        // Hand that already-complete state to the caller, but still make the
        // target panel closure an explicit bounded state check.
        if !panel.exists {
            guard waitForPanelState(
                { !panel.exists },
                operation: operation,
                stage: .panelClosed,
                path: path,
                startedAt: startedAt,
                app: app,
                panel: panel,
                confirmation: confirmation,
                goToWindow: goToWindow,
                location: location
            ) else { return }
            return
        }

        // If the open panel is still present, wait for a real actionable
        // button. Panel closure also completes this wait, but only because the
        // target panel itself disappeared—not because the button is absent.
        guard waitForPanelState(
            {
                !panel.exists
                    || (confirmation.exists && confirmation.isEnabled && confirmation.isHittable)
            },
            operation: operation,
            stage: .confirmationReady,
            path: path,
            startedAt: startedAt,
            app: app,
            panel: panel,
            confirmation: confirmation,
            goToWindow: goToWindow,
            location: location
        ) else { return }
        if !panel.exists {
            guard waitForPanelState(
                { !panel.exists },
                operation: operation,
                stage: .panelClosed,
                path: path,
                startedAt: startedAt,
                app: app,
                panel: panel,
                confirmation: confirmation,
                goToWindow: goToWindow,
                location: location
            ) else { return }
            return
        }
        guard confirmation.exists && confirmation.isEnabled && confirmation.isHittable else {
            failPanelInteraction(
                operation: operation,
                stage: .confirmationReady,
                path: path,
                startedAt: startedAt,
                app: app,
                panel: panel,
                confirmation: confirmation,
                goToWindow: goToWindow,
                location: location
            )
            return
        }
        confirmation.click()

        // A single click is sufficient; completion is defined by the target
        // panel closing, never by the confirmation button disappearing.
        guard waitForPanelState(
            { !panel.exists },
            operation: operation,
            stage: .panelClosed,
            path: path,
            startedAt: startedAt,
            app: app,
            panel: panel,
            confirmation: confirmation,
            goToWindow: goToWindow,
            location: location
        ) else { return }
    }

    @MainActor
    @discardableResult
    private func waitForPanelState(
        _ condition: @escaping () -> Bool,
        operation: PanelOperation,
        stage: PanelWaitStage,
        path: String,
        startedAt: TimeInterval,
        app: XCUIApplication,
        panel: XCUIElement,
        confirmation: XCUIElement,
        goToWindow: XCUIElement? = nil,
        location: XCUIElement? = nil
    ) -> Bool {
        // Keep this expectation out of XCTestCase's shared expectation list.
        // The test methods still use `waitForExpectations` for file results and
        // window counts after this helper returns; registering an expectation
        // here and waiting on it through a separate XCTWaiter makes XCTest 26
        // try to wait on the same expectation a second time.
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in condition() },
            object: app
        )
        let result = XCTWaiter().wait(for: [expectation], timeout: Self.panelWaitTimeout)
        guard result == .completed else {
            failPanelInteraction(
                operation: operation,
                stage: stage,
                path: path,
                startedAt: startedAt,
                app: app,
                panel: panel,
                confirmation: confirmation,
                goToWindow: goToWindow,
                location: location
            )
            return false
        }
        return true
    }

    @MainActor
    private func failPanelInteraction(
        operation: PanelOperation,
        stage: PanelWaitStage,
        path: String,
        startedAt: TimeInterval,
        app: XCUIApplication,
        panel: XCUIElement,
        confirmation: XCUIElement,
        goToWindow: XCUIElement? = nil,
        location: XCUIElement? = nil
    ) {
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        let state = [
            "operation=\(operation.rawValue) (\(operation.displayName))",
            "stage=\(stage.rawValue)",
            "elapsedSeconds=\(String(format: "%.3f", elapsed))",
            "requestedPath=\(path)",
            "applicationState=\(String(describing: app.state))",
            "windowCount=\(app.windows.count)",
            describePanelElement("panel", panel),
            describePanelElement("confirmation", confirmation),
            describePanelElement("GoToWindow", goToWindow),
            describePanelElement("PathTextField", location),
        ].joined(separator: "\n")

        let stateAttachment = XCTAttachment(string: state)
        stateAttachment.name = "Panel-\(operation.rawValue)-\(stage.rawValue)-state"
        stateAttachment.lifetime = .keepAlways
        add(stateAttachment)

        let treeAttachment = XCTAttachment(string: app.debugDescription)
        treeAttachment.name = "Panel-\(operation.rawValue)-\(stage.rawValue)-accessibility-tree"
        treeAttachment.lifetime = .keepAlways
        add(treeAttachment)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Panel-\(operation.rawValue)-\(stage.rawValue)-screenshot"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        XCTFail(
            "文件面板交互超时：操作=\(operation.displayName)，阶段=\(stage.rawValue)，"
                + "耗时=\(String(format: "%.3f", elapsed))s"
        )
    }

    @MainActor
    private func describePanelElement(_ name: String, _ element: XCUIElement?) -> String {
        guard let element else { return "\(name): unavailable" }
        return [
            "\(name).exists=\(element.exists)",
            "\(name).enabled=\(element.isEnabled)",
            "\(name).hittable=\(element.isHittable)",
            "\(name).label=\(element.label.debugDescription)",
            "\(name).value=\(String(describing: element.value))",
            "\(name).frame=\(element.frame)",
        ].joined(separator: " ")
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
