import AppKit
import SwiftUI

public struct SidebarView: View {
    @Environment(\.slateSyncDensity) private var density
    // Same persisted keys as AppRootView/Settings; both owners observe the
    // same defaults so a toggle here restyles the whole window immediately.
    @AppStorage("appearance") private var appearancePreference = "system"
    @AppStorage("density") private var densityPreference = "comfortable"
    @Binding private var selection: SidebarDestination

    public init(selection: Binding<SidebarDestination>) {
        _selection = selection
    }

    public var body: some View {
        List(selection: $selection) {
            Section("资源") {
                sidebarRow(.projects)
            }
            Section("当前项目") {
                sidebarRow(.workspace)
                sidebarRow(.projectSettings)
            }
            Section("支持") {
                sidebarRow(.logs)
                sidebarRow(.help)
            }
        }
        .listStyle(.sidebar)
        // Branding lives outside the source list so it never becomes a
        // selectable route or paints over the system sidebar material.
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 10) {
                // Use the running app's icon so sidebar branding follows the
                // packaged icon without duplicating or tinting its artwork.
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("SlateSync").font(.headline)
                    Text("场记整理工作台").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(density.panelPadding)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 12) {
                SettingsLink {
                    Label("全局设置", systemImage: "gearshape")
                }
                .buttonStyle(.borderless)
                Spacer(minLength: 8)
                // Persistent appearance/density toggles (design 2026-09-14):
                // icon buttons with full labels, shortcuts to the same
                // preference the Settings scene owns.
                Button(action: cycleAppearance) {
                    Image(systemName: appearanceSymbol)
                        .frame(width: 20)
                }
                .buttonStyle(.borderless)
                .help("外观：\(appearanceTitle)")
                .accessibilityLabel("外观：\(appearanceTitle)")
                .accessibilityIdentifier("sidebar.appearance")
                Button {
                    densityPreference = densityPreference == "compact" ? "comfortable" : "compact"
                } label: {
                    Image(systemName: densityPreference == "compact"
                        ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                        .frame(width: 20)
                }
                .buttonStyle(.borderless)
                .help("界面密度：\(densityPreference == "compact" ? "紧凑" : "舒适")")
                .accessibilityLabel("界面密度：\(densityPreference == "compact" ? "紧凑" : "舒适")")
                .accessibilityIdentifier("sidebar.density")
            }
            .padding(density.panelPadding)
        }
        .navigationTitle("SlateSync")
        // Navigation icons stay neutral; the amber accent is reserved for the
        // primary action, focus and live-recognition signals (DESIGN.md).
        .tint(Color.secondary)
        .accessibilityIdentifier("sidebar")
    }

    private func cycleAppearance() {
        appearancePreference = switch appearancePreference {
        case "system": "light"
        case "light": "dark"
        default: "system"
        }
    }

    private var appearanceTitle: String {
        switch appearancePreference {
        case "light": "浅色"
        case "dark": "深色"
        default: "跟随系统"
        }
    }

    private var appearanceSymbol: String {
        switch appearancePreference {
        case "light": "sun.max"
        case "dark": "moon"
        default: "circle.lefthalf.filled"
        }
    }

    private func sidebarRow(_ destination: SidebarDestination) -> some View {
        Label(destination.title, systemImage: destination.symbol)
            // Match task/project rhythm without replacing native selection.
            .padding(.vertical, density == .compact ? 0 : 3)
            .tag(destination)
            .accessibilityIdentifier("sidebar.\(destination.rawValue)")
    }
}
