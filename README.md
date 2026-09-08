# SlateSync

SlateSync 是用于影视场记识别、项目与任务管理、Resolve CSV 编辑和导出的原生 macOS 应用。

## 环境与运行

- macOS 15.0 或更高版本。
- 开发与测试使用 Xcode 26.3（17C529）、Swift 6.2.4、macOS 26.2 SDK。
- Release 为一个包含 arm64 与 x86_64 的 Universal app。

在仓库根目录执行：

```sh
./script/build_and_run.sh
./script/build_and_run.sh --verify
./script/build_and_run.sh --logs
```

也可以用 Xcode 打开 `SlateSync.xcodeproj`，选择共享 `SlateSync` Scheme，然后使用
Run、Test、Profile 或 Archive。Codex 的 Run 按钮使用同一个开发脚本。

## 验证

```sh
swift test
./script/tests/phase_gate_tests.zsh
./script/phase_gate.sh SM-09
```

正式 Gate 要求干净的已提交工作区。施工诊断可加 `--allow-dirty`，此时结果不可用于批准。
Gate 验证删除前 Git 来源、冻结夹具、原生测试实际执行、界面与性能预算、Universal
Archive、ZIP/DMG 回验，以及 ZIP 中 Release app 的独立 UI 启动和退出重开。
历史迁移阶段的命令应从各自已批准的 Git 提交重放。新 checkout 需要完整 Git 历史；
CI 使用 `fetch-depth: 0`。原始结果位于忽略目录 `.codex/gate-results/`。

## 使用与数据

在项目库中新建项目，打开工作区后新建任务、导入场记素材，选择已配置的 Provider/模型，
或使用本地 CSV 合并。结果可编辑并导出 Resolve CSV。设置通过 ⌘, 打开；帮助和运行日志
可从侧栏访问。保存使用 ⌘S，新建项目使用 ⇧⌘N，新建窗口使用 ⌥⌘N。

机器设置与日志保留在 `~/Library/Application Support/SlateSync/`；默认项目库位于
`~/Library/Application Support/Local SlateSync Library/`，也支持用户选定的项目库。
API key 由 macOS Keychain 保存；不要把 key 写入项目包或提交到仓库。
项目库/项目导入导出格式仍为 v1。备份优先使用应用的导出功能；手工复制数据库前应退出
应用，避免遗漏 WAL 中尚未合并的修改。升级或回退前请保存独立备份。

自动测试只使用临时数据根；手工隔离运行可设置：

```sh
SLATESYNC_TEST_ROOT=/private/tmp/slatesync-manual-test ./script/build_and_run.sh --verify
```

Vision 使用系统能力。PaddleOCR 是可选功能，可在设置中显式安装/检查：固定版本为
paddlepaddle 3.3.1、paddleocr 3.7.0。App 只携带 runner 源码和依赖清单，
不携带 Python、虚拟环境或模型缓存。安装需要用户选择的 Python 环境和网络；自动 Gate
不执行联网安装。真实离线模型推理另需显式提供隔离的 `SM06_PADDLE_RUNTIME_FILE`：

```sh
./script/paddle_offline_check.sh
```

## 本地候选包

```sh
./script/archive_release.sh /private/tmp/SlateSync-release 1.0.0 1
./script/package_release.sh /private/tmp/SlateSync-release/SlateSync.xcarchive/Products/Applications/SlateSync.app /private/tmp/SlateSync-artifacts 1.0.0 1
```

输出必须是仓库外的新目录。ZIP 和 DMG 来自同一 app，附 `SHA256SUMS`、JSON manifest
及中英 release notes。详细步骤见 [发布与支持说明](RELEASE.md)。

当前仅验证 ad-hoc 本地候选包，尚未完成 Developer ID 签名、公证或公开发布。
普通用户分发前需要独立的签名、公证、Gatekeeper 与发布授权验证。

## 结构

- `SlateSyncDomain`：类型、验证、设置和错误合同。
- `SlateSyncPersistence`：SQLite v1、项目包、设置、Keychain 和日志。
- `SlateSyncMedia`：媒体渲染、Vision/Paddle OCR 与资源生命周期。
- `SlateSyncWorkflow`：CSV、场景、Provider、识别与安装编排。
- `SlateSyncUI`：原生窗口、项目库、工作区、CSV、设置、帮助和日志。
- `SlateSyncApp/Resources/PaddleOCR`：唯一 Paddle runner/requirements 来源。

当前方案见 [AGENT.md](AGENT.md)，迁移证据与逐项删除来源见 `.codex/swift-migration/`。
`.codex/refactor/`、`DESIGN.md`、`UX-CONTRACT.md` 是历史设计/兼容审查材料，不参与运行或打包。

## 许可

项目许可见 [LICENSE](LICENSE)。系统 frameworks 与 SQLite 通过 macOS 系统链接；
可选 Paddle Python 依赖由用户安装，其上游许可和 notices 以固定版本分发内容
为准。模型与 Python 环境不包含在本 App 的 ZIP/DMG 中。
