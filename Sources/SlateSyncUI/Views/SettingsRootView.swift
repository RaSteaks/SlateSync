import SwiftUI

public struct SettingsRootView: View {
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("density") private var density = "comfortable"

    public init() {}

    public var body: some View {
        TabView {
            Form {
                Picker("外观", selection: $appearance) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
                Picker("界面密度", selection: $density) {
                    Text("舒适").tag("comfortable")
                    Text("紧凑").tag("compact")
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("通用", systemImage: "gearshape") }

            ContentUnavailableView(
                "识别服务",
                systemImage: "sparkles.rectangle.stack",
                description: Text("Provider、模型和 OCR 设置将在对应迁移阶段接入。")
            )
            .tabItem { Label("识别", systemImage: "viewfinder") }
        }
        .padding()
        .frame(width: 560, height: 360)
    }
}
