import AppKit
import SlateSyncDomain
import SlateSyncPersistence
import SlateSyncWorkflow
import SwiftUI
import XCTest

@testable import SlateSyncUI

/// Real settings persistence under disposable roots; external operations are
/// disabled, and native layout checks never show or activate their windows.
@MainActor
final class RecognitionRequestSettingsTests: XCTestCase {
    private let defaults: [GlobalSettingKey: String] = [
        .modelRequestTimeoutMS: "180000", .modelRequestMaxRetries: "1",
        .modelPageConcurrency: "2", .maxConcurrentRecognitions: "1",
    ]

    func testMissingRequestOverridesDisplayDefaultsWithoutPersistingThem() async throws {
        let service = makeService()
        let settings = try await load(service)
        for (key, value) in defaults {
            XCTAssertEqual(settings.value(key), value)
            XCTAssertNil(settings.draft[key], "Displaying a default must not create an override")
        }
        XCTAssertEqual(settings.requestTimeoutSeconds, "180")
        XCTAssertEqual(settings.value(.paddleOCRPython), "", "Other panes keep their existing override semantics")
        await settings.save()
        let saved = try await service.globalSettings()
        XCTAssertTrue(saved.values.values.isEmpty)
    }

    func testInheritedRequestValuesAndClearedDraftUseRuntimePrecedence() async throws {
        let service = makeService(environment: ["MODEL_REQUEST_TIMEOUT_MS": "270000", "MODEL_PAGE_CONCURRENCY": "4"])
        let settings = try await load(service)
        XCTAssertEqual(settings.value(.modelRequestTimeoutMS), "270000")
        XCTAssertEqual(settings.requestTimeoutSeconds, "270")
        XCTAssertEqual(settings.value(.modelPageConcurrency), "4")
        XCTAssertEqual(settings.value(.modelRequestMaxRetries), "1")
        XCTAssertNil(settings.draft[.modelRequestTimeoutMS])

        settings.setValue("300000", for: .modelRequestTimeoutMS)
        await settings.save()
        XCTAssertEqual(settings.value(.modelRequestTimeoutMS), "300000")
        settings.setValue("", for: .modelRequestTimeoutMS)
        XCTAssertEqual(settings.value(.modelRequestTimeoutMS), "", "Clearing must remain possible while editing")
        XCTAssertEqual(settings.requestTimeoutSeconds, "")
        await settings.save()
        let saved = try await service.globalSettings()
        XCTAssertNil(saved.values[.modelRequestTimeoutMS])
        XCTAssertEqual(settings.value(.modelRequestTimeoutMS), "270000")
    }

    func testEditedRequestValuesPersistAcrossReloadAndRefreshKeepsDraft() async throws {
        let service = makeService()
        let settings = try await load(service)
        let edited: [GlobalSettingKey: String] = [
            .modelRequestTimeoutMS: "240000", .modelRequestMaxRetries: "0",
            .modelPageConcurrency: "3", .maxConcurrentRecognitions: "2",
        ]
        for (key, value) in edited { settings.setValue(value, for: key) }
        let refreshed = await settings.refresh()
        XCTAssertTrue(refreshed)
        for (key, value) in edited { XCTAssertEqual(settings.value(key), value) }
        await settings.save()
        guard case .succeeded = settings.operation else { return XCTFail("Save failed: \(settings.operation)") }

        let reopened = try await load(service)
        let saved = try await service.globalSettings()
        for (key, value) in edited {
            XCTAssertEqual(reopened.value(key), value)
            XCTAssertEqual(saved.values[key], value)
            XCTAssertEqual(saved.effectiveValues[key], value)
        }
    }

    func testRestoreDefaultsIsDraftOnlyAndPreservesOtherSettings() async throws {
        let service = makeService(environment: ["MODEL_REQUEST_TIMEOUT_MS": "270000"])
        _ = try await service.saveGlobalSettings(values: .init([
            .modelRequestTimeoutMS: "240000", .modelRequestMaxRetries: "3",
            .modelPageConcurrency: "6", .maxConcurrentRecognitions: "16",
            .visionOCRLanguage: "en",
        ]), customProviders: [])
        let settings = try await load(service)
        settings.setValue("fast", for: .visionOCRRecognitionLevel)
        let before = settings.live
        settings.restoreRecognitionRequestDefaults()
        for (key, value) in defaults { XCTAssertEqual(settings.value(key), value) }
        XCTAssertEqual(settings.live, before)
        XCTAssertEqual(settings.value(.visionOCRLanguage), "en")
        XCTAssertEqual(settings.value(.visionOCRRecognitionLevel), "fast")
        let unchanged = try await service.globalSettings()
        XCTAssertEqual(unchanged.values[.modelRequestTimeoutMS], "240000")

        await settings.save()
        let reopened = try await load(service)
        for (key, value) in defaults { XCTAssertEqual(reopened.value(key), value) }
        XCTAssertEqual(reopened.value(.visionOCRRecognitionLevel), "fast")
    }

    func testOutOfRangeEditsAreRetainedAndDoNotReachPersistence() async throws {
        let service = makeService()
        let settings = try await load(service)
        let invalid: [GlobalSettingKey: String] = [
            .modelRequestTimeoutMS: "29999", .modelRequestMaxRetries: "4",
            .modelPageConcurrency: "0", .maxConcurrentRecognitions: "17",
        ]
        for (key, value) in invalid {
            settings.setValue(value, for: key)
            await settings.save()
            guard case .failed(let error) = settings.operation else { return XCTFail("Accepted invalid \(key)") }
            XCTAssertEqual(error.code, "GLOBAL_CONFIG_INVALID")
            XCTAssertEqual(settings.value(key), value)
            let unchanged = try await service.globalSettings()
            XCTAssertTrue(unchanged.values.values.isEmpty)
            settings.setValue(defaults[key]!, for: key)
        }
    }

    func testSecondsEditingPreservesLegacyMillisecondsAndPartialInput() async throws {
        let service = makeService()
        _ = try await service.saveGlobalSettings(values: .init([.modelRequestTimeoutMS: "30001"]), customProviders: [])
        let settings = try await load(service)
        XCTAssertEqual(settings.requestTimeoutSeconds, "30.001")
        // Exercise decimal conversion and both allowed boundaries through real
        // persistence; binary floating-point scaling can corrupt 32.001 seconds.
        for (seconds, milliseconds) in [("30", "30000"), ("32.001", "32001"), ("180.", "180000"), ("3600", "3600000")] {
            settings.requestTimeoutSeconds = seconds
            XCTAssertEqual(settings.requestTimeoutSeconds, seconds)
            await settings.save()
            guard case .succeeded = settings.operation else { return XCTFail("Seconds save failed: \(settings.operation)") }
            let saved = try await service.globalSettings()
            XCTAssertEqual(saved.values[.modelRequestTimeoutMS], milliseconds)
            let reopened = try await load(service)
            XCTAssertEqual(reopened.requestTimeoutSeconds, seconds == "180." ? "180" : seconds)
        }
        settings.restoreRecognitionRequestDefaults()
        XCTAssertEqual(settings.requestTimeoutSeconds, "180")
    }

    func testInvalidSecondsStayEditableAndClearingRestoresInheritedTimeout() async throws {
        let service = makeService(environment: ["MODEL_REQUEST_TIMEOUT_MS": "270000"])
        let settings = try await load(service)
        for seconds in ["29.999", "3600.001", "30.0001", "invalid"] {
            settings.requestTimeoutSeconds = seconds
            await settings.save()
            guard case .failed(let error) = settings.operation else { return XCTFail("Accepted invalid seconds: \(seconds)") }
            XCTAssertEqual(error.code, "GLOBAL_CONFIG_INVALID")
            XCTAssertEqual(error.message, L10n.tr("请求超时必须为 30–3600 秒，最多保留三位小数。"))
            XCTAssertEqual(settings.requestTimeoutSeconds, seconds)
            let unchanged = try await service.globalSettings()
            XCTAssertNil(unchanged.values[.modelRequestTimeoutMS])
        }
        settings.requestTimeoutSeconds = ""
        XCTAssertEqual(settings.requestTimeoutSeconds, "")
        await settings.save()
        XCTAssertEqual(settings.requestTimeoutSeconds, "270")
    }

    func testRequestFieldsAreVisibleInOffscreenSettings() async throws {
        let service = makeService()
        let settings = try await load(service)
        let suite = "request-settings-\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let previousLanguage = L10n.language
        defer {
            preferences.set(previousLanguage.rawValue, forKey: AppLanguage.preferenceKey)
            L10n.configure(preferences: preferences)
            preferences.removePersistentDomain(forName: suite)
        }
        let directory = ProcessInfo.processInfo.environment["SLATESYNC_REQUEST_SETTINGS_SNAPSHOT_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        if let directory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        for language in AppLanguage.allCases {
            preferences.set(language.rawValue, forKey: AppLanguage.preferenceKey)
            L10n.configure(preferences: preferences)
            for dark in [false, true] {
                preferences.set(dark ? "dark" : "light", forKey: "appearance")
                for size in [CGSize(width: 700, height: 540), CGSize(width: 1000, height: 700)] {
                    let navigation = SettingsNavigationModel()
                    navigation.navigate(to: .recognition)
                    let host = NSHostingView(rootView: SettingsRootView(
                        settings: settings, paddleInstaller: PaddleInstallerModel(service: service),
                        navigation: navigation, preferences: preferences
                    ).defaultAppStorage(preferences))
                    host.frame = CGRect(origin: .zero, size: size)
                    let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.contentView = host
                    defer { window.contentView = nil; window.close() }
                    for _ in 0..<12 {
                        host.layoutSubtreeIfNeeded()
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    let fields = descendants(host).compactMap { $0 as? NSTextField }.filter(\.isEditable)
                    let displayed = defaults.merging([.modelRequestTimeoutMS: "180"]) { _, seconds in seconds }
                    XCTAssertEqual(fields.map(\.stringValue).sorted(), displayed.values.sorted())
                    for field in fields {
                        let frame = field.convert(field.bounds, to: host)
                        XCTAssertGreaterThan(frame.width, 80)
                        XCTAssertTrue(host.bounds.contains(frame), "Request field must remain visible at the minimum window size")
                    }
                    if let directory {
                        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        try png.write(to: directory.appending(path: "requests-\(language.rawValue)-\(dark ? "dark" : "light")-\(Int(size.width)).png"))
                    }
                    XCTAssertFalse(window.isVisible, "Offline verification must never present a window")
                }
            }
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    private func load(_ service: SlateSyncWorkflowFacade) async throws -> GlobalSettingsModel {
        let settings = GlobalSettingsModel(service: service)
        await settings.load()
        _ = try XCTUnwrap(settings.live, "Settings must load before testing editing behavior")
        return settings
    }

    private func makeService(environment: [String: String] = [:]) -> SlateSyncWorkflowFacade {
        let root = FileManager.default.temporaryDirectory.appending(path: "request-settings-\(UUID())", directoryHint: .isDirectory)
        let locator = ApplicationSupportLocator(root: root)
        let runtime = SlateSyncRuntime(locator: locator, environment: environment)
        let library = ProjectLibraryStartupService(locator: locator, machineSettings: runtime.machineSettingsStore,
            environment: [:], forceIsolatedRoot: true)
        let service = SlateSyncWorkflowFacade(library: library, runtime: runtime,
            logs: LocalLogStore(directory: root.appending(path: "logs")),
            paddleInstaller: PaddleOCRInstallerService(userDataRoot: root, requirementsURL: root.appending(path: "unused.txt")),
            allowsExternalOperations: false)
        addTeardownBlock {
            try await service.drain()
            try FileManager.default.removeItem(at: root)
        }
        return service
    }
}
