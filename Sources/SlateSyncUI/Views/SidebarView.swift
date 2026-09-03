import SwiftUI

public struct SidebarView: View {
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
        .navigationTitle("SlateSync")
        .accessibilityIdentifier("sidebar")
    }

    private func sidebarRow(_ destination: SidebarDestination) -> some View {
        Label(destination.title, systemImage: destination.symbol)
            .tag(destination)
            .accessibilityIdentifier("sidebar.\(destination.rawValue)")
    }
}
