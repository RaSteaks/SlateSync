<div align="center">

# SlateSync

**场记单识别 · 结构校对 · Resolve CSV 回填**

识别 PDF 或图片场记单，复核场、镜、次及条次状态，
再将确认后的结果写回 DaVinci Resolve CSV。

[![Swift](https://img.shields.io/badge/Swift-6.2.4-F05138?logo=swift&logoColor=white)](https://www.swift.org/)
[![Platform](https://img.shields.io/badge/Platform-macOS%2015%2B-111827?logo=apple&logoColor=white)](https://github.com/RaSteaks/SlateSync)
[![Xcode](https://img.shields.io/badge/Xcode-26.3-147EFB?logo=xcode&logoColor=white)](https://developer.apple.com/xcode/)
[![Universal](https://img.shields.io/badge/Build-arm64%20%2B%20x86__64-2563eb)](https://github.com/RaSteaks/SlateSync)
[![License](https://img.shields.io/badge/License-MIT-2563eb)](./LICENSE)

<br />

[快速开始](#快速开始) · [项目包](#项目包导入与导出) · [工作流](#工作流) · [架构](#架构) · [开发与验证](#开发与验证)

</div>

---

## 一眼了解

| 输入 | 处理 | 输出 |
| --- | --- | --- |
| PDF、JPEG、PNG、WebP 场记单 | 本地逐页栅格化、OCR evidence、视觉模型识别、字段校验、版式 Profile 复用 | 保留原格式的 Resolve CSV |
| Resolve CSV、素材目录 | 条号对账、场镜次序检查、`slate.txt` 元数据读取 | 可预览、可校对、可导出的回填结果 |
| 项目库或项目包 | SQLite v1 校验、原子传输、导入导出与关闭重开回归 | 可迁移的项目与项目库数据 |

> [!NOTE]
> SlateSync 当前是原生 Swift/SwiftUI macOS 应用，不再依赖 Electron、Node.js 或 npm 运行时。
> 原生迁移已在本地 ad-hoc 交付范围通过 SM-09 Gate；Developer ID 签名、公证和公开发布仍未配置。

## 核心能力

| 识别与理解 | 校对与回填 | 项目与安全 |
| --- | --- | --- |
| 支持 macOS Vision OCR、可选 PaddleOCR，以及已配置的 OpenAI/兼容视觉模型。 | 导入 Resolve CSV，校验条号、场镜次序和识别完整性，确认后再导出。 | Project Library 使用 SQLite 保存项目、任务、诊断和场记结构 Profile。 |
| 根据 OCR 表头、坐标和页面版式学习并复用场记结构 Profile。 | 读取素材目录中的 `slate.txt`，补充 `Camera FPS` 和 `Shoot Day`。 | 项目库和项目包执行路径边界、符号链接和版本校验；API Key 使用 macOS Keychain。 |
| PDF 先在本地逐页准备，模型请求使用页面图片与 OCR evidence。 | 保留原 CSV 的编码、换行和未匹配字段，仅更新匹配到的字段。 | 所有自动测试使用隔离临时数据，不触碰用户项目库、日志或 Keychain。 |

## 快速开始

### 1. 环境要求

- macOS 15.0 或更高版本。
- Xcode 26.3（17C529）。
- Swift 6.2.4、macOS 26.2 SDK。
- 当前 Release 目标为 arm64 与 x86_64 的 Universal app。

项目不需要安装 Node.js、npm 或 Electron 依赖。在仓库根目录执行：

```sh
./script/build_and_run.sh
```

常用启动选项：

```sh
./script/build_and_run.sh --release       # 构建并启动 Release
./script/build_and_run.sh --verify        # 启动后验证本次构建的进程
./script/build_and_run.sh --logs          # 启动并输出 SlateSync 日志
./script/build_and_run.sh --telemetry     # 启动并输出结构化遥测日志
./script/build_and_run.sh --background    # 后台启动
```

也可以用 Xcode 打开 `SlateSync.xcodeproj`，选择共享 `SlateSync` Scheme，然后使用 Run、Test、
Profile 或 Archive。开发脚本和 Xcode 使用相同的工程配置。

### 2. 隔离运行

手工验证时可以指定独立数据根，避免读写默认的 Application Support 和项目库：

```sh
SLATESYNC_TEST_ROOT=/private/tmp/slatesync-manual-test ./script/build_and_run.sh --verify
```

## 项目包导入与导出

在项目库或工作区的项目设置中，可以导入、导出独立项目包；项目库页面也支持整个 Project
Library 的导入、导出、改名和迁移。导入会创建新的项目 ID，原项目不会被覆盖；任务、诊断证据、
场记结构 Profile、设置、时间戳以及任务中保存的图片和 CSV 数据会随项目保留。

v1 项目包使用目录格式而不是 ZIP，结构固定为：

```text
<项目名>.slatesync-project/
├── slatesync-project.json
├── project.json
├── project.sqlite
├── tasks/*.json
└── diagnostics/*.json
```

项目库导入/导出不包含全局配置、API Key、OCR 环境与路径、日志或项目库索引。传输前会等待正在
进行的保存和项目写入；数据通过临时目录、SQLite online backup 和原子重命名完成。包校验会拒绝
符号链接、非法未来版本、同路径、嵌套路径和已存在目标。

备份优先使用应用的导出功能。手工复制 SQLite 数据库前应退出应用，避免遗漏 WAL 中尚未合并的
修改；升级或回退前请保存独立备份。

## 工作流

```text
导入场记单
    ↓
PDF 逐页栅格化 → Vision/PaddleOCR → OCR evidence + 页面图片 → 视觉模型 → 字段归一化与版式匹配
    ↓
载入 Resolve CSV + 可选扫描 slate.txt
    ↓
条号对账 / 场镜次序检查 / 完整性告警
    ↓
回填预览 → 人工校对 → 导出 CSV
```

| 阶段 | SlateSync 会做什么 |
| --- | --- |
| 识别 | 本地准备 PDF 页面，提取文字、置信度和坐标，再由视觉模型抽取场、镜、次和条次状态。 |
| 学习 | 从 OCR 表头、坐标和版式生成场记结构 Profile，并在相似任务中复用。 |
| 对账 | 载入 Resolve CSV，检查条号缺失、场镜次序异常和识别完整性。 |
| 回填 | 只更新匹配到的素材与允许写入的字段，保留原 CSV 的编码、换行和其他内容。 |

### 支持的识别方式

| 方式 | 位置 | 适合场景 |
| --- | --- | --- |
| macOS Vision OCR | 本地 | 基础文字与坐标识别，无需额外 OCR 安装 |
| PaddleOCR | 本地，可选安装 | 需要额外 OCR 引擎或本地处理能力 |
| OpenAI / OpenAI 兼容视觉接口 | 按设置配置 | 复杂版式、中文或手写内容的视觉理解 |

### Resolve 字段回填

| Resolve 字段 | 数据来源 |
| --- | --- |
| `Scene` | 场记单中的场次 |
| `Shot` | 场记单中的镜 |
| `Take` | 场记单中的次 |
| `Comments` | 按设置写入过条、保条标记；其他情况为空 |
| `Camera FPS` | 素材目录 `slate.txt` 的 `Sensor FPS` |
| `Shoot Day` | 素材目录 `slate.txt` 的 `Shot Date` |

字段无法确认时不会被强行写入，必须人工校对。合并导出不会因为单纯的位宽规范化而掩盖没有
匹配到完整素材记录的情况。

## 架构

```text
SlateSyncApp（SwiftUI 应用入口）
  └─ SlateSyncUI
      └─ SlateSyncWorkflow
          ├─ SlateSyncMedia
          ├─ SlateSyncPersistence
          └─ SlateSyncDomain

SlateSyncApp/Resources/PaddleOCR
  └─ runner 源码与固定依赖清单
```

- `SlateSyncDomain`：领域类型、验证、设置、Provider、OCR、识别和错误合同。
- `SlateSyncPersistence`：SQLite v1、项目包、Project Library、设置、Keychain 和日志。
- `SlateSyncMedia`：PDF/图片准备、Vision/Paddle OCR、OCR 进程与资源生命周期。
- `SlateSyncWorkflow`：CSV、场景、Provider、识别、版式 Profile 和安装编排。
- `SlateSyncUI`：原生窗口、项目库、工作区、CSV、设置、帮助和日志界面。
- `SlateSyncApp/Resources/PaddleOCR`：唯一的 Paddle runner 与 requirements 来源。
- `Tests`、`SlateSyncTests`、`SlateSyncUITests`：SwiftPM 单元/合同测试与 Xcode UI 验收。

业务状态和文件/进程生命周期由 Swift concurrency、actor 和隔离的数据服务管理；应用不会
携带旧 Electron/Node 运行时。历史迁移材料保存在 `.codex/refactor/` 和
`.codex/swift-migration/`，不参与运行或打包。

## 配置

### 全局设置

应用内的“全局设置”用于管理 Provider、Base URL、模型、请求并发/超时、Vision OCR、PaddleOCR
和模型缓存路径。自定义 OpenAI 兼容接口支持多个连接和手动模型 ID；API Key 由 macOS Keychain
保存，不写入项目包、项目库或 Git。

机器设置、非敏感配置和日志位于：

```text
~/Library/Application Support/SlateSync/
```

默认项目库位于：

```text
~/Library/Application Support/Local SlateSync Library/
```

也可以在应用中选择其他项目库位置。全局设置按机器用户保存，不随项目包导入/导出。

### PaddleOCR

PaddleOCR 是可选功能。App 只携带 runner 源码和固定依赖清单，不携带 Python、虚拟环境或模型缓存。
安装需要用户选择的 Python 环境和网络；当前固定版本为 `paddlepaddle==3.3.1` 与
`paddleocr==3.7.0`。自动 Gate 不执行联网安装。

真实离线模型推理需要显式提供隔离的 `SM06_PADDLE_RUNTIME_FILE`：

```sh
./script/paddle_offline_check.sh
```

## 数据与安全

- Project Library 和每个项目使用 SQLite v1；迁移和导入会执行版本、路径和内容校验。
- 项目库边界拒绝越界路径和符号链接，文件写入使用临时文件与原子替换。
- API Key 只由原生应用的数据服务读取，UI 不直接访问凭据或任意文件系统能力。
- PDF 原始字节只用于本地逐页栅格化；模型请求发送页面图片与本地 OCR evidence，不发送原始 PDF。
- OCR 引擎不可用、超时或失败时会按设置降级为页面图片识别；设置为必需时则停止识别并报告错误。
- 自动测试只使用临时数据根，不应指向个人 Project Library、日志或 Keychain。
- 不要将用户项目库、`data/`、凭据、模型缓存或本地安装环境提交到 Git。

## 开发与验证

SwiftPM 基线：

```sh
swift build
swift test
```

项目合同和发布链路测试：

```sh
./script/tests/phase_gate_tests.zsh
./script/tests/release_pipeline_tests.zsh
python3 script/tests/sm09_coverage_tests.py
python3 script/tests/sm09_inventory_tests.py
```

运行当前原生迁移的完整 Gate：

```sh
./script/phase_gate.sh SM-09
```

正式 Gate 要求干净的已提交工作区。施工诊断可加 `--allow-dirty`，但该结果不可用于批准。
Gate 会验证原生项目布局、Swift/Xcode 构建与测试、删除来源和冻结夹具、Release/Archive、
Universal bundle、ZIP/DMG 回验、打包后的 UI 启动与退出重开，以及 CSV 性能预算。

当前本地基线为：Swift 测试 320 项执行、1 项按设计跳过、0 失败；SM-09 Gate 27/27 通过并
标记 `approvable=true`。严格的 `-warnings-as-errors` 构建仍有一处 Swift 弃用警告待清理，
不影响上述常规 Gate 结果：

```sh
swift build -Xswiftc -warnings-as-errors
```

原始 Gate 结果写入忽略目录 `.codex/gate-results/`；迁移状态、审查摘要和逐项来源记录在
`.codex/swift-migration/`。

## 构建与打包

### 构建 Release 与归档

```sh
./script/archive_release.sh /private/tmp/SlateSync-release 1.0.0 1
```

脚本会在仓库外的新目录中生成 Universal `SlateSync.xcarchive`，并验证最低 macOS 版本、
架构、资源、签名、hardened runtime 和依赖。版本号和 build number 是显式输入，不会改写
已跟踪的工程文件。

### 生成 ZIP 与 DMG

```sh
./script/package_release.sh \
  /private/tmp/SlateSync-release/SlateSync.xcarchive/Products/Applications/SlateSync.app \
  /private/tmp/SlateSync-artifacts 1.0.0 1
```

ZIP 和 DMG 来自同一个已审计的 app，并会经过解压、只读挂载、签名和 bundle lineage 回验。输出
包括：

- `SlateSync-<version>-macOS-universal.zip`
- `SlateSync-<version>-macOS-universal.dmg`
- `SHA256SUMS`
- JSON manifest
- 中英 release notes

当前只验证 ad-hoc 本地候选包；尚未配置 Developer ID 签名、公证、Gatekeeper 评估或公开发布。
详细说明见 [发布与支持说明](RELEASE.md)。

## 限制与已知边界

- 当前仅支持 macOS 15.0 及以上版本，不提供 Windows 或 Linux 运行时。
- PaddleOCR 需要用户提供 Python 环境和网络安装条件；Python、虚拟环境和模型不包含在 App 中。
- 无法确认的识别字段不会被强行写入，必须人工校对。
- 项目库与项目包当前保持 v1 格式；升级、迁移或回退前应保留独立备份。
- 当前公开分发链路尚未完成 Developer ID 签名、公证和发布授权验证。

## License

[MIT](./LICENSE)
