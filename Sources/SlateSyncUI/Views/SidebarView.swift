import AppKit
import SwiftUI

public struct SidebarView: View {
    @Environment(\.slateSyncDensity) private var density
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
            SettingsLink {
                Label("全局设置", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(density.panelPadding)
        }
        .navigationTitle("SlateSync")
        .accessibilityIdentifier("sidebar")
    }

    private func sidebarRow(_ destination: SidebarDestination) -> some View {
        Label(destination.title, systemImage: destination.symbol)
            // Match task/project rhythm without replacing native selection.
            .padding(.vertical, density == .compact ? 0 : 3)
            .tag(destination)
            .accessibilityIdentifier("sidebar.\(destination.rawValue)")
    }
}
