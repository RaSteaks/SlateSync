import SwiftUI
import SlateSyncPersistence

public struct SettingsRootView: View {
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("density") private var density = "comfortable"
    @State private var runtimeModel: SlateSyncRuntimeModel?

    public init(runtimeModel: SlateSyncRuntimeModel? = nil) {
        _runtimeModel = State(initialValue: runtimeModel)
    }

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

            recognitionStatus
            .tabItem { Label("识别", systemImage: "viewfinder") }
        }
        .padding()
        .frame(width: 560, height: 360)
        .task {
            await runtimeModel?.bootstrap()
        }
    }

    @ViewBuilder
    private var recognitionStatus: some View {
        if let runtimeModel {
            if let snapshot = runtimeModel.snapshot {
                Form {
                    Section("原生启动状态") {
                        LabeledContent("配置解析", value: "\(snapshot.configuration.values.values.count) 项")
                        LabeledContent("全局配置版本", value: "\(snapshot.globalConfigVersion)")
                        LabeledContent(
                            ".env",
                            value: snapshot.environmentFileLoaded ? "已加载" : "未加载或使用默认值"
                        )
                    }
                    Section("旧凭据迁移") {
                        LabeledContent("状态", value: migrationStatus(snapshot.migration.status))
                        if let errorMessage = snapshot.migration.errorMessage {
                            Text(errorMessage)
                                .foregroundStyle(.secondary)
                        }
                        if snapshot.migration.status == .failed {
                            Button("重试旧凭据迁移") {
                                Task { await runtimeModel.retryLegacyMigration() }
                            }
                            .disabled(runtimeModel.isBootstrapping)
                        }
                    }
                }
                .formStyle(.grouped)
            } else {
                ContentUnavailableView(
                    "正在加载识别服务",
                    systemImage: "hourglass",
                    description: Text("正在读取配置并检查旧凭据迁移状态。")
                )
            }
        } else {
            ContentUnavailableView(
                "识别服务",
                systemImage: "sparkles.rectangle.stack",
                description: Text("Provider、模型和 OCR 编辑界面将在后续迁移阶段接入。")
            )
        }
    }

    private func migrationStatus(_ status: SlateSyncRuntimeMigrationStatus) -> String {
        switch status {
        case .notRun: return "未运行"
        case .sourceMissing: return "未发现旧凭据文件"
        case .noCredentials: return "没有可迁移凭据"
        case .migrated: return "迁移完成"
        case .failed: return "迁移失败（源文件已保留）"
    }
}
}
