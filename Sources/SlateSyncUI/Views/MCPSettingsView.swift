import AppKit
import SwiftUI

/// Service controls and offline setup share one form. Registration is an
/// explicit client action; copying remains an independent clipboard operation.
struct MCPSettingsView: View {
    let navigation: SettingsNavigationModel
    var service: MCPSettingsModel?
    @State private var copyOperation: OperationState = .idle
    // One-click setup keeps the long manual fallback guide collapsed initially.
    @State private var showsGuide: Bool

    init(navigation: SettingsNavigationModel, service: MCPSettingsModel? = nil) {
        self.navigation = navigation
        self.service = service
        _showsGuide = State(initialValue: service == nil)
    }

    var body: some View {
        Form {
            Section(L10n.tr("MCP 本机接入")) {
                Text(L10n.tr("通过 MCP，让支持该协议的 AI 客户端调用 SlateSync 的识别、元数据扫描和 CSV 回填能力。"))
                LabeledContent(L10n.tr("连接方式"), value: "stdio")
                LabeledContent(L10n.tr("协议版本"), value: "2025-11-25")
                Label(L10n.tr("独立组件 · 支持一键构建并启动"), systemImage: "shippingbox")
                    .font(.callout).foregroundStyle(.secondary)
                Text(L10n.tr("点击“一键启动 MCP”自动准备并启动组件；也可使用客户端独立管理的 stdio 接入。"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let service {
                MCPServiceSettingsSection(model: service)
                if service.hasClientConfiguration {
                    Section(L10n.tr("托管连接")) {
                        codeExample(service.clientConfiguration, copyTitle: L10n.tr("复制托管配置"), identifier: "copyManagedConfiguration", hasPlaceholders: false)
                    }
                }
            }

            // Service controls stay on top; the long setup guide folds away.
            Section {
                Button {
                    showsGuide.toggle()
                } label: {
                    HStack {
                        Label(L10n.tr("设置指南"), systemImage: showsGuide ? "chevron.down" : "chevron.right")
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(showsGuide ? L10n.tr("已展开") : L10n.tr("已收起"))
                .accessibilityIdentifier("settings.mcp.guide.toggle")
            } footer: {
                Text(L10n.tr("构建组件、客户端配置、可调用工具和常见问题。"))
            }

            if showsGuide { guideSections }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("settings.mcp.guide")
        .safeAreaInset(edge: .bottom) {
            if case .succeeded(let message) = copyOperation {
                SlateStatusBar(message, tone: .success)
            } else if case .failed(let error) = copyOperation {
                SlateStatusBar(error.message, tone: .error)
            }
        }
    }

    /// Build, client, image-recognition, workflow and FAQ sections. Numbered
    /// steps run 1–3 in reading order.
    @ViewBuilder private var guideSections: some View {
        Group {
            Section(L10n.tr("1. 构建 MCP 组件")) {
                Text(L10n.tr("准备项目要求的 Xcode / Swift 工具链，在终端进入 SlateSync 源码目录并执行构建。首次构建会下载依赖。"))
                codeExample(MCPSettingsGuide.buildCommand, copyTitle: L10n.tr("复制构建命令"), identifier: "copyBuildCommand")
                Text(L10n.tr("将 /absolute/path/SlateSync-Swift 替换为实际源码路径。构建完成后保留生成的可执行文件和资源目录，启动入口为 script/run_mcp.sh。"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(L10n.tr("2. 客户端独立启动（可选）")) {
                // Keep the legacy direct mode explicit: those processes are
                // client-owned and cannot be stopped by the app's service toggle.
                Text(L10n.tr("以下配置由客户端独立管理进程，不受自动启停开关控制；使用托管服务时，请复制上方“托管连接”。"))
                    .font(.caption).foregroundStyle(.secondary)
                Text(L10n.tr("在客户端的 MCP 配置中添加以下条目。替换源码、素材和导出目录这三处绝对路径，然后重新连接服务。"))
                codeExample(MCPSettingsGuide.clientConfiguration, copyTitle: L10n.tr("复制配置示例"), identifier: "copyConfiguration")
                Text(L10n.tr("此示例启用本地 CSV 和元数据工具。--allow-directory 可重复添加；输入、扫描和导出路径都必须位于授权目录内。"))
                    .font(.caption).foregroundStyle(.secondary)
                Text(L10n.tr("客户端须支持 2025-11-25 初始化协议；本服务使用本机标准输入输出通信，无需填写 HTTP 地址或端口。"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(L10n.tr("3. 可选：启用图片识别")) {
                Text(L10n.tr("使用托管服务时，先停止服务，再开启“允许模型请求”并重新启动。"))
                Text(L10n.tr("先在模型服务设置中配置并验证模型，再在客户端配置的 args 数组中加入 --allow-model-requests。"))
                Button(L10n.tr("打开模型服务设置"), systemImage: "slider.horizontal.3") {
                    navigation.navigate(to: .providers)
                }
                .accessibilityIdentifier("settings.mcp.openProviders")
                Text(L10n.tr("开启后，识别会将页面图片、OCR 文字和补充提示发送给所选模型服务，可能产生 API 费用。未添加该参数时，模型请求保持禁用。"))
                    .font(.callout)
                Text(L10n.tr("无需把 API Key 写入 MCP 配置。服务读取本机 SlateSync 模型设置；修改模型设置后，请重启 MCP 连接。"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(L10n.tr("使用流程与功能")) {
                Text(L10n.tr("识别场记图片或导入场记 CSV → 可选扫描素材元数据 → 预览回填 → 校对告警 → 导出到新文件。"))
                DisclosureGroup(L10n.tr("查看 6 个可调用工具")) {
                    tool("slatesync_list_models", L10n.tr("查看本机已配置的模型目录，不向服务商发起查询。"))
                    tool("slatesync_recognize", L10n.tr("识别 PDF 或图片，返回场、镜、次和复核提示；需要允许模型请求。"))
                    tool("slatesync_import_slate_csv", L10n.tr("从 UTF-8 场记 CSV 生成识别记录，全程本地处理。"))
                    tool("slatesync_scan_metadata", L10n.tr("按 Resolve CSV 素材编号扫描 slate.txt，读取帧率、日期和缺失项。"))
                    tool("slatesync_preview_merge", L10n.tr("预览匹配、冲突和字段变化，不写入文件。"))
                    tool("slatesync_export_csv", L10n.tr("导出完整回填 CSV，只创建新文件，不覆盖现有文件。"))
                }
                Text(L10n.tr("预览有待核对项时，导出返回 MCP_REVIEW_REQUIRED。检查后可明确传入 allowWarnings: true；这不会绕过记录完整性校验。"))
                    .font(.caption).foregroundStyle(.secondary)
                Text(L10n.tr("当前 MCP 处理单次输入，不读取当前 GUI 任务，也不修改项目库或保存场记结构 Profile。"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(L10n.tr("常见问题与参数")) {
                DisclosureGroup(L10n.tr("客户端找不到启动程序")) {
                    Text(L10n.tr("先运行构建命令，再检查 command 是否为 script/run_mcp.sh 的实际绝对路径。移动源码目录后应重新构建，并更新客户端路径。"))
                }
                DisclosureGroup(L10n.tr("提示目录未授权或输出文件已存在")) {
                    Text(L10n.tr("用 --allow-directory 添加所需的素材或导出目录，然后重连。MCP 不覆盖已有文件，请为输出选择一个新文件名。"))
                }
                DisclosureGroup(L10n.tr("需要指定设置或 PaddleOCR 目录")) {
                    Text(L10n.tr("--settings-directory 指定本机设置和凭据根目录，适用于隔离配置或不同安装环境。--paddle-resources 指定包含 paddleocr_runner.py 的可信目录；仓库启动脚本已自动设置此参数。"))
                }
                DisclosureGroup(L10n.tr("输入限制与更多说明")) {
                    Text(L10n.tr("PDF / 图片最多 20 MiB、20 页；CSV 最多 64 MiB。预览默认返回每类结果的前 50 项，可用 offset / limit 分页，limit 最大为 200；导出始终包含完整表格。"))
                    Text(L10n.tr("默认支持 Kinefinity slate.txt。详细工具参数可在客户端查看 tools/list；源码中的 docs/mcp.md 提供完整接入说明。"))
                }
            }
        }
    }

    private func codeExample(_ value: String, copyTitle: String, identifier: String, hasPlaceholders: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Wrap long paths inside the form's single scrolling surface;
            // copy always uses the unchanged source, including JSON newlines.
            Text(verbatim: value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copyTitle, systemImage: "doc.on.doc") {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                if pasteboard.setString(value, forType: .string) {
                    copyOperation = .succeeded(message: hasPlaceholders ? L10n.tr("已复制。请替换示例中的绝对路径。") : L10n.tr("已复制托管配置，请添加到 MCP 客户端。"))
                } else {
                    copyOperation = .failed(.init(code: "CLIPBOARD_WRITE",
                        message: L10n.tr("无法写入剪贴板，请选择上方文本后手动复制。")))
                }
            }
            .accessibilityIdentifier("settings.mcp." + identifier)
        }
        .padding(.vertical, 4)
    }

    private func tool(_ name: String, _ description: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: name).font(.caption.monospaced()).textSelection(.enabled)
            Text(description).font(.callout).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 4)
    }
}

/// Copyable templates intentionally use placeholders, never developer-machine
/// paths or API keys. The initial configuration permits local tools only.
enum MCPSettingsGuide {
    static let buildCommand = """
    cd "/absolute/path/SlateSync-Swift"
    ./script/build_mcp.sh
    """

    static let clientConfiguration = """
    {
      "mcpServers": {
        "slatesync": {
          "command": "/absolute/path/SlateSync-Swift/script/run_mcp.sh",
          "args": [
            "--allow-directory", "/absolute/path/shoot",
            "--allow-directory", "/absolute/path/exports"
          ]
        }
      }
    }
    """
}
